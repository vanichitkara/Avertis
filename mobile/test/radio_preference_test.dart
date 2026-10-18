/// Which radio a phone wakes up on.
///
/// The app began every launch on the simulated radio — an in-memory space
/// with one node in it, so a handset on it can never find a peer. The
/// choice was not saved either, so two phones under test fell back to it
/// on every restart and sat there discovering nothing.
library;

import 'package:avertis/core/mesh_controller.dart';
import 'package:avertis/core/radio_preference.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('with no choice stored yet', () {
    test('a device with an adapter starts on Bluetooth', () async {
      final choice = await RadioPreference(
        isBluetoothSupported: () async => true,
      ).resolve();

      expect(choice.mode, TransportMode.ble);
      expect(choice.origin, RadioChoiceOrigin.adapterPresent);
    });

    test('a device without one falls back to simulated', () async {
      final choice = await RadioPreference(
        isBluetoothSupported: () async => false,
      ).resolve();

      expect(choice.mode, TransportMode.mock);
      expect(choice.origin, RadioChoiceOrigin.noAdapter);
    });

    test('an adapter that cannot be asked does not stop the app', () async {
      // BLE on a device with no radio fails to start; simulated always
      // does. When we cannot tell, take the one that runs.
      final choice = await RadioPreference(
        isBluetoothSupported: () async => throw StateError('no platform'),
      ).resolve();

      expect(choice.mode, TransportMode.mock);
      expect(choice.origin, RadioChoiceOrigin.undetermined);
    });
  });

  group('once a choice has been made', () {
    test('Bluetooth is restored on the next launch', () async {
      final pref = RadioPreference(isBluetoothSupported: () async => true);
      await pref.remember(TransportMode.ble);

      final choice = await RadioPreference(
        // Even if the probe would now say otherwise.
        isBluetoothSupported: () async => false,
      ).resolve();

      expect(choice.mode, TransportMode.ble);
      expect(choice.origin, RadioChoiceOrigin.remembered);
    });

    test('simulated is restored too, and not overridden by the adapter',
        () async {
      await RadioPreference().remember(TransportMode.mock);

      final choice = await RadioPreference(
        isBluetoothSupported: () async => true,
      ).resolve();

      expect(choice.mode, TransportMode.mock,
          reason: 'a deliberate choice outranks the default');
      expect(choice.origin, RadioChoiceOrigin.remembered);
    });

    test('switching back is remembered', () async {
      await RadioPreference().remember(TransportMode.ble);
      await RadioPreference().remember(TransportMode.mock);

      final choice = await RadioPreference(
        isBluetoothSupported: () async => true,
      ).resolve();
      expect(choice.mode, TransportMode.mock);
    });
  });

  test('a value this version does not know is treated as no choice', () async {
    SharedPreferences.setMockInitialValues(
        {RadioPreference.storageKey: 'lora'});

    final choice = await RadioPreference(
      isBluetoothSupported: () async => true,
    ).resolve();

    expect(choice.mode, TransportMode.ble);
    expect(choice.origin, RadioChoiceOrigin.adapterPresent);
  });

  test('every outcome explains itself', () {
    for (final origin in RadioChoiceOrigin.values) {
      final text = RadioChoice(TransportMode.mock, origin).explanation;
      expect(text, isNotEmpty);
      expect(text, endsWith('.'),
          reason: 'this goes on screen under the radio switch');
    }
  });
}
