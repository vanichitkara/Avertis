/// A phone has to be able to say it is a responder.
///
/// The backend keeps no responder registry. It derives responders from
/// the mesh — any node a gateway reports with role RESPONDER is a unit it
/// can dispatch — which is the right design, because the mesh is the only
/// thing that knows where anyone currently is.
///
/// But `MeshController.start` took a role and every caller let it
/// default, and there was no picker anywhere in the app. So every handset
/// ever built was a SURVIVOR, and every incident on the command centre
/// read "no responders available" with nothing explaining why.
///
/// The second half matters as much as the first: a gateway role is earned
/// by having a connection, and a rescue unit is exactly the phone most
/// likely to have one. Promoting it would reclassify the only responder
/// on the board the moment it found signal.
library;

import 'package:avertis/core/mesh_controller.dart';
import 'package:avertis/core/role_preference.dart';
import 'package:avertis/data/report_store.dart';
import 'package:avertis/mesh/protocol/packet.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const preference = RolePreference();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('what an operator may choose', () {
    test('survivor and responder, and nothing else', () {
      expect(selectableRoles, [NodeRole.survivor, NodeRole.responder]);
    });

    test('gateway is not offered — it is earned', () {
      // Asserting it by hand would put a claim on the board that the
      // network does not support.
      expect(selectableRoles, isNot(contains(NodeRole.gateway)));
      expect(selectableRoles, isNot(contains(NodeRole.relay)));
    });

    test('every choice is described, so none is a bare word', () {
      for (final role in selectableRoles) {
        expect(roleLabel(role), isNotEmpty);
        expect(roleDescription(role).length, greaterThan(20));
      }
    });
  });

  group('remembering it', () {
    test('a phone that has never been set is a survivor', () async {
      expect(await preference.resolve(), NodeRole.survivor);
    });

    test('a declared role survives a restart — the bug', () async {
      await preference.remember(NodeRole.responder);

      expect(await preference.resolve(), NodeRole.responder,
          reason: 'a responder that reverts on relaunch disappears from '
              'the command centre mid-demo');
    });

    test('it can be handed back', () async {
      await preference.remember(NodeRole.responder);
      await preference.remember(NodeRole.survivor);

      expect(await preference.resolve(), NodeRole.survivor);
    });

    test('a stored role nobody may pick is ignored', () async {
      // An older build, or a hand-edited preference. Coming back up as a
      // self-declared gateway would be worse than coming back as nothing.
      SharedPreferences.setMockInitialValues(
        {'avertis.node_role': 'GATEWAY'},
      );

      expect(await preference.resolve(), NodeRole.survivor);
    });

    test('unreadable rubbish does not stop the app starting', () async {
      SharedPreferences.setMockInitialValues(
        {'avertis.node_role': 'not-a-role'},
      );

      expect(await preference.resolve(), NodeRole.survivor);
    });
  });

  test('the role goes over the wire as the backend spells it', () {
    // agents/coordinator.py matches on node.role.value == "RESPONDER".
    expect(NodeRole.responder.wire, 'RESPONDER');
    expect(NodeRole.fromWire('RESPONDER'), NodeRole.responder);
  });

  group('who acts as a gateway', () {
    test('a survivor with a connection does', () {
      expect(
        shouldActAsGateway(
            canReachBackend: true, configured: NodeRole.survivor),
        isTrue,
      );
    });

    test('a survivor without one does not', () {
      expect(
        shouldActAsGateway(
            canReachBackend: false, configured: NodeRole.survivor),
        isFalse,
      );
    });

    test('a responder with a connection does NOT — the bug', () {
      // The plain rule promotes whichever phone finds signal, and a
      // rescue unit is the likeliest to have it. The board would lose
      // the only unit it could dispatch, silently.
      expect(
        shouldActAsGateway(
            canReachBackend: true, configured: NodeRole.responder),
        isFalse,
        reason: 'promoting the responder is how "no responders available" '
            'comes back the moment one finds Wi-Fi',
      );
    });

    test('and certainly not without one', () {
      expect(
        shouldActAsGateway(
            canReachBackend: false, configured: NodeRole.responder),
        isFalse,
      );
    });

    test('no connection is never a gateway, whatever was declared', () {
      for (final role in NodeRole.values) {
        expect(
          shouldActAsGateway(canReachBackend: false, configured: role),
          isFalse,
          reason: 'a phone that cannot reach the backend cannot be '
              'anybody\'s way out',
        );
      }
    });
  });

  group('a running node', () {
    late ReportDatabase db;
    late MeshController controller;

    setUp(() {
      db = ReportDatabase(NativeDatabase.memory());
      // No backend, so nothing reaches out during the test and the node
      // can never be promoted behind our backs.
      controller = MeshController(database: db, apiBase: '');
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
    });

    test('starts as whatever it was told — the bug', () async {
      // Every caller let the role default, so this was always survivor.
      await controller.start(
        nodeId: 'node-test',
        role: NodeRole.responder,
      );

      expect(controller.configuredRole, NodeRole.responder);
      expect(controller.engine!.state.role, NodeRole.responder,
          reason: 'the engine\'s role is what the gateway sync reports, '
              'and what makes this phone dispatchable');
    });

    test('can be changed while running', () async {
      await controller.start(nodeId: 'node-test');
      expect(controller.configuredRole, NodeRole.survivor);

      await controller.setRole(NodeRole.responder);

      expect(controller.configuredRole, NodeRole.responder);
      expect(controller.engine!.state.role, NodeRole.responder);
    });

    test('and the change is remembered for next launch', () async {
      await controller.start(nodeId: 'node-test');
      await controller.setRole(NodeRole.responder);

      expect(await preference.resolve(), NodeRole.responder);
    });

    test('setting the role it already has does nothing', () async {
      await controller.start(nodeId: 'node-test');
      await controller.setRole(NodeRole.survivor);

      expect(controller.configuredRole, NodeRole.survivor);
    });

    test('a responder keeps its custody when it changes role', () async {
      await controller.start(nodeId: 'node-test');
      await controller.engine!.sendSos(note: 'trapped');
      expect(controller.engine!.custodyDepth, 1);

      await controller.setRole(NodeRole.responder);

      expect(controller.engine!.custodyDepth, 1,
          reason: 'declaring a role restarts the radio, not the node — '
              'somebody is still waiting on that report');
    });
  });
}
