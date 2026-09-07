/// Switching the radio must leave a *running* node behind.
///
/// Riverpod replaces the controller when the transport changes, and the
/// replacement starts life stopped. If nothing starts it the phone goes
/// silently dead — no engine, no transport, nothing relayed — while the UI
/// still looks perfectly healthy. That failure would only show up with two
/// handsets in hand, which is the worst possible moment to find it.
library;

import 'package:avertis/core/mesh_controller.dart';
import 'package:avertis/core/providers.dart';
import 'package:avertis/data/report_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late ReportDatabase db;

  setUp(() {
    db = ReportDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('the controller starts on the mock radio by default', () {
    expect(container.read(transportModeProvider), TransportMode.mock);
    expect(container.read(meshControllerProvider).mode, TransportMode.mock);
  });

  test('changing the radio builds a different controller', () {
    final before = container.read(meshControllerProvider);
    container.read(transportModeProvider.notifier).state = TransportMode.ble;
    final after = container.read(meshControllerProvider);

    expect(identical(before, after), isFalse,
        reason: 'the transport is chosen at construction, so the controller '
            'must be rebuilt — and therefore restarted');
    expect(after.mode, TransportMode.ble);
  });

  test('the replacement controller arrives stopped', () {
    container.read(meshControllerProvider);
    container.read(transportModeProvider.notifier).state = TransportMode.ble;

    // This is the whole hazard: a fresh controller is not running, and
    // something has to start it.
    expect(container.read(meshControllerProvider).isRunning, isFalse);
  });

  test('start is idempotent, so a redundant restart is harmless', () async {
    final controller = MeshController(database: db);
    await controller.start(nodeId: 'node-test');
    final engine = controller.engine;

    await controller.start(nodeId: 'node-test');
    expect(identical(controller.engine, engine), isTrue,
        reason: 'a second start must not replace a live engine');

    controller.dispose();
  });

  test('a started node reports itself running', () async {
    final controller = MeshController(database: db);
    expect(controller.isRunning, isFalse);

    await controller.start(nodeId: 'node-test');
    expect(controller.isRunning, isTrue);
    expect(controller.engine, isNotNull);

    controller.dispose();
  });

  group('backend configuration', () {
    test('no backend means no gateway client and no sync', () async {
      final controller = MeshController(database: db, apiBase: '');
      await controller.start(nodeId: 'node-test');

      expect(controller.hasBackend, isFalse);
      expect(controller.gateway, isNull);
      // A null result says "there was nowhere to send this" rather than
      // pretending an empty sync succeeded.
      expect(await controller.syncNow(), isNull);

      controller.dispose();
    });

    test('a configured backend produces a gateway client', () async {
      final controller = MeshController(
        database: db,
        apiBase: 'http://127.0.0.1:9',
      );
      await controller.start(nodeId: 'node-test');

      expect(controller.hasBackend, isTrue);
      expect(controller.gateway, isNotNull);

      controller.dispose();
    });
  });
}
