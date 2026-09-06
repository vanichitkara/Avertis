/// In-process mesh transport for development, the emulator and tests.
///
/// Nodes share a [MockRadioSpace] and hear each other according to a simple
/// range model. This is how the whole engine is exercised before any BLE
/// works — and it is what the widget tests run against.
library;

import 'dart:async';
import 'dart:math';

import '../protocol/packet.dart';
import 'mesh_transport.dart';

/// A virtual radio space that mock nodes join.
class MockRadioSpace {
  MockRadioSpace({
    this.rangeM = 120.0,
    this.lossProbability = 0.0,
    this.latency = const Duration(milliseconds: 60),
    int seed = 42,
  }) : _rng = Random(seed);

  final double rangeM;
  final double lossProbability;
  final Duration latency;
  final Random _rng;

  final Map<String, MockMeshTransport> _nodes = {};
  final Map<String, Point<double>> _positions = {};

  void register(MockMeshTransport transport, {double x = 0, double y = 0}) {
    _nodes[transport.nodeId] = transport;
    _positions[transport.nodeId] = Point(x, y);
    _announceNeighbours(transport.nodeId);
  }

  void unregister(String nodeId) {
    _nodes.remove(nodeId);
    _positions.remove(nodeId);
    for (final other in _nodes.values) {
      other.notifyPeerLost(nodeId);
    }
  }

  void moveTo(String nodeId, double x, double y) {
    final before = peersOf(nodeId).toSet();
    _positions[nodeId] = Point(x, y);
    final after = peersOf(nodeId).toSet();
    for (final gone in before.difference(after)) {
      _nodes[nodeId]?.notifyPeerLost(gone);
      _nodes[gone]?.notifyPeerLost(nodeId);
    }
    _announceNeighbours(nodeId);
  }

  void _announceNeighbours(String nodeId) {
    for (final peer in peersOf(nodeId)) {
      _nodes[nodeId]?.notifyPeerFound(PeerInfo(nodeId: peer));
      _nodes[peer]?.notifyPeerFound(PeerInfo(nodeId: nodeId));
    }
  }

  double _distance(String a, String b) {
    final pa = _positions[a], pb = _positions[b];
    if (pa == null || pb == null) return double.infinity;
    return sqrt(pow(pa.x - pb.x, 2) + pow(pa.y - pb.y, 2));
  }

  List<String> peersOf(String nodeId) {
    final transport = _nodes[nodeId];
    if (transport == null || !transport.running) return const [];
    final out = <String>[];
    for (final entry in _nodes.entries) {
      if (entry.key == nodeId || !entry.value.running) continue;
      if (_distance(nodeId, entry.key) < rangeM) out.add(entry.key);
    }
    out.sort();
    return out;
  }

  Future<bool> transmit(String from, String to, Packet packet) async {
    final target = _nodes[to];
    if (target == null || !target.running) return false;
    if (_distance(from, to) >= rangeM) return false;
    if (lossProbability > 0 && _rng.nextDouble() < lossProbability) {
      // The sender still transmitted; loss is invisible to it, exactly as on
      // a real radio.
      return true;
    }
    if (latency > Duration.zero) {
      Future.delayed(latency, () => target.deliver(from, packet));
    } else {
      scheduleMicrotask(() => target.deliver(from, packet));
    }
    return true;
  }
}

class MockMeshTransport extends MeshTransport {
  MockMeshTransport(super.nodeId, this.space);

  final MockRadioSpace space;
  bool running = false;

  final _incoming =
      StreamController<({String from, Packet packet})>.broadcast();
  final _peerFound = StreamController<PeerInfo>.broadcast();
  final _peerLost = StreamController<String>.broadcast();

  @override
  Stream<({String from, Packet packet})> get incoming => _incoming.stream;

  @override
  Stream<PeerInfo> get peerFound => _peerFound.stream;

  @override
  Stream<String> get peerLost => _peerLost.stream;

  @override
  Future<void> start() async => running = true;

  @override
  Future<void> stop() async => running = false;

  @override
  List<String> get peers => running ? space.peersOf(nodeId) : const [];

  @override
  Future<bool> send(String toNode, Packet packet) async {
    if (!running) return false;
    return space.transmit(nodeId, toNode, packet);
  }

  @override
  Future<int> broadcast(Packet packet) async {
    if (!running) return 0;
    var sent = 0;
    for (final peer in peers) {
      if (await space.transmit(nodeId, peer, packet)) sent++;
    }
    return sent;
  }

  void deliver(String from, Packet packet) {
    if (running && !_incoming.isClosed) {
      _incoming.add((from: from, packet: packet));
    }
  }

  void notifyPeerFound(PeerInfo peer) {
    if (running && !_peerFound.isClosed) _peerFound.add(peer);
  }

  void notifyPeerLost(String nodeId) {
    if (!_peerLost.isClosed) _peerLost.add(nodeId);
  }

  Future<void> dispose() async {
    await stop();
    space.unregister(nodeId);
    await _incoming.close();
    await _peerFound.close();
    await _peerLost.close();
  }
}
