/// Per-node mesh state: neighbours, link quality, queues, seen-set, custody.
///
/// Sibling of simulator/avertis_sim/node_state.py — the two must agree on
/// behaviour, and the shared fixtures pin the parts that go on the wire.
library;

import 'dart:collection';

import 'protocol/packet.dart';

// docs/protocol.md §9
const Duration beaconInterval = Duration(seconds: 3);
const int suspectAfterMissed = 3;
const int downAfterMissed = 5;

const int seenCapacity = 4096;
const Duration seenTtl = Duration(minutes: 30);
const int queueCapacity = 512;

enum LinkState { up, suspect, down }

/// One node's view of a directly reachable peer.
class Neighbor {
  Neighbor(this.nodeId);

  final String nodeId;
  NodeRole role = NodeRole.survivor;
  double battery = 1.0;
  GeoPoint? location;
  int? gatewayDistance;
  DateTime lastSeen = DateTime.now().toUtc();
  int lastSeq = -1;
  int rssi = -70;

  /// EWMA of beacon delivery ratio — docs/protocol.md §8.
  double stability = 1.0;
  LinkState state = LinkState.up;

  /// Set once NODE_DOWN has been announced, so route recovery runs exactly
  /// once per failure. Cleared when the peer comes back.
  bool downAnnounced = false;

  void observeBeacon(DateTime now, int seq, {double alpha = 0.3}) {
    var missed = 0;
    if (lastSeq >= 0) missed = (seq - lastSeq - 1).clamp(0, 5);
    for (var i = 0; i < missed; i++) {
      stability = (1 - alpha) * stability;
    }
    stability = ((1 - alpha) * stability + alpha).clamp(0.0, 1.0);
    lastSeq = seq;
    lastSeen = now;
    state = LinkState.up;
    downAnnounced = false;
  }

  /// Recompute UP/SUSPECT/DOWN from silence.
  LinkState ageOut(DateTime now) {
    final missed =
        now.difference(lastSeen).inMilliseconds / beaconInterval.inMilliseconds;
    if (missed >= downAfterMissed) {
      state = LinkState.down;
    } else if (missed >= suspectAfterMissed) {
      state = LinkState.suspect;
    }
    return state;
  }
}

/// Time- and size-bounded packet-ID dedup cache (docs/protocol.md §6.1).
class SeenSet {
  final LinkedHashMap<String, DateTime> _items = LinkedHashMap();

  bool seen(String packetId, DateTime now) {
    final ts = _items[packetId];
    if (ts == null) return false;
    if (now.difference(ts) > seenTtl) {
      _items.remove(packetId);
      return false;
    }
    return true;
  }

  void add(String packetId, DateTime now) {
    _items.remove(packetId);
    _items[packetId] = now;
    while (_items.length > seenCapacity) {
      _items.remove(_items.keys.first);
    }
  }

  int get length => _items.length;
}

class QueueEntry {
  QueueEntry(this.packet, {this.nextHop});

  final Packet packet;
  String? nextHop;
  int attempts = 0;
  DateTime? lastAttempt;
}

/// Priority queue: LIFE_CRITICAL first, then oldest-first within a class.
/// Overflow drops the lowest-priority, oldest packet (docs/protocol.md §8).
class PacketQueue {
  PacketQueue({this.capacity = queueCapacity});

  final int capacity;
  final List<QueueEntry> _entries = [];
  final Set<String> _ids = {};

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  int _compare(QueueEntry a, QueueEntry b) {
    final byPriority = a.packet.priority.rank.compareTo(b.packet.priority.rank);
    if (byPriority != 0) return byPriority;
    return a.packet.createdAt.compareTo(b.packet.createdAt);
  }

  /// Enqueue. Returns the packet evicted by overflow, if any.
  Packet? push(Packet packet, {String? nextHop}) {
    if (_ids.contains(packet.packetId)) return null;
    _entries.add(QueueEntry(packet, nextHop: nextHop));
    _ids.add(packet.packetId);
    _entries.sort(_compare);
    if (_entries.length > capacity) {
      final worst = _entries.removeLast();
      _ids.remove(worst.packet.packetId);
      return worst.packet;
    }
    return null;
  }

  /// Snapshot in delivery order.
  List<QueueEntry> get entries => List.unmodifiable(_entries);

  void removeWhere(bool Function(QueueEntry) test) {
    _entries.removeWhere((e) {
      if (test(e)) {
        _ids.remove(e.packet.packetId);
        return true;
      }
      return false;
    });
  }

  /// Clear the next-hop pin on packets routed through a failed node.
  int unpinNextHop(String failedNode) {
    var n = 0;
    for (final e in _entries) {
      if (e.nextHop == failedNode) {
        e.nextHop = null;
        e.attempts = 0;
        n++;
      }
    }
    return n;
  }
}

/// A report this node owes an end-to-end ACK for.
///
/// Store-and-forward at the *report* level: the forwarding queue empties as
/// soon as a frame is handed to a neighbour, which is no guarantee the report
/// reached a gateway. Custody is what survives a partition.
class CustodyEntry {
  CustodyEntry({
    required this.reportId,
    required this.packet,
    required this.createdAt,
  }) : packetIds = {packet.packetId};

  final String reportId;
  final Packet packet;
  final DateTime createdAt;
  final Set<String> packetIds;
  int attempts = 0;
  DateTime? lastAttempt;
}

/// Everything one node knows. Mirrors docs/protocol.md §16.
class NodeState {
  NodeState({
    required this.nodeId,
    this.role = NodeRole.survivor,
    this.battery = 1.0,
    this.location,
    this.mobilityMps = 0.0,
  });

  final String nodeId;
  NodeRole role;
  double battery;
  GeoPoint? location;
  double mobilityMps;
  bool alive = true;

  final Map<String, Neighbor> neighbors = {};
  final SeenSet seen = SeenSet();
  final PacketQueue queue = PacketQueue();
  final Map<String, CustodyEntry> custody = {};

  /// Reports this node has delivered locally (a gateway holds these for sync).
  final List<Packet> pendingReports = [];
  final List<Packet> delivered = [];

  int beaconSeq = 0;
  int? gatewayDistance;

  bool get isGateway => role == NodeRole.gateway;

  List<Neighbor> get liveNeighbors =>
      neighbors.values.where((n) => n.state != LinkState.down).toList();

  /// Deterministic relay scoring baseline — docs/protocol.md §8.
  double scoreOf(Neighbor neighbor) => relayScore(
        battery: neighbor.battery,
        // A neighbour's own degree is not observable without NODE_STATUS; our
        // own degree is the best proxy a real device has.
        neighborCount: liveNeighbors.length,
        gatewayDistance: neighbor.gatewayDistance,
        linkStability: neighbor.stability,
        mobilityMps: mobilityMps,
      );
}
