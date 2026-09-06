/// Dart side of the Kotlin BLE peripheral (see
/// android/app/src/main/kotlin/com/avertis/avertis/AvertisBlePeripheral.kt).
///
/// `flutter_blue_plus` implements only the central role — it can scan and
/// connect, but it cannot advertise or host a GATT server. A mesh needs both
/// halves: if no node advertises, no node is ever discovered. This channel
/// supplies the peripheral half on Android, as the project plan anticipated
/// (§13: "add a small Kotlin Android BLE implementation through Platform
/// Channels").
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Why advertising is not running, when it is not.
enum AdvertisingError {
  none,
  bluetoothOff,
  unsupported,
  tooManyAdvertisers,
  internal,
  unavailable,
}

@immutable
class PeripheralState {
  const PeripheralState({
    required this.advertising,
    this.error = AdvertisingError.none,
    this.rawError,
  });

  final bool advertising;
  final AdvertisingError error;
  final String? rawError;

  /// Plain language for the UI. A node that cannot advertise is only half a
  /// mesh node, and the operator should be told rather than left guessing.
  String? get message => switch (error) {
        AdvertisingError.none => null,
        AdvertisingError.bluetoothOff =>
          'Bluetooth is off — other phones cannot discover this one.',
        AdvertisingError.unsupported =>
          'This device cannot advertise over Bluetooth. It can still relay '
              'for phones that can, but it will not be discovered by them.',
        AdvertisingError.tooManyAdvertisers =>
          'Bluetooth advertising slots are exhausted. Close other Bluetooth '
              'apps and restart the mesh.',
        AdvertisingError.internal =>
          'Bluetooth advertising failed to start. Toggling Bluetooth usually '
              'clears this.',
        AdvertisingError.unavailable =>
          'Bluetooth advertising is unavailable on this platform.',
      };

  static const idle = PeripheralState(advertising: false);
}

class BlePeripheral {
  BlePeripheral({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ??
            const MethodChannel('avertis/ble_peripheral'),
        _events = eventChannel ??
            const EventChannel('avertis/ble_peripheral/events');

  final MethodChannel _method;
  final EventChannel _events;

  StreamSubscription<dynamic>? _sub;

  final _payloads =
      StreamController<({String deviceId, Uint8List bytes})>.broadcast();
  final _peerConnected = StreamController<String>.broadcast();
  final _peerDisconnected = StreamController<String>.broadcast();
  final _state = StreamController<PeripheralState>.broadcast();

  Stream<({String deviceId, Uint8List bytes})> get payloads =>
      _payloads.stream;
  Stream<String> get peerConnected => _peerConnected.stream;
  Stream<String> get peerDisconnected => _peerDisconnected.stream;
  Stream<PeripheralState> get stateChanges => _state.stream;

  PeripheralState state = PeripheralState.idle;

  /// Begin advertising and hosting the GATT server.
  ///
  /// Returns false when the platform refused. That is not necessarily fatal —
  /// a node that cannot advertise can still act as a central and reach peers
  /// that can — so the caller decides what to do about it.
  Future<bool> start({
    required String nodeId,
    required String role,
    required double battery,
  }) async {
    _sub ??= _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: (Object error) => _emit(const PeripheralState(
            advertising: false,
            error: AdvertisingError.unavailable,
          )),
        );
    try {
      final ok = await _method.invokeMethod<bool>('start', {
        'nodeId': nodeId,
        'role': role,
        'battery': battery,
      });
      return ok ?? false;
    } on MissingPluginException {
      // Not Android, or the channel is not registered — the app must still
      // run, just without the peripheral half.
      _emit(const PeripheralState(
        advertising: false,
        error: AdvertisingError.unavailable,
      ));
      return false;
    } on PlatformException {
      _emit(const PeripheralState(
        advertising: false,
        error: AdvertisingError.internal,
      ));
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<bool>('stop');
    } on PlatformException {
      // Already stopped.
    } on MissingPluginException {
      // Never started.
    }
    _emit(PeripheralState.idle);
  }

  /// Notify a connected peer. False if it is not connected or not subscribed.
  Future<bool> send(String deviceId, Uint8List bytes) async {
    try {
      final ok = await _method.invokeMethod<bool>('send', {
        'deviceId': deviceId,
        'bytes': bytes,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<List<String>> connectedPeers() async {
    try {
      final peers = await _method.invokeListMethod<String>('connectedPeers');
      return peers ?? const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final event = raw['event'] as String?;
    switch (event) {
      case 'payload':
        final deviceId = raw['deviceId'] as String?;
        final bytes = raw['bytes'];
        if (deviceId != null && bytes is Uint8List) {
          _payloads.add((deviceId: deviceId, bytes: bytes));
        }
      case 'peerConnected':
        final id = raw['deviceId'] as String?;
        if (id != null) _peerConnected.add(id);
      case 'peerDisconnected':
        final id = raw['deviceId'] as String?;
        if (id != null) _peerDisconnected.add(id);
      case 'advertisingState':
        _emit(PeripheralState(
          advertising: raw['advertising'] as bool? ?? false,
          error: _errorFrom(raw['error'] as String?),
          rawError: raw['error'] as String?,
        ));
    }
  }

  static AdvertisingError _errorFrom(String? raw) => switch (raw) {
        null => AdvertisingError.none,
        'BLUETOOTH_OFF' => AdvertisingError.bluetoothOff,
        'ADVERTISING_UNSUPPORTED' ||
        'FEATURE_UNSUPPORTED' ||
        'NO_ADVERTISER' =>
          AdvertisingError.unsupported,
        'TOO_MANY_ADVERTISERS' => AdvertisingError.tooManyAdvertisers,
        _ => AdvertisingError.internal,
      };

  void _emit(PeripheralState next) {
    state = next;
    if (!_state.isClosed) _state.add(next);
  }

  Future<void> dispose() async {
    await stop();
    await _sub?.cancel();
    await _payloads.close();
    await _peerConnected.close();
    await _peerDisconnected.close();
    await _state.close();
  }
}
