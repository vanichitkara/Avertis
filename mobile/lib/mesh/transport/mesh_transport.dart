/// The transport abstraction — the seam that keeps the mesh engine free of
/// any Bluetooth dependency (plan §12).
///
/// The engine only ever sees `MeshTransport`. `MockMeshTransport` runs it on
/// an emulator or in tests; `BleMeshTransport` runs it over real radios. The
/// same routing, healing and partition logic runs unchanged in both.
library;

import '../protocol/packet.dart';

/// A peer we can currently reach directly (one radio hop).
class PeerInfo {
  const PeerInfo({
    required this.nodeId,
    this.role = NodeRole.survivor,
    this.battery = 1.0,
    this.rssi = -70,
  });

  final String nodeId;
  final NodeRole role;
  final double battery;
  final int rssi;
}

abstract class MeshTransport {
  MeshTransport(this.nodeId);

  final String nodeId;

  /// Frames arriving from a directly reachable peer.
  Stream<({String from, Packet packet})> get incoming;

  /// Peers appearing and disappearing at the link layer.
  Stream<PeerInfo> get peerFound;
  Stream<String> get peerLost;

  Future<void> start();
  Future<void> stop();

  /// Currently reachable peers.
  List<String> get peers;

  /// Unicast to a direct peer. False if the link is unusable right now.
  Future<bool> send(String toNode, Packet packet);

  /// Send to every direct peer. Returns how many links were written to.
  Future<int> broadcast(Packet packet);
}
