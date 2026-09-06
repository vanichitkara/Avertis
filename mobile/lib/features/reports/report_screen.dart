/// Incident report — text, optional photo, location, priority.
///
/// Priority is chosen by the reporter, but the backend may reclassify after
/// Gemini analysis. That is explained on screen rather than hidden, because a
/// reporter who believes their chosen priority is final will misuse it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../mesh/protocol/packet.dart';
import '../../services/voice_recorder.dart';

class ReportScreen extends ConsumerStatefulWidget {
  const ReportScreen({super.key, this.locationOnly = false});

  final bool locationOnly;

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  final _textController = TextEditingController();
  final _recorder = VoiceRecorder();
  Priority _priority = Priority.emergency;
  XFile? _photo;
  VoiceRecording? _voice;
  Timer? _tick;
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
    _tick?.cancel();
    _textController.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_recorder.status == RecorderStatus.recording) {
      final recording = await _recorder.stop();
      _tick?.cancel();
      if (mounted) setState(() => _voice = recording);
      return;
    }

    final started = await _recorder.start();
    if (!mounted) return;
    if (!started) {
      final reason = _recorder.status == RecorderStatus.denied
          ? 'Microphone permission is needed to record a voice report.'
          : 'Recording is not available on this device.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(reason)));
      return;
    }
    // Drive the elapsed counter so the 60s cap is visible, not a surprise.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  Future<void> _discardRecording() async {
    await _recorder.cancel();
    if (mounted) setState(() => _voice = null);
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
    var text = _textController.text.trim();
    // A voice-only report is legitimate — someone may be unable to type. The
    // placeholder is honest that the words are not known on this device: only
    // the backend can transcribe, and inventing a summary here would put
    // words in a survivor's mouth.
    if (text.isEmpty && _voice != null) {
      text = 'Voice report (${_voice!.duration.inSeconds}s) — not yet '
          'transcribed.';
    }
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
      if (_voice != null)
        {
          'kind': 'AUDIO',
          'media_id': 'med-${DateTime.now().millisecondsSinceEpoch}-a',
          'local_path': _voice!.path,
          'bytes': _voice!.bytes,
          'duration_s': _voice!.duration.inSeconds,
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
            _VoiceControl(
              status: _recorder.status,
              elapsed: _recorder.elapsed,
              recording: _voice,
              onToggle: _toggleRecording,
              onDiscard: _discardRecording,
            ),
            const SizedBox(height: 12),
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


/// Record / stop / discard, with the elapsed time and the cap always visible.
class _VoiceControl extends StatelessWidget {
  const _VoiceControl({
    required this.status,
    required this.elapsed,
    required this.recording,
    required this.onToggle,
    required this.onDiscard,
  });

  final RecorderStatus status;
  final Duration elapsed;
  final VoiceRecording? recording;
  final VoidCallback onToggle;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final isRecording = status == RecorderStatus.recording;

    if (recording != null && !isRecording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AvertisColors.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AvertisColors.online),
        ),
        child: Row(
          children: [
            const Icon(Icons.graphic_eq, color: AvertisColors.online, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Voice report · ${recording!.duration.inSeconds}s',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  const Text(
                    'Sent when a gateway is reachable — the mesh carries only '
                    'its description.',
                    style: TextStyle(
                        fontSize: 11, color: AvertisColors.textSecondary),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onDiscard,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Discard recording',
              color: AvertisColors.textSecondary,
            ),
          ],
        ),
      );
    }

    final remaining = maxRecordingDuration - elapsed;
    return OutlinedButton.icon(
      onPressed: onToggle,
      icon: Icon(isRecording ? Icons.stop_circle : Icons.mic_none),
      label: Text(
        isRecording
            ? 'STOP · ${elapsed.inSeconds}s '
                '(${remaining.inSeconds}s left)'
            : 'RECORD VOICE REPORT',
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        foregroundColor:
            isRecording ? AvertisColors.lifeCritical : AvertisColors.textPrimary,
        side: BorderSide(
          color: isRecording
              ? AvertisColors.lifeCritical
              : AvertisColors.outline,
        ),
      ),
    );
  }
}
