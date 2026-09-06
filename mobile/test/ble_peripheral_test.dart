/// The peripheral half is what makes a phone *discoverable*. Without it the
/// mesh never forms, so its failure modes are worth pinning down — especially
/// the ones that are survivable, which must not be reported as fatal.
library;


import 'package:avertis/mesh/transport/ble_peripheral.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('test/ble_peripheral');
  const eventChannel = EventChannel('test/ble_peripheral/events');

  late List<MethodCall> calls;
  late BlePeripheral peripheral;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'start' => true,
        'stop' => true,
        'send' => true,
        'connectedPeers' => <String>['AA:BB', 'CC:DD'],
        _ => null,
      };
    });
    peripheral = BlePeripheral(
      methodChannel: methodChannel,
      eventChannel: eventChannel,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('start passes the identity peers need to score us', () async {
    await peripheral.start(nodeId: 'n7ac20', role: 'RELAY', battery: 0.67);

    expect(calls.single.method, 'start');
    expect(calls.single.arguments, {
      'nodeId': 'n7ac20',
      'role': 'RELAY',
      'battery': 0.67,
    });
  });

  test('send forwards bytes to the named peer', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    expect(await peripheral.send('AA:BB', bytes), isTrue);
    expect(calls.single.arguments, {'deviceId': 'AA:BB', 'bytes': bytes});
  });

  test('connectedPeers round-trips', () async {
    expect(await peripheral.connectedPeers(), ['AA:BB', 'CC:DD']);
  });

  group('failure is reported, not swallowed', () {
    test('a missing platform channel does not throw', () async {
      final orphan = BlePeripheral(
        methodChannel: const MethodChannel('test/does_not_exist'),
        eventChannel: eventChannel,
      );
      expect(await orphan.start(nodeId: 'n1', role: 'SURVIVOR', battery: 1),
          isFalse);
      expect(orphan.state.error, AdvertisingError.unavailable);
      expect(await orphan.send('AA:BB', Uint8List(1)), isFalse);
      expect(await orphan.connectedPeers(), isEmpty);
    });

    test('a platform exception surfaces as an internal error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(code: 'BOOM');
      });
      expect(await peripheral.start(nodeId: 'n1', role: 'SURVIVOR', battery: 1),
          isFalse);
      expect(peripheral.state.error, AdvertisingError.internal);
    });
  });

  group('advertising state messages', () {
    test('every failure has an operator-readable explanation', () {
      for (final error in AdvertisingError.values) {
        final state = PeripheralState(advertising: false, error: error);
        if (error == AdvertisingError.none) {
          expect(state.message, isNull);
        } else {
          expect(state.message, isNotNull,
              reason: '$error must be explainable to the operator');
          expect(state.message, isNot(contains('_')),
              reason: '$error leaks a raw platform code into the UI');
        }
      }
    });

    test('an unsupported radio is described as half-usable, not broken', () {
      const state = PeripheralState(
        advertising: false,
        error: AdvertisingError.unsupported,
      );
      // Such a node can still act as a central and relay for others. Telling
      // the operator it is simply broken would be wrong.
      expect(state.message, contains('still relay'));
    });
  });
}
