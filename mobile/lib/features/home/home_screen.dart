/// Home — the screen someone sees in an emergency.
///
/// Layout follows plan §14: connectivity state at the top so it is never in
/// doubt, then the four actions, largest and reddest first.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/mesh_controller.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../mesh/mesh_activity_feed.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(meshStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AVERTIS'),
        actions: [
          IconButton(
            icon: const Icon(Icons.hub_outlined),
            tooltip: 'Mesh detail',
            onPressed: () => context.push('/mesh'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _ConnectivityCard(status: status),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AvertisColors.lifeCritical,
                minimumSize: const Size.fromHeight(96),
              ),
              onPressed: () => context.push('/sos'),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('SOS',
                      style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 3)),
                  Text('Life-critical — sends immediately',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w400)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              label: 'REPORT INCIDENT',
              icon: Icons.report_outlined,
              onPressed: () => context.push('/report'),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              label: 'SHARE LOCATION',
              icon: Icons.my_location,
              onPressed: () => context.push('/report?mode=location'),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              label: 'MY REPORTS',
              icon: Icons.inbox_outlined,
              onPressed: () => context.push('/reports'),
            ),
            const SizedBox(height: 24),
            const Text('MESH ACTIVITY',
                style: TextStyle(
                    color: AvertisColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2)),
            const SizedBox(height: 8),
            const SizedBox(height: 220, child: MeshActivityFeed(limit: 12)),
          ],
        ),
      ),
    );
  }
}

class _ConnectivityCard extends StatelessWidget {
  const _ConnectivityCard({required this.status});

  final MeshStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusRow(
              label: 'Internet',
              value: status.internetOnline ? 'ONLINE' : 'OFFLINE',
              color: status.internetOnline
                  ? AvertisColors.online
                  : AvertisColors.offline,
            ),
            const SizedBox(height: 8),
            _StatusRow(
              label: 'Mesh',
              value: status.meshConnected ? 'CONNECTED' : 'SEARCHING',
              color: status.meshConnected
                  ? AvertisColors.mesh
                  : AvertisColors.textSecondary,
            ),
            const Divider(height: 24, color: AvertisColors.outline),
            Row(
              children: [
                _Metric(
                    label: 'Nearby nodes', value: '${status.neighborCount}'),
                _Metric(
                  label: 'Mesh health',
                  // Shown only when there is something to measure it from —
                  // a health percentage with no neighbours would be fiction.
                  value: status.neighborCount == 0
                      ? '—'
                      : '${(status.meshHealth * 100).round()}%',
                ),
                _Metric(
                    label: 'Battery',
                    value: '${(status.battery * 100).round()}%'),
              ],
            ),
            if (status.queueDepth > 0 || status.custodyDepth > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AvertisColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule,
                        size: 16, color: AvertisColors.operational),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${status.custodyDepth} report(s) waiting to be '
                        'confirmed · ${status.queueDepth} packet(s) queued',
                        style: const TextStyle(
                            fontSize: 12,
                            color: AvertisColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Node ${status.nodeId} · '
              '${status.transport == TransportMode.ble ? 'BLE' : 'simulated radio'}'
              '${status.gatewayDistance != null ? ' · gateway ${status.gatewayDistance} hop(s)' : ''}',
              style: const TextStyle(
                  fontSize: 11, color: AvertisColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 10, height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Text(label,
            style: const TextStyle(
                color: AvertisColors.textSecondary, fontSize: 14)),
        const Spacer(),
        Text(value,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 14,
                letterSpacing: 0.8)),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700)),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: AvertisColors.textSecondary)),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        backgroundColor: AvertisColors.surfaceHigh,
        foregroundColor: AvertisColors.textPrimary,
        minimumSize: const Size.fromHeight(60),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Align(
        alignment: Alignment.centerLeft,
        child: Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      ),
    );
  }
}
