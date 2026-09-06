/// Mesh events — docs/protocol.md §10.
///
/// Everything the deterministic layer does is emitted here. The UI renders
/// this stream directly, so what the screen shows is what the mesh did.
library;

import 'dart:async';

import 'protocol/packet.dart';

enum MeshEventType {
  nodeJoined('NODE_JOINED'),
  nodeSuspect('NODE_SUSPECT'),
  nodeDown('NODE_DOWN'),
  nodeRecovered('NODE_RECOVERED'),
  linkUp('LINK_UP'),
  linkDown('LINK_DOWN'),
  packetSent('PACKET_SENT'),
  packetForwarded('PACKET_FORWARDED'),
  packetDelivered('PACKET_DELIVERED'),
  packetDropped('PACKET_DROPPED'),
  queueDrop('QUEUE_DROP'),
  partitionDetected('PARTITION_DETECTED'),
  partitionHealed('PARTITION_HEALED'),
  relayElected('RELAY_ELECTED'),
  routeChanged('ROUTE_CHANGED'),
  gatewayUp('GATEWAY_UP'),
  gatewayDown('GATEWAY_DOWN'),
  syncStarted('SYNC_STARTED'),
  syncCompleted('SYNC_COMPLETED');

  const MeshEventType(this.wire);
  final String wire;
}

class MeshEvent {
  MeshEvent(this.type, this.nodeId, [this.data = const {}])
      : at = DateTime.now().toUtc();

  MeshEvent.at(this.type, this.at, this.nodeId, [this.data = const {}]);

  final MeshEventType type;
  final DateTime at;
  final String nodeId;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
        'event': type.wire,
        'at': isoOf(at),
        'node_id': nodeId,
        ...data,
      };

  /// A short line for the on-device activity feed.
  String get label => switch (type) {
        MeshEventType.linkUp => 'Node ${data['peer']} in range',
        MeshEventType.linkDown => 'Lost node ${data['peer']}',
        MeshEventType.nodeSuspect => 'Node ${data['peer']} not responding',
        MeshEventType.nodeDown => 'Node ${data['peer']} down',
        MeshEventType.packetSent => '${data['type']} sent',
        MeshEventType.packetForwarded => 'Relayed via ${data['to']}',
        MeshEventType.packetDelivered => '${data['type']} delivered',
        MeshEventType.packetDropped => 'Dropped (${data['reason']})',
        MeshEventType.queueDrop => 'Queue full — dropped ${data['priority']}',
        MeshEventType.relayElected => 'Relay → ${data['relay']}',
        MeshEventType.routeChanged => 'Route changed',
        MeshEventType.partitionDetected => 'Network partition detected',
        MeshEventType.partitionHealed => 'Network healed',
        MeshEventType.gatewayUp => 'Gateway available',
        MeshEventType.gatewayDown => 'Gateway offline',
        MeshEventType.syncStarted => 'Sync started',
        MeshEventType.syncCompleted =>
          'Synced ${data['accepted'] ?? 0} report(s)',
        MeshEventType.nodeJoined => 'Node started',
        MeshEventType.nodeRecovered => 'Node recovered',
      };
}

/// Fan-out plus a bounded in-memory log for the activity feed.
class MeshEventBus {
  MeshEventBus({int keep = 500}) : _keep = keep;

  final _controller = StreamController<MeshEvent>.broadcast();
  final List<MeshEvent> _log = [];
  final int _keep;

  Stream<MeshEvent> get stream => _controller.stream;
  List<MeshEvent> get log => List.unmodifiable(_log);

  void emit(MeshEvent event) {
    _log.add(event);
    if (_log.length > _keep) {
      _log.removeRange(0, _log.length - _keep);
    }
    if (!_controller.isClosed) _controller.add(event);
  }

  Future<void> dispose() => _controller.close();
}
