/// App shell: routing, theme, and mesh startup.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/mesh_controller.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/map/mesh_map_screen.dart';
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
    GoRoute(path: '/situation', builder: (_, __) => const MeshMapScreen()),
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCurrentNode());
  }

  /// Start whichever controller is current.
  ///
  /// Switching the radio replaces the controller outright: Riverpod disposes
  /// the old one and builds a new one. Without starting the replacement the
  /// node goes silently dead — no engine, no transport, nothing relayed — and
  /// the UI would still look fine. [MeshController.start] is idempotent, so
  /// calling this more than once is harmless.
  Future<void> _startCurrentNode() async {
    final nodeId = await ref.read(nodeIdProvider.future);
    if (!mounted) return;
    await ref.read(meshControllerProvider).start(nodeId: nodeId);
  }

  @override
  Widget build(BuildContext context) {
    // Fires on every notifyListeners() with the same instance, and with a new
    // instance only when the radio changed — which is the case that matters.
    ref.listen<MeshController>(meshControllerProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        unawaited(_startCurrentNode());
      }
    });

    return MaterialApp.router(
      title: 'Avertis',
      debugShowCheckedModeBanner: false,
      theme: buildAvertisTheme(),
      routerConfig: _router,
    );
  }
}
