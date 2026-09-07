/// Media upload — `POST /api/v1/media/upload` (docs/api.md).
///
/// Photos and voice clips never cross the mesh. Only their descriptors do
/// (docs/protocol.md §5), because a 30-second clip is tens of kilobytes and a
/// degraded link carries a few kB/s — one clip would sit in front of every
/// life-critical text report behind it. The bytes wait here until a gateway
/// window opens.
///
/// Three rules follow from that, and they are the whole design:
///
///  1. **Text first, always.** Uploads spend only what the incident sync left
///     over. A window that fits reports but not photos should carry reports.
///  2. **Only for accepted reports.** Bytes are useless to the backend until
///     it has an incident to attach them to, so a rejected or undelivered
///     report's media is not uploaded.
///  3. **Never block the sync.** A failed upload is a missing photo. A failed
///     sync is a missing person. The first must never cause the second.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// Do not begin a file that the remaining window cannot finish. A half-sent
/// upload wastes the whole window and delivers nothing; deferring it costs one
/// window and delivers it whole on the next.
const double uploadSafetyFactor = 0.9;

class MediaUploadResult {
  const MediaUploadResult({
    required this.uploaded,
    required this.deferred,
    required this.failed,
    required this.bytesSent,
    this.uris = const {},
  });

  final int uploaded;
  final int deferred;
  final int failed;
  final int bytesSent;

  /// media_id → remote URI, for the ones that landed.
  final Map<String, String> uris;

  static const none =
      MediaUploadResult(uploaded: 0, deferred: 0, failed: 0, bytesSent: 0);
}

/// One pending file, resolved from a report's media descriptor.
class PendingMedia {
  const PendingMedia({
    required this.mediaId,
    required this.reportId,
    required this.path,
    required this.bytes,
    required this.kind,
  });

  final String mediaId;
  final String reportId;
  final String path;
  final int bytes;
  final String kind;
}

abstract class MediaBackend {
  /// Returns the remote URI, or null if the upload did not land.
  Future<String?> uploadMedia({
    required String mediaId,
    required String reportId,
    required String sha256Hex,
    required File file,
  });
}

class HttpMediaBackend implements MediaBackend {
  HttpMediaBackend({required String baseUrl, String apiKey = ''})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          connectTimeout: const Duration(seconds: 5),
          // Generous: a slow window is still a usable one, and the caller has
          // already decided this file is worth starting.
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 30),
          headers: {
            if (apiKey.isNotEmpty) 'X-Avertis-Key': apiKey,
          },
        ));

  final Dio _dio;

  @override
  Future<String?> uploadMedia({
    required String mediaId,
    required String reportId,
    required String sha256Hex,
    required File file,
  }) async {
    try {
      final form = FormData.fromMap({
        'media_id': mediaId,
        'report_id': reportId,
        'sha256': sha256Hex,
        'file': await MultipartFile.fromFile(file.path),
      });
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/media/upload',
        data: form,
      );
      if (response.statusCode != 200) return null;
      return response.data?['uri'] as String?;
    } on DioException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}

class MediaUploader {
  MediaUploader({required this.backend});

  final MediaBackend backend;

  /// Media already delivered, so a later window does not re-send it.
  final Set<String> _uploadedMediaIds = {};

  Set<String> get uploadedMediaIds => Set.unmodifiable(_uploadedMediaIds);

  /// Pull the uploadable files out of the reports the backend just accepted.
  ///
  /// [reportBodies] are the incident bodies as sent, keyed for lookup by
  /// report id; [acceptedReportIds] is what came back in `accepted`.
  List<PendingMedia> pendingFor(
    Iterable<Map<String, dynamic>> reportBodies,
    Set<String> acceptedReportIds,
  ) {
    final pending = <PendingMedia>[];
    for (final report in reportBodies) {
      final reportId = report['report_id'] as String?;
      if (reportId == null || !acceptedReportIds.contains(reportId)) continue;

      for (final raw in (report['media'] as List?) ?? const []) {
        if (raw is! Map) continue;
        final mediaId = raw['media_id'] as String?;
        final path = raw['local_path'] as String?;
        // A descriptor with no local path belongs to another node — it
        // relayed the report to us, but it holds the bytes, not us.
        if (mediaId == null || path == null) continue;
        if (_uploadedMediaIds.contains(mediaId)) continue;

        pending.add(PendingMedia(
          mediaId: mediaId,
          reportId: reportId,
          path: path,
          bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
          kind: raw['kind'] as String? ?? 'IMAGE',
        ));
      }
    }
    return pending;
  }

  /// Spend whatever the incident sync left of the window.
  ///
  /// Nothing here can fail the sync: every error path returns a count, never
  /// throws. [budgetBytes] is what the window can still carry.
  Future<MediaUploadResult> upload(
    List<PendingMedia> pending, {
    required int budgetBytes,
  }) async {
    if (pending.isEmpty || budgetBytes <= 0) {
      return MediaUploadResult(
        uploaded: 0,
        deferred: pending.length,
        failed: 0,
        bytesSent: 0,
      );
    }

    // Smallest first. With a scarce window this delivers the most evidence:
    // one large photo can cost the same as five voice clips.
    final ordered = [...pending]..sort((a, b) => a.bytes.compareTo(b.bytes));

    var remaining = (budgetBytes * uploadSafetyFactor).round();
    var uploaded = 0;
    var failed = 0;
    var deferred = 0;
    var sent = 0;
    final uris = <String, String>{};

    for (final item in ordered) {
      final file = File(item.path);

      // The file can be gone: Android clears caches, and the user may have
      // deleted it. That is not a failure to retry — it is unrecoverable, so
      // it is marked done rather than left to block every future window.
      if (!file.existsSync()) {
        _uploadedMediaIds.add(item.mediaId);
        failed++;
        continue;
      }

      final int size;
      try {
        size = await file.length();
      } on FileSystemException {
        _uploadedMediaIds.add(item.mediaId);
        failed++;
        continue;
      }

      if (size > remaining) {
        // Too big for what is left. Keep it for the next window rather than
        // starting something that cannot finish.
        deferred++;
        continue;
      }

      final String digest;
      try {
        digest = sha256.convert(await file.readAsBytes()).toString();
      } on FileSystemException {
        _uploadedMediaIds.add(item.mediaId);
        failed++;
        continue;
      }

      String? uri;
      try {
        uri = await backend.uploadMedia(
          mediaId: item.mediaId,
          reportId: item.reportId,
          sha256Hex: digest,
          file: file,
        );
      } on Exception {
        // Fire-and-forget by contract: a failed media upload never blocks
        // incident sync, so this is counted and stepped over.
        uri = null;
      }

      if (uri == null) {
        // Transient, most likely. Leave it un-marked so the next window
        // retries it.
        failed++;
        continue;
      }

      _uploadedMediaIds.add(item.mediaId);
      uris[item.mediaId] = uri;
      uploaded++;
      sent += size;
      remaining -= size;
    }

    return MediaUploadResult(
      uploaded: uploaded,
      deferred: deferred,
      failed: failed,
      bytesSent: sent,
      uris: uris,
    );
  }
}

/// Strip device-local fields from a media descriptor before it is sent.
///
/// `local_path` is meaningful only on this handset and is not part of the
/// frozen descriptor in docs/protocol.md §5. Sending it would leak a filesystem
/// path — and a username with it — to the backend for no benefit.
List<Map<String, dynamic>> wireMediaDescriptors(Object? media) {
  if (media is! List) return const [];
  return media.whereType<Map>().map((m) {
    final copy = Map<String, dynamic>.from(m.cast<String, dynamic>());
    copy.remove('local_path');
    return copy;
  }).toList();
}

/// Canonical JSON helper shared with the sync path, kept here so the uploader
/// has no dependency on the gateway client.
String canonicalJson(Object? value) => jsonEncode(value);
