/// The deterministic mesh engine (Dart).
///
/// Sibling of simulator/avertis_sim/mesh_engine.py. Implements
/// docs/protocol.md §6 (forwarding), §8 (queues and relay selection) and §9
/// (failure detection). No LLM is ever called from here — Gemini reasons
/// *about* the network, deterministic code *operates* it.
library;

import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'mesh_events.dart';
import 'node_state.dart';
import 'protocol/packet.dart';
import 'transport/mesh_transport.dart';

const Duration retryInterval = Duration(seconds: 5);
const int maxForwardAttempts = 4;
const Duration custodyRetry = Duration(seconds: 20);
const int maxCustodyAttempts = 12;

/// How many best-scoring neighbours a packet is handed to when there is no
/// specific route. More than one buys resilience; too many floods the mesh.
const int fanoutDefault = 2;
const int fanoutCritical = 3;

final _uuid = Uuid();

String newPacketId() =>
    'pkt-${_uuid.v4().replaceAll('-', '').substring(0, 16)}';

String newReportId() =>
    'rpt-${_uuid.v4().replaceAll('-', '').substring(0, 12)}';

class MeshEngine {
  MeshEngine({
    required this.state,
    required this.transport,
    required this.bus,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final NodeState state;

  /// Not final: a radio can be restarted under a running node. See
  /// [restartTransport].
  MeshTransport transport;
  final MeshEventBus bus;
  final DateTime Function() _clock;

  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _ticker;
  DateTime? _lastBeacon;
  DateTime? _lastRetry;

  // Counters, surfaced in the debug view.
  int packetsOriginated = 0;
  int packetsForwarded = 0;
  int packetsDelivered = 0;
  int packetsDroppedTtl = 0;
  int packetsDroppedDup = 0;
  int packetsDroppedQueue = 0;

  String get nodeId => state.nodeId;
  int get custodyDepth => state.custody.length;
  int get queueDepth => state.queue.length;

  // -- lifecycle ------------------------------------------------------

  Future<void> start() async {
    await transport.start();
    _subs.add(transport.incoming.listen((m) => onPacket(m.from, m.packet)));
    _subs.add(transport.peerLost.listen(_markNeighborDown));
    _subs.add(transport.peerFound.listen((peer) {
      // Discovery alone does not make a neighbour — a HELLO does. But it is a
      // topology change, so it is worth retrying held traffic.
      unawaited(_pump());
    }));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    bus.emit(MeshEvent(MeshEventType.nodeJoined, nodeId, {
      'role': state.role.wire,
    }));
  }

  Future<void> stop() async {
    _ticker?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await transport.stop();
  }

  /// Swap the radio without replacing the node.
  ///
  /// Used when a Bluetooth permission is granted after the transport has
  /// already started: the old one was refused by the OS and will never
  /// find anybody, but the node itself is fine and may be holding
  /// somebody's report. Custody, counters and identity all survive —
  /// this is a radio being restarted, not a node being rebuilt.
  ///
  /// Neighbours do not survive, because they genuinely do not: nothing
  /// has been heard on the new radio yet, and carrying the old list over
  /// would claim links that may no longer exist.
  Future<void> restartTransport(MeshTransport replacement) async {
    _ticker?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await transport.stop();

    state.neighbors.clear();
    transport = replacement;
    await start();
  }

  // -- origination ----------------------------------------------------

  Future<Packet> originate({
    required MessageType messageType,
    required Priority priority,
    required Map<String, dynamic> payload,
    String destination = anyGateway,
    int? ttl,
  }) async {
    final packet = Packet.create(
      packetId: newPacketId(),
      originNode: nodeId,
      destination: destination,
      messageType: messageType,
      priority: priority,
      createdAt: _clock(),
      payload: payload,
      ttl: ttl,
    );
    packetsOriginated++;
    state.seen.add(packet.packetId, _clock());

    if (messageType == MessageType.sos || messageType == MessageType.incident) {
      _takeCustody(packet);
    }

    bus.emit(MeshEvent(MeshEventType.packetSent, nodeId, {
      'packet_id': packet.packetId,
      'type': messageType.wire,
      'priority': priority.wire,
      'destination': destination,
    }));

    if (_isLocalDestination(packet)) {
      _deliverLocally(packet);
    } else {
      _enqueue(packet);
      await _pump();
    }
    return packet;
  }

  /// The one-tap path. Always LIFE_CRITICAL (docs/protocol.md §4).
  Future<Packet> sendSos({String note = '', int? peopleCount}) {
    return originate(
      messageType: MessageType.sos,
      priority: Priority.lifeCritical,
      payload: {
        'report_id': newReportId(),
        'node_id': nodeId,
        'location': state.location?.toJson(),
        'created_at': isoOf(_clock()),
        'people_count': peopleCount,
        'note': note,
      },
    );
  }

  Future<Packet> sendIncident(
    String text, {
    Priority priority = Priority.emergency,
    List<Map<String, dynamic>> media = const [],
    String? transcript,
  }) {
    return originate(
      messageType: MessageType.incident,
      priority: priority,
      payload: {
        'report_id': newReportId(),
        'node_id': nodeId,
        'created_at': isoOf(_clock()),
        'location': state.location?.toJson(),
        'text': text,
        'transcript': transcript,
        'media': media,
        'reported_priority': priority.wire,
      },
    );
  }

  // -- reception -------------------------------------------------------

  Future<void> onPacket(String fromNode, Packet packet) async {
    if (!state.alive) return;
    final now = _clock();

    if (packet.messageType == MessageType.hello) {
      _handleHello(fromNode, packet, now);
      return;
    }

    // 1. dedup
    if (state.seen.seen(packet.packetId, now)) {
      packetsDroppedDup++;
      return;
    }
    state.seen.add(packet.packetId, now);

    // 2. loop check
    if (packet.path.contains(nodeId)) {
      packetsDroppedDup++;
      return;
    }

    // 3. deliver
    var delivered = false;
    if (_isLocalDestination(packet)) {
      _deliverLocally(packet);
      delivered = true;
      if (packet.destination != broadcast) return;
    }

    // 4. TTL
    final hopped = packet.forwardedBy(nodeId);
    if (hopped.ttl <= 0) {
      packetsDroppedTtl++;
      bus.emit(MeshEvent(MeshEventType.packetDropped, nodeId, {
        'packet_id': packet.packetId,
        'reason': 'TTL_EXPIRED',
        'hop_count': packet.hopCount,
      }));
      return;
    }

    // 5. forward
    if (!delivered || packet.destination == broadcast) {
      _enqueue(hopped);
      await _pump();
    }
  }

  void _handleHello(String fromNode, Packet packet, DateTime now) {
    final p = packet.payload;
    final isNew = !state.neighbors.containsKey(fromNode);
    final neighbor = state.neighbors.putIfAbsent(
      fromNode,
      () => Neighbor(fromNode),
    );
    neighbor.role = NodeRole.fromWire((p['role'] as String?) ?? 'SURVIVOR');
    neighbor.battery = (p['battery'] as num?)?.toDouble() ?? 1.0;
    neighbor.location =
        GeoPoint.fromJson(p['location'] as Map<String, dynamic>?);
    neighbor.gatewayDistance = p['gateway_distance'] as int?;
    neighbor.observeBeacon(now, (p['seq'] as int?) ?? 0);

    if (isNew) {
      bus.emit(MeshEvent(MeshEventType.linkUp, nodeId, {
        'peer': fromNode,
        'role': neighbor.role.wire,
      }));
      // A new neighbour is a topology change: retry held packets and anything
      // still in custody. This is how a healed partition flushes.
      for (final entry in state.custody.values) {
        entry.lastAttempt = null;
      }
      unawaited(_pump().then((_) => _retryCustody()));
    }
    _recomputeGatewayDistance();
  }

  void _deliverLocally(Packet packet) {
    packetsDelivered++;
    state.delivered.add(packet);
    bus.emit(MeshEvent(MeshEventType.packetDelivered, nodeId, {
      'packet_id': packet.packetId,
      'type': packet.messageType.wire,
      'priority': packet.priority.wire,
      'origin': packet.originNode,
      'hop_count': packet.hopCount,
      'path': packet.path,
    }));

    if (packet.messageType == MessageType.ack) {
      _resolveCustody(packet.payload['ack_packet_id'] as String? ?? '');
    }

    if (packet.messageType == MessageType.sos ||
        packet.messageType == MessageType.incident) {
      if (state.isGateway) state.pendingReports.add(packet);
      unawaited(_sendAck(packet));
    }
  }

  Future<void> _sendAck(Packet packet) async {
    if (packet.originNode == nodeId) return;
    final ack = Packet.create(
      packetId: newPacketId(),
      originNode: nodeId,
      destination: packet.originNode,
      messageType: MessageType.ack,
      priority: Priority.operational,
      createdAt: _clock(),
      payload: {
        'ack_packet_id': packet.packetId,
        'by_node': nodeId,
        'status': 'DELIVERED',
      },
    );
    state.seen.add(ack.packetId, _clock());
    _enqueue(ack);
    await _pump();
  }

  // -- custody ---------------------------------------------------------

  void _takeCustody(Packet packet) {
    final reportId = packet.payload['report_id'] as String?;
    if (reportId == null) return;
    state.custody[reportId] = CustodyEntry(
      reportId: reportId,
      packet: packet,
      createdAt: _clock(),
    )..lastAttempt = _clock();
  }

  void _resolveCustody(String ackedPacketId) {
    for (final entry in state.custody.values.toList()) {
      if (entry.packetIds.contains(ackedPacketId)) {
        state.custody.remove(entry.reportId);
        return;
      }
    }
  }

  /// Retransmit unacknowledged reports — this is what survives a partition.
  ///
  /// The retransmission keeps the same `report_id` (so the gateway and the
  /// backend deduplicate it) but takes a fresh `packet_id`, because every
  /// relay along the way has the old ID in its seen-set and would drop it.
  Future<void> _retryCustody() async {
    final now = _clock();
    for (final entry in state.custody.values.toList()) {
      final last = entry.lastAttempt;
      if (last != null && now.difference(last) < custodyRetry) continue;
      if (entry.attempts >= maxCustodyAttempts) continue;
      if (state.liveNeighbors.isEmpty) continue; // hold without burning a try

      entry.attempts++;
      entry.lastAttempt = now;
      final resent = Packet.create(
        packetId: newPacketId(),
        originNode: entry.packet.originNode,
        destination: entry.packet.destination,
        messageType: entry.packet.messageType,
        priority: entry.packet.priority,
        createdAt: entry.packet.createdAt,
        payload: entry.packet.payload,
      );
      entry.packetIds.add(resent.packetId);
      state.seen.add(resent.packetId, now);
      _enqueue(resent);
      bus.emit(MeshEvent(MeshEventType.packetSent, nodeId, {
        'packet_id': resent.packetId,
        'type': resent.messageType.wire,
        'priority': resent.priority.wire,
        'retransmission_of': entry.reportId,
        'attempt': entry.attempts,
      }));
    }
    await _pump();
  }

  // -- routing ----------------------------------------------------------

  bool _isLocalDestination(Packet packet) {
    final d = packet.destination;
    if (d == nodeId || d == broadcast) return true;
    return d == anyGateway && state.isGateway;
  }

  void _enqueue(Packet packet, {String? nextHop}) {
    final evicted = state.queue.push(packet, nextHop: nextHop);
    if (evicted != null) {
      packetsDroppedQueue++;
      bus.emit(MeshEvent(MeshEventType.queueDrop, nodeId, {
        'packet_id': evicted.packetId,
        'priority': evicted.priority.wire,
        'queue_depth': state.queue.length,
      }));
    }
  }

  /// Deterministic next-hop choice. See docs/protocol.md §8.
  List<String> _selectNextHops(Packet packet) {
    final live = state.liveNeighbors
        .where((n) =>
            !packet.path.contains(n.nodeId) && n.nodeId != packet.originNode)
        .toList();
    if (live.isEmpty) return const [];

    // Direct delivery beats any relay heuristic.
    for (final n in live) {
      if (n.nodeId == packet.destination) return [n.nodeId];
    }
    if (packet.destination == anyGateway) {
      final gateways =
          live.where((n) => n.role == NodeRole.gateway).toList();
      if (gateways.isNotEmpty) return [gateways.first.nodeId];
    }

    live.sort((a, b) {
      final byScore = state.scoreOf(b).compareTo(state.scoreOf(a));
      return byScore != 0 ? byScore : a.nodeId.compareTo(b.nodeId);
    });
    if (packet.destination == broadcast) {
      return live.map((n) => n.nodeId).toList();
    }
    final fanout = packet.priority == Priority.lifeCritical
        ? fanoutCritical
        : fanoutDefault;
    return live.take(fanout).map((n) => n.nodeId).toList();
  }

  /// Try to move everything the queue is holding. Store-and-forward.
  ///
  /// Entries are walked in delivery order in place: a packet that is only
  /// waiting out its retry interval keeps its existing `lastAttempt`, so the
  /// timer actually elapses.
  Future<void> _pump() async {
    if (!state.alive) return;
    final now = _clock();
    final done = <String>{};

    for (final entry in state.queue.entries) {
      final last = entry.lastAttempt;
      if (entry.attempts > 0 &&
          last != null &&
          now.difference(last) < retryInterval) {
        continue;
      }

      final hops = entry.nextHop != null
          ? [entry.nextHop!]
          : _selectNextHops(entry.packet);
      var sentAny = false;
      for (final hop in hops) {
        if (await transport.send(hop, entry.packet)) {
          sentAny = true;
          packetsForwarded++;
          bus.emit(MeshEvent(MeshEventType.packetForwarded, nodeId, {
            'packet_id': entry.packet.packetId,
            'to': hop,
            'priority': entry.packet.priority.wire,
            'hop_count': entry.packet.hopCount,
            'ttl': entry.packet.ttl,
          }));
        }
      }

      entry.attempts++;
      entry.lastAttempt = now;

      if (sentAny) {
        done.add(entry.packet.packetId);
      } else if (entry.attempts >= maxForwardAttempts &&
          (entry.packet.priority == Priority.normal ||
              entry.packet.priority == Priority.operational)) {
        // Low-priority traffic gives up; critical traffic is held until a
        // route exists — that is the whole point of the mesh.
        done.add(entry.packet.packetId);
        bus.emit(MeshEvent(MeshEventType.packetDropped, nodeId, {
          'packet_id': entry.packet.packetId,
          'reason': 'NO_ROUTE',
          'attempts': entry.attempts,
        }));
      }
    }

    if (done.isNotEmpty) {
      state.queue.removeWhere((e) => done.contains(e.packet.packetId));
    }
  }

  // -- periodic work -----------------------------------------------------

  void tick() {
    if (!state.alive) return;
    final now = _clock();

    if (_lastBeacon == null ||
        now.difference(_lastBeacon!) >= beaconInterval) {
      unawaited(_beacon());
      _lastBeacon = now;
    }

    _ageNeighbors(now);

    if (_lastRetry == null ||
        now.difference(_lastRetry!) >= const Duration(seconds: 1)) {
      unawaited(_pump().then((_) => _retryCustody()));
      _lastRetry = now;
    }
  }

  Future<void> _beacon() async {
    state.beaconSeq++;
    final hello = Packet.create(
      packetId: newPacketId(),
      originNode: nodeId,
      destination: broadcast,
      messageType: MessageType.hello,
      priority: Priority.normal,
      createdAt: _clock(),
      payload: {
        'node_id': nodeId,
        'role': state.role.wire,
        'battery': double.parse(state.battery.toStringAsFixed(3)),
        'location': state.location?.toJson(),
        'gateway_distance': state.gatewayDistance,
        'seq': state.beaconSeq,
      },
    );
    await transport.broadcast(hello);
  }

  void _ageNeighbors(DateTime now) {
    for (final entry in state.neighbors.entries.toList()) {
      final before = entry.value.state;
      final after = entry.value.ageOut(now);
      if (before == after) continue;
      if (after == LinkState.suspect) {
        bus.emit(MeshEvent(MeshEventType.nodeSuspect, nodeId, {
          'peer': entry.key,
        }));
      } else if (after == LinkState.down) {
        _markNeighborDown(entry.key);
      }
    }
  }

  void _markNeighborDown(String peerId) {
    final neighbor = state.neighbors[peerId];
    if (neighbor == null || neighbor.downAnnounced) return;

    // Ask which relay we preferred *while this peer still counted*.
    final wasBestRelay = _preferredRelay() == peerId;
    neighbor.state = LinkState.down;
    neighbor.downAnnounced = true;

    bus.emit(MeshEvent(MeshEventType.nodeDown, nodeId, {
      'peer': peerId,
      'last_seen_stability': double.parse(neighbor.stability.toStringAsFixed(3)),
    }));
    bus.emit(MeshEvent(MeshEventType.linkDown, nodeId, {'peer': peerId}));

    // Self-healing. Packets are re-scored at every pump rather than pinned, so
    // the meaningful question is whether losing this peer actually changed our
    // route: our distance to a gateway, or traffic it would have carried.
    final beforeDistance = state.gatewayDistance;
    final requeued = state.queue.unpinNextHop(peerId);
    _recomputeGatewayDistance();

    if (requeued > 0 ||
        beforeDistance != state.gatewayDistance ||
        (wasBestRelay && state.queue.length > 0)) {
      bus.emit(MeshEvent(MeshEventType.routeChanged, nodeId, {
        'reason': 'NEXT_HOP_DOWN',
        'peer': peerId,
        'packets_requeued': requeued,
        'queue_depth': state.queue.length,
        'gateway_distance_before': beforeDistance,
        'gateway_distance_after': state.gatewayDistance,
      }));
    }
    _electRelay(exclude: peerId);
    unawaited(_pump());
  }

  /// The neighbour we would hand a gateway-bound packet to right now.
  String? _preferredRelay() {
    final live = state.liveNeighbors;
    if (live.isEmpty) return null;
    live.sort((a, b) {
      final byScore = state.scoreOf(b).compareTo(state.scoreOf(a));
      return byScore != 0 ? byScore : a.nodeId.compareTo(b.nodeId);
    });
    return live.first.nodeId;
  }

  /// Pick the best replacement relay and announce it (plan §18).
  String? _electRelay({String? exclude}) {
    final candidates =
        state.liveNeighbors.where((n) => n.nodeId != exclude).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final byScore = state.scoreOf(b).compareTo(state.scoreOf(a));
      return byScore != 0 ? byScore : a.nodeId.compareTo(b.nodeId);
    });
    final best = candidates.first;
    bus.emit(MeshEvent(MeshEventType.relayElected, nodeId, {
      'relay': best.nodeId,
      'score': double.parse(state.scoreOf(best).toStringAsFixed(4)),
      'replaced': exclude,
    }));
    return best.nodeId;
  }

  /// Distance-vector hop count to the nearest known gateway.
  void _recomputeGatewayDistance() {
    int? next;
    if (state.isGateway) {
      next = 0;
    } else {
      final candidates = <int>[];
      for (final n in state.liveNeighbors) {
        if (n.gatewayDistance != null) candidates.add(n.gatewayDistance! + 1);
        if (n.role == NodeRole.gateway) candidates.add(1);
      }
      next = candidates.isEmpty ? null : candidates.reduce(min);
    }
    state.gatewayDistance = next;
  }

  /// The per-node half of the network state sent in gateway/sync.
  Map<String, dynamic> snapshot() {
    final live = state.liveNeighbors;
    final meanStability = live.isEmpty
        ? 0.0
        : live.map((n) => n.stability).reduce((a, b) => a + b) / live.length;
    return {
      'node_id': nodeId,
      'role': state.role.wire,
      'battery': double.parse(state.battery.toStringAsFixed(3)),
      'location': state.location?.toJson(),
      'neighbors': (live.map((n) => n.nodeId).toList()..sort()),
      'gateway_distance': state.gatewayDistance,
      'link_stability': double.parse(meanStability.toStringAsFixed(3)),
      'mobility': state.mobilityMps,
      'queue_depth': state.queue.length,
      'custody_depth': state.custody.length,
      'alive': state.alive,
    };
  }
}
