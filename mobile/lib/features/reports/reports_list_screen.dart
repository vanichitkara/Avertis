/// My reports — what this device has sent, and what it actually knows about
/// their fate.
///
/// The status shown is deliberately conservative: "waiting" until an
/// end-to-end acknowledgement arrives. Telling someone their SOS was
/// delivered when it is still sitting in a queue would be the worst kind of
/// lie this app could tell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/report_store.dart';

class ReportsListScreen extends ConsumerWidget {
  const ReportsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(reportsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('MY REPORTS')),
      body: SafeArea(
        child: reports.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not load reports: $e')),
          data: (rows) => rows.isEmpty
              ? const Center(
                  child: Text('You have not sent any reports yet',
                      style: TextStyle(color: AvertisColors.textSecondary)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _ReportCard(report: rows[i]),
                ),
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final Report report;

  @override
  Widget build(BuildContext context) {
    final color = colorForPriority(report.priority);
    final time = DateFormat('HH:mm:ss').format(report.createdAt.toLocal());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: color),
                  ),
                  child: Text(
                    report.priority.replaceAll('_', ' '),
                    style: TextStyle(
                        color: color,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8),
                  ),
                ),
                const SizedBox(width: 8),
                Text(report.kind,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AvertisColors.textSecondary,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(time,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: AvertisColors.textSecondary)),
              ],
            ),
            const SizedBox(height: 10),
            Text(report.body ?? '(no description)',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  report.acknowledged
                      ? Icons.check_circle_outline
                      : Icons.schedule,
                  size: 14,
                  color: report.acknowledged
                      ? AvertisColors.online
                      : AvertisColors.operational,
                ),
                const SizedBox(width: 6),
                Text(
                  report.acknowledged
                      ? 'Acknowledged by the network'
                      : 'Waiting for acknowledgement',
                  style: TextStyle(
                    fontSize: 12,
                    color: report.acknowledged
                        ? AvertisColors.online
                        : AvertisColors.operational,
                  ),
                ),
                if (report.retransmissions > 0) ...[
                  const SizedBox(width: 8),
                  Text('· retried ${report.retransmissions}×',
                      style: const TextStyle(
                          fontSize: 11,
                          color: AvertisColors.textSecondary)),
                ],
              ],
            ),
            if (report.incidentId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Command centre incident ${report.incidentId}',
                    style: const TextStyle(
                        fontSize: 11, color: AvertisColors.mesh)),
              ),
          ],
        ),
      ),
    );
  }
}
