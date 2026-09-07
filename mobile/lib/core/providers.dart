/// Riverpod wiring for the app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/report_store.dart';
import '../mesh/mesh_events.dart';
import 'mesh_controller.dart';
import 'node_identity.dart';

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

/// Which radio this node is on.
///
/// Defaults to the mock so the app is fully exercisable on an emulator, which
/// has no Bluetooth. Switching is a real operational act — it tears the node
/// out of one mesh and puts it in another — so it is deliberate, done from the
/// mesh screen, and the home screen always names the radio in use.
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
