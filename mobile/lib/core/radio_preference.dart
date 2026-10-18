/// Which radio this phone starts on, and why.
///
/// The app used to begin every launch on the simulated radio. That radio is
/// an in-memory map inside one app process with exactly one node registered
/// — itself — so a phone on it cannot find a peer, ever. It is the right
/// default for an emulator and the wrong one for a handset, and because the
/// choice was never saved, two phones being tested together silently fell
/// back to it on every restart.
///
/// So: remember what the operator picked, and when nobody has picked yet,
/// decide from whether this device actually has a Bluetooth adapter.
library;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mesh_controller.dart';

/// How the starting radio was arrived at. Carried so the mesh screen can
/// say which it was rather than leaving the operator to guess.
enum RadioChoiceOrigin {
  /// Restored from what this phone was last set to.
  remembered,

  /// No stored choice, and this device has a Bluetooth adapter.
  adapterPresent,

  /// No stored choice and no adapter — an emulator, or a device with
  /// Bluetooth hardware missing.
  noAdapter,

  /// The adapter could not be asked. Simulated is the safe answer: it
  /// always starts, where BLE on a device with no radio does not.
  undetermined,
}

class RadioChoice {
  const RadioChoice(this.mode, this.origin);

  final TransportMode mode;
  final RadioChoiceOrigin origin;

  /// One line for the mesh screen, so the default is never mysterious.
  String get explanation {
    switch (origin) {
      case RadioChoiceOrigin.remembered:
        return 'Restored from your last choice on this phone.';
      case RadioChoiceOrigin.adapterPresent:
        return 'Defaulted to Bluetooth because this device has a radio.';
      case RadioChoiceOrigin.noAdapter:
        return 'No Bluetooth adapter on this device, so the simulated '
            'radio is the only one available.';
      case RadioChoiceOrigin.undetermined:
        return 'Could not check for a Bluetooth adapter, so this started '
            'on the simulated radio.';
    }
  }
}

class RadioPreference {
  RadioPreference({Future<bool> Function()? isBluetoothSupported})
      : _isSupported = isBluetoothSupported ?? _defaultIsSupported;

  static const String storageKey = 'avertis.radio_mode';

  final Future<bool> Function() _isSupported;

  static Future<bool> _defaultIsSupported() => FlutterBluePlus.isSupported;

  /// What this phone should start on.
  ///
  /// Never throws. A preference that cannot be read is not a reason to
  /// refuse to start a mesh node, so every failure path still returns a
  /// usable answer and says how it got there.
  Future<RadioChoice> resolve() async {
    final stored = await _read();
    if (stored != null) return RadioChoice(stored, RadioChoiceOrigin.remembered);

    try {
      final supported = await _isSupported();
      return supported
          ? const RadioChoice(TransportMode.ble, RadioChoiceOrigin.adapterPresent)
          : const RadioChoice(TransportMode.mock, RadioChoiceOrigin.noAdapter);
    } catch (_) {
      return const RadioChoice(
          TransportMode.mock, RadioChoiceOrigin.undetermined);
    }
  }

  Future<TransportMode?> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _fromWire(prefs.getString(storageKey));
    } catch (_) {
      // Unreadable preferences mean "no choice yet", not a failure.
      return null;
    }
  }

  /// Remember a deliberate switch. A write that fails costs the memory,
  /// not the switch — the node is already moving to the new radio.
  Future<void> remember(TransportMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, _toWire(mode));
    } catch (_) {
      // Nothing to do about it, and nothing worth blocking the operator for.
    }
  }

  static String _toWire(TransportMode mode) =>
      mode == TransportMode.ble ? 'ble' : 'mock';

  static TransportMode? _fromWire(String? value) {
    switch (value) {
      case 'ble':
        return TransportMode.ble;
      case 'mock':
        return TransportMode.mock;
      default:
        // Includes null, and anything written by a future version.
        return null;
    }
  }
}
