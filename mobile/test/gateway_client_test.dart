/// The Dart gateway sync path.
///
/// This is the code that runs on the actual demo phones when a connectivity
/// window opens, and it was the one major path with no test. The Python
/// simulator's equivalent is covered by simulator/tests/test_gateway_sync.py;
/// these are the on-device counterparts, asserting the same guarantees:
/// critical traffic goes first, a short window defers rather than drops, and
/// a failed sync never loses a report.
library;

import 'dart:convert';

import 'package:avertis/mesh/mesh_engine.dart';
import 'package:avertis/mesh/mesh_events.dart';
import 'package:avertis/mesh/node_state.dart';
import 'package:avertis/mesh/protocol/packet.dart';
import 'package:avertis/mesh/transport/mock_mesh_transport.dart';
import 'package:avertis/services/gateway_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what was sent and replies the way the real backend does.
class FakeBackend implements SyncBackend {
  FakeBackend({this.failWith});

  final Object? failWith;
  final List<Map<String, dynamic>> bodies = [];
  final Set<String> everAccepted = {};
  int _next = 1042;

  @override
  Future<Map<String, dynamic>> postSync(Map<String, dynamic> body) async {
    if (failWith != null) throw failWith!;
    bodies.add(body);

    final accepted = <String>[];
    final incidents = <Map<String, dynamic>>[];
    for (final raw in (body['incidents'] as List).cast<Map<String, dynamic>>()) {
      final reportId = raw['report_id'] as String;
      accepted.add(reportId);
      everAccepted.add(reportId);
      incidents.add({
        'report_id': reportId,
        'incident_id': 'INC-${_next++}',
        'fused_into': null,
      });
    }
    return {
      'received_at': '2026-09-06T12:04:01.100Z',
      'accepted': accepted,
      'rejected': <dynamic>[],
      'incidents': incidents,
      'commands': <dynamic>[],
    };
  }

  @override
  Future<bool> health() async => failWith == null;
}

Future<MeshEngine> gatewayEngine() async {
  final space = MockRadioSpace(rangeM: 120, latency: Duration.zero);
  final transport = MockMeshTransport('gw-01', space);
  space.register(transport, x: 0, y: 0);
  final engine = MeshEngine(
    state: NodeState(nodeId: 'gw-01', role: NodeRole.gateway),
    transport: transport,
    bus: MeshEventBus(),
  );
  await engine.start();
  return engine;
}

/// Put a report into the gateway's custody, as if it had arrived over the mesh.
Packet hold(
  MeshEngine engine, {
  required String reportId,
  required Priority priority,
  required DateTime createdAt,
  String text = 'people trapped near the bridge',
}) {
  final packet = Packet(
    packetId: 'pkt-$reportId',
    originNode: 'node-07',
    destination: 'gateway',
    messageType:
        priority == Priority.lifeCritical ? MessageType.sos : MessageType.incident,
    priority: priority,
    ttl: 8,
    hopCount: 2,
    createdAt: createdAt,
    payload: {
      'report_id': reportId,
      'node_id': 'node-07',
      'created_at': isoOf(createdAt),
      'location': {'lat': 12.9716, 'lon': 77.5946, 'accuracy_m': 12.0},
      'text': text,
      'media': <dynamic>[],
    },
  );
  engine.state.pendingReports.add(packet);
  return packet;
}

void main() {
  final t0 = DateTime.utc(2026, 9, 6, 12, 0);

  late MeshEngine engine;
  late FakeBackend backend;
  late GatewayClient client;

  setUp(() async {
    engine = await gatewayEngine();
    backend = FakeBackend();
    client = GatewayClient(engine: engine, backend: backend, bus: engine.bus);
  });

  tearDown(() async => engine.stop());

  group('ordering', () {
    test('life-critical goes before everything older', () {
      final normal = hold(engine, reportId: 'rpt-normal',
          priority: Priority.normal, createdAt: t0);
      final critical = hold(engine, reportId: 'rpt-critical',
          priority: Priority.lifeCritical,
          createdAt: t0.add(const Duration(minutes: 30)));

      final ordered = GatewayClient.syncOrder([normal, critical]);

      // A newer life-critical report outranks an older routine one.
      expect(ordered.first.payload['report_id'], 'rpt-critical');
    });

    test('within one priority the oldest goes first', () {
      final newer = hold(engine, reportId: 'rpt-new',
          priority: Priority.emergency,
          createdAt: t0.add(const Duration(minutes: 5)));
      final older = hold(engine, reportId: 'rpt-old',
          priority: Priority.emergency, createdAt: t0);

      final ordered = GatewayClient.syncOrder([newer, older]);
      expect(ordered.first.payload['report_id'], 'rpt-old');
    });
  });

  group('spending a window', () {
    test('a report is delivered and acknowledged', () async {
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);

      final result = await client.sync(windowSeconds: 18);

      expect(result.ok, isTrue);
      expect(result.accepted, 1);
      expect(result.incidentIds.single, startsWith('INC-'));
      // Acknowledged reports are no longer this node's problem.
      expect(engine.state.pendingReports, isEmpty);
    });

    test('the body matches the frozen contract', () async {
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);
      await client.sync(windowSeconds: 18);

      final body = backend.bodies.single;
      for (final field in ['gateway_id', 'sent_at',
            'connectivity_window_seconds', 'nodes', 'links', 'incidents',
            'messages', 'metrics']) {
        expect(body.containsKey(field), isTrue,
            reason: 'docs/api.md requires $field');
      }

      final report = (body['incidents'] as List).first as Map<String, dynamic>;
      for (final field in ['report_id', 'origin_node', 'created_at',
            'priority', 'kind', 'location', 'text', 'hop_count', 'path']) {
        expect(report.containsKey(field), isTrue,
            reason: 'docs/api.md requires incidents[].$field');
      }
    });

    test('a short window sends the critical report and defers the rest',
        () async {
      // A long body per report, so the budget bites quickly.
      final filler = 'x' * 400;
      hold(engine, reportId: 'rpt-normal-1', priority: Priority.normal,
          createdAt: t0, text: filler);
      hold(engine, reportId: 'rpt-normal-2', priority: Priority.normal,
          createdAt: t0, text: filler);
      hold(engine, reportId: 'rpt-critical', priority: Priority.lifeCritical,
          createdAt: t0.add(const Duration(minutes: 1)), text: filler);

      final result = await client.sync(windowSeconds: 1);

      expect(result.accepted, greaterThanOrEqualTo(1));
      final sent = (backend.bodies.single['incidents'] as List)
          .cast<Map<String, dynamic>>()
          .map((r) => r['report_id'])
          .toList();
      expect(sent.first, 'rpt-critical',
          reason: 'a scarce window must carry life-critical traffic first');
    });

    test('a topology-only sync still reaches the backend', () async {
      // No reports, but this node's view of the mesh is worth sending: a
      // relay failing changes which responder should go, and produces no
      // report of its own.
      final result = await client.sync(windowSeconds: 18);

      expect(result.accepted, 0);
      expect(backend.bodies, hasLength(1),
          reason: 'network state is payload, not packaging');
      expect(backend.bodies.single['nodes'], isNotEmpty);
    });

    test('duplicate copies of one report cost one slot', () async {
      // Custody retransmission delivers the same report by several routes.
      // The window is spent per report, not per copy.
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0.add(const Duration(seconds: 5)));

      await client.sync(windowSeconds: 18);

      final sent = (backend.bodies.single['incidents'] as List);
      expect(sent.length, 1);
    });

    test('a second window does not resend what was acknowledged', () async {
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);
      await client.sync(windowSeconds: 18);

      final second = await client.sync(windowSeconds: 18);

      // The second window still talks to the backend — topology is worth
      // sending on its own — but it must not re-send a report the backend
      // has already acknowledged.
      expect(second.accepted, 0);
      expect(backend.bodies.last['incidents'], isEmpty,
          reason: 'an acknowledged report must not be sent twice');
    });
  });

  group('failure', () {
    test('a failed sync keeps every report', () async {
      final failing = GatewayClient(
        engine: engine,
        backend: FakeBackend(failWith: Exception('no route to host')),
        bus: engine.bus,
      );
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);

      final result = await failing.sync(windowSeconds: 18);

      expect(result.ok, isFalse);
      expect(result.accepted, 0);
      // The single most important guarantee here: a failed sync must never
      // discard a report. Someone is waiting on it.
      expect(engine.state.pendingReports, hasLength(1));
    });

    test('a failure is reported, not swallowed', () async {
      final failing = GatewayClient(
        engine: engine,
        backend: FakeBackend(failWith: Exception('boom')),
        bus: engine.bus,
      );
      hold(engine, reportId: 'rpt-1', priority: Priority.emergency,
          createdAt: t0);

      final result = await failing.sync(windowSeconds: 18);
      expect(result.error, isNotNull);
    });
  });

  group('topology', () {
    test('this node\'s own view travels with the reports', () async {
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);
      await client.sync(windowSeconds: 18);

      final nodes = backend.bodies.single['nodes'] as List;
      expect(nodes, isNotEmpty,
          reason: 'the backend needs network state to reason about '
              'reachability at all');
      expect((nodes.first as Map)['node_id'], 'gw-01');
    });

    test('a tiny window still delivers the report', () async {
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);
      // Topology must never crowd out the reports themselves.
      final result = await client.sync(windowSeconds: 0.4);
      expect(result.accepted, 1);
    });
  });

  group('this node\'s own reports', () {
    test('an unacknowledged SOS written here is synced', () async {
      // Only gateway nodes populate pendingReports. A survivor's own report
      // lives in custody, and if sync ignores that, someone with working
      // internet cannot upload their own SOS — it waits forever for a mesh
      // peer while the screen says nothing is pending.
      final packet = Packet(
        packetId: 'pkt-own',
        originNode: 'gw-01',
        destination: 'gateway',
        messageType: MessageType.sos,
        priority: Priority.lifeCritical,
        ttl: 10,
        hopCount: 0,
        createdAt: t0,
        payload: {
          'report_id': 'rpt-own',
          'node_id': 'gw-01',
          'created_at': isoOf(t0),
          'text': 'three people trapped',
          'media': <dynamic>[],
        },
      );
      engine.state.custody['rpt-own'] =
          CustodyEntry(reportId: 'rpt-own', packet: packet, createdAt: t0);

      final result = await client.sync(windowSeconds: 18);

      expect(result.accepted, 1);
      expect(backend.everAccepted, contains('rpt-own'));
    });

    test('acknowledgement clears custody so it is not resent forever',
        () async {
      final packet = Packet(
        packetId: 'pkt-own',
        originNode: 'gw-01',
        destination: 'gateway',
        messageType: MessageType.sos,
        priority: Priority.lifeCritical,
        ttl: 10,
        hopCount: 0,
        createdAt: t0,
        payload: {
          'report_id': 'rpt-own',
          'node_id': 'gw-01',
          'created_at': isoOf(t0),
          'text': 'trapped',
          'media': <dynamic>[],
        },
      );
      engine.state.custody['rpt-own'] =
          CustodyEntry(reportId: 'rpt-own', packet: packet, createdAt: t0);

      await client.sync(windowSeconds: 18);

      expect(engine.state.custody.containsKey('rpt-own'), isFalse,
          reason: 'the backend has it; retransmitting wastes the next window');
    });

    test('a report held for someone else and one of our own both go',
        () async {
      hold(engine, reportId: 'rpt-relayed', priority: Priority.emergency,
          createdAt: t0);
      final own = Packet(
        packetId: 'pkt-own',
        originNode: 'gw-01',
        destination: 'gateway',
        messageType: MessageType.sos,
        priority: Priority.lifeCritical,
        ttl: 10,
        hopCount: 0,
        createdAt: t0,
        payload: {
          'report_id': 'rpt-own',
          'node_id': 'gw-01',
          'created_at': isoOf(t0),
          'text': 'trapped',
          'media': <dynamic>[],
        },
      );
      engine.state.custody['rpt-own'] =
          CustodyEntry(reportId: 'rpt-own', packet: own, createdAt: t0);

      final result = await client.sync(windowSeconds: 18);
      expect(result.accepted, 2);
    });
  });

  group('reachability', () {
    test('health is what decides connectivity, not a guess', () async {
      final reachable = _HealthBackend(healthy: true);
      final unreachable = _HealthBackend(healthy: false);

      expect(await reachable.health(), isTrue);
      expect(await unreachable.health(), isFalse);
      expect(reachable.healthChecks, 1);
    });

    test('a held report is still there until a sync accepts it', () async {
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);

      // Before any sync the report is held — this is what the home screen
      // counts, and it must not read zero while something is undelivered.
      expect(client.heldReports(), hasLength(1));

      await client.sync(windowSeconds: 18);
      expect(client.heldReports(), isEmpty);
    });
  });

  group('fields the operator acts on', () {
    test('a stated headcount reaches the backend', () async {
      final packet = hold(engine, reportId: 'rpt-1',
          priority: Priority.lifeCritical, createdAt: t0);
      packet.payload['people_count'] = 3;

      await client.sync(windowSeconds: 18);

      final sent = (backend.bodies.single['incidents'] as List).first
          as Map<String, dynamic>;
      // The backend never infers a count it was not given, so losing it here
      // means dispatching for an unknown number when we were told the number.
      expect(sent['people_count'], 3);
    });

    test('an unstated headcount stays null rather than becoming a guess',
        () async {
      hold(engine, reportId: 'rpt-1', priority: Priority.lifeCritical,
          createdAt: t0);
      await client.sync(windowSeconds: 18);

      final sent = (backend.bodies.single['incidents'] as List).first
          as Map<String, dynamic>;
      expect(sent['people_count'], isNull);
    });
  });

  group('media descriptors', () {
    test('device-local paths never reach the backend', () async {
      final packet = hold(engine, reportId: 'rpt-1',
          priority: Priority.emergency, createdAt: t0);
      packet.payload['media'] = [
        {
          'kind': 'IMAGE',
          'media_id': 'med-1',
          'local_path': '/data/user/0/com.avertis.avertis/files/a.jpg',
          'bytes': 1024,
          'inline': false,
        }
      ];

      await client.sync(windowSeconds: 18);

      final wire = jsonEncode(backend.bodies.single);
      expect(wire.contains('local_path'), isFalse,
          reason: 'a filesystem path leaks a username and means nothing '
              'off-device');
      expect(wire.contains('med-1'), isTrue,
          reason: 'the descriptor itself must still travel');
    });
  });

  /// What the command centre can draw depends entirely on this payload.
  ///
  /// Two handsets beside each other showed up as one lone node with no
  /// edges: the sync carried this phone's own snapshot and nothing else,
  /// and a neighbour with no internet never syncs on its own behalf.
  group('neighbours in the topology', () {
    Neighbor heard(String id, {double stability = 0.9, int rssi = -62}) {
      final n = Neighbor(id)
        ..role = NodeRole.survivor
        ..battery = 0.64
        ..location = const GeoPoint(12.9716, 77.5946, accuracyM: 8.0)
        ..gatewayDistance = 1
        ..rssi = rssi
        ..stability = stability
        ..state = LinkState.up;
      engine.state.neighbors[id] = n;
      return n;
    }

    test('a neighbour this phone can hear is reported as a node', () async {
      heard('phone-1');
      await client.sync(windowSeconds: 30);

      final nodes = (backend.bodies.single['nodes'] as List)
          .cast<Map<String, dynamic>>();
      final ids = nodes.map((n) => n['node_id']).toList();
      expect(ids, containsAll(<String>['gw-01', 'phone-1']),
          reason: 'the offline phone exists only in what this one heard');

      final seen = nodes.firstWhere((n) => n['node_id'] == 'phone-1');
      expect(seen['battery'], 0.64);
      expect(seen['link_stability'], 0.9);
      expect(seen['neighbors'], ['gw-01'], reason: 'the link is two-way');
    });

    test('the link between them is reported too', () async {
      heard('phone-1', stability: 0.82, rssi: -71);
      await client.sync(windowSeconds: 30);

      final links = (backend.bodies.single['links'] as List)
          .cast<Map<String, dynamic>>();
      expect(links, hasLength(1));
      expect(links.single['a'], 'gw-01');
      expect(links.single['b'], 'phone-1');
      expect(links.single['stability'], 0.82);
      expect(links.single['rssi'], -71);
    });

    test('a neighbour that has gone quiet is not reported', () async {
      heard('phone-1').state = LinkState.down;
      await client.sync(windowSeconds: 30);

      final body = backend.bodies.single;
      final ids = (body['nodes'] as List)
          .cast<Map<String, dynamic>>()
          .map((n) => n['node_id']);
      expect(ids, ['gw-01'],
          reason: 'a node nobody can hear must not be drawn as reachable');
      expect(body['links'], isEmpty);
    });

    test('nothing is claimed about a neighbour that was not heard', () async {
      heard('phone-1');
      await client.sync(windowSeconds: 30);

      final seen = (backend.bodies.single['nodes'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((n) => n['node_id'] == 'phone-1');
      expect(seen.containsKey('queue_depth'), isFalse,
          reason: 'a beacon says nothing about the sender\'s queue');
    });

    test('topology still goes out with no reports to send', () async {
      heard('phone-1');
      final result = await client.sync(windowSeconds: 30);

      expect(result.attempted, 0);
      expect(backend.bodies, hasLength(1),
          reason: 'a relay appearing is news even with no report attached');
    });
  });
}

/// Reachability drives both the connectivity shown on the home screen and
/// whether a held report is delivered without anyone pressing a button.
class _HealthBackend extends FakeBackend {
  _HealthBackend({required this.healthy});
  final bool healthy;
  int healthChecks = 0;

  @override
  Future<bool> health() async {
    healthChecks++;
    return healthy;
  }
}
