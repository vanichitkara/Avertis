/// One physical BLE link, two names for it.
///
/// A peripheral learns an inbound peer as an Android device address. The
/// central half learns the same peer from its advertisement as a node id
/// like `n7ac20`. The mesh engine must only ever see the node id, so the
/// transport maps between them.
///
/// The mapping is learned from a HELLO, which creates an ordering trap:
/// you cannot address a peer until it has named itself, and it names
/// itself in a beacon you have to be addressable to receive. The two
/// lookups therefore have to agree about an unlearned peer, and when they
/// did not, two phones that had connected to each other both sat waiting
/// for a beacon neither could send — a live BLE link reporting zero
/// neighbours on both handsets.
library;

import 'package:avertis/mesh/protocol/packet.dart';
import 'package:avertis/mesh/transport/ble_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const String deviceAddress = 'AA:BB:CC:DD:EE:FF';
const String nodeId = 'n7ac20';

Packet hello({String origin = nodeId, String? declared}) => Packet.create(
      packetId: 'pkt-hello-0001',
      originNode: origin,
      destination: broadcast,
      messageType: MessageType.hello,
      priority: Priority.normal,
      createdAt: DateTime.utc(2026, 10, 18, 12),
      payload: {'node_id': declared ?? origin, 'seq': 1},
    );

void main() {
  late BlePeerIdentityMap map;

  setUp(() => map = BlePeerIdentityMap());

  group('before a HELLO has arrived', () {
    test('a link is known by its own address', () {
      expect(map.nodeIdFor(deviceAddress), deviceAddress);
    });

    test('and that address still resolves back to the link — the bug', () {
      // This returned null, so `peers` offered the device address and
      // `send` could not turn it back into anything to write to.
      expect(map.linkIdFor(deviceAddress), deviceAddress,
          reason: 'an unaddressable peer can never be sent the beacon that '
              'would make it addressable');
    });

    test('the two lookups are inverses', () {
      expect(map.linkIdFor(map.nodeIdFor(deviceAddress)), deviceAddress);
    });
  });

  group('once a HELLO has named the peer', () {
    setUp(() => map.learn(deviceAddress, hello()));

    test('the link resolves to the node id', () {
      expect(map.nodeIdFor(deviceAddress), nodeId);
    });

    test('the node id resolves back to the link', () {
      expect(map.linkIdFor(nodeId), deviceAddress);
    });

    test('the two lookups are still inverses', () {
      expect(map.linkIdFor(map.nodeIdFor(deviceAddress)), deviceAddress);
    });

    test('forgetting the link gives its own name back', () {
      expect(map.remove(deviceAddress), nodeId);
      expect(map.nodeIdFor(deviceAddress), deviceAddress);
      expect(map.linkIdFor(nodeId), nodeId);
    });
  });

  group('what may establish an identity', () {
    test('only a HELLO', () {
      final report = Packet.create(
        packetId: 'pkt-report-0001',
        originNode: 'n00001',
        destination: anyGateway,
        messageType: MessageType.sos,
        priority: Priority.lifeCritical,
        createdAt: DateTime.utc(2026, 10, 18, 12),
        payload: const {'node_id': 'n00001'},
      );
      map.learn(deviceAddress, report);

      expect(map.nodeIdFor(deviceAddress), deviceAddress,
          reason: 'a relayed report names its author, not the peer that '
              'handed it over');
    });

    test('and only when the payload agrees with the origin', () {
      // A HELLO claiming to come from somebody else does not get to
      // rename the link it arrived on.
      map.learn(deviceAddress, hello(origin: 'n00001', declared: 'nffff9'));

      expect(map.nodeIdFor(deviceAddress), deviceAddress);
    });

    test('an empty id is not an identity', () {
      map.learn(deviceAddress, hello(origin: '', declared: ''));
      expect(map.nodeIdFor(deviceAddress), deviceAddress);
    });
  });

  test('two links keep their own identities', () {
    const otherAddress = '11:22:33:44:55:66';
    map.learn(deviceAddress, hello());
    map.learn(otherAddress, hello(origin: 'nbbbb1'));

    expect(map.nodeIdFor(deviceAddress), nodeId);
    expect(map.nodeIdFor(otherAddress), 'nbbbb1');
    expect(map.linkIdFor(nodeId), deviceAddress);
    expect(map.linkIdFor('nbbbb1'), otherAddress);
  });
}
