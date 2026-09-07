/// Gateway client — the bridge from mesh to backend (docs/api.md).
///
/// Dart sibling of simulator/avertis_sim/gateway_client.py. The interesting
/// behaviour is critical-first sync under a time budget: a connectivity window
/// is short, so what goes first matters.
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../mesh/mesh_engine.dart';
import '../mesh/mesh_events.dart';
import '../mesh/protocol/packet.dart';
import 'media_uploader.dart';

/// What one second of a *recovered but degraded* uplink carries, in bytes.
/// A brief opportunistic window during a disaster is congested and shared, so
/// this is deliberately conservative (~24 kbit/s) rather than nominal LTE.
const int assumedUplinkBytesPerSecond = 3000;
const int maxSyncBytes = 2 * 1024 * 1024;

/// Never let the topology snapshot crowd out the reports themselves.
const double maxTopologyFraction = 0.35;

class SyncResult {
  const SyncResult({
    required this.attempted,
    required this.accepted,
    required this.deferred,
    required this.bytesSent,
    this.incidentIds = const [],
    this.acceptedReportIds = const [],
    this.media = MediaUploadResult.none,
    this.error,
  });

  final int attempted;
  final int accepted;
  final int deferred;
  final int bytesSent;
  final List<String> incidentIds;
  final List<String> acceptedReportIds;

  /// What the leftover window carried, after the reports.
  final MediaUploadResult media;
  final String? error;

  bool get ok => error == null;
}

abstract class SyncBackend {
  Future<Map<String, dynamic>> postSync(Map<String, dynamic> body);
  Future<bool> health();
}

class HttpSyncBackend implements SyncBackend {
  HttpSyncBackend({required String baseUrl, String apiKey = ''})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          connectTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'X-Avertis-Key': apiKey,
          },
        ));

  final Dio _dio;

  @override
  Future<Map<String, dynamic>> postSync(Map<String, dynamic> body) async {
    final response =
        await _dio.post<Map<String, dynamic>>('/api/v1/gateway/sync', data: body);
    return response.data ?? const {};
  }

  /// Check the window is genuinely usable before spending it on a large sync.
  @override
  Future<bool> health() async {
    try {
      final r = await _dio.get<dynamic>('/api/v1/health');
      return r.statusCode == 200;
    } on DioException {
      return false;
    }
  }
}

class GatewayClient {
  GatewayClient({
    required this.engine,
    required this.backend,
    required this.bus,
    this.uploader,
  });

  final MeshEngine engine;
  final SyncBackend backend;
  final MeshEventBus bus;

  /// Optional: without it, media descriptors still sync and the bytes simply
  /// stay on the device. Reports are never held back waiting for photos.
  final MediaUploader? uploader;

  final Set<String> _syncedReportIds = {};

  /// Reports the gateway holds, one copy per report.
  ///
  /// Custody retransmissions mean the same report can arrive several times by
  /// different routes. Each copy is a legitimate packet, but they are one
  /// report — sending all of them would spend a scarce window on duplicates.
  List<Packet> heldReports() {
    final unique = <String, Packet>{};
    for (final packet in engine.state.pendingReports) {
      final reportId = packet.payload['report_id'] as String?;
      if (reportId == null || _syncedReportIds.contains(reportId)) continue;
      final existing = unique[reportId];
      if (existing == null || packet.createdAt.isBefore(existing.createdAt)) {
        unique[reportId] = packet;
      }
    }
    return unique.values.toList();
  }

  /// LIFE_CRITICAL first, then oldest first (docs/protocol.md §4).
  static List<Packet> syncOrder(List<Packet> packets) {
    final sorted = [...packets];
    sorted.sort((a, b) {
      final byPriority = a.priority.rank.compareTo(b.priority.rank);
      return byPriority != 0
          ? byPriority
          : a.createdAt.compareTo(b.createdAt);
    });
    return sorted;
  }

  Map<String, dynamic> _reportBody(Packet packet) {
    final p = packet.payload;
    return {
      'report_id': p['report_id'],
      'origin_node': packet.originNode,
      'created_at': isoOf(packet.createdAt),
      'priority': packet.priority.wire,
      'kind': packet.messageType == MessageType.sos ? 'SOS' : 'REPORT',
      'location': p['location'],
      'text': p['text'] ?? p['note'],
      'transcript': p['transcript'],
      // Device-local paths are stripped: they mean nothing off this handset
      // and are not part of the frozen descriptor (docs/protocol.md §5).
      'media': wireMediaDescriptors(p['media']),
      'hop_count': packet.hopCount,
      'path': packet.path,
    };
  }

  /// Spend a connectivity window. Returns what actually happened — nothing is
  /// reported as sent that was not sent.
  Future<SyncResult> sync({
    required double windowSeconds,
    Map<String, dynamic>? metrics,
  }) async {
    final pending = heldReports();
    final ordered = syncOrder(pending);

    final budget = (windowSeconds * assumedUplinkBytesPerSecond)
        .round()
        .clamp(0, maxSyncBytes);

    final body = <String, dynamic>{
      'gateway_id': engine.nodeId,
      'sent_at': isoOf(DateTime.now().toUtc()),
      'connectivity_window_seconds':
          double.parse(windowSeconds.toStringAsFixed(1)),
      'nodes': <Map<String, dynamic>>[],
      'links': <Map<String, dynamic>>[],
      'incidents': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
      'metrics': metrics ??
          {
            'nodes_total': engine.state.neighbors.length + 1,
            'queue_depth_total': engine.queueDepth,
          },
    };

    var used = utf8.encode(jsonEncode(body)).length;
    final reportBudget = budget - (budget * maxTopologyFraction).round();
    final batch = <Packet>[];

    for (final packet in ordered) {
      final report = _reportBody(packet);
      final size = utf8.encode(jsonEncode(report)).length;
      if (used + size > reportBudget && batch.isNotEmpty) break;
      (body['incidents'] as List).add(report);
      batch.add(packet);
      used += size;
    }

    // Whatever budget is left carries this node's own view of the topology.
    final snapshot = engine.snapshot();
    final snapshotSize = utf8.encode(jsonEncode(snapshot)).length;
    if (used + snapshotSize <= budget) {
      (body['nodes'] as List).add(snapshot);
      used += snapshotSize;
    }

    bus.emit(MeshEvent(MeshEventType.syncStarted, engine.nodeId, {
      'window_seconds': windowSeconds,
      'queued': ordered.length,
      'batched': batch.length,
      'budget_bytes': budget,
    }));

    if (batch.isEmpty) {
      bus.emit(MeshEvent(MeshEventType.syncCompleted, engine.nodeId, {
        'accepted': 0,
        'deferred': ordered.length,
      }));
      return SyncResult(
        attempted: 0,
        accepted: 0,
        deferred: ordered.length,
        bytesSent: used,
      );
    }

    Map<String, dynamic> response;
    try {
      response = await backend.postSync(body);
    } catch (error) {
      // Any failure means "keep everything" — a failed sync must never
      // discard a report.
      bus.emit(MeshEvent(MeshEventType.syncCompleted, engine.nodeId, {
        'accepted': 0,
        'deferred': ordered.length,
        'error': error.runtimeType.toString(),
      }));
      return SyncResult(
        attempted: batch.length,
        accepted: 0,
        deferred: ordered.length,
        bytesSent: used,
        error: error.toString(),
      );
    }

    final accepted = List<String>.from(
        (response['accepted'] as List?) ?? const <String>[]);
    _syncedReportIds.addAll(accepted);

    final incidents = ((response['incidents'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final incidentIds =
        incidents.map((i) => i['incident_id'] as String).toList();

    // Anything acknowledged is no longer this node's problem.
    engine.state.pendingReports.removeWhere(
      (p) => accepted.contains(p.payload['report_id']),
    );

    // Only now, with the reports safely acknowledged, spend what is left of
    // the window on the bytes. A photo is evidence; a report is a person.
    var mediaResult = MediaUploadResult.none;
    if (uploader != null && accepted.isNotEmpty) {
      // Resolve files from the original packets, not the wire bodies — the
      // latter have local_path stripped, which is exactly the field needed.
      final pending = uploader!.pendingFor(
        batch.map((packet) => {
              'report_id': packet.payload['report_id'],
              'media': packet.payload['media'] ?? const [],
            }),
        accepted.toSet(),
      );
      mediaResult = await uploader!.upload(
        pending,
        budgetBytes: (budget - used).clamp(0, maxSyncBytes),
      );
    }

    bus.emit(MeshEvent(MeshEventType.syncCompleted, engine.nodeId, {
      'accepted': accepted.length,
      'deferred': ordered.length - batch.length,
      'bytes': used + mediaResult.bytesSent,
      'incident_ids': incidentIds.take(10).toList(),
      if (mediaResult.uploaded > 0 ||
          mediaResult.deferred > 0 ||
          mediaResult.failed > 0)
        'media': {
          'uploaded': mediaResult.uploaded,
          'deferred': mediaResult.deferred,
          'failed': mediaResult.failed,
          'bytes': mediaResult.bytesSent,
        },
    }));

    return SyncResult(
      attempted: batch.length,
      accepted: accepted.length,
      deferred: ordered.length - batch.length,
      bytesSent: used + mediaResult.bytesSent,
      incidentIds: incidentIds,
      acceptedReportIds: accepted,
      media: mediaResult,
    );
  }
}
