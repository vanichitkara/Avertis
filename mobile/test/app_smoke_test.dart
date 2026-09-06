/// The app must open straight into a usable emergency screen — no sign-in, no
/// setup, no empty state. That is a product requirement, so it is a test.
library;

import 'package:avertis/app.dart';
import 'package:avertis/core/providers.dart';
import 'package:avertis/data/report_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home shows connectivity state and the SOS action',
      (tester) async {
    final db = ReportDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const AvertisApp(),
      ),
    );
    await tester.pump();

    expect(find.text('AVERTIS'), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
    expect(find.text('REPORT INCIDENT'), findsOneWidget);

    // Connectivity must be stated explicitly — never left ambiguous.
    expect(find.text('Internet'), findsOneWidget);
    expect(find.text('OFFLINE'), findsOneWidget);
    expect(find.text('Mesh'), findsOneWidget);
  });

  testWidgets('SOS screen is reachable and warns before sending',
      (tester) async {
    final db = ReportDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const AvertisApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('SOS'));
    await tester.pumpAndSettle();

    expect(find.text('SEND SOS NOW'), findsOneWidget);
    expect(find.text('LIFE-CRITICAL'), findsOneWidget);
    expect(
      find.textContaining('relayed ahead of all other traffic'),
      findsOneWidget,
    );
  });
}
