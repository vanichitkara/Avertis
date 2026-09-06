/// Mesh detail — neighbours, link quality, and what this node is holding.
///
/// This is the screen that makes the mesh legible during a demo: every number
/// here is measured by this device, not reported by a server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../mesh/node_state.dart';
import 'mesh_activity_feed.dart';

class MeshScreen extends ConsumerWidget {
  const MeshScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(meshControllerProvider);
    final status = ref.watch(meshStatusProvider);
    final engine = controller.engine;
    final neighbors = engine?.state.neighbors.values.toList() ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('MESH')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This node · ${status.nodeId}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 10),
                    _kv('Role', status.role.wire),
                    _kv('Transport',
                        status.transport.name == 'ble'
                            ? 'Bluetooth LE'
                            : 'Simulated radio'),
                    _kv(
                      'Gateway distance',
                      status.gatewayDistance == null
                          ? 'unknown — no route to a gateway'
                          : '${status.gatewayDistance} hop(s)',
                    ),
                    _kv('Packets queued', '${status.queueDepth}'),
                    _kv('Reports awaiting acknowledgement',
                        '${status.custodyDepth}'),
                    if (engine != null) ...[
                      const Divider(
                          height: 24, color: AvertisColors.outline),
                      _kv('Forwarded', '${engine.packetsForwarded}'),
                      _kv('Delivered', '${engine.packetsDelivered}'),
                      _kv('Dropped (TTL)', '${engine.packetsDroppedTtl}'),
                      _kv('Dropped (duplicate)',
                          '${engine.packetsDroppedDup}'),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('NEIGHBOURS (${neighbors.length})',
                style: const TextStyle(
                    color: AvertisColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2)),
            const SizedBox(height: 8),
            if (neighbors.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('No nodes in range',
                    style: TextStyle(color: AvertisColors.textSecondary)),
              )
            else
              for (final neighbor in neighbors)
                _NeighborTile(neighbor: neighbor),
            const SizedBox(height: 20),
            const Text('ACTIVITY',
                style: TextStyle(
                    color: AvertisColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2)),
            const SizedBox(height: 8),
            const SizedBox(height: 320, child: MeshActivityFeed(limit: 40)),
          ],
        ),
      ),
    );
  }

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(key,
                  style: const TextStyle(
                      fontSize: 13, color: AvertisColors.textSecondary)),
            ),
            Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

class _NeighborTile extends StatelessWidget {
  const _NeighborTile({required this.neighbor});

  final Neighbor neighbor;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (neighbor.state) {
      LinkState.up => ('UP', AvertisColors.online),
      LinkState.suspect => ('SUSPECT', AvertisColors.operational),
      LinkState.down => ('DOWN', AvertisColors.lifeCritical),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(neighbor.nodeId,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  Text(
                    '${neighbor.role.wire.toLowerCase()} · '
                    'stability ${(neighbor.stability * 100).round()}% · '
                    'battery ${(neighbor.battery * 100).round()}%'
                    '${neighbor.gatewayDistance != null ? ' · gw ${neighbor.gatewayDistance}h' : ''}',
                    style: const TextStyle(
                        fontSize: 11, color: AvertisColors.textSecondary),
                  ),
                ],
              ),
            ),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8)),
          ],
        ),
      ),
    );
  }
}
