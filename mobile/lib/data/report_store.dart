/// Local persistence for reports (Drift + SQLite).
///
/// A report is written to disk *before* it is handed to the mesh. If the app
/// is killed, the battery dies, or the phone reboots while offline, the report
/// is still there and is re-offered to the mesh on next launch. Losing a
/// life-critical report to a process death would defeat the whole point.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

part 'report_store.g.dart';

/// One report this device originated.
class Reports extends Table {
  TextColumn get reportId => text()();
  TextColumn get packetId => text()();
  TextColumn get kind => text()();            // SOS | REPORT
  TextColumn get priority => text()();
  // Named `body`, not `text`: `text` collides with Drift's own
  // Table.text() column builder.
  TextColumn get body => text().nullable()();
  TextColumn get transcript => text().nullable()();
  RealColumn get lat => real().nullable()();
  RealColumn get lon => real().nullable()();
  RealColumn get accuracyM => real().nullable()();
  IntColumn get peopleCount => integer().nullable()();
  TextColumn get mediaJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get createdAt => dateTime()();

  /// Local delivery state — what this device actually knows.
  BoolColumn get acknowledged => boolean().withDefault(const Constant(false))();
  DateTimeColumn get acknowledgedAt => dateTime().nullable()();
  IntColumn get retransmissions => integer().withDefault(const Constant(0))();

  /// Assigned by the backend once it has been synced through a gateway.
  TextColumn get incidentId => text().nullable()();

  @override
  Set<Column> get primaryKey => {reportId};
}

@DriftDatabase(tables: [Reports])
class ReportDatabase extends _$ReportDatabase {
  ReportDatabase(super.e);

  ReportDatabase.open() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  Future<void> insertReport(ReportsCompanion report) =>
      into(reports).insert(report, mode: InsertMode.insertOrReplace);

  Future<List<Report>> allReports() =>
      (select(reports)..orderBy([(r) => OrderingTerm.desc(r.createdAt)])).get();

  Stream<List<Report>> watchReports() =>
      (select(reports)..orderBy([(r) => OrderingTerm.desc(r.createdAt)]))
          .watch();

  /// Reports this device has not seen acknowledged. These are re-offered to
  /// the mesh on launch.
  Future<List<Report>> unacknowledged() =>
      (select(reports)..where((r) => r.acknowledged.equals(false))).get();

  Future<void> markAcknowledged(String reportId, DateTime at) =>
      (update(reports)..where((r) => r.reportId.equals(reportId)))
          .write(ReportsCompanion(
        acknowledged: const Value(true),
        acknowledgedAt: Value(at),
      ));

  Future<void> recordRetransmission(String reportId) async {
    final row = await (select(reports)
          ..where((r) => r.reportId.equals(reportId)))
        .getSingleOrNull();
    if (row == null) return;
    await (update(reports)..where((r) => r.reportId.equals(reportId)))
        .write(ReportsCompanion(
      retransmissions: Value(row.retransmissions + 1),
    ));
  }

  Future<void> attachIncidentId(String reportId, String incidentId) =>
      (update(reports)..where((r) => r.reportId.equals(reportId)))
          .write(ReportsCompanion(incidentId: Value(incidentId)));
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    return NativeDatabase.createInBackground(
      File(p.join(dir.path, 'avertis_reports.sqlite')),
    );
  });
}
