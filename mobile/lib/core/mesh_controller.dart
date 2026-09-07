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
import '../services/location_service.dart';
import '../services/gateway_client.dart';
import '../services/media_uploader.dart';
import '../services/mesh_service_channel.dart';
import '../services/permissions_service.dart';
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

/// Where the backend lives, supplied at build time:
///
///   flutter run --dart-define=AVERTIS_API_BASE=https://... \
///               --dart-define=AVERTIS_API_KEY=...
///
/// Empty by default, and that is the honest default: this app is built for
/// having no backend to reach. Without it the mesh runs exactly as it does
/// now, holding reports in custody until a gateway appears.
const String avertisApiBase =
    String.fromEnvironment('AVERTIS_API_BASE', defaultValue: '');
const String avertisApiKey =
    String.fromEnvironment('AVERTIS_API_KEY', defaultValue: '');

class MeshController extends ChangeNotifier {
  MeshController({
    required this.database,
    this.mode = TransportMode.mock,
    this.apiBase = avertisApiBase,
    this.apiKey = avertisApiKey,
  });

  final ReportDatabase database;
  final TransportMode mode;
  final String apiBase;
  final String apiKey;

  final MeshEventBus bus = MeshEventBus();
  final LocationService locationService = LocationService();
  final MeshServiceChannel meshService = MeshServiceChannel();
  final PermissionsService permissions = PermissionsService();
  StreamSubscription<LocationState>? _locationSub;
  MeshEngine? _engine;
  MockRadioSpace? _mockSpace;
  Timer? _statusTimer;

  GatewayClient? _gateway;

  MeshEngine? get engine => _engine;
  bool get isRunning => _engine != null;

  /// Null until a backend is configured. The UI reads this to know whether
  /// syncing is possible at all, rather than offering an action that cannot
  /// work.
  GatewayClient? get gateway => _gateway;
  bool get hasBackend => apiBase.isNotEmpty;

  MeshStatus _status = MeshStatus.empty;
  MeshStatus get status => _status;

  /// Async work started before disposal can complete after it — a timer tick,
  /// an in-flight ACK. Notifying a disposed notifier throws, so every path
  /// that notifies checks this first.
  bool _disposed = false;
  String? _lastServiceFingerprint;

  /// Set by the gateway client / connectivity check. Offline is the default
  /// assumption — this app exists for when there is no internet.
  bool _internetOnline = false;

  /// What we actually know about our position. The UI reads this rather than
  /// assuming a fix exists — claiming a location we do not have would send
  /// responders to the wrong place.
  LocationState locationState = LocationState.unknown;

  /// What the OS actually lets this node do. Read by the UI so it can say
  /// which capability is missing instead of failing quietly.
  MeshPermissions grantedPermissions = MeshPermissions.none;

  /// True only once the foreground service is genuinely running. Android
  /// refuses it without a Bluetooth runtime permission, so this is never
  /// assumed — it is the value the platform returned.
  bool backgroundRelayActive = false;

  Future<void> start({
    required String nodeId,
    NodeRole role = NodeRole.survivor,
    GeoPoint? location,
  }) async {
    if (_engine != null) return;

    final MeshTransport transport;
    switch (mode) {
      case TransportMode.ble:
        transport = BleMeshTransport(nodeId, role: role);
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

    // The gateway client exists only if there is somewhere to sync to. The
    // media uploader rides along with it: photos and voice clips spend
    // whatever the reports leave of a connectivity window.
    if (hasBackend) {
      _gateway = GatewayClient(
        engine: engine,
        backend: HttpSyncBackend(baseUrl: apiBase, apiKey: apiKey),
        bus: bus,
        uploader: MediaUploader(
          backend: HttpMediaBackend(baseUrl: apiBase, apiKey: apiKey),
        ),
      );
    }

    // Anything unacknowledged from a previous run goes back into the mesh.
    await _restoreUnacknowledged(engine);

    bus.stream.listen(_onMeshEvent);
    _locationSub = locationService.stream.listen((state) {
      locationState = state;
      _engine?.state.location = state.point;
      if (!_disposed) notifyListeners();
    });
    unawaited(locationService.start());

    // Ask for what the mesh needs, then start background relaying only if the
    // OS will actually allow it. Android refuses a connectedDevice foreground
    // service without a Bluetooth runtime permission, so starting it blindly
    // would either fail silently or crash the app.
    unawaited(_startBackgroundRelay());
    _statusTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
    _refreshStatus();
  }

  Future<void> _startBackgroundRelay() async {
    grantedPermissions = await permissions.request();
    if (_disposed) return;
    if (grantedPermissions.canRelayInBackground) {
      backgroundRelayActive = await meshService.start();
    } else {
      backgroundRelayActive = false;
    }
    if (!_disposed) notifyListeners();
  }

  /// Spend a connectivity window, if there is a backend to spend it on.
  ///
  /// Returns null when no backend is configured — the caller should not be
  /// offering a sync action in that case, and a null says so rather than
  /// pretending an empty sync succeeded.
  Future<SyncResult?> syncNow({double windowSeconds = 18}) async {
    final gateway = _gateway;
    if (gateway == null) return null;

    final result = await gateway.sync(windowSeconds: windowSeconds);

    // Anything the backend acknowledged is settled: mark it locally so a
    // restart does not re-offer it.
    for (final reportId in result.acceptedReportIds) {
      await database.markAcknowledged(reportId, DateTime.now().toUtc());
    }
    _internetOnline = result.ok;
    if (!_disposed) notifyListeners();
    return result;
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

    // The ongoing notification is the only mesh readout available when the
    // app is closed, so keep it current — but only on real change, to avoid
    // waking the notification manager every second.
    final fingerprint = '${live.length}/${engine.queueDepth}/'
        '${engine.custodyDepth}';
    if (fingerprint != _lastServiceFingerprint) {
      _lastServiceFingerprint = fingerprint;
      unawaited(meshService.update(
        neighbors: live.length,
        queued: engine.queueDepth,
        custody: engine.custodyDepth,
      ));
    }

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
    unawaited(_locationSub?.cancel());
    unawaited(locationService.dispose());
    unawaited(meshService.stop());
    unawaited(_engine?.stop());
    unawaited(bus.dispose());
    super.dispose();
  }
}
