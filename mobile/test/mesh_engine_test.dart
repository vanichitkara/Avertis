/// The Dart engine must show the same behaviour as the Python simulator:
/// multi-hop delivery, dedup, TTL, custody, and self-healing after a relay
/// dies. These are the on-device equivalents of the simulator's test suite.
library;

import 'package:avertis/mesh/mesh_engine.dart';
import 'package:avertis/mesh/mesh_events.dart';
import 'package:avertis/mesh/node_state.dart';
import 'package:avertis/mesh/protocol/packet.dart';
import 'package:avertis/mesh/transport/mock_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// A test harness with a controllable clock, so beacon timeouts and custody
/// retries can be exercised without waiting in real time.
class TestMesh {
  TestMesh({double rangeM = 120.0})
      : space = MockRadioSpace(
          rangeM: rangeM,
          latency: Duration.zero,
        );

  final MockRadioSpace space;
  final MeshEventBus bus = MeshEventBus();
  final Map<String, MeshEngine> engines = {};
  final Map<String, MockMeshTransport> transports = {};
  DateTime now = DateTime.utc(2026, 9, 6, 8, 17);

  Future<MeshEngine> addNode(
    String nodeId, {
    NodeRole role = NodeRole.survivor,
    double x = 0,
    double y = 0,
    double battery = 1.0,
  }) async {
    final transport = MockMeshTransport(nodeId, space);
    space.register(transport, x: x, y: y);
    final engine = MeshEngine(
      state: NodeState(nodeId: nodeId, role: role, battery: battery),
      transport: transport,
      bus: bus,
      clock: () => now,
    );
    transports[nodeId] = transport;
    engines[nodeId] = engine;
    await transport.start();
    // Subscribe without the periodic timer — the test drives `tick` itself.
    transport.incoming.listen((m) => engine.onPacket(m.from, m.packet));
    transport.peerLost.listen((peer) => engine.tick());
    return engine;
  }

  /// Advance the simulated clock, ticking every engine each second.
  Future<void> advance(Duration duration) async {
    for (var i = 0; i < duration.inSeconds; i++) {
      now = now.add(const Duration(seconds: 1));
      for (final engine in engines.values) {
        engine.tick();
      }
      await pumpEventQueue();
    }
  }

  Future<void> pumpEventQueue() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> kill(String nodeId) async {
    engines[nodeId]!.state.alive = false;
    await transports[nodeId]!.stop();
  }

  Future<void> revive(String nodeId) async {
    engines[nodeId]!.state.alive = true;
    engines[nodeId]!.state.neighbors.clear();
    await transports[nodeId]!.start();
  }

  List<MeshEvent> eventsOf(MeshEventType type) =>
      bus.log.where((e) => e.type == type).toList();
}

void main() {
  group('multi-hop delivery', () {
    late TestMesh mesh;

    setUp(() async {
      // A --- B --- C, with A and C out of range of each other.
      mesh = TestMesh();
      await mesh.addNode('node-a', x: 0);
      await mesh.addNode('node-b', role: NodeRole.relay, x: 100);
      await mesh.addNode('node-c', role: NodeRole.gateway, x: 200);
    });

    test('the topology really is multi-hop', () {
      expect(mesh.space.peersOf('node-a'), ['node-b']);
      expect(mesh.space.peersOf('node-c'), ['node-b']);
      expect(mesh.space.peersOf('node-b'), ['node-a', 'node-c']);
    });

    test('an SOS reaches the gateway through the relay', () async {
      await mesh.advance(const Duration(seconds: 10));
      final packet = await mesh.engines['node-a']!
          .sendSos(note: 'trapped, water rising');
      await mesh.advance(const Duration(seconds: 10));

      final delivered = mesh.engines['node-c']!.state.delivered
          .where((p) => p.packetId == packet.packetId)
          .toList();
      expect(delivered, isNotEmpty,
          reason: 'the SOS never reached the gateway');
      expect(delivered.first.hopCount, 1);
      expect(delivered.first.path, ['node-b']);
      expect(delivered.first.priority, Priority.lifeCritical);
    });

    test('the origin receives an ACK and clears custody', () async {
      await mesh.advance(const Duration(seconds: 10));
      final engine = mesh.engines['node-a']!;
      await engine.sendSos(note: 'help');
      expect(engine.custodyDepth, 1);

      await mesh.advance(const Duration(seconds: 15));
      expect(engine.custodyDepth, 0,
          reason: 'custody should clear once the report is acknowledged');
    });

    test('a duplicate packet is dropped', () async {
      await mesh.advance(const Duration(seconds: 10));
      final relay = mesh.engines['node-b']!;
      final packet = await mesh.engines['node-a']!.sendSos(note: 'dup');
      await mesh.advance(const Duration(seconds: 5));

      final before = relay.packetsDroppedDup;
      await relay.onPacket('node-a', packet);
      expect(relay.packetsDroppedDup, before + 1);
    });

    test('a packet whose TTL runs out is dropped', () async {
      await mesh.advance(const Duration(seconds: 10));
      final relay = mesh.engines['node-b']!;
      final dying = Packet.create(
        packetId: 'pkt-deadbeefdeadbeef',
        originNode: 'node-a',
        destination: 'node-zzz',
        messageType: MessageType.incident,
        priority: Priority.normal,
        createdAt: mesh.now,
        payload: const {'text': 'x'},
        ttl: 1,
      );
      await relay.onPacket('node-a', dying);
      expect(relay.packetsDroppedTtl, 1);
    });
  });

  group('self-healing', () {
    test('traffic reroutes after the chosen relay dies', () async {
      // A reaches C through either B or D.
      final mesh = TestMesh();
      await mesh.addNode('node-a', x: 0, y: 0, battery: 0.9);
      await mesh.addNode('node-b',
          role: NodeRole.relay, x: 100, y: 40, battery: 1.0);
      await mesh.addNode('node-d',
          role: NodeRole.relay, x: 100, y: -40, battery: 0.55);
      await mesh.addNode('node-c',
          role: NodeRole.gateway, x: 200, y: 0, battery: 1.0);

      await mesh.advance(const Duration(seconds: 12));
      final first = await mesh.engines['node-a']!.sendSos(note: 'pre-failure');
      await mesh.advance(const Duration(seconds: 8));
      expect(
        mesh.engines['node-c']!.state.delivered
            .any((p) => p.packetId == first.packetId),
        isTrue,
      );

      await mesh.kill('node-b');
      // Failure is detected by beacon timeout, not a magic callback.
      await mesh.advance(const Duration(seconds: 25));

      final a = mesh.engines['node-a']!;
      expect(a.state.neighbors['node-b']!.state, LinkState.down);
      expect(a.state.neighbors['node-d']!.state, LinkState.up);
      expect(mesh.eventsOf(MeshEventType.nodeDown), isNotEmpty);
      expect(mesh.eventsOf(MeshEventType.relayElected), isNotEmpty);

      final second = await a.sendSos(note: 'post-failure');
      await mesh.advance(const Duration(seconds: 15));
      final delivered = mesh.engines['node-c']!.state.delivered
          .where((p) => p.packetId == second.packetId)
          .toList();
      expect(delivered, isNotEmpty,
          reason: 'the network did not heal after the relay died');
      expect(delivered.first.path, ['node-d']);
    });

    test('a report survives a partition and flushes when it heals', () async {
      final mesh = TestMesh();
      await mesh.addNode('node-a', x: 0, battery: 0.9);
      await mesh.addNode('node-b', role: NodeRole.relay, x: 100);
      await mesh.addNode('node-c', role: NodeRole.gateway, x: 200);
      await mesh.advance(const Duration(seconds: 12));

      // Sever the only bridge, then report from the isolated side.
      await mesh.kill('node-b');
      await mesh.advance(const Duration(seconds: 25));
      final packet = await mesh.engines['node-a']!.sendSos(note: 'cut off');
      final reportId = packet.payload['report_id'] as String;
      await mesh.advance(const Duration(seconds: 30));

      final gateway = mesh.engines['node-c']!;
      expect(
        gateway.state.delivered
            .any((p) => p.payload['report_id'] == reportId),
        isFalse,
      );
      expect(mesh.engines['node-a']!.custodyDepth, 1,
          reason: 'the report must be retained, not lost');

      await mesh.revive('node-b');
      await mesh.advance(const Duration(seconds: 40));

      expect(
        gateway.state.delivered
            .any((p) => p.payload['report_id'] == reportId),
        isTrue,
        reason: 'custody did not flush after the partition healed',
      );
    });
  });

  group('queueing', () {
    test('the queue is critical-first', () async {
      final mesh = TestMesh();
      final engine = await mesh.addNode('node-a');
      await mesh.transports['node-a']!.stop(); // nothing can leave

      await engine.originate(
        messageType: MessageType.incident,
        priority: Priority.normal,
        payload: const {'text': 'shelter full'},
      );
      await engine.originate(
        messageType: MessageType.incident,
        priority: Priority.operational,
        payload: const {'text': 'road blocked'},
      );
      await engine.sendSos(note: 'trapped');

      final order =
          engine.state.queue.entries.map((e) => e.packet.priority).toList();
      expect(order.first, Priority.lifeCritical);
      for (var i = 1; i < order.length; i++) {
        expect(order[i - 1].rank, lessThanOrEqualTo(order[i].rank));
      }
    });

    test('overflow drops the lowest priority, not the newest', () {
      final queue = PacketQueue(capacity: 3);
      final base = DateTime.utc(2026, 9, 6, 12);
      Packet mk(int i, Priority p, int offset) => Packet.create(
            packetId: 'pkt-${i.toString().padLeft(16, '0')}',
            originNode: 'node-a',
            destination: anyGateway,
            messageType: MessageType.incident,
            priority: p,
            createdAt: base.add(Duration(seconds: offset)),
          );

      queue.push(mk(1, Priority.normal, 0));
      queue.push(mk(2, Priority.lifeCritical, 5));
      queue.push(mk(3, Priority.emergency, 1));
      final evicted = queue.push(mk(4, Priority.operational, 2));

      expect(evicted?.priority, Priority.normal);
      expect(
        queue.entries.map((e) => e.packet.priority),
        [Priority.lifeCritical, Priority.emergency, Priority.operational],
      );
    });
  });
}
