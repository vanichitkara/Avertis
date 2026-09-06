/// App shell: routing, theme, and mesh startup.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/mesh/mesh_screen.dart';
import 'features/reports/report_screen.dart';
import 'features/reports/reports_list_screen.dart';
import 'features/sos/sos_screen.dart';

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/sos', builder: (_, __) => const SosScreen()),
    GoRoute(
      path: '/report',
      builder: (_, state) => ReportScreen(
        locationOnly: state.uri.queryParameters['mode'] == 'location',
      ),
    ),
    GoRoute(path: '/reports', builder: (_, __) => const ReportsListScreen()),
    GoRoute(path: '/mesh', builder: (_, __) => const MeshScreen()),
  ],
);

class AvertisApp extends ConsumerStatefulWidget {
  const AvertisApp({super.key});

  @override
  ConsumerState<AvertisApp> createState() => _AvertisAppState();
}

class _AvertisAppState extends ConsumerState<AvertisApp> {
  @override
  void initState() {
    super.initState();
    // Start the mesh as soon as we have a stable node identity. The app is
    // useful the moment it opens — there is no sign-in, no setup, no account.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final nodeId = await ref.read(nodeIdProvider.future);
      if (!mounted) return;
      await ref.read(meshControllerProvider).start(nodeId: nodeId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Avertis',
      debugShowCheckedModeBanner: false,
      theme: buildAvertisTheme(),
      routerConfig: _router,
    );
  }
}
