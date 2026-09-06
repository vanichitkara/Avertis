/// The foreground service is what keeps this phone relaying for other people
/// once the screen goes off. Its failures must degrade, never crash, and never
/// be reported as success — the home screen's warning depends on that.
library;

import 'package:avertis/services/mesh_service_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/mesh_service');
  late List<MethodCall> calls;

  void mock(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() => calls = []);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a successful start is reported as running', () async {
    mock((_) async => true);
    final service = MeshServiceChannel(channel: channel);

    expect(await service.start(), isTrue);
    expect(service.isRunning, isTrue);
    expect(calls.single.method, 'start');
  });

  test('a refused start is reported as not running', () async {
    // Android refuses a connectedDevice foreground service without a
    // Bluetooth runtime permission. Claiming success here would make the UI
    // promise background relaying that is not happening.
    mock((_) async => throw PlatformException(code: 'DENIED'));
    final service = MeshServiceChannel(channel: channel);

    expect(await service.start(), isFalse);
    expect(service.isRunning, isFalse);
  });

  test('a missing platform channel is survivable', () async {
    final service = MeshServiceChannel(
      channel: const MethodChannel('test/no_such_channel'),
    );
    expect(await service.start(), isFalse);
    expect(service.isRunning, isFalse);
    // Must not throw.
    await service.update(neighbors: 1, queued: 2, custody: 3);
    await service.stop();
  });

  test('updates carry the live mesh figures', () async {
    mock((_) async => true);
    final service = MeshServiceChannel(channel: channel);
    await service.start();
    await service.update(neighbors: 4, queued: 12, custody: 2);

    expect(calls.last.method, 'update');
    expect(calls.last.arguments,
        {'neighbors': 4, 'queued': 12, 'custody': 2});
  });

  test('updates are suppressed while the service is not running', () async {
    mock((_) async => throw PlatformException(code: 'DENIED'));
    final service = MeshServiceChannel(channel: channel);
    await service.start();
    calls.clear();

    await service.update(neighbors: 4, queued: 1, custody: 0);
    expect(calls, isEmpty,
        reason: 'nothing should be pushed to a service that never started');
  });

  test('a failing update never propagates to the mesh', () async {
    mock((call) async {
      if (call.method == 'update') throw PlatformException(code: 'BOOM');
      return true;
    });
    final service = MeshServiceChannel(channel: channel);
    await service.start();

    // A notification problem must never disturb packet forwarding.
    await service.update(neighbors: 1, queued: 0, custody: 0);
    expect(service.isRunning, isTrue);
  });

  test('stop clears the running flag even when the platform errors', () async {
    mock((call) async {
      if (call.method == 'stop') throw PlatformException(code: 'BOOM');
      return true;
    });
    final service = MeshServiceChannel(channel: channel);
    await service.start();
    await service.stop();
    expect(service.isRunning, isFalse);
  });
}
