/// Controls the Android foreground service that keeps the mesh relaying while
/// the screen is off.
///
/// Without it, Android suspends the app within minutes of backgrounding and
/// the phone silently stops carrying other people's traffic — while still
/// appearing, to its neighbours, to be a working relay until their beacons
/// time out. A relay that quietly dies is worse than one that was never there.
library;

import 'package:flutter/services.dart';

class MeshServiceChannel {
  MeshServiceChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('avertis/mesh_service');

  final MethodChannel _channel;
  bool _running = false;

  bool get isRunning => _running;

  Future<bool> start() async {
    try {
      await _channel.invokeMethod<bool>('start');
      _running = true;
      return true;
    } on MissingPluginException {
      return false; // not Android — the app still works, foregrounded
    } on PlatformException {
      return false;
    }
  }

  /// Keep the ongoing notification honest about what the mesh is doing.
  Future<void> update({
    required int neighbors,
    required int queued,
    required int custody,
  }) async {
    if (!_running) return;
    try {
      await _channel.invokeMethod<bool>('update', {
        'neighbors': neighbors,
        'queued': queued,
        'custody': custody,
      });
    } on MissingPluginException {
      // Nothing to update.
    } on PlatformException {
      // A failed notification update must never disturb the mesh.
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } on MissingPluginException {
      // Never started.
    } on PlatformException {
      // Already gone.
    }
    _running = false;
  }
}
