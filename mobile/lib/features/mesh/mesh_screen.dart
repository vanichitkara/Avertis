/// Mesh detail — neighbours, link quality, and what this node is holding.
///
/// This is the screen that makes the mesh legible during a demo: every number
/// here is measured by this device, not reported by a server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mesh_controller.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../mesh/protocol/packet.dart';
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
            _TransportSwitch(
              mode: status.transport,
              advertisingWarning: controller.advertisingWarning,
            ),
            const SizedBox(height: 12),
            if (controller.hasBackend) ...[
              _SyncCard(controller: controller),
              const SizedBox(height: 12),
            ],
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
                      // A gateway is the way out, so it is never "no route"
                      // to itself. It reports no distance because the
                      // question does not apply to it.
                      status.role == NodeRole.gateway
                          ? 'this node is the gateway'
                          : status.gatewayDistance == null
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


/// Choose the radio.
///
/// Switching restarts the node: it leaves one mesh and joins another, so any
/// neighbours are lost and rediscovered. Reports already in custody survive —
/// they are on disk — but this is not a cosmetic toggle, and it says so.
class _TransportSwitch extends ConsumerWidget {
  const _TransportSwitch({required this.mode, required this.advertisingWarning});

  final TransportMode mode;
  final String? advertisingWarning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBle = mode == TransportMode.ble;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RADIO',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 1.2)),
            const SizedBox(height: 12),
            SegmentedButton<TransportMode>(
              segments: const [
                ButtonSegment(
                  value: TransportMode.mock,
                  label: Text('Simulated'),
                  icon: Icon(Icons.memory, size: 16),
                ),
                ButtonSegment(
                  value: TransportMode.ble,
                  label: Text('Bluetooth'),
                  icon: Icon(Icons.bluetooth, size: 16),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) async {
                final next = selection.first;
                if (next == mode) return;
                final confirmed = await _confirm(context, next);
                if (!confirmed) return;
                // Remember it before switching. A deliberate choice that
                // is forgotten on restart is how both test phones ended up
                // back on a radio that cannot reach anything.
                await ref.read(radioPreferenceProvider).remember(next);
                ref.read(transportModeProvider.notifier).state = next;
              },
            ),
            const SizedBox(height: 10),
            Text(
              isBle
                  ? 'Real Bluetooth LE. This node advertises so other phones '
                      'can find it, and scans for theirs.'
                  : 'Simulated radio, in this app only. Other phones cannot '
                      'see this node — each app has its own simulated space.',
              style: const TextStyle(
                  fontSize: 11, color: AvertisColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Text(
              ref.watch(radioChoiceProvider).explanation,
              style: const TextStyle(
                  fontSize: 11, color: AvertisColors.textSecondary),
            ),
            if (isBle && advertisingWarning != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: AvertisColors.operational),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      advertisingWarning!,
                      style: const TextStyle(
                          fontSize: 11, color: AvertisColors.operational),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(BuildContext context, TransportMode next) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch radio?'),
        content: Text(
          next == TransportMode.ble
              ? 'This node will restart on Bluetooth. Nearby nodes are lost '
                  'and rediscovered. Reports already waiting are kept.'
              : 'This node will restart on the simulated radio and will no '
                  'longer reach other phones. Reports already waiting are '
                  'kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('SWITCH'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// Spend a connectivity window on demand.
///
/// Shown only when a backend is configured — offering a sync with nowhere to
/// send it would be a button that always fails.
class _SyncCard extends StatefulWidget {
  const _SyncCard({required this.controller});

  final MeshController controller;

  @override
  State<_SyncCard> createState() => _SyncCardState();
}

class _SyncCardState extends State<_SyncCard> {
  bool _syncing = false;
  String? _lastResult;

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _lastResult = null;
    });
    final result = await widget.controller.syncNow();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _lastResult = switch (result) {
        null => 'No backend configured.',
        final r when !r.ok => 'Sync failed — everything is still held.',
        final r => '${r.accepted} report(s) delivered'
            '${r.deferred > 0 ? ', ${r.deferred} deferred' : ''}'
            '${r.media.uploaded > 0 ? ', ${r.media.uploaded} file(s) sent' : ''}',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    // Count what a sync would actually carry — reports held for others *and*
    // this node's own unacknowledged ones — rather than saying "nothing
    // waiting" while an unsent SOS sits on the device.
    final held = widget.controller.gateway?.heldReports().length ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('GATEWAY',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 1.2)),
            const SizedBox(height: 8),
            Text(
              held == 0
                  ? 'Nothing waiting to be sent.'
                  : '$held report(s) waiting for a connectivity window.',
              style: const TextStyle(
                  fontSize: 12, color: AvertisColors.textSecondary),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _syncing ? null : _sync,
              icon: _syncing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload_outlined, size: 18),
              label: Text(_syncing ? 'SYNCING…' : 'SYNC NOW'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46)),
            ),
            if (_lastResult != null) ...[
              const SizedBox(height: 8),
              Text(_lastResult!,
                  style: const TextStyle(
                      fontSize: 11, color: AvertisColors.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}
