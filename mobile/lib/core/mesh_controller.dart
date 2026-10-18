/// Wires the mesh engine to the app: identity, transport choice, location,
/// persistence and the gateway client.
library;

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
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
import '../services/incident_lookup.dart';
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
    this.starting = false,
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

  /// True before the node has started — while permissions are being
  /// asked for, above all. Nothing in here is a measurement yet, and the
  /// UI says "starting" rather than reporting zeros as findings.
  final bool starting;

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
    starting: true,
  );

  /// The placeholder for a node that has not started, on the radio it is
  /// actually configured for. `empty` said `mock`, so a phone waiting on
  /// a Bluetooth permission reported "simulated radio" on its home
  /// screen — naming the one radio it was not about to use.
  static MeshStatus notStarted(TransportMode mode) => MeshStatus(
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
        transport: mode,
        starting: true,
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

  /// The role this node was started with, restored when an uplink is lost.
  NodeRole _configuredRole = NodeRole.survivor;

  MeshEngine? get engine => _engine;
  bool get isRunning => _engine != null;

  /// Null until a backend is configured. The UI reads this to know whether
  /// syncing is possible at all, rather than offering an action that cannot
  /// work.
  GatewayClient? get gateway => _gateway;
  bool get hasBackend => apiBase.isNotEmpty;

  /// Looks up what the command centre made of a report. Null without a
  /// backend, since there is nowhere to ask.
  IncidentLookup? get incidentLookup => hasBackend
      ? IncidentLookup(baseUrl: apiBase, apiKey: apiKey)
      : null;

  /// A phone that can reach the backend *is* a gateway.
  ///
  /// Reports are addressed to "gateway", and only a node whose role is
  /// GATEWAY accepts delivery of them or holds them for syncing. Every
  /// phone runs as a survivor, so a neighbour's report would be relayed
  /// past a handset that had working internet and never picked up — the
  /// one thing store-and-forward exists to do.
  ///
  /// The role follows connectivity rather than being configured, because
  /// in a disaster that is exactly what changes: whichever phone finds
  /// signal becomes everyone else's way out.
  void _applyGatewayRole(bool reachable) {
    final engine = _engine;
    if (engine == null) return;

    final shouldBeGateway = reachable && hasBackend;
    final isGateway = engine.state.role == NodeRole.gateway;
    if (shouldBeGateway == isGateway) return;

    engine.state.role =
        shouldBeGateway ? NodeRole.gateway : _configuredRole;
    bus.emit(MeshEvent(
      shouldBeGateway ? MeshEventType.gatewayUp : MeshEventType.gatewayDown,
      engine.nodeId,
      {
        'reason': shouldBeGateway
            ? 'this device can reach the command centre'
            : 'this device lost its connection',
      },
    ));
  }

  /// Why an unacknowledged report has not gone yet.
  ///
  /// "Waiting for acknowledgement" on its own is not good enough for a
  /// life-critical report: it reads the same whether delivery is seconds
  /// away or impossible, and leaves the sender with no idea whether to
  /// find a signal, find a person, or wait. Each branch names the thing
  /// that would unblock it.
  String pendingReason() {
    final neighbours = _engine?.state.liveNeighbors.length ?? 0;

    if (!hasBackend) {
      return neighbours > 0
          ? 'Relaying through $neighbours nearby device(s). This build has '
              'no command centre configured, so it travels by mesh only.'
          : 'No command centre configured in this build, and no devices in '
              'range. It is saved here and will relay to the first device '
              'that appears.';
    }

    if (!_internetOnline) {
      return neighbours > 0
          ? 'No internet. Relaying through $neighbours nearby device(s) '
              'towards one that has a connection.'
          : 'No internet and no devices in range. It is saved here and '
              'sends automatically as soon as either appears.';
    }

    final failure = _lastSyncError;
    if (failure != null) {
      // The uplink is fine and the command centre answered — it just would
      // not take this. Saying "no internet" here would send someone to
      // look for a signal they already have.
      return 'The command centre is reachable but refused the last send: '
          '$failure. Your report is still here and will go when that is '
          'fixed.';
    }

    return 'Connected — sending at the next window, within about 20 '
        'seconds.';
  }

  /// Why this node is not discoverable, when it is not.
  ///
  /// A node that scans but cannot advertise is only half a mesh node: it finds
  /// others, but nobody finds it. That is invisible without being told, so the
  /// mesh screen surfaces it.
  String? get advertisingWarning {
    final transport = _engine?.transport;
    return transport is BleMeshTransport ? transport.peripheralWarning : null;
  }

  /// What the radio has done, for a node that is finding nobody.
  ///
  /// Null on the simulated radio, and null once a peer is connected.
  /// Otherwise the first step that has not happened yet — see
  /// [BleDiagnostics.stalledAt].
  String? get radioStalledAt {
    final transport = _engine?.transport;
    if (transport is! BleMeshTransport) return null;
    return transport.diagnostics.stalledAt;
  }

  BleDiagnostics? get radioDiagnostics {
    final transport = _engine?.transport;
    return transport is BleMeshTransport ? transport.diagnostics : null;
  }

  late MeshStatus _status = MeshStatus.notStarted(mode);
  MeshStatus get status => _status;

  /// Async work started before disposal can complete after it — a timer tick,
  /// an in-flight ACK. Notifying a disposed notifier throws, so every path
  /// that notifies checks this first.
  bool _disposed = false;
  String? _lastServiceFingerprint;

  /// Set by the connectivity check, and by nothing else. Offline is the
  /// default assumption — this app exists for when there is no internet.
  bool _internetOnline = false;

  /// Why the last sync failed, when it did and the backend was reachable.
  ///
  /// A refused write is not a dead uplink. Folding the two together cost
  /// an afternoon of looking at Wi-Fi settings while the real fault was an
  /// APK built without its API key: every sync came back 401, the home
  /// screen read `Internet OFFLINE`, and nothing on the phone said
  /// otherwise. Reachability is what the health check saw; this is what
  /// happened when we tried to write.
  String? _lastSyncError;
  String? get lastSyncError => _lastSyncError;

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

  Timer? _reachabilityTimer;

  final Battery _battery = Battery();
  Timer? _batteryTimer;

  /// True once a real battery reading has landed. Until then the node's
  /// battery is a default, not a measurement, and nothing should present
  /// it as one.
  bool _batteryKnown = false;
  bool get batteryKnown => _batteryKnown;
  String? _batteryError;
  String? get batteryError => _batteryError;

  /// Battery moves slowly; a minute is often enough to be honest about.
  static const Duration batteryInterval = Duration(minutes: 1);
  bool _syncInFlight = false;

  /// How often to ask whether the command centre can be reached.
  ///
  /// "Internet" here means exactly that — not whether Wi-Fi is associated,
  /// which tells a survivor nothing. A captive portal, a dead uplink or a
  /// backend that is down all look like working Wi-Fi to the OS and like no
  /// connectivity to this app, which is the honest reading.
  static const Duration reachabilityInterval = Duration(seconds: 20);

  /// Ask for the runtime permissions, once.
  ///
  /// Separate from [_startBackgroundRelay] because the BLE transport needs
  /// the answer *before* it starts, and the foreground service needs it
  /// after. Asking twice would put two sets of dialogs in front of someone
  /// opening the app for the first time.
  bool _permissionsAsked = false;
  Future<void> _ensurePermissions() async {
    if (_permissionsAsked) return;
    _permissionsAsked = true;
    grantedPermissions = await permissions.request();
    if (!_disposed) notifyListeners();
  }

  /// True when the radio was started with no Bluetooth permission, so a
  /// later grant has something to retry.
  bool _radioStartedUnpermitted = false;

  Future<void> start({
    required String nodeId,
    NodeRole role = NodeRole.survivor,
    GeoPoint? location,
  }) async {
    if (_engine != null) return;
    _configuredRole = role;

    // Ask before the radio starts, not after.
    //
    // Android refuses a scan without BLUETOOTH_SCAN and an advertisement
    // without BLUETOOTH_ADVERTISE, and nothing here restarted the
    // transport when the grant arrived a moment later — so the node sat
    // on "searching" for the rest of the session, with Bluetooth on and
    // two phones side by side finding nothing.
    //
    // This was latent until the radio began defaulting to Bluetooth. Before
    // that the app always came up simulated and a BLE transport was only
    // ever built after someone had granted permissions by hand.
    if (mode == TransportMode.ble) {
      await _ensurePermissions();
      if (_disposed) return;
      _radioStartedUnpermitted = !grantedPermissions.bluetooth;
    }

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
    unawaited(_trackBattery());
    _statusTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());

    // Find out whether the backend is actually reachable, rather than
    // assuming it is not until someone presses a button. Without this the
    // home screen reads "Internet OFFLINE" on a phone with perfectly good
    // Wi-Fi, and nothing ever corrects it.
    if (hasBackend) {
      unawaited(_checkReachability());
      _reachabilityTimer = Timer.periodic(
        reachabilityInterval,
        (_) => unawaited(_checkReachability()),
      );
    }
    _refreshStatus();
  }

  Future<void> _startBackgroundRelay() async {
    await _ensurePermissions();
    if (_disposed) return;
    if (grantedPermissions.canRelayInBackground) {
      backgroundRelayActive = await meshService.start();
    } else {
      backgroundRelayActive = false;
    }
    if (!_disposed) notifyListeners();
  }

  /// Bring the radio back up after a permission was granted late.
  ///
  /// Someone who refuses the Bluetooth prompt and then grants it in system
  /// settings has done everything asked of them; without this the app
  /// would still be deaf until they restarted it, with nothing on screen
  /// to say so.
  Future<void> retryRadioIfNowPermitted() async {
    if (_disposed || mode != TransportMode.ble) return;
    if (!_radioStartedUnpermitted) return;

    final now = await permissions.check();
    if (_disposed || !now.bluetooth) return;

    grantedPermissions = now;
    _radioStartedUnpermitted = false;
    await _restartTransport();
    if (!_disposed) notifyListeners();
  }

  /// Rebuild the transport under the running engine, keeping its state.
  ///
  /// Reports already in custody stay in custody: this is a radio being
  /// restarted, not a node being replaced.
  Future<void> _restartTransport() async {
    final engine = _engine;
    if (engine == null) return;
    await engine.restartTransport(
      BleMeshTransport(engine.nodeId, role: _configuredRole),
    );
    if (!backgroundRelayActive && grantedPermissions.canRelayInBackground) {
      backgroundRelayActive = await meshService.start();
    }
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
    // Record what each report became, so the sender can see that their
    // SOS is now a numbered incident at the command centre rather than
    // just "acknowledged" by something unnamed.
    for (final entry in result.incidentByReport.entries) {
      await database.attachIncidentId(entry.key, entry.value);
    }
    _lastSyncError = result.error;
    if (!_disposed) notifyListeners();
    return result;
  }

  /// Ask the backend whether it is there, and deliver anything waiting.
  ///
  /// Auto-sync only runs when there is actually something to send. A
  /// periodic empty sync would still make the backend re-plan every open
  /// incident, and each re-plan asks the model for a fresh explanation —
  /// a steady drip of API calls for no new information.
  Future<void> _checkReachability() async {
    final gateway = _gateway;
    if (gateway == null || _disposed) return;

    final reachable = await gateway.backend.health();
    if (_disposed) return;

    final becameReachable = reachable && !_internetOnline;
    _internetOnline = reachable;
    _applyGatewayRole(reachable);
    notifyListeners();

    if (!reachable) return;

    final waiting = gateway.heldReports().isNotEmpty;
    if (waiting && !_syncInFlight) {
      // Deliver without being asked. A survivor should not have to find a
      // button on a diagnostics screen for their report to leave the
      // phone — and when connectivity is intermittent, the window may be
      // gone by the time they do.
      _syncInFlight = true;
      try {
        await syncNow();
      } finally {
        _syncInFlight = false;
      }
    } else if (becameReachable) {
      notifyListeners();
    }
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
    _engine?.state.battery = battery.clamp(0.0, 1.0);
    _refreshStatus();
  }

  /// Keep the node's battery level true.
  ///
  /// It defaulted to 1.0 and nothing ever moved it, so every phone
  /// reported 100% charged for as long as it ran — on its own screen, to
  /// its neighbours in every beacon, and to the command centre. Relay
  /// election weights battery (see relay_policy.dart), so a constant made
  /// that part of the scoring decorative: the phone about to die looked
  /// exactly as good a relay as the one on charge.
  ///
  /// Polled rather than streamed. `onBatteryStateChanged` fires on
  /// charging transitions, not on the level moving, which is the number
  /// this needs.
  Future<void> _trackBattery() async {
    Future<void> read() async {
      try {
        final percent = await _battery.batteryLevel;
        if (_disposed) return;
        updateBattery(percent / 100);
        _batteryKnown = true;
      } catch (error) {
        // A platform that will not say leaves the last known value alone,
        // but it does not get to fail quietly: a silent catch here is why
        // the screen sat at 100% with nothing to explain it.
        _batteryKnown = false;
        if (_batteryError == null) {
          debugPrint('avertis: cannot read the battery level ($error); '
              'the reported figure is not measured');
        }
        _batteryError = error.toString();
      }
    }

    await read();
    _batteryTimer =
        Timer.periodic(batteryInterval, (_) => unawaited(read()));
  }

  /// The engine, or an error a person can act on.
  ///
  /// This used to be `_engine!`, which surfaced as "Null check operator
  /// used on a null value" under a Could not send banner — true, and
  /// useless to anyone reading it.
  MeshEngine _requireEngine() {
    final engine = _engine;
    if (engine == null) {
      throw StateError(
        'The mesh is still starting up. Close and reopen the app; if this '
        'keeps happening, reinstall it.',
      );
    }
    return engine;
  }

  // -- reporting -------------------------------------------------------

  /// Persist first, then transmit. If this device dies between the two, the
  /// report is still on disk and is re-offered next launch.
  Future<Packet> sendSos({String note = '', int? peopleCount}) async {
    final engine = _requireEngine();
    final packet = await engine.sendSos(note: note, peopleCount: peopleCount);
    await _persist(packet, kind: 'SOS', body: note, peopleCount: peopleCount);
    return packet;
  }

  Future<Packet> sendIncident(
    String text, {
    Priority priority = Priority.emergency,
    List<Map<String, dynamic>> media = const [],
  }) async {
    final engine = _requireEngine();
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
    _reachabilityTimer?.cancel();
    _batteryTimer?.cancel();
    unawaited(_locationSub?.cancel());
    unawaited(locationService.dispose());
    unawaited(meshService.stop());
    unawaited(_engine?.stop());
    unawaited(bus.dispose());
    super.dispose();
  }
}
