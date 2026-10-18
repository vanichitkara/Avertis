import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/radio_preference.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Settle the radio before the first frame. Resolving it later would build
  // a node on one radio and immediately replace it with a node on another,
  // which is a visible flip and a wasted start — and on a handset the
  // discarded one is the node that cannot find anybody.
  final choice = await RadioPreference().resolve();

  runApp(ProviderScope(
    overrides: [
      transportModeProvider.overrideWith((ref) => choice.mode),
      radioChoiceProvider.overrideWithValue(choice),
    ],
    child: const AvertisApp(),
  ));
}
