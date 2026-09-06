/// Location acquisition.
///
/// A report without a location is far less useful to a responder, but a
/// *wrong* location is worse than none — so this service never fabricates a
/// position and never reports a stale fix as current. If there is no fix, the
/// UI says so.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../mesh/protocol/packet.dart';

enum LocationAvailability {
  /// A fix has been obtained.
  available,

  /// Permission was denied — we can ask again.
  denied,

  /// Permission was denied permanently; only Settings can change it.
  deniedForever,

  /// Location services are switched off on the device.
  serviceDisabled,

  /// Permission granted but no fix yet.
  waiting,
}

class LocationState {
  const LocationState(this.availability, [this.point, this.fixedAt]);

  final LocationAvailability availability;
  final GeoPoint? point;
  final DateTime? fixedAt;

  bool get hasFix => point != null;

  /// A fix older than two minutes is not "where you are" any more. It is
  /// still sent — it is better than nothing — but it is labelled as stale.
  bool get isStale =>
      fixedAt != null &&
      DateTime.now().difference(fixedAt!) > const Duration(minutes: 2);

  static const unknown = LocationState(LocationAvailability.waiting);
}

class LocationService {
  StreamSubscription<Position>? _sub;
  final _controller = StreamController<LocationState>.broadcast();

  Stream<LocationState> get stream => _controller.stream;
  LocationState current = LocationState.unknown;

  Future<LocationState> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return _emit(const LocationState(LocationAvailability.serviceDisabled));
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return _emit(const LocationState(LocationAvailability.deniedForever));
    }
    if (permission == LocationPermission.denied) {
      return _emit(const LocationState(LocationAvailability.denied));
    }

    _emit(const LocationState(LocationAvailability.waiting));

    // A 10 m filter: enough to keep a moving responder's position useful
    // without waking the GPS for every step, which matters when the phone may
    // need to last days.
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(
      (position) => _emit(LocationState(
        LocationAvailability.available,
        GeoPoint(position.latitude, position.longitude,
            accuracyM: position.accuracy),
        DateTime.now(),
      )),
      onError: (_) => _emit(const LocationState(LocationAvailability.waiting)),
    );

    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && !current.hasFix) {
        _emit(LocationState(
          LocationAvailability.available,
          GeoPoint(last.latitude, last.longitude, accuracyM: last.accuracy),
          last.timestamp,
        ));
      }
    } on Exception {
      // No last-known fix is not an error; the stream will provide one.
    }
    return current;
  }

  LocationState _emit(LocationState state) {
    current = state;
    if (!_controller.isClosed) _controller.add(state);
    return state;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
