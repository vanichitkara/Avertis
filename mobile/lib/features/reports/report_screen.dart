/// Incident report — text, optional photo, location, priority.
///
/// Priority is chosen by the reporter, but the backend may reclassify after
/// Gemini analysis. That is explained on screen rather than hidden, because a
/// reporter who believes their chosen priority is final will misuse it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../mesh/protocol/packet.dart';

class ReportScreen extends ConsumerStatefulWidget {
  const ReportScreen({super.key, this.locationOnly = false});

  final bool locationOnly;

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  final _textController = TextEditingController();
  Priority _priority = Priority.emergency;
  XFile? _photo;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    if (widget.locationOnly) {
      _textController.text = 'Sharing my location.';
      _priority = Priority.operational;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _attachPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1280,
      imageQuality: 70,
    );
    if (picked != null) setState(() => _photo = picked);
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);

    // Media is described, not carried: only the descriptor travels over the
    // mesh, and the bytes upload when a gateway window opens
    // (docs/protocol.md §5). This keeps critical text traffic fast.
    final media = <Map<String, dynamic>>[
      if (_photo != null)
        {
          'kind': 'IMAGE',
          'media_id': 'med-${DateTime.now().millisecondsSinceEpoch}',
          'local_path': _photo!.path,
          'bytes': await _photo!.length(),
          'inline': false,
        },
    ];

    try {
      await ref
          .read(meshControllerProvider)
          .sendIncident(text, priority: _priority, media: media);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report queued for the mesh')),
      );
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.locationOnly ? 'SHARE LOCATION' : 'REPORT INCIDENT'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _textController,
              maxLines: 5,
              autofocus: !widget.locationOnly,
              decoration: const InputDecoration(
                labelText: 'What is happening?',
                hintText: 'e.g. three people trapped near the bridge, '
                    'water is rising',
              ),
            ),
            const SizedBox(height: 20),
            const Text('Priority',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            RadioGroup<Priority>(
              groupValue: _priority,
              onChanged: (v) => setState(() => _priority = v!),
              child: Column(
                children: [
                  for (final p in Priority.values)
                    RadioListTile<Priority>(
                      value: p,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: colorForPriority(p.wire),
                      title: Text(p.wire.replaceAll('_', ' '),
                          style: TextStyle(
                              color: colorForPriority(p.wire),
                              fontWeight: FontWeight.w700,
                              fontSize: 14)),
                      subtitle: Text(_describe(p),
                          style: const TextStyle(
                              fontSize: 12,
                              color: AvertisColors.textSecondary)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'The command centre may reclassify this after analysis. Your '
              'choice decides how it is relayed right now.',
              style:
                  TextStyle(fontSize: 11, color: AvertisColors.textSecondary),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _attachPhoto,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(_photo == null ? 'ADD PHOTO' : 'PHOTO ATTACHED'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: _photo == null
                    ? AvertisColors.textPrimary
                    : AvertisColors.online,
              ),
            ),
            if (_photo != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'The photo stays on this device until a gateway is '
                  'reachable — only its description travels over the mesh.',
                  style: TextStyle(
                      fontSize: 11, color: AvertisColors.textSecondary),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('SEND REPORT'),
            ),
          ],
        ),
      ),
    );
  }

  String _describe(Priority p) => switch (p) {
        Priority.lifeCritical => 'Life at immediate risk',
        Priority.emergency => 'Urgent, not immediately life-threatening',
        Priority.operational => 'Coordination and logistics',
        Priority.normal => 'Background information',
      };
}
