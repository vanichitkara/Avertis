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
import '../mesh/node_state.dart';
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
    this.incidentByReport = const {},
    this.acceptedReportIds = const [],
    this.media = MediaUploadResult.none,
    this.error,
  });

  final int attempted;
  final int accepted;
  final int deferred;
  final int bytesSent;
  final List<String> incidentIds;

  /// report_id → incident_id, as the backend paired them.
  ///
  /// The pairing is the useful part and used to be discarded: without it
  /// the app knows a report was accepted but not what it became, so it
  /// can never show the sender what the command centre made of their
  /// report.
  final Map<String, String> incidentByReport;
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
          connectTimeout: const Duration(seconds: 10),
          // The backend spends a model call per report, 10-20s each. A
          // client that gives up sooner reports a wasted window for a sync
          // the backend completed, and the report is re-sent next time.
          sendTimeout: const Duration(seconds: 90),
          receiveTimeout: const Duration(seconds: 90),
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

/// A sync failure in words someone can act on.
///
/// `error.toString()` on a Dio exception is a paragraph of stack-adjacent
/// detail that ends up in front of a survivor, and the one case that
/// matters most — the build has no API key, so every write is refused —
/// reads identically to a timeout. The status code is the whole story
/// here, so say what it means.
String describeSyncFailure(Object error) {
  if (error is! DioException) return error.toString();

  final status = error.response?.statusCode;
  switch (status) {
    case 401:
    case 403:
      return 'the command centre rejected this app\'s credentials '
          '(HTTP $status) — this build is missing its API key';
    case 413:
      return 'the batch was too large for the command centre (HTTP 413)';
    case null:
      break;
    default:
      if (status >= 500) {
        return 'the command centre returned an error (HTTP $status)';
      }
      return 'the command centre refused the send (HTTP $status)';
  }

  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'the connection timed out before the send finished';
    case DioExceptionType.connectionError:
      return 'the command centre could not be reached';
    default:
      return error.message ?? 'the send failed';
  }
}

class GatewayClient {
  GatewayClient({
    required this.engine,
    required this.backend,
    required this.bus,
    this.uploader,
    this.storedMedia,
  });

  final MeshEngine engine;
  final SyncBackend backend;
  final MeshEventBus bus;

  /// Optional: without it, media descriptors still sync and the bytes simply
  /// stay on the device. Reports are never held back waiting for photos.
  final MediaUploader? uploader;

  /// Every media descriptor this handset has on disk, however old the
  /// report. Supplied by the controller, which owns the database.
  ///
  /// Without it the only uploadable media is whatever happens to be in the
  /// current batch, and a report acknowledged over the mesh is never in a
  /// batch again — so a photo attached on a phone with no internet could
  /// never reach the backend, which is precisely the case the product
  /// exists for.
  final Future<List<({String reportId, List<dynamic> media})>> Function()?
      storedMedia;

  final Set<String> _syncedReportIds = {};

  /// Everything this node still needs to get to the backend.
  ///
  /// Two sources, and both matter:
  ///
  ///  * `pendingReports` — other people's reports this node is holding as a
  ///    gateway, waiting for a window.
  ///  * `custody` — this node's *own* reports that have not been
  ///    acknowledged by anyone yet.
  ///
  /// The second is easy to forget, and omitting it has a bad failure mode: a
  /// survivor whose phone still has internet could not upload their own SOS,
  /// because only gateway nodes populate `pendingReports`. Their report would
  /// sit on the device waiting for a mesh peer that may never appear, while
  /// the screen showed nothing waiting to send.
  ///
  /// Custody retransmission means the same report can appear several times by
  /// different routes. Each copy is a legitimate packet, but they are one
  /// report — sending all of them would spend a scarce window on duplicates.
  List<Packet> heldReports() {
    final unique = <String, Packet>{};

    void offer(Packet packet) {
      final reportId = packet.payload['report_id'] as String?;
      if (reportId == null || _syncedReportIds.contains(reportId)) return;
      final existing = unique[reportId];
      if (existing == null || packet.createdAt.isBefore(existing.createdAt)) {
        unique[reportId] = packet;
      }
    }

    for (final packet in engine.state.pendingReports) {
      offer(packet);
    }
    for (final entry in engine.state.custody.values) {
      offer(entry.packet);
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
      // Stated outright on the SOS screen. The backend will not infer a
      // headcount it was not given, so dropping this here means dispatching
      // for an unknown number of people when the person told us the number.
      'people_count': p['people_count'],
      // Device-local paths are stripped: they mean nothing off this handset
      // and are not part of the frozen descriptor (docs/protocol.md §5).
      'media': wireMediaDescriptors(p['media']),
      'hop_count': packet.hopCount,
      'path': packet.path,
    };
  }

  /// What this phone knows about a neighbour, and only that.
  ///
  /// Everything here came off that neighbour's beacons. What a beacon does
  /// not carry is left at its default rather than guessed: the queue depth
  /// is its own business, and claiming a figure for it would put a number
  /// on an operator's screen that nothing measured.
  Map<String, dynamic> _neighborSnapshot(Neighbor neighbor) {
    return {
      'node_id': neighbor.nodeId,
      'role': neighbor.role.wire,
      'battery': double.parse(neighbor.battery.toStringAsFixed(3)),
      'location': neighbor.location?.toJson(),
      // The link is two-way, so this phone belongs in its list as well.
      'neighbors': [engine.nodeId],
      'gateway_distance': neighbor.gatewayDistance,
      'link_stability': double.parse(neighbor.stability.toStringAsFixed(3)),
      'alive': true,
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
      // This is a real handset. The command centre uses this to separate
      // devices from simulated nodes, so nobody watching has to guess
      // which half of the demo they are looking at.
      'source': 'DEVICE',
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

    // Whatever budget is left carries this node's own view of the topology:
    // this phone, every phone it can currently hear, and the links between.
    //
    // Reporting only itself was not enough. A neighbour that has no internet
    // never syncs on its own behalf, so the only evidence it exists is this
    // phone hearing its beacons — and the command centre drew a lone node
    // with no edges while two handsets sat beside each other talking. The
    // fields below are all things a beacon actually carries (docs/protocol.md
    // §5); nothing is invented to fill the shape out.
    final snapshot = engine.snapshot();
    final snapshotSize = utf8.encode(jsonEncode(snapshot)).length;
    if (used + snapshotSize <= budget) {
      (body['nodes'] as List).add(snapshot);
      used += snapshotSize;
    }

    for (final neighbor in engine.state.liveNeighbors) {
      final heard = _neighborSnapshot(neighbor);
      final link = <String, dynamic>{
        'a': engine.nodeId,
        'b': neighbor.nodeId,
        'stability': double.parse(neighbor.stability.toStringAsFixed(3)),
        'rssi': neighbor.rssi,
      };
      final size = utf8.encode(jsonEncode(heard)).length +
          utf8.encode(jsonEncode(link)).length;
      if (used + size > budget) break;
      (body['nodes'] as List).add(heard);
      (body['links'] as List).add(link);
      used += size;
    }

    bus.emit(MeshEvent(MeshEventType.syncStarted, engine.nodeId, {
      'window_seconds': windowSeconds,
      'queued': ordered.length,
      'batched': batch.length,
      'budget_bytes': budget,
    }));

    // Note what is not checked here: whether there are reports to send.
    //
    // Network state is payload in its own right. A relay dying produces no
    // new report, yet it is precisely the event that should change which
    // responder is dispatched. Skipping the sync on an empty report queue
    // would mean the backend never learns the topology changed and the
    // recommendation never moves.
    if (batch.isEmpty && (body['nodes'] as List).isEmpty) {
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
        error: describeSyncFailure(error),
      );
    }

    final accepted = List<String>.from(
        (response['accepted'] as List?) ?? const <String>[]);
    _syncedReportIds.addAll(accepted);

    final incidents = ((response['incidents'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final incidentIds =
        incidents.map((i) => i['incident_id'] as String).toList();
    final incidentByReport = <String, String>{
      for (final i in incidents)
        if (i['report_id'] is String && i['incident_id'] is String)
          i['report_id'] as String: i['incident_id'] as String,
    };

    // Anything acknowledged is no longer this node's problem — neither as a
    // gateway holding it for someone else, nor as the node that wrote it.
    // Leaving it in custody would keep retransmitting a report the backend
    // already has.
    engine.state.pendingReports.removeWhere(
      (p) => accepted.contains(p.payload['report_id']),
    );
    for (final reportId in accepted) {
      engine.state.custody.remove(reportId);
    }

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

    // The backend lists the descriptors it holds no bytes for. Answer as
    // many as the rest of the window affords — after the reports, and
    // after this batch's own media, because an old photo must never crowd
    // out a new person.
    final requested = ((response['commands'] as List?) ?? const [])
        .whereType<Map>()
        .where((c) => c['type'] == 'REQUEST_MEDIA')
        .map((c) => c['media_id'])
        .whereType<String>()
        .toSet();
    if (uploader != null && storedMedia != null && requested.isNotEmpty) {
      final remaining =
          (budget - used - mediaResult.bytesSent).clamp(0, maxSyncBytes);
      if (remaining > 0) {
        final backlog = uploader!.pendingByMediaId(
          await storedMedia!(),
          requested,
        );
        if (backlog.isNotEmpty) {
          final extra =
              await uploader!.upload(backlog, budgetBytes: remaining);
          mediaResult = MediaUploadResult(
            uploaded: mediaResult.uploaded + extra.uploaded,
            deferred: mediaResult.deferred + extra.deferred,
            failed: mediaResult.failed + extra.failed,
            bytesSent: mediaResult.bytesSent + extra.bytesSent,
            uris: {...mediaResult.uris, ...extra.uris},
          );
        }
      }
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
      incidentByReport: incidentByReport,
      acceptedReportIds: accepted,
      media: mediaResult,
    );
  }
}
