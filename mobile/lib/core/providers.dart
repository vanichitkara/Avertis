/// Riverpod wiring for the app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/report_store.dart';
import '../mesh/mesh_events.dart';
import 'mesh_controller.dart';
import 'node_identity.dart';
import 'radio_preference.dart';

final databaseProvider = Provider<ReportDatabase>((ref) {
  final db = ReportDatabase.open();
  ref.onDispose(db.close);
  return db;
});

final nodeIdentityProvider = Provider<NodeIdentity>(
  (ref) => NodeIdentity(const FlutterSecureStorage()),
);

final nodeIdProvider = FutureProvider<String>(
  (ref) => ref.watch(nodeIdentityProvider).nodeId(),
);

final radioPreferenceProvider = Provider<RadioPreference>(
  (ref) => RadioPreference(),
);

/// How the starting radio was chosen. Overridden in `main`, which resolves
/// it before the first frame; this default only applies to tests and to any
/// entry point that forgets to.
final radioChoiceProvider = Provider<RadioChoice>(
  (ref) => const RadioChoice(TransportMode.mock, RadioChoiceOrigin.undetermined),
);

/// Which radio this node is on.
///
/// Seeded in `main` from what this phone was last set to, or from whether
/// it has a Bluetooth adapter at all. It used to default to the mock
/// unconditionally, which meant a handset began every launch on a radio
/// that cannot reach another phone — and because the choice was never
/// saved, two phones being tested together quietly fell back to it on
/// every restart.
///
/// Switching remains a real operational act — it tears the node out of one
/// mesh and puts it in another — so it stays deliberate, done from the mesh
/// screen, and the home screen always names the radio in use.
final transportModeProvider = StateProvider<TransportMode>(
  (ref) => TransportMode.mock,
);

final meshControllerProvider = ChangeNotifierProvider<MeshController>((ref) {
  // ChangeNotifierProvider disposes the notifier itself — registering
  // ref.onDispose here as well would dispose it twice.
  return MeshController(
    database: ref.watch(databaseProvider),
    mode: ref.watch(transportModeProvider),
  );
});

final meshStatusProvider = Provider<MeshStatus>(
  (ref) => ref.watch(meshControllerProvider).status,
);

final meshEventsProvider = StreamProvider<MeshEvent>(
  (ref) => ref.watch(meshControllerProvider).bus.stream,
);

final reportsProvider = StreamProvider<List<Report>>(
  (ref) => ref.watch(databaseProvider).watchReports(),
);
