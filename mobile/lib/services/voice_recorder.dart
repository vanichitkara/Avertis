/// Voice reports.
///
/// Speaking is faster than typing, works with wet or injured hands, and works
/// for someone who cannot see the screen. It is often the only usable input in
/// the situations this app is built for.
///
/// The audio itself does **not** travel over the mesh (docs/protocol.md §5):
/// only a media descriptor does, and the bytes upload when a gateway window
/// opens. A 30-second clip is tens of kilobytes — enough to delay every
/// life-critical text report behind it on a link that manages a few kB/s.
/// Transcription is the backend's job; this records and hands over a file.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Long enough to describe an emergency, short enough to sync in one window.
const Duration maxRecordingDuration = Duration(seconds: 60);

class VoiceRecording {
  const VoiceRecording({
    required this.path,
    required this.duration,
    required this.bytes,
  });

  final String path;
  final Duration duration;
  final int bytes;
}

enum RecorderStatus { idle, denied, recording, stopped, unavailable }

class VoiceRecorder {
  VoiceRecorder({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  Timer? _limitTimer;
  DateTime? _startedAt;
  String? _path;

  RecorderStatus status = RecorderStatus.idle;

  final _statusChanges = StreamController<RecorderStatus>.broadcast();
  Stream<RecorderStatus> get statusChanges => _statusChanges.stream;

  /// Elapsed time, so the UI can show a running counter and the cap.
  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  Future<bool> start() async {
    if (!await _recorder.hasPermission()) {
      _set(RecorderStatus.denied);
      return false;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(
        dir.path,
        'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _recorder.start(
        // AAC in an m4a container: small enough to sync in a short window and
        // decodable server-side without extra tooling.
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 22050,
          numChannels: 1,
        ),
        path: path,
      );
      _path = path;
      _startedAt = DateTime.now();
      _set(RecorderStatus.recording);

      // Hard cap. An accidentally open microphone would otherwise fill the
      // disk and produce a clip too large to ever sync.
      _limitTimer = Timer(maxRecordingDuration, () => unawaited(stop()));
      return true;
    } on Exception {
      _set(RecorderStatus.unavailable);
      return false;
    }
  }

  Future<VoiceRecording?> stop() async {
    _limitTimer?.cancel();
    _limitTimer = null;
    if (status != RecorderStatus.recording) return null;

    final duration = elapsed;
    try {
      final path = await _recorder.stop() ?? _path;
      _startedAt = null;
      _set(RecorderStatus.stopped);
      if (path == null) return null;

      final file = File(path);
      if (!file.existsSync()) return null;
      return VoiceRecording(
        path: path,
        duration: duration,
        bytes: await file.length(),
      );
    } on Exception {
      _set(RecorderStatus.unavailable);
      return null;
    }
  }

  /// Abandon a recording and delete it. Used when the user discards.
  Future<void> cancel() async {
    _limitTimer?.cancel();
    _limitTimer = null;
    try {
      final path = await _recorder.stop() ?? _path;
      if (path != null) {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      }
    } on Exception {
      // Nothing to clean up.
    }
    _startedAt = null;
    _set(RecorderStatus.idle);
  }

  void _set(RecorderStatus next) {
    status = next;
    if (!_statusChanges.isClosed) _statusChanges.add(next);
  }

  Future<void> dispose() async {
    _limitTimer?.cancel();
    await _recorder.dispose();
    await _statusChanges.close();
  }
}
