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
  /// Both directions of a BLE link must put the same thing on the wire.
  ///
  /// A central writes to the peer's characteristic; a peripheral notifies
  /// on its own. Different Android APIs, and the framing is applied in
  /// different places — Dart fragments for the central path, the Kotlin
  /// peripheral fragments for its own — but the receiving code is the
  /// same on both sides and always reads a 4-byte header first.
  ///
  /// So the rule both paths have to keep is that exactly one of them
  /// frames. Framing twice wraps each frame in a second header and
  /// nothing reassembles; framing neither way means a packet's own first
  /// bytes are read as [total][index][count] and nothing decodes.
  group('what goes on the wire', () {
    Packet report() => Packet.create(
          packetId: 'pkt-aaaaaaaaaaaaaaaa',
          originNode: 'n7ac20',
          destination: anyGateway,
          messageType: MessageType.sos,
          priority: Priority.lifeCritical,
          createdAt: DateTime.utc(2026, 10, 18, 12),
          payload: const {
            'report_id': 'rpt-1',
            'node_id': 'n7ac20',
            'text': 'three people trapped under the bridge, water rising',
            'location': {'lat': 28.6861, 'lon': 77.1253, 'accuracy_m': 12.0},
          },
        );

    Packet? feed(List<Uint8List> frames) {
      final buffer = Reassembly();
      Packet? out;
      for (final frame in frames) {
        out = BleFraming.accept(buffer, frame) ?? out;
      }
      return out;
    }

    test('a framed packet is reassembled', () {
      final decoded = feed(BleFraming.fragment(report()));
      expect(decoded, isNotNull);
      expect(decoded!.packetId, 'pkt-aaaaaaaaaaaaaaaa');
      expect(decoded.payload['report_id'], 'rpt-1');
    });

    test('an unframed packet is not', () {
      final raw = Uint8List.fromList(report().encode());
      expect(feed([raw]), isNull,
          reason: 'the receiver reads the packet\'s own first bytes as a '
              'fragment header, so something must frame it first');
    });

    test('every frame carries a header the receiver can read', () {
      for (final frame in BleFraming.fragment(report())) {
        expect(frame.length, greaterThanOrEqualTo(4));
        expect(frame.length, lessThanOrEqualTo(safeFragmentBytes));
      }
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
