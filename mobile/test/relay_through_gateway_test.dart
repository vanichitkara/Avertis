/// One phone has no internet, another does. The report must still get out.
///
/// This is the whole store-and-forward premise, and it did not work on two
/// real handsets. Reports are addressed to "gateway", and only a node whose
/// role is GATEWAY takes delivery of one or holds it for syncing. Every
/// phone starts as a survivor, so a neighbour's report was relayed straight
/// past the handset that had working internet and never picked up.
///
/// The fix is in [MeshController]: a phone that can reach the backend
/// promotes itself to gateway, and hands the role back when it cannot. These
/// tests pin the engine behaviour that promotion turns on and off, since
/// that is where the report is accepted or lost.
library;

import 'package:avertis/mesh/mesh_engine.dart';
import 'package:avertis/mesh/mesh_events.dart';
import 'package:avertis/mesh/node_state.dart';
import 'package:avertis/mesh/protocol/packet.dart';
import 'package:avertis/mesh/transport/mock_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two or three phones on a controllable clock, so beacons and custody
/// retries happen without waiting in real time.
class Handsets {
  Handsets() : space = MockRadioSpace(rangeM: 120, latency: Duration.zero);

  final MockRadioSpace space;
  final MeshEventBus bus = MeshEventBus();
  final Map<String, MeshEngine> engines = {};
  DateTime now = DateTime.utc(2026, 10, 18, 9, 30);

  Future<MeshEngine> add(String id, {double x = 0}) async {
    final transport = MockMeshTransport(id, space);
    space.register(transport, x: x, y: 0);
    final engine = MeshEngine(
      state: NodeState(nodeId: id, role: NodeRole.survivor),
      transport: transport,
      bus: bus,
      clock: () => now,
    );
    engines[id] = engine;
    await transport.start();
    transport.incoming.listen((m) => engine.onPacket(m.from, m.packet));
    transport.peerLost.listen((_) => engine.tick());
    return engine;
  }

  Future<void> advance(Duration duration) async {
    for (var i = 0; i < duration.inSeconds; i++) {
      now = now.add(const Duration(seconds: 1));
      for (final engine in engines.values) {
        engine.tick();
      }
      for (var p = 0; p < 8; p++) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }
}

void main() {
  group('a survivor beside a connected phone', () {
    late Handsets mesh;
    late MeshEngine offline;
    late MeshEngine connected;

    setUp(() async {
      mesh = Handsets();
      offline = await mesh.add('phone-1', x: 0);
      connected = await mesh.add('phone-2', x: 20);
      await mesh.advance(const Duration(seconds: 10));
    });

    test('they can hear each other', () {
      expect(mesh.space.peersOf('phone-1'), ['phone-2']);
    });

    test('an unpromoted neighbour holds nothing — the bug', () async {
      await offline.sendSos(note: 'trapped, water rising');
      await mesh.advance(const Duration(seconds: 10));

      expect(connected.state.pendingReports, isEmpty,
          reason: 'a survivor is not a gateway, so the report goes nowhere');
      expect(offline.custodyDepth, 1,
          reason: 'the sender is still holding it, unacknowledged');
    });

    test('once promoted, it holds the report for syncing', () async {
      // What MeshController does when the health check succeeds.
      connected.state.role = NodeRole.gateway;
      await mesh.advance(const Duration(seconds: 10));

      await offline.sendSos(note: 'trapped, water rising');
      await mesh.advance(const Duration(seconds: 10));

      final held = connected.state.pendingReports;
      expect(held, isNotEmpty,
          reason: 'the connected phone is this report\'s only way out');
      expect(held.first.originNode, 'phone-1');
      expect(held.first.payload['note'], 'trapped, water rising');
      expect(held.first.priority, Priority.lifeCritical);
    });

    test('the sender learns it was received', () async {
      connected.state.role = NodeRole.gateway;
      await mesh.advance(const Duration(seconds: 10));

      await offline.sendSos(note: 'trapped');
      expect(offline.custodyDepth, 1);

      await mesh.advance(const Duration(seconds: 15));
      expect(offline.custodyDepth, 0,
          reason: 'clearing custody is what turns the sender\'s screen '
              'from waiting to acknowledged');
    });

    test('handing the role back stops it accepting more', () async {
      connected.state.role = NodeRole.gateway;
      await mesh.advance(const Duration(seconds: 10));
      await offline.sendSos(note: 'first');
      await mesh.advance(const Duration(seconds: 10));
      expect(connected.state.pendingReports, hasLength(1));

      // The uplink drops; MeshController restores the configured role.
      connected.state.role = NodeRole.survivor;
      await offline.sendSos(note: 'second');
      await mesh.advance(const Duration(seconds: 10));

      expect(connected.state.pendingReports, hasLength(1),
          reason: 'a phone with no internet must not claim a report it '
              'cannot deliver');
    });
  });

  test('a gateway two hops away still gets it', () async {
    final mesh = Handsets();
    final offline = await mesh.add('phone-1', x: 0);
    final middle = await mesh.add('phone-2', x: 100);
    final connected = await mesh.add('phone-3', x: 200);
    connected.state.role = NodeRole.gateway;
    await mesh.advance(const Duration(seconds: 12));

    expect(mesh.space.peersOf('phone-1'), ['phone-2'],
        reason: 'phone-1 cannot reach phone-3 directly');

    await offline.sendSos(note: 'three people trapped');
    await mesh.advance(const Duration(seconds: 12));

    expect(connected.state.pendingReports, isNotEmpty);
    expect(middle.state.pendingReports, isEmpty,
        reason: 'the middle phone relays, it does not hold');
  });
}
