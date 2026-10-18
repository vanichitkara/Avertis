/// BLE framing is pure and testable without a radio — which matters, because
/// a fragmentation bug would only show up on physical phones otherwise.
library;

import 'dart:math';
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
  /// Two packets in flight on one link.
  ///
  /// The frame header carries no packet identifier, so the receiver keeps
  /// one buffer per peer and cannot tell two packets apart. The engine
  /// beacons and pumps its queue without awaiting either, so a one-frame
  /// HELLO landed between two fragments of a report and overwrote both
  /// the buffer's count and one of its fragments — losing the pair.
  ///
  /// Small packets survived that most of the time and multi-fragment ones
  /// almost never did: two handsets held a steady link, exchanged
  /// beacons, agreed they were neighbours, and never got a report across.
  /// It showed as about four frames received for every packet decoded.
  group('two packets interleaved on one link', () {
    Packet beacon() => Packet.create(
          packetId: 'pkt-hello-00000001',
          originNode: 'n7ac20',
          destination: broadcast,
          messageType: MessageType.hello,
          priority: Priority.normal,
          createdAt: DateTime.utc(2026, 10, 18, 12),
          payload: const {'node_id': 'n7ac20', 'seq': 4},
        );

    Packet report() => Packet.create(
          packetId: 'pkt-sos-0000000001',
          originNode: 'n7ac20',
          destination: anyGateway,
          messageType: MessageType.sos,
          priority: Priority.lifeCritical,
          createdAt: DateTime.utc(2026, 10, 18, 12),
          payload: {
            'report_id': 'rpt-1',
            'node_id': 'n7ac20',
            // Long enough to need more than one fragment, as a real one is.
            'note': 'three people trapped under the collapsed bridge on the '
                'east side, water is rising fast and one of them is not '
                'responding, we cannot reach them from the bank',
            'location': {'lat': 28.6861, 'lon': 77.1253, 'accuracy_m': 12.0},
          },
        );

    test('the report needs more than one frame, or this proves nothing', () {
      // Both are multi-fragment in practice; what matters is that they
      // differ, so the receiver has something to tell them apart by.
      expect(BleFraming.fragment(report()).length, greaterThan(1));
      expect(BleFraming.fragment(beacon()).length,
          lessThan(BleFraming.fragment(report()).length));
    });

    /// The report's frames and the beacon's, alternating — the worst
    /// case the radio can actually produce.
    List<Uint8List> shuffledTogether() {
      final a = BleFraming.fragment(report());
      final b = BleFraming.fragment(beacon());
      final mixed = <Uint8List>[];
      for (var i = 0; i < a.length + b.length; i++) {
        if (i ~/ 2 < a.length && i.isEven) mixed.add(a[i ~/ 2]);
        if (i ~/ 2 < b.length && i.isOdd) mixed.add(b[i ~/ 2]);
      }
      // Anything left over, in order.
      mixed.addAll(a.skip((a.length + b.length + 1) ~/ 2));
      return mixed;
    }

    test('both packets survive being interleaved', () {
      final buffer = Reassembly();
      final decoded = <Packet>[];
      for (final frame in BleFraming.fragment(report())
          .followedBy(BleFraming.fragment(beacon()))
          .toList()
        ..shuffle(Random(7))) {
        final packet = BleFraming.accept(buffer, frame);
        if (packet != null) decoded.add(packet);
      }

      expect(decoded.map((p) => p.messageType),
          containsAll([MessageType.sos, MessageType.hello]),
          reason: 'one buffer per peer used to let these overwrite each '
              'other, and both were lost');
      expect(
        decoded.firstWhere((p) => p.messageType == MessageType.sos)
            .payload['report_id'],
        'rpt-1',
      );
    });

    test('alternating frames still reassemble', () {
      final buffer = Reassembly();
      final decoded = <Packet>[];
      for (final frame in shuffledTogether()) {
        final packet = BleFraming.accept(buffer, frame);
        if (packet != null) decoded.add(packet);
      }
      expect(decoded.where((p) => p.messageType == MessageType.sos),
          isNotEmpty);
    });

    test('the interruption is counted rather than passed over', () {
      final buffer = Reassembly();
      BleFraming.accept(buffer, BleFraming.fragment(report()).first);
      BleFraming.accept(buffer, BleFraming.fragment(beacon()).first);

      expect(buffer.mismatches, greaterThan(0),
          reason: 'a link that is still interleaving should be visible');
    });

    test('an uninterrupted report still reassembles', () {
      final buffer = Reassembly();
      Packet? decoded;
      for (final frame in BleFraming.fragment(report())) {
        decoded = BleFraming.accept(buffer, frame) ?? decoded;
      }
      expect(decoded?.payload['report_id'], 'rpt-1');
    });
  });

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
