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
final Guid avertisServiceUuid =
    Guid('a5e7f1c0-1c2b-4c9a-9f10-000000000001');
final Guid avertisTxCharacteristic =
    Guid('a5e7f1c0-1c2b-4c9a-9f10-000000000002');

/// The characteristic a peer's *peripheral* half notifies us on. We subscribe
/// to this on every peer we connect to as a central.
final Guid avertisNotifyCharacteristic =
    Guid('a5e7f1c0-1c2b-4c9a-9f10-000000000003');

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
      return null;   // a corrupt frame is dropped, never crashes the engine
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

  final _incoming =
      StreamController<({String from, Packet packet})>.broadcast();
  final _peerFound = StreamController<PeerInfo>.broadcast();
  final _peerLost = StreamController<String>.broadcast();

  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, BluetoothCharacteristic> _writeChars = {};
  final Map<String, Reassembly> _buffers = {};
  final Map<String, StreamSubscription<dynamic>> _valueSubs = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  final List<StreamSubscription<dynamic>> _peripheralSubs = [];
  Timer? _scanTimer;
  bool _running = false;

  @override
  Stream<({String from, Packet packet})> get incoming => _incoming.stream;

  @override
  Stream<PeerInfo> get peerFound => _peerFound.stream;

  @override
  Stream<String> get peerLost => _peerLost.stream;

  @override
  List<String> get peers =>
      {..._writeChars.keys, ..._inboundPeers}.toList()..sort();

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
        if (!_writeChars.containsKey(id)) _dropPeer(id);
      }),
    ]);
    await peripheral.start(
      nodeId: nodeId,
      role: role.wire,
      battery: battery,
    );

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
      await FlutterBluePlus.startScan(
        withServices: [avertisServiceUuid],
        timeout: scanWindow,
      );
    } on Exception {
      // A failed scan window is not fatal; the next one will retry.
    }
  }

  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      final peerId = _peerIdOf(result);
      if (peerId == null || peerId == nodeId) continue;
      _devices[peerId] = result.device;
      _peerFound.add(PeerInfo(
        nodeId: peerId,
        battery: _batteryOf(result),
        rssi: result.rssi,
      ));
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

  Future<void> _ensureConnected(String peerId, BluetoothDevice device) async {
    if (_writeChars.containsKey(peerId)) return;
    try {
      await device.connect(timeout: const Duration(seconds: 8));
      final services = await device.discoverServices();
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
            await characteristic.setNotifyValue(true);
            _valueSubs[peerId] = characteristic.onValueReceived.listen(
              (value) => _onFrame(peerId, Uint8List.fromList(value)),
            );
          }
        }
      }
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _dropPeer(peerId);
        }
      });
    } on Exception {
      _dropPeer(peerId);
    }
  }

  void _onFrame(String peerId, Uint8List frame) {
    final buffer = _buffers.putIfAbsent(peerId, Reassembly.new);
    final packet = BleFraming.accept(buffer, frame);
    if (packet != null && !_incoming.isClosed) {
      _incoming.add((from: peerId, packet: packet));
    }
  }

  void _dropPeer(String peerId) {
    _writeChars.remove(peerId);
    _buffers.remove(peerId);
    unawaited(_valueSubs.remove(peerId)?.cancel());
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
        return true;
      } on Exception {
        _dropPeer(toNode);
        // Fall through: the peer may still be reachable inbound.
      }
    }
    // The peer connected to us, so answer it over our own notify
    // characteristic instead of dialling back.
    if (_inboundPeers.contains(toNode)) {
      return peripheral.send(
        toNode,
        Uint8List.fromList(packet.encode()),
      );
    }
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
