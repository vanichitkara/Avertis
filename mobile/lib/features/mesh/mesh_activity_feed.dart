/// Live mesh activity — rendered straight from the event bus.
///
/// This is deliberately the *same* event stream the replay log is written
/// from, so what the phone shows is what the mesh did, not a narration of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../mesh/mesh_events.dart';

class MeshActivityFeed extends ConsumerWidget {
  const MeshActivityFeed({super.key, this.limit = 30});

  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching the stream keeps this rebuilding as events arrive; the log
    // itself is the source of truth for what to draw.
    ref.watch(meshEventsProvider);
    final events = ref.watch(meshControllerProvider).bus.log;

    if (events.isEmpty) {
      return const Center(
        child: Text('No mesh activity yet',
            style: TextStyle(color: AvertisColors.textSecondary)),
      );
    }

    final recent = events.reversed.take(limit).toList();
    return ListView.separated(
      itemCount: recent.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, i) => _EventTile(event: recent[i]),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final MeshEvent event;

  @override
  Widget build(BuildContext context) {
    final time = event.at.toLocal();
    final clock = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(clock,
            style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: AvertisColors.textSecondary)),
        const SizedBox(width: 10),
        Container(
          margin: const EdgeInsets.only(top: 4),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
              color: _colorFor(event.type), shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(event.label,
              style: const TextStyle(
                  fontSize: 12, color: AvertisColors.textPrimary)),
        ),
      ],
    );
  }

  Color _colorFor(MeshEventType type) => switch (type) {
        MeshEventType.nodeDown ||
        MeshEventType.linkDown ||
        MeshEventType.packetDropped ||
        MeshEventType.queueDrop ||
        MeshEventType.partitionDetected =>
          AvertisColors.lifeCritical,
        MeshEventType.nodeSuspect ||
        MeshEventType.routeChanged ||
        MeshEventType.relayElected =>
          AvertisColors.operational,
        MeshEventType.linkUp ||
        MeshEventType.packetDelivered ||
        MeshEventType.partitionHealed ||
        MeshEventType.syncCompleted ||
        MeshEventType.gatewayUp =>
          AvertisColors.online,
        _ => AvertisColors.mesh,
      };
}
