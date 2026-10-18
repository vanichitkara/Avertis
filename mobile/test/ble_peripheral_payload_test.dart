/// Exactly one side of each path does the framing.
///
/// The central path frames in Dart: [BleFraming.fragment] on the way out,
/// [BleFraming.accept] on the way in. The peripheral path frames in
/// Kotlin, in BOTH directions — the GATT server fragments what it notifies
/// and reassembles what is written to it, handing Dart a finished payload.
///
/// Dart piped that payload into the reassembler anyway. It reads the first
/// four bytes as [total][index][count], and for a JSON packet those are
/// `{`, `"`, and two characters of the first key, so the declared length
/// never matched and every packet was dropped without a word.
///
/// On the handsets: the gateway reported seven frames received and zero
/// packets decoded, while the phone writing to it was sending perfectly
/// well and decoding six packets of its own in the other direction.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:avertis/mesh/protocol/packet.dart';
import 'package:avertis/mesh/transport/ble_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

Packet sos({String note = 'trapped, water rising'}) => Packet.create(
  packetId: 'pkt-sos-0001',
  originNode: 'n2b5cd',
  destination: anyGateway,
  messageType: MessageType.sos,
  priority: Priority.lifeCritical,
  createdAt: DateTime.utc(2026, 10, 18, 21, 4),
  payload: {'note': note, 'node_id': 'n2b5cd'},
);

void main() {
  test('a reassembled payload decodes as it stands', () {
    final packet = sos();
    final payload = Uint8List.fromList(packet.encode());

    final decoded = BleFraming.decode(payload);

    expect(decoded, isNotNull);
    expect(decoded!.packetId, packet.packetId);
    expect(decoded.payload['note'], 'trapped, water rising');
  });

  test('putting it through the reassembler instead loses it — the bug', () {
    final payload = Uint8List.fromList(sos().encode());

    expect(
      BleFraming.accept(Reassembly(), payload),
      isNull,
      reason: 'the packet\'s own first bytes are read as a fragment header, '
          'which is how a working link decoded nothing at all',
    );
  });

  test('that holds for a packet short enough to be one fragment', () {
    // A HELLO is the smallest thing on the wire, and single-fragment
    // packets are exactly the case where a double-framing bug can look
    // like it works. It does not.
    final hello = Packet.create(
      packetId: 'pkt-hello-0001',
      originNode: 'n2b5cd',
      destination: broadcast,
      messageType: MessageType.hello,
      priority: Priority.normal,
      createdAt: DateTime.utc(2026, 10, 18, 21, 4),
      payload: const {'node_id': 'n2b5cd', 'seq': 1},
    );
    final payload = Uint8List.fromList(hello.encode());

    expect(BleFraming.decode(payload)?.packetId, 'pkt-hello-0001');
    expect(BleFraming.accept(Reassembly(), payload), isNull);
  });

  test('a long report survives the peripheral path whole', () {
    // Several fragments' worth, so a silently truncated payload would show.
    final packet = sos(note: 'x' * 900);
    final payload = Uint8List.fromList(packet.encode());

    expect(BleFraming.decode(payload)?.payload['note'], 'x' * 900);
  });

  test('rubbish is dropped, not thrown', () {
    expect(BleFraming.decode(Uint8List.fromList(utf8.encode('not a packet'))),
        isNull);
    expect(BleFraming.decode(Uint8List(0)), isNull);
  });

  test('the central path still needs its reassembler', () {
    // The other half of the asymmetry: these bytes ARE framed, and
    // decoding them directly must fail. Otherwise a future "simplification"
    // could make both paths the same and break this one instead.
    final packet = sos();
    final frames = BleFraming.fragment(packet);

    expect(frames.length, greaterThan(1));
    expect(BleFraming.decode(frames.first), isNull);

    final buffer = Reassembly();
    Packet? assembled;
    for (final frame in frames) {
      assembled = BleFraming.accept(buffer, frame) ?? assembled;
    }
    expect(assembled?.packetId, packet.packetId);
  });
}
