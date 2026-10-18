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
import '../../services/incident_lookup.dart';
import '../../core/theme.dart';
import '../../data/report_store.dart';

class ReportsListScreen extends ConsumerWidget {
  const ReportsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(reportsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MY REPORTS'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear delivered reports',
            onPressed: () => _clearDelivered(context, ref),
          ),
        ],
      ),
      body: SafeArea(
        child: reports.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not load reports: $e')),
          data: (rows) => rows.isEmpty
              ? const Center(
                  child: Text(
                    'You have not sent any reports yet',
                    style: TextStyle(color: AvertisColors.textSecondary),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _ReportCard(
                    report: rows[i],
                    pendingReason: ref
                        .watch(meshControllerProvider)
                        .pendingReason(),
                    onOpen: rows[i].incidentId == null
                        ? null
                        : () =>
                              _showIncident(context, ref, rows[i].incidentId!),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Remove reports the command centre already holds.
///
/// Deliberately only the delivered ones. An unacknowledged report is the
/// only copy in existence, so no amount of tidying should be able to
/// discard someone's undelivered SOS.
Future<void> _clearDelivered(BuildContext context, WidgetRef ref) async {
  final database = ref.read(databaseProvider);
  final waiting = await database.countUnacknowledged();
  if (!context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Clear delivered reports?'),
      content: Text(
        waiting == 0
            ? 'Removes reports the command centre has confirmed it holds. '
                  'They stay on the command centre; only this phone\'s copy '
                  'goes.'
            : 'Removes reports the command centre has confirmed it holds.\n\n'
                  '$waiting report(s) still waiting to be sent will be kept — '
                  'this phone has the only copy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('CLEAR'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  final removed = await database.deleteAcknowledged();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        removed == 0
            ? 'Nothing to clear — no reports have been delivered yet.'
            : 'Cleared $removed delivered report(s)'
                  '${waiting > 0 ? ', kept $waiting still waiting' : ''}.',
      ),
    ),
  );
}

/// Show what the command centre made of this report.
void _showIncident(BuildContext context, WidgetRef ref, String incidentId) {
  final lookup = ref.read(meshControllerProvider).incidentLookup;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AvertisColors.surface,
    showDragHandle: true,
    // Without this the sheet is capped at half the screen, and on a small
    // phone the detail below the fold is simply unreachable.
    isScrollControlled: true,
    builder: (_) => _IncidentSheet(incidentId: incidentId, lookup: lookup),
  );
}

/// The sheet holds its own request.
///
/// Built inline in a FutureBuilder, the fetch restarted on every rebuild —
/// and the parent rebuilds once a second from the mesh status timer — so
/// the sheet flashed back to a spinner continually and never settled. The
/// future is created once, here.
class _IncidentSheet extends StatefulWidget {
  const _IncidentSheet({required this.incidentId, required this.lookup});

  final String incidentId;
  final IncidentLookup? lookup;

  @override
  State<_IncidentSheet> createState() => _IncidentSheetState();
}

class _IncidentSheetState extends State<_IncidentSheet> {
  late final Future<IncidentView?> _incident =
      widget.lookup?.fetch(widget.incidentId) ?? Future.value(null);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) => FutureBuilder<IncidentView?>(
        future: _incident,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          // Scrollable in its own right, so a drag moves the content
          // rather than dismissing the sheet.
          return SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            child: snapshot.data == null
                ? _unavailable(widget.incidentId)
                : _details(snapshot.data!),
          );
        },
      ),
    );
  }

  Widget _unavailable(String incidentId) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        incidentId,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      // The report is not in doubt — only our ability to look it up.
      const Text(
        'Your report reached the command centre. Its current details '
        'cannot be fetched right now — that needs a connection.',
        style: TextStyle(color: AvertisColors.textSecondary),
      ),
    ],
  );

  Widget _details(IncidentView view) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            view.incidentId,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colorForPriority(view.severity),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              view.severity.replaceAll('_', ' '),
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (view.description != null && view.description!.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(view.description!),
        ),
      _detail('Classified as', view.type.toLowerCase()),
      _detail('Status', view.status.toLowerCase()),
      _detail(
        'People affected',
        view.peopleAffected?.toString() ?? 'not stated — nobody guessed one',
      ),
      _detail(
        'Confidence',
        '${(view.confidence * 100).round()}% from '
            '${view.sourceCount} source(s)',
      ),
      if (view.recommendedResponder != null)
        _detail('Responder assigned', view.recommendedResponder!),
      if (view.wasFused)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            '${view.sourceCount} people reported this event. They were '
            'combined into one incident so the command centre sees it '
            'once.',
            style: const TextStyle(
              fontSize: 12,
              color: AvertisColors.textSecondary,
            ),
          ),
        ),
    ],
  );
}

Widget _detail(String label, String value) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 130,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AvertisColors.textSecondary,
          ),
        ),
      ),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
    ],
  ),
);

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.pendingReason,
    this.onOpen,
  });

  final Report report;

  /// What is holding an unacknowledged report up, in plain words.
  final String pendingReason;

  /// Set once the report has become an incident worth opening.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final color = colorForPriority(report.priority);
    final time = DateFormat('HH:mm:ss').format(report.createdAt.toLocal());

    return Card(
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
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
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    report.kind,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AvertisColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    time,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AvertisColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                report.body ?? '(no description)',
                style: const TextStyle(fontSize: 14),
              ),
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
                    Text(
                      '· retried ${report.retransmissions}×',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AvertisColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
              // Say what is actually holding it up. Without this the same
              // line appears whether delivery is twenty seconds away or
              // impossible.
              if (!report.acknowledged)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 20),
                  child: Text(
                    pendingReason,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AvertisColors.textSecondary,
                    ),
                  ),
                ),
              if (report.incidentId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Command centre incident ${report.incidentId} — tap for '
                    'details',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AvertisColors.mesh,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
