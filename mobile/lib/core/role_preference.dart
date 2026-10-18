/// What this phone says it is, and why.
///
/// The backend does not have a responder registry. It derives responders
/// from the mesh: any node a gateway reports with role RESPONDER is a unit
/// it can dispatch (`agents/coordinator.py`). That is the right design —
/// the mesh is the only thing that knows where anybody currently is — but
/// it means a responder has to exist as a node before dispatch can work.
///
/// Nothing could make one. `MeshController.start` took a role and every
/// caller let it default, so every handset ever built was a SURVIVOR and
/// every incident read "no responders available" with nothing on screen
/// explaining why, or offering to change it.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../mesh/protocol/packet.dart';

const String _storageKey = 'avertis.node_role';

/// The roles an operator may choose between.
///
/// GATEWAY and RELAY are deliberately absent. Both are earned at runtime —
/// a phone is a gateway when it can reach the backend and a relay when it
/// is carrying somebody else's traffic — and letting someone assert either
/// by hand would put a claim on the board that the network does not
/// support.
const List<NodeRole> selectableRoles = [
  NodeRole.survivor,
  NodeRole.responder,
];

String roleLabel(NodeRole role) {
  switch (role) {
    case NodeRole.responder:
      return 'Responder';
    case NodeRole.gateway:
      return 'Gateway';
    case NodeRole.relay:
      return 'Relay';
    case NodeRole.survivor:
      return 'Survivor';
  }
}

String roleDescription(NodeRole role) {
  switch (role) {
    case NodeRole.responder:
      return 'A rescue unit. The command centre can dispatch this phone, '
          'and judges whether it can be reached before it does.';
    case NodeRole.gateway:
      return 'Carries other people\'s reports to the command centre. '
          'Earned automatically whenever this phone has a connection.';
    case NodeRole.relay:
      return 'Passing other people\'s traffic along.';
    case NodeRole.survivor:
      return 'Someone who may need help. Can send an SOS and relay for '
          'others.';
  }
}

class RolePreference {
  const RolePreference();

  /// What this phone was last set to, or survivor for a phone that has
  /// never been set. Defaulting to responder would put a rescue unit on
  /// the board that nobody asked for.
  Future<NodeRole> resolve() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_storageKey);
      if (stored == null) return NodeRole.survivor;
      final role = NodeRole.fromWire(stored);
      return selectableRoles.contains(role) ? role : NodeRole.survivor;
    } on Exception {
      // Storage is unavailable on some devices on first run. A phone that
      // cannot remember its role is still a usable phone.
      return NodeRole.survivor;
    }
  }

  Future<void> remember(NodeRole role) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, role.wire);
    } on Exception {
      // Not worth failing the change the operator just made.
    }
  }
}

/// Whether a node that declared [configured] should act as a gateway.
///
/// Gateway is earned, not chosen: whichever phone can reach the backend
/// becomes everyone else's way out, and hands the role back when it
/// cannot. That is the whole store-and-forward premise.
///
/// A responder is the exception. A rescue unit is the phone most likely
/// to have a connection, so the plain rule would promote it the instant
/// it found signal — and the command centre would lose the only unit it
/// could dispatch, silently, at the worst possible moment.
bool shouldActAsGateway({
  required bool canReachBackend,
  required NodeRole configured,
}) =>
    canReachBackend && configured != NodeRole.responder;
