/// BLE transport — the same mesh engine over real radios (plan §12, Phase 9).
///
/// Every routing, healing and partition behaviour was developed and tested
/// against MockMeshTransport. This class changes only how bytes reach a
/// neighbour; the engine above it is unchanged.
///
/// Framing follows docs/protocol.md §7:
///   [2-byte total length][1-byte fragment index][1-byte fragment count][bytes]
/// with a 10 s reassembly timeout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/packet.dart';
import 'ble_peripheral.dart';
import 'mesh_transport.dart';

/// Service and characteristic UUIDs. Placeholders until the BLE bring-up —
/// the engine never references them, which is the point of the abstraction.
final Guid avertisServiceUuid = Guid('a5e7f1c0-1c2b-4c9a-9f10-000000000001');
final Guid avertisTxCharacteristic = Guid(
  'a5e7f1c0-1c2b-4c9a-9f10-000000000002',
);

/// The characteristic a peer's *peripheral* half notifies us on. We subscribe
/// to this on every peer we connect to as a central.
final Guid avertisNotifyCharacteristic = Guid(
  'a5e7f1c0-1c2b-4c9a-9f10-000000000003',
);

/// Conservative payload per write; MTU is negotiated but not relied upon.
const int safeFragmentBytes = 180;
const Duration reassemblyTimeout = Duration(seconds: 10);
const Duration scanWindow = Duration(seconds: 4);
const Duration scanInterval = Duration(seconds: 10);

/// Splits a packet into BLE-sized frames and reassembles them.
///
/// Pure and dependency-free so it can be unit tested without a radio.
class BleFraming {
  static List<Uint8List> fragment(Packet packet) {
    final payload = Uint8List.fromList(packet.encode());
    final total = payload.length;
    final chunkSize = safeFragmentBytes - 4;
    final count = (total / chunkSize).ceil().clamp(1, 255);
    final frames = <Uint8List>[];

    for (var i = 0; i < count; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, total);
      final chunk = payload.sublist(start, end);
      final frame = Uint8List(4 + chunk.length);
      final view = ByteData.view(frame.buffer);
      view.setUint16(0, total, Endian.big);
      frame[2] = i;
      frame[3] = count;
      frame.setRange(4, 4 + chunk.length, chunk);
      frames.add(frame);
    }
    return frames;
  }

  /// Feed a frame; returns the packet once every fragment has arrived.
  static Packet? accept(Reassembly buffer, Uint8List frame) {
    if (frame.length < 4) return null;
    final view = ByteData.view(frame.buffer, frame.offsetInBytes);
    final total = view.getUint16(0, Endian.big);
    final index = frame[2];
    final count = frame[3];
    if (count == 0 || index >= count) return null;

    buffer.touch();
    buffer.expected = count;
    buffer.totalBytes = total;
    buffer.fragments[index] = frame.sublist(4);

    if (buffer.fragments.length != count) return null;

    final assembled = <int>[];
    for (var i = 0; i < count; i++) {
      final part = buffer.fragments[i];
      if (part == null) return null;
      assembled.addAll(part);
    }
    buffer.reset();
    if (assembled.length != total) return null;
    try {
      return Packet.decode(assembled);
    } on FormatException {
      return null; // a corrupt frame is dropped, never crashes the engine
    }
  }
}

class Reassembly {
  final Map<int, Uint8List> fragments = {};
  int expected = 0;
  int totalBytes = 0;
  DateTime lastFragment = DateTime.now();

  void touch() {
    if (DateTime.now().difference(lastFragment) > reassemblyTimeout) reset();
    lastFragment = DateTime.now();
  }

  void reset() {
    fragments.clear();
    expected = 0;
    totalBytes = 0;
  }
}

/// What the radio has actually done, for a node that is finding nobody.
///
/// Every field is a count or a message from the platform. Nothing here is
/// inferred: the point is to separate "we never scanned", "we scanned and
/// heard nothing", "we heard something that was not us", "we heard us but
/// could not read it" and "we read it but could not connect".
class BleDiagnostics {
  int scanWindows = 0;

  /// Advertisements matching the Avertis service filter.
  int advertisementsSeen = 0;

  /// Matched the filter but carried no readable node id.
  int unidentified = 0;

  final Set<String> peersIdentified = {};

  int connectAttempts = 0;
  int connected = 0;
  int connectFailures = 0;

  /// Packets handed to the radio, by direction. A link can be up in one
  /// direction only, and the two halves use different Android APIs, so
  /// one number moving while the other does not is the diagnosis.
  int sentAsCentral = 0;
  int sentAsPeripheral = 0;
  int sendFailures = 0;

  /// Frames off the radio, and the packets that survived reassembly.
  int framesReceived = 0;
  int packetsDecoded = 0;

  String? scanError;
  String? connectError;
  String? sendError;

  /// The first step that has not happened, in the order it has to happen.
  /// Null once a peer has been connected to.
  String? get stalledAt {
    if (scanError != null) return 'the scan will not start: $scanError';
    if (scanWindows == 0) return 'no scan has run yet';
    if (advertisementsSeen == 0) {
      return 'scanning, but no Avertis advertisement has been heard — '
          'check the other phone is on Bluetooth, in range, and not '
          'reporting an advertising failure of its own';
    }
    if (peersIdentified.isEmpty) {
      return 'heard $advertisementsSeen Avertis advertisement(s) but could '
          'not read a node id from any — the scan response is not arriving';
    }
    if (connected == 0 && sentAsPeripheral == 0 && framesReceived == 0) {
      return 'found ${peersIdentified.length} peer(s) but no connection '
          'succeeded${connectError == null ? '' : ': $connectError'}';
    }
    if (sentAsCentral == 0 && sentAsPeripheral == 0) {
      return 'connected, but nothing has been sent yet'
          '${sendError == null ? '' : ' — $sendError'}';
    }
    if (framesReceived == 0) {
      return 'sending, but nothing has come back — the link is working in '
          'one direction only';
    }
    if (packetsDecoded == 0) {
      return 'receiving frames but decoding no packets — the two phones '
          'disagree about the wire format';
    }
    return null;
  }
}

/// Resolves a platform BLE connection identifier to the stable Avertis node
/// identifier carried in a HELLO.
///
/// A peripheral learns an inbound peer as an Android device address, while
/// the central half learns that same peer from its advertisement as (for
/// example) `n7ac20`. Passing those two names through to the mesh engine made
/// one physical link look like two different neighbours. In particular, the
/// inbound side could receive a HELLO but could not subsequently route a
/// packet to the node ID named in that HELLO.
///
/// The mapping is deliberately learned only from a direct HELLO whose payload
/// agrees with its packet origin. Forwarded traffic cannot establish a direct
/// BLE identity: its origin belongs to the source of the report, not the peer
/// that relayed it.
class BlePeerIdentityMap {
  final Map<String, String> _nodeIdByLinkId = {};

  void learn(String linkId, Packet packet) {
    if (packet.messageType != MessageType.hello) return;
    final declared = packet.payload['node_id'];
    if (declared is String &&
        declared.isNotEmpty &&
        declared == packet.originNode) {
      _nodeIdByLinkId[linkId] = declared;
    }
  }

  /// The node id a link is known by, or the link id itself until a HELLO
  /// has named it.
  String nodeIdFor(String linkId) => _nodeIdByLinkId[linkId] ?? linkId;

  /// The link a node is reachable on. The exact inverse of [nodeIdFor],
  /// including the unlearned case, and it has to be.
  ///
  /// This returned null for an unlearned peer while [nodeIdFor] returned
  /// the link id, so the two stopped being inverses before the first
  /// HELLO. `peers` listed an inbound peer by its device address, `send`
  /// looked that address up as a node id, found nothing, and refused to
  /// send. Since the only way to learn a mapping is to *receive* a HELLO,
  /// and the only way to be sent one is to already be mapped, two phones
  /// that had connected to each other both sat waiting for a beacon
  /// neither could send: a live BLE link, and zero neighbours on both.
  String linkIdFor(String nodeId) {
    for (final entry in _nodeIdByLinkId.entries) {
      if (entry.value == nodeId) return entry.key;
    }
    return nodeId;
  }

  String remove(String linkId) => _nodeIdByLinkId.remove(linkId) ?? linkId;
}

/// A BLE node runs *both* roles at once.
///
/// As a **central** it scans, connects to peers and writes frames to them.
/// As a **peripheral** it advertises so other phones can find it, and hosts
/// the GATT server they write to. `flutter_blue_plus` only provides the first
/// half; [BlePeripheral] bridges to Kotlin for the second. Running only the
/// central half would mean nobody is ever discoverable and the mesh never
/// forms — which is precisely the failure this class exists to avoid.
class BleMeshTransport extends MeshTransport {
  BleMeshTransport(
    super.nodeId, {
    required this.role,
    this.battery = 1.0,
    BlePeripheral? peripheral,
  }) : peripheral = peripheral ?? BlePeripheral();

  /// Advertised so peers can score this node before connecting.
  final NodeRole role;
  final double battery;

  /// The peripheral half. Kept public so the UI can surface advertising state
  /// — a node that cannot advertise is only half a mesh node.
  final BlePeripheral peripheral;

  /// Peers reachable because *they* connected to *us*. We answer them through
  /// the peripheral's notify characteristic rather than dialling back, which
  /// would race with their own connection.
  final Set<String> _inboundPeers = {};
  final BlePeerIdentityMap _peerIds = BlePeerIdentityMap();

  final _incoming =
      StreamController<({String from, Packet packet})>.broadcast();
  final _peerFound = StreamController<PeerInfo>.broadcast();
  final _peerLost = StreamController<String>.broadcast();

  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, BluetoothCharacteristic> _writeChars = {};
  final Map<String, Reassembly> _buffers = {};
  final Map<String, StreamSubscription<dynamic>> _valueSubs = {};
  final Map<String, StreamSubscription<dynamic>> _connSubs = {};

  /// Peers whose setup is in flight, so repeated scan results do not
  /// start a second one over the top of the first.
  final Set<String> _connecting = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  final List<StreamSubscription<dynamic>> _peripheralSubs = [];
  Timer? _scanTimer;
  bool _running = false;

  /// Counts from the radio, so a node that finds nobody can say at which
  /// step it stopped.
  ///
  /// "Searching" is not a diagnosis. Scanning and not being advertised to,
  /// hearing advertisements that are not ours, hearing ours but failing to
  /// read a node id, and reading one but failing to connect are four
  /// different faults with four different fixes, and they looked identical
  /// from the outside — which cost real hours on two handsets that were a
  /// foot apart the whole time.
  final BleDiagnostics diagnostics = BleDiagnostics();

  @override
  Stream<({String from, Packet packet})> get incoming => _incoming.stream;

  @override
  Stream<PeerInfo> get peerFound => _peerFound.stream;

  @override
  Stream<String> get peerLost => _peerLost.stream;

  @override
  List<String> get peers =>
      {..._writeChars.keys, ..._inboundPeers.map(_peerIds.nodeIdFor)}.toList()
        ..sort();

  /// True when this node is discoverable by other phones.
  bool get isAdvertising => peripheral.state.advertising;

  /// Non-null when the peripheral half is not running, with a reason the UI
  /// can show.
  String? get peripheralWarning => peripheral.state.message;

  @override
  Future<void> start() async {
    if (_running) return;
    if (!await FlutterBluePlus.isSupported) {
      throw StateError('Bluetooth is not supported on this device');
    }
    _running = true;

    // Peripheral half first: start being findable before looking for others,
    // so two phones starting together can see each other on the first scan.
    _peripheralSubs.addAll([
      peripheral.payloads.listen((m) => _onFrame(m.deviceId, m.bytes)),
      peripheral.peerConnected.listen((id) {
        _inboundPeers.add(id);
        _peerFound.add(PeerInfo(nodeId: id));
      }),
      peripheral.peerDisconnected.listen((id) {
        _inboundPeers.remove(id);
        final nodeId = _peerIds.remove(id);
        if (!_writeChars.containsKey(nodeId)) _dropPeer(nodeId);
      }),
    ]);
    await peripheral.start(nodeId: nodeId, role: role.wire, battery: battery);

    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
    // Scan in windows rather than continuously — a continuous scan is the
    // fastest way to flatten the battery of a device that may need to last
    // days without power.
    _scanTimer = Timer.periodic(scanInterval, (_) => _scanOnce());
    await _scanOnce();
  }

  Future<void> _scanOnce() async {
    if (!_running) return;
    try {
      diagnostics.scanWindows++;
      await FlutterBluePlus.startScan(
        withServices: [avertisServiceUuid],
        timeout: scanWindow,
      );
      diagnostics.scanError = null;
    } on Exception catch (error) {
      // A failed scan window is not fatal; the next one will retry. But it
      // is recorded: a scan that never starts looks exactly like a scan
      // that finds nothing.
      diagnostics.scanError = error.toString();
    }
  }

  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      diagnostics.advertisementsSeen++;
      final peerId = _peerIdOf(result);
      if (peerId == null) {
        // Matched our service filter but carried no readable node id —
        // usually a scan response that did not arrive.
        diagnostics.unidentified++;
        continue;
      }
      if (peerId == nodeId) continue;
      diagnostics.peersIdentified.add(peerId);
      _devices[peerId] = result.device;
      _peerFound.add(
        PeerInfo(
          nodeId: peerId,
          battery: _batteryOf(result),
          rssi: result.rssi,
        ),
      );
      unawaited(_ensureConnected(peerId, result.device));
    }
  }

  /// Advertised manufacturer data carries node_id, role and battery so peers
  /// can be scored before we pay the cost of connecting (docs/protocol.md §7).
  String? _peerIdOf(ScanResult result) {
    final name = result.advertisementData.advName;
    if (name.startsWith('AVX-')) return name.substring(4);
    for (final data in result.advertisementData.manufacturerData.values) {
      if (data.length >= 6) {
        return utf8.decode(data.sublist(0, 6), allowMalformed: true);
      }
    }
    return null;
  }

  double _batteryOf(ScanResult result) {
    for (final data in result.advertisementData.manufacturerData.values) {
      if (data.length >= 8) return data[7] / 255.0;
    }
    return 1.0;
  }

  /// Set up a peer we found by scanning, once.
  ///
  /// This is called for every scan result, and scan results repeat — the
  /// same peer arrives every few seconds for as long as it is in range.
  /// Without the in-flight guard several setups ran at once on a single
  /// GATT connection, and Android allows one outstanding operation per
  /// connection. Service discovery and the CCCD write raced, and the
  /// CCCD write is the one that loses: the connection comes up, the
  /// write characteristic is found, and the subscription silently never
  /// happens.
  ///
  /// The peer's GATT server then has us in `connected` but not in
  /// `subscribed`, so every notification back to us is refused — "the
  /// GATT server refused a notification … is the peer subscribed?" — and
  /// the link carries traffic in one direction only. Which is a mesh
  /// that relays reports and never acknowledges them.
  Future<void> _ensureConnected(String peerId, BluetoothDevice device) async {
    // Fully set up means both halves: somewhere to write, and a
    // subscription to be written to. Either one alone is a one-way link
    // and must be retried, not treated as done.
    if (_writeChars.containsKey(peerId) && _valueSubs.containsKey(peerId)) {
      return;
    }
    if (!_connecting.add(peerId)) return;

    try {
      diagnostics.connectAttempts++;
      await device.connect(timeout: const Duration(seconds: 8));
      final services = await device.discoverServices();

      BluetoothCharacteristic? notify;
      for (final service in services) {
        if (service.serviceUuid != avertisServiceUuid) continue;
        for (final characteristic in service.characteristics) {
          // We write frames to the peer here...
          if (characteristic.characteristicUuid == avertisTxCharacteristic) {
            _writeChars[peerId] = characteristic;
          }
          // ...and the peer notifies us back here.
          if (characteristic.characteristicUuid ==
              avertisNotifyCharacteristic) {
            notify = characteristic;
          }
        }
      }

      // Subscribe after discovery has finished rather than in the middle
      // of walking its results, so the CCCD write is the only operation
      // in flight.
      if (notify != null) {
        await notify.setNotifyValue(true);
        await _valueSubs.remove(peerId)?.cancel();
        _valueSubs[peerId] = notify.onValueReceived.listen(
          (value) => _onFrame(peerId, Uint8List.fromList(value)),
        );
      }

      if (_writeChars.containsKey(peerId) && _valueSubs.containsKey(peerId)) {
        diagnostics.connected++;
        diagnostics.connectError = null;
      } else if (_writeChars.containsKey(peerId)) {
        diagnostics.connectError =
            'connected to $peerId but could not subscribe to its '
            'notifications — it will not be able to answer us';
      } else {
        // Connected, but the service did not expose what we need. Worth
        // separating from a failed connection: it means the peer is a
        // different build, not out of range.
        diagnostics.connectError =
            'connected to $peerId but found no Avertis write characteristic';
      }

      // One listener per peer. Registering this on every setup left a
      // stack of them, each firing _dropPeer on the same disconnect.
      await _connSubs.remove(peerId)?.cancel();
      _connSubs[peerId] = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _dropPeer(peerId);
        }
      });
    } on Exception catch (error) {
      diagnostics.connectFailures++;
      diagnostics.connectError = error.toString();
      _dropPeer(peerId);
    } finally {
      _connecting.remove(peerId);
    }
  }

  void _onFrame(String peerId, Uint8List frame) {
    diagnostics.framesReceived++;
    final buffer = _buffers.putIfAbsent(peerId, Reassembly.new);
    final packet = BleFraming.accept(buffer, frame);
    if (packet != null) diagnostics.packetsDecoded++;
    if (packet != null && !_incoming.isClosed) {
      _peerIds.learn(peerId, packet);
      _incoming.add((from: _peerIds.nodeIdFor(peerId), packet: packet));
    }
  }

  void _dropPeer(String peerId) {
    _writeChars.remove(peerId);
    _buffers.remove(peerId);
    unawaited(_valueSubs.remove(peerId)?.cancel());
    unawaited(_connSubs.remove(peerId)?.cancel());
    if (!_peerLost.isClosed) _peerLost.add(peerId);
  }

  @override
  Future<bool> send(String toNode, Packet packet) async {
    final characteristic = _writeChars[toNode];
    if (characteristic != null) {
      try {
        for (final frame in BleFraming.fragment(packet)) {
          await characteristic.write(frame, withoutResponse: false);
        }
        diagnostics.sentAsCentral++;
        diagnostics.sendError = null;
        return true;
      } on Exception catch (error) {
        diagnostics.sendFailures++;
        diagnostics.sendError = error.toString();
        _dropPeer(toNode);
        // Fall through: the peer may still be reachable inbound.
      }
    }
    // The peer connected to us, so answer it over our own notify
    // characteristic instead of dialling back.
    //
    // The whole packet goes down in one call, unlike the central path
    // above: the Kotlin peripheral applies the identical
    // [total][index][count] framing on its own side before notifying.
    // Fragmenting here as well would wrap each frame in a second header
    // and nothing would reassemble.
    final inboundLinkId = _peerIds.linkIdFor(toNode);
    if (_inboundPeers.contains(inboundLinkId)) {
      final ok = await peripheral.send(
        inboundLinkId,
        Uint8List.fromList(packet.encode()),
      );
      if (ok) {
        diagnostics.sentAsPeripheral++;
        diagnostics.sendError = null;
      } else {
        diagnostics.sendFailures++;
        diagnostics.sendError =
            'the GATT server refused a notification to $inboundLinkId '
            '(is the peer subscribed?)';
      }
      return ok;
    }
    diagnostics.sendFailures++;
    diagnostics.sendError = 'no route to $toNode: not connected as a '
        'central, and not subscribed to us as a peer';
    return false;
  }

  @override
  Future<int> broadcast(Packet packet) async {
    var sent = 0;
    for (final peer in peers) {
      if (await send(peer, packet)) sent++;
    }
    return sent;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _scanTimer?.cancel();
    await _scanSub?.cancel();
    for (final sub in _peripheralSubs) {
      await sub.cancel();
    }
    _peripheralSubs.clear();
    await peripheral.stop();
    _inboundPeers.clear();
    try {
      await FlutterBluePlus.stopScan();
    } on Exception {
      // Already stopped.
    }
    for (final sub in _valueSubs.values) {
      await sub.cancel();
    }
    _valueSubs.clear();
    for (final sub in _connSubs.values) {
      await sub.cancel();
    }
    _connSubs.clear();
    _connecting.clear();
    for (final device in _devices.values) {
      try {
        await device.disconnect();
      } on Exception {
        // Best effort.
      }
    }
    _writeChars.clear();
    _buffers.clear();
  }

  Future<void> dispose() async {
    await stop();
    await peripheral.dispose();
    await _incoming.close();
    await _peerFound.close();
    await _peerLost.close();
  }
}
