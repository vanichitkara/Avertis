/// BLE framing is pure and testable without a radio — which matters, because
/// a fragmentation bug would only show up on physical phones otherwise.
library;

import 'dart:typed_data';

import 'package:avertis/mesh/protocol/packet.dart';
import 'package:avertis/mesh/transport/ble_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

Packet packetOfSize(int approxPayloadChars) => Packet.create(
  packetId: 'pkt-0000000000000001',
  originNode: 'node-07',
  destination: anyGateway,
  messageType: MessageType.incident,
  priority: Priority.lifeCritical,
  createdAt: DateTime.utc(2026, 9, 6, 12),
  payload: {'text': 'x' * approxPayloadChars},
);

void main() {
  group('BLE peer identity mapping', () {
    Packet hello({required String nodeId, String? origin}) => Packet.create(
      packetId: 'pkt-hello-$nodeId',
      originNode: origin ?? nodeId,
      destination: broadcast,
      messageType: MessageType.hello,
      priority: Priority.normal,
      createdAt: DateTime.utc(2026, 10, 18),
      payload: {'node_id': nodeId},
    );

    test('uses the node id after learning it from a direct HELLO', () {
      final peers = BlePeerIdentityMap();
      peers.learn('AA:BB:CC:DD:EE:FF', hello(nodeId: 'n7ac20'));

      expect(peers.nodeIdFor('AA:BB:CC:DD:EE:FF'), 'n7ac20');
      expect(peers.linkIdFor('n7ac20'), 'AA:BB:CC:DD:EE:FF');
    });

    test('does not let a mismatched HELLO rename a direct peer', () {
      final peers = BlePeerIdentityMap();
      peers.learn(
        'AA:BB:CC:DD:EE:FF',
        hello(nodeId: 'n7ac20', origin: 'n-other'),
      );

      expect(peers.nodeIdFor('AA:BB:CC:DD:EE:FF'), 'AA:BB:CC:DD:EE:FF');
      expect(peers.linkIdFor('n7ac20'), isNull);
    });

    test('forgets the mapping when the BLE connection closes', () {
      final peers = BlePeerIdentityMap();
      peers.learn('AA:BB:CC:DD:EE:FF', hello(nodeId: 'n7ac20'));

      expect(peers.remove('AA:BB:CC:DD:EE:FF'), 'n7ac20');
      expect(peers.linkIdFor('n7ac20'), isNull);
    });
  });

  test('a small packet still produces at least one frame', () {
    final frames = BleFraming.fragment(packetOfSize(1));
    expect(frames, isNotEmpty);
    expect(frames.first[3], frames.length);
  });

  test('every frame fits inside the safe BLE write size', () {
    for (final frames in [
      BleFraming.fragment(packetOfSize(1)),
      BleFraming.fragment(packetOfSize(500)),
      BleFraming.fragment(packetOfSize(3000)),
    ]) {
      for (final frame in frames) {
        expect(frame.length, lessThanOrEqualTo(safeFragmentBytes));
      }
    }
  });

  test('a fragmented packet reassembles exactly', () {
    final original = packetOfSize(1200);
    final frames = BleFraming.fragment(original);
    expect(
      frames.length,
      greaterThan(1),
      reason: 'this packet should need fragmenting',
    );

    final buffer = Reassembly();
    Packet? result;
    for (final frame in frames) {
      result = BleFraming.accept(buffer, frame);
    }
    expect(result, isNotNull);
    expect(result!.toJson(), equals(original.toJson()));
  });

  test('fragments arriving out of order still reassemble', () {
    final original = packetOfSize(1200);
    final frames = BleFraming.fragment(original).reversed.toList();

    final buffer = Reassembly();
    Packet? result;
    for (final frame in frames) {
      result = BleFraming.accept(buffer, frame);
    }
    expect(result, isNotNull);
    expect(result!.packetId, original.packetId);
  });

  test('an incomplete packet yields nothing rather than a partial one', () {
    final frames = BleFraming.fragment(packetOfSize(1200));
    final buffer = Reassembly();
    for (final frame in frames.take(frames.length - 1)) {
      expect(BleFraming.accept(buffer, frame), isNull);
    }
  });

  test('a corrupt frame is dropped, not thrown', () {
    final buffer = Reassembly();
    final garbage = Uint8List.fromList([0, 5, 0, 1, 1, 2, 3, 4, 5]);
    expect(() => BleFraming.accept(buffer, garbage), returnsNormally);
    expect(BleFraming.accept(buffer, garbage), isNull);
  });

  test('a runt frame is ignored', () {
    expect(BleFraming.accept(Reassembly(), Uint8List.fromList([1, 2])), isNull);
  });
}
