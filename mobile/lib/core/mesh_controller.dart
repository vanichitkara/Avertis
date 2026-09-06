/// Wires the mesh engine to the app: identity, transport choice, location,
/// persistence and the gateway client.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/report_store.dart';
import '../mesh/mesh_engine.dart';
import '../mesh/mesh_events.dart';
import '../mesh/node_state.dart';
import '../mesh/protocol/packet.dart';
import '../mesh/transport/ble_mesh_transport.dart';
import '../mesh/transport/mesh_transport.dart';
import '../mesh/transport/mock_mesh_transport.dart';
import 'package:drift/drift.dart' show Value;

enum TransportMode {
  /// Real radios. Requires a physical device.
  ble,

  /// In-process virtual radio — emulator, tests, and demoing the mesh logic
  /// on a single machine.
  mock,
}

/// A snapshot of everything the UI needs to render.
@immutable
class MeshStatus {
  const MeshStatus({
    required this.nodeId,
    required this.role,
    required this.internetOnline,
    required this.meshConnected,
    required this.neighborCount,
    required this.meshHealth,
    required this.battery,
    required this.queueDepth,
    required this.custodyDepth,
    required this.gatewayDistance,
    required this.transport,
  });

  final String nodeId;
  final NodeRole role;
  final bool internetOnline;
  final bool meshConnected;
  final int neighborCount;

  /// Mean link stability across live neighbours — measured, not estimated.
  final double meshHealth;
  final double battery;
  final int queueDepth;
  final int custodyDepth;
  final int? gatewayDistance;
  final TransportMode transport;

  static const empty = MeshStatus(
    nodeId: '—',
    role: NodeRole.survivor,
    internetOnline: false,
    meshConnected: false,
    neighborCount: 0,
    meshHealth: 0,
    battery: 1,
    queueDepth: 0,
    custodyDepth: 0,
    gatewayDistance: null,
    transport: TransportMode.mock,
  );
}

class MeshController extends ChangeNotifier {
  MeshController({
    required this.database,
    this.mode = TransportMode.mock,
  });

  final ReportDatabase database;
  final TransportMode mode;

  final MeshEventBus bus = MeshEventBus();
  MeshEngine? _engine;
  MockRadioSpace? _mockSpace;
  Timer? _statusTimer;

  MeshEngine? get engine => _engine;
  bool get isRunning => _engine != null;

  MeshStatus _status = MeshStatus.empty;
  MeshStatus get status => _status;

  /// Async work started before disposal can complete after it — a timer tick,
  /// an in-flight ACK. Notifying a disposed notifier throws, so every path
  /// that notifies checks this first.
  bool _disposed = false;

  /// Set by the gateway client / connectivity check. Offline is the default
  /// assumption — this app exists for when there is no internet.
  bool _internetOnline = false;

  Future<void> start({
    required String nodeId,
    NodeRole role = NodeRole.survivor,
    GeoPoint? location,
  }) async {
    if (_engine != null) return;

    final MeshTransport transport;
    switch (mode) {
      case TransportMode.ble:
        transport = BleMeshTransport(nodeId);
      case TransportMode.mock:
        _mockSpace = MockRadioSpace(rangeM: 120);
        final mock = MockMeshTransport(nodeId, _mockSpace!);
        _mockSpace!.register(mock);
        transport = mock;
    }

    final engine = MeshEngine(
      state: NodeState(nodeId: nodeId, role: role, location: location),
      transport: transport,
      bus: bus,
    );
    _engine = engine;
    await engine.start();

    // Anything unacknowledged from a previous run goes back into the mesh.
    await _restoreUnacknowledged(engine);

    bus.stream.listen(_onMeshEvent);
    _statusTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
    _refreshStatus();
  }

  /// Re-offer reports that were never acknowledged before the app died.
  Future<void> _restoreUnacknowledged(MeshEngine engine) async {
    final pending = await database.unacknowledged();
    for (final report in pending) {
      await engine.originate(
        messageType:
            report.kind == 'SOS' ? MessageType.sos : MessageType.incident,
        priority: Priority.fromWire(report.priority),
        payload: {
          'report_id': report.reportId,
          'node_id': engine.nodeId,
          'created_at': isoOf(report.createdAt),
          'location': report.lat == null
              ? null
              : {
                  'lat': report.lat,
                  'lon': report.lon,
                  'accuracy_m': report.accuracyM ?? 10.0,
                },
          'text': report.body,
          'note': report.body,
          'people_count': report.peopleCount,
          'media': const [],
          'reported_priority': report.priority,
        },
      );
      await database.recordRetransmission(report.reportId);
    }
  }

  void _onMeshEvent(MeshEvent event) {
    if (_disposed) return;
    if (event.type == MeshEventType.packetDelivered &&
        event.data['type'] == 'ACK') {
      // ACKs resolve custody in the engine; mirror that into storage so the
      // UI can show what has genuinely been acknowledged.
      unawaited(_syncAcknowledgements());
    }
    notifyListeners();
  }

  Future<void> _syncAcknowledgements() async {
    final engine = _engine;
    if (engine == null) return;
    final outstanding = engine.state.custody.keys.toSet();
    for (final report in await database.unacknowledged()) {
      if (!outstanding.contains(report.reportId)) {
        await database.markAcknowledged(
            report.reportId, DateTime.now().toUtc());
      }
    }
  }

  void _refreshStatus() {
    final engine = _engine;
    if (engine == null || _disposed) return;
    final live = engine.state.liveNeighbors;
    final health = live.isEmpty
        ? 0.0
        : live.map((n) => n.stability).reduce((a, b) => a + b) / live.length;

    _status = MeshStatus(
      nodeId: engine.nodeId,
      role: engine.state.role,
      internetOnline: _internetOnline,
      meshConnected: live.isNotEmpty,
      neighborCount: live.length,
      meshHealth: health,
      battery: engine.state.battery,
      queueDepth: engine.queueDepth,
      custodyDepth: engine.custodyDepth,
      gatewayDistance: engine.state.gatewayDistance,
      transport: mode,
    );
    notifyListeners();
  }

  void setInternetOnline(bool online) {
    _internetOnline = online;
    _refreshStatus();
  }

  void updateLocation(GeoPoint? location) {
    if (_disposed) return;
    _engine?.state.location = location;
    notifyListeners();
  }

  void updateBattery(double battery) {
    _engine?.state.battery = battery;
    _refreshStatus();
  }

  // -- reporting -------------------------------------------------------

  /// Persist first, then transmit. If this device dies between the two, the
  /// report is still on disk and is re-offered next launch.
  Future<Packet> sendSos({String note = '', int? peopleCount}) async {
    final engine = _engine!;
    final packet = await engine.sendSos(note: note, peopleCount: peopleCount);
    await _persist(packet, kind: 'SOS', body: note, peopleCount: peopleCount);
    return packet;
  }

  Future<Packet> sendIncident(
    String text, {
    Priority priority = Priority.emergency,
    List<Map<String, dynamic>> media = const [],
  }) async {
    final engine = _engine!;
    final packet =
        await engine.sendIncident(text, priority: priority, media: media);
    await _persist(packet, kind: 'REPORT', body: text);
    return packet;
  }

  Future<void> _persist(
    Packet packet, {
    required String kind,
    required String body,
    int? peopleCount,
  }) async {
    final location = packet.payload['location'] as Map<String, dynamic>?;
    await database.insertReport(ReportsCompanion.insert(
      reportId: packet.payload['report_id'] as String,
      packetId: packet.packetId,
      kind: kind,
      priority: packet.priority.wire,
      body: Value(body),
      lat: Value((location?['lat'] as num?)?.toDouble()),
      lon: Value((location?['lon'] as num?)?.toDouble()),
      accuracyM: Value((location?['accuracy_m'] as num?)?.toDouble()),
      peopleCount: Value(peopleCount),
      createdAt: packet.createdAt,
    ));
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    unawaited(_engine?.stop());
    unawaited(bus.dispose());
    super.dispose();
  }
}
