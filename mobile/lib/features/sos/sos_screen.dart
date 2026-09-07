/// SOS — one deliberate action, then it is in the mesh.
///
/// The confirmation step exists because an accidental life-critical broadcast
/// wastes scarce relay capacity and responder attention. It is one tap, not a
/// form: everything else is optional and can be added afterwards.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../services/location_service.dart';

class SosScreen extends ConsumerStatefulWidget {
  const SosScreen({super.key});

  @override
  ConsumerState<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends ConsumerState<SosScreen> {
  final _noteController = TextEditingController();
  int? _peopleCount;
  bool _sending = false;
  String? _sentReportId;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final packet = await ref.read(meshControllerProvider).sendSos(
            note: _noteController.text.trim(),
            peopleCount: _peopleCount,
          );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sentReportId = packet.payload['report_id'] as String;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(meshStatusProvider);

    if (_sentReportId != null) {
      return _SosSentView(
        reportId: _sentReportId!,
        neighborCount: status.neighborCount,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('SEND SOS')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: AvertisColors.lifeCritical.withValues(alpha: 0.12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: AvertisColors.lifeCritical),
              ),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('LIFE-CRITICAL',
                        style: TextStyle(
                            color: AvertisColors.lifeCritical,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.5)),
                    SizedBox(height: 6),
                    Text(
                      'This is broadcast at the highest priority and is '
                      'relayed ahead of all other traffic. Use it when life '
                      'is at immediate risk.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('How many people need help?',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final n in [1, 2, 3, 4, 5])
                  ChoiceChip(
                    label: Text(n == 5 ? '5+' : '$n'),
                    selected: _peopleCount == n,
                    onSelected: (v) =>
                        setState(() => _peopleCount = v ? n : null),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _noteController,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'What is happening? (optional)',
                hintText: 'e.g. trapped on the roof, water rising',
              ),
            ),
            const SizedBox(height: 12),
            _LocationNotice(
                state: ref.watch(meshControllerProvider).locationState),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AvertisColors.lifeCritical,
                minimumSize: const Size.fromHeight(72),
              ),
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('SEND SOS NOW',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.5)),
            ),
            const SizedBox(height: 12),
            if (!status.meshConnected)
              const Text(
                'No nearby nodes right now. Your SOS is still saved and will '
                'be sent automatically as soon as any device comes in range.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: AvertisColors.operational),
              ),
          ],
        ),
      ),
    );
  }
}

class _LocationNotice extends StatelessWidget {
  const _LocationNotice({required this.state});

  final LocationState state;

  @override
  Widget build(BuildContext context) {
    final (icon, color, message) = switch (state.availability) {
      LocationAvailability.available when state.isStale => (
          Icons.location_searching,
          AvertisColors.operational,
          'Using your last known location — it may be out of date.',
        ),
      LocationAvailability.available => (
          Icons.my_location,
          AvertisColors.online,
          'Your location will be attached '
              '(±${state.point!.accuracyM.round()} m).',
        ),
      LocationAvailability.waiting => (
          Icons.location_searching,
          AvertisColors.textSecondary,
          'Still getting a location fix. Your SOS will be sent either way.',
        ),
      LocationAvailability.serviceDisabled => (
          Icons.location_disabled,
          AvertisColors.operational,
          'Location is turned off on this device, so none will be attached.',
        ),
      LocationAvailability.denied ||
      LocationAvailability.deniedForever =>
        (
          Icons.location_disabled,
          AvertisColors.operational,
          'Without location permission, responders will not know where you '
              'are. The report will still be sent.',
        ),
      LocationAvailability.unavailable => (
          Icons.location_disabled,
          AvertisColors.operational,
          'This device cannot provide a location, so none will be attached. '
              'The report will still be sent.',
        ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message,
              style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
  }
}


class _SosSentView extends ConsumerWidget {
  const _SosSentView({required this.reportId, required this.neighborCount});

  final String reportId;
  final int neighborCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(meshStatusProvider);
    // Custody is the honest signal: the report is only "confirmed" once some
    // node has acknowledged it end-to-end.
    final confirmed = status.custodyDepth == 0;

    return Scaffold(
      appBar: AppBar(title: const Text('SOS SENT')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(confirmed ? Icons.check_circle : Icons.sync,
                  size: 64,
                  color: confirmed
                      ? AvertisColors.online
                      : AvertisColors.operational),
              const SizedBox(height: 16),
              Text(
                confirmed
                    ? 'Your SOS has been acknowledged by the network.'
                    : 'Your SOS is in the mesh.',
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                confirmed
                    ? 'Another node confirmed receipt. It will be delivered '
                        'to the command centre at the next connectivity '
                        'window.'
                    : neighborCount > 0
                        ? 'Relaying through $neighborCount nearby '
                            'node(s). Waiting for confirmation.'
                        : 'No nodes in range yet. It is saved on this device '
                            'and will be sent automatically when one appears.',
                style: const TextStyle(
                    fontSize: 14, color: AvertisColors.textSecondary),
              ),
              const SizedBox(height: 20),
              Text('Report $reportId',
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AvertisColors.textSecondary)),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('DONE'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
