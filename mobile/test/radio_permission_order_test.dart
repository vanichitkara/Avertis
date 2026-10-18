/// Restarting the radio under a running node.
///
/// Android refuses a scan without BLUETOOTH_SCAN and an advertisement
/// without BLUETOOTH_ADVERTISE. The controller started the transport
/// first and asked for permissions afterwards, and nothing restarted it
/// when the grant arrived — so two phones with Bluetooth switched on sat
/// on "searching" for the whole session.
///
/// That ordering was latent for as long as the app came up on the
/// simulated radio: a BLE transport was only ever built after someone had
/// granted permissions by hand. Defaulting to Bluetooth exposed it.
///
/// The ordering fix itself lives in [MeshController.start] and is
/// verified on a handset. What is covered here is the other half — that
/// a radio can be replaced after a late grant without losing the node,
/// which is what makes recovery possible at all.
library;

import 'package:avertis/mesh/mesh_engine.dart';
import 'package:avertis/mesh/mesh_events.dart';
import 'package:avertis/mesh/node_state.dart';
import 'package:avertis/mesh/transport/mock_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MeshEngine engine;

  setUp(() async {
    final space = MockRadioSpace(rangeM: 120, latency: Duration.zero);
    final first = MockMeshTransport('n1', space);
    space.register(first);
    engine = MeshEngine(
      state: NodeState(nodeId: 'n1'),
      transport: first,
      bus: MeshEventBus(),
    );
    await engine.start();
  });

  tearDown(() async => engine.stop());

  Future<MockMeshTransport> swapInFreshRadio() async {
    final space = MockRadioSpace(rangeM: 120, latency: Duration.zero);
    final replacement = MockMeshTransport('n1', space);
    space.register(replacement);
    await engine.restartTransport(replacement);
    return replacement;
  }

  test('the new radio is the one in use', () async {
    final replacement = await swapInFreshRadio();
    expect(identical(engine.transport, replacement), isTrue);
  });

  test('a held report survives the swap', () async {
    await engine.sendSos(note: 'trapped');
    expect(engine.custodyDepth, 1);

    await swapInFreshRadio();

    expect(engine.custodyDepth, 1,
        reason: 'the radio restarted, the node did not — somebody is still '
            'waiting on that report');
    expect(engine.nodeId, 'n1');
  });

  test('counters are kept, because they are this node\'s history', () async {
    await engine.sendSos(note: 'one');
    final originated = engine.packetsOriginated;

    await swapInFreshRadio();

    expect(engine.packetsOriginated, originated);
  });

  test('neighbours are not carried over', () async {
    engine.state.neighbors['n2'] = Neighbor('n2');

    await swapInFreshRadio();

    expect(engine.state.neighbors, isEmpty,
        reason: 'nothing has been heard on the new radio yet, so keeping '
            'the old list would claim a link that may not exist');
  });

  test('the node still works afterwards', () async {
    await swapInFreshRadio();

    final packet = await engine.sendSos(note: 'after the swap');
    expect(packet.originNode, 'n1');
    expect(engine.custodyDepth, greaterThan(0));
  });

  test('swapping twice is safe', () async {
    await swapInFreshRadio();
    final second = await swapInFreshRadio();

    expect(identical(engine.transport, second), isTrue);
    final packet = await engine.sendSos(note: 'still here');
    expect(packet.originNode, 'n1');
  });
}
