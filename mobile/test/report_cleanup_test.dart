/// Clearing old reports must never discard an undelivered one.
///
/// A report the command centre has not acknowledged exists only on this
/// phone. Tidying the list is a convenience; losing someone's SOS to it
/// would not be.
library;

import 'package:avertis/data/report_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ReportDatabase db;

  setUp(() => db = ReportDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  Future<void> addReport(String id, {required bool acknowledged}) async {
    await db.insertReport(ReportsCompanion.insert(
      reportId: id,
      packetId: 'pkt-$id',
      kind: 'SOS',
      priority: 'LIFE_CRITICAL',
      createdAt: DateTime.utc(2026, 9, 6, 12),
    ));
    if (acknowledged) {
      await db.markAcknowledged(id, DateTime.utc(2026, 9, 6, 12, 1));
    }
  }

  test('delivered reports are removed', () async {
    await addReport('rpt-done', acknowledged: true);
    await addReport('rpt-also-done', acknowledged: true);

    expect(await db.deleteAcknowledged(), 2);
    expect(await db.allReports(), isEmpty);
  });

  test('an undelivered report is never removed', () async {
    await addReport('rpt-done', acknowledged: true);
    await addReport('rpt-waiting', acknowledged: false);

    final removed = await db.deleteAcknowledged();

    expect(removed, 1);
    final left = await db.allReports();
    expect(left.map((r) => r.reportId), ['rpt-waiting'],
        reason: 'this phone holds the only copy of it');
  });

  test('clearing with nothing delivered removes nothing', () async {
    await addReport('rpt-waiting', acknowledged: false);

    expect(await db.deleteAcknowledged(), 0);
    expect(await db.allReports(), hasLength(1));
  });

  test('the count of waiting reports is what the warning quotes', () async {
    await addReport('rpt-a', acknowledged: false);
    await addReport('rpt-b', acknowledged: false);
    await addReport('rpt-c', acknowledged: true);

    expect(await db.countUnacknowledged(), 2);
  });

  test('clearing is safe to repeat', () async {
    await addReport('rpt-done', acknowledged: true);
    await db.deleteAcknowledged();

    expect(await db.deleteAcknowledged(), 0);
  });
}
