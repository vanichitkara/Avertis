/// Runtime permissions, requested honestly and only when they are needed.
///
/// The app is deliberately usable before any of these are granted — it opens
/// straight to a working SOS button. Each permission buys a specific
/// capability, and when one is missing the UI says which capability is lost
/// rather than nagging or pretending everything is fine.
library;

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// What the app can actually do right now.
class MeshPermissions {
  const MeshPermissions({
    required this.bluetooth,
    required this.location,
    required this.notifications,
  });

  /// Scan, advertise and connect — without this there is no mesh at all.
  final bool bluetooth;

  /// Attach a position to reports. Without it responders get no coordinates.
  final bool location;

  /// Required for the ongoing notification, and therefore for the foreground
  /// service that keeps relaying with the screen off.
  final bool notifications;

  /// Android refuses a `connectedDevice` foreground service unless a
  /// Bluetooth runtime permission is held, so background relaying needs both.
  bool get canRelayInBackground => bluetooth && notifications;

  static const none = MeshPermissions(
    bluetooth: false,
    location: false,
    notifications: false,
  );
}

class PermissionsService {
  Future<MeshPermissions> request() async {
    if (!Platform.isAndroid) {
      return const MeshPermissions(
        bluetooth: true,
        location: true,
        notifications: true,
      );
    }

    // Android 12+ splits Bluetooth into scan/advertise/connect. On older
    // versions these resolve to the legacy permission and are granted at
    // install time, so requesting them is harmless either way.
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();

    bool granted(Permission p) => results[p]?.isGranted ?? false;

    return MeshPermissions(
      // Scan and connect are the minimum to participate. Advertise is what
      // makes us discoverable; without it we are only half a node, which the
      // BLE transport reports separately.
      bluetooth: granted(Permission.bluetoothScan) &&
          granted(Permission.bluetoothConnect),
      location: granted(Permission.locationWhenInUse),
      notifications: granted(Permission.notification),
    );
  }

  Future<MeshPermissions> check() async {
    if (!Platform.isAndroid) {
      return const MeshPermissions(
        bluetooth: true,
        location: true,
        notifications: true,
      );
    }
    return MeshPermissions(
      bluetooth: await Permission.bluetoothScan.isGranted &&
          await Permission.bluetoothConnect.isGranted,
      location: await Permission.locationWhenInUse.isGranted,
      notifications: await Permission.notification.isGranted,
    );
  }
}
