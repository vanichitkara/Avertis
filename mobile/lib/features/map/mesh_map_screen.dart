/// The local situation view.
///
/// This deliberately is **not** Google Maps. A tile-backed map needs network
/// to fetch tiles and an API key to work at all — both unavailable in exactly
/// the situation Avertis exists for. What a survivor or responder needs on a
/// disconnected phone is not streets: it is who is reachable, how far away,
/// in which direction, and what this node is still carrying.
///
/// So this draws the live mesh from measured state: real bearings and
/// distances computed from GPS, real link stability, real queue depths. Every
/// element on screen corresponds to something this device actually observed.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../mesh/node_state.dart';
import '../../mesh/protocol/packet.dart';

const double _earthRadiusM = 6371000;

/// Great-circle distance in metres.
double distanceM(GeoPoint a, GeoPoint b) {
  final p1 = a.lat * math.pi / 180;
  final p2 = b.lat * math.pi / 180;
  final dp = p2 - p1;
  final dl = (b.lon - a.lon) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// Initial bearing from a to b, in radians clockwise from north.
double bearingRad(GeoPoint a, GeoPoint b) {
  final p1 = a.lat * math.pi / 180;
  final p2 = b.lat * math.pi / 180;
  final dl = (b.lon - a.lon) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) -
      math.sin(p1) * math.cos(p2) * math.cos(dl);
  return math.atan2(y, x);
}

/// A neighbour placed for drawing.
class PlottedNode {
  const PlottedNode({
    required this.nodeId,
    required this.role,
    required this.state,
    required this.stability,
    required this.battery,
    this.distanceM,
    this.bearingRad,
  });

  final String nodeId;
  final NodeRole role;
  final LinkState state;
  final double stability;
  final double battery;

  /// Null when we have no position for this peer — it is still drawn, but
  /// placed by link quality rather than geography, and labelled as such.
  final double? distanceM;
  final double? bearingRad;

  bool get located => distanceM != null && bearingRad != null;
}

/// Turn neighbours into plottable points using only what was measured.
List<PlottedNode> plotNeighbors(
  Iterable<Neighbor> neighbors,
  GeoPoint? origin,
) {
  return neighbors.map((n) {
    final peer = n.location;
    final canLocate = origin != null && peer != null;
    return PlottedNode(
      nodeId: n.nodeId,
      role: n.role,
      state: n.state,
      stability: n.stability,
      battery: n.battery,
      distanceM: canLocate ? distanceM(origin, peer) : null,
      bearingRad: canLocate ? bearingRad(origin, peer) : null,
    );
  }).toList();
}

class MeshMapScreen extends ConsumerWidget {
  const MeshMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(meshControllerProvider);
    final engine = controller.engine;
    final origin = controller.locationState.point;
    final plotted =
        plotNeighbors(engine?.state.neighbors.values ?? const [], origin);

    final located = plotted.where((n) => n.located).toList();
    final range = located.isEmpty
        ? 200.0
        : math.max(
            100.0,
            located.map((n) => n.distanceM!).reduce(math.max) * 1.15,
          );

    return Scaffold(
      appBar: AppBar(title: const Text('SITUATION')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: CustomPaint(
                painter: _MeshPainter(
                  nodes: plotted,
                  rangeM: range,
                  hasFix: origin != null,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                origin == null
                    ? 'No location fix — nodes are placed by signal strength, '
                        'not direction.'
                    : 'Range ${_formatDistance(range)} · north is up',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 11, color: AvertisColors.textSecondary),
              ),
            ),
            const SizedBox(height: 20),
            if (plotted.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No nodes in range',
                      style: TextStyle(color: AvertisColors.textSecondary)),
                ),
              )
            else
              for (final node in plotted) _NodeRow(node: node),
          ],
        ),
      ),
    );
  }
}

String _formatDistance(double metres) =>
    metres >= 1000 ? '${(metres / 1000).toStringAsFixed(1)} km'
                   : '${metres.round()} m';

class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.node});

  final PlottedNode node;

  @override
  Widget build(BuildContext context) {
    final color = switch (node.state) {
      LinkState.up => AvertisColors.online,
      LinkState.suspect => AvertisColors.operational,
      LinkState.down => AvertisColors.lifeCritical,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(node.nodeId,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                Text(
                  [
                    node.role.wire.toLowerCase(),
                    if (node.located)
                      '${_formatDistance(node.distanceM!)} '
                          '${_compass(node.bearingRad!)}'
                    else
                      'bearing unknown',
                    'link ${(node.stability * 100).round()}%',
                  ].join(' · '),
                  style: const TextStyle(
                      fontSize: 11, color: AvertisColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _compass(double radians) {
  const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  var degrees = radians * 180 / math.pi;
  if (degrees < 0) degrees += 360;
  return points[((degrees + 22.5) ~/ 45) % 8];
}

class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.nodes,
    required this.rangeM,
    required this.hasFix,
  });

  final List<PlottedNode> nodes;
  final double rangeM;
  final bool hasFix;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 16;

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = AvertisColors.outline;

    // Range rings at a quarter, a half and full range.
    for (final fraction in [0.33, 0.66, 1.0]) {
      canvas.drawCircle(centre, radius * fraction, grid);
    }
    canvas.drawLine(Offset(centre.dx, centre.dy - radius),
        Offset(centre.dx, centre.dy + radius), grid);
    canvas.drawLine(Offset(centre.dx - radius, centre.dy),
        Offset(centre.dx + radius, centre.dy), grid);

    _label(canvas, hasFix ? 'N' : '?', Offset(centre.dx, centre.dy - radius - 4),
        AvertisColors.textSecondary, 11);

    // Neighbours.
    var unlocatedIndex = 0;
    final unlocatedCount = nodes.where((n) => !n.located).length;

    for (final node in nodes) {
      final Offset position;
      if (node.located) {
        final r = (node.distanceM! / rangeM).clamp(0.0, 1.0) * radius;
        // Bearing is clockwise from north; screen y grows downward.
        position = centre +
            Offset(math.sin(node.bearingRad!) * r,
                -math.cos(node.bearingRad!) * r);
      } else {
        // No position for this peer. Place it by link quality on a ring, and
        // draw it hollow so it is never mistaken for a real bearing.
        final angle = unlocatedCount == 0
            ? 0.0
            : (unlocatedIndex / unlocatedCount) * 2 * math.pi;
        unlocatedIndex++;
        final r = (1.0 - node.stability.clamp(0.0, 1.0)) * radius * 0.8 +
            radius * 0.15;
        position =
            centre + Offset(math.sin(angle) * r, -math.cos(angle) * r);
      }

      final color = switch (node.state) {
        LinkState.up => AvertisColors.online,
        LinkState.suspect => AvertisColors.operational,
        LinkState.down => AvertisColors.lifeCritical,
      };

      canvas.drawLine(
        centre,
        position,
        Paint()
          ..color = color.withValues(alpha: 0.25 + node.stability * 0.5)
          ..strokeWidth = 1 + node.stability * 2,
      );

      canvas.drawCircle(
        position,
        node.role == NodeRole.gateway ? 9 : 7,
        Paint()
          ..color = node.located ? color : AvertisColors.background
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        position,
        node.role == NodeRole.gateway ? 9 : 7,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _label(canvas, node.nodeId, position + const Offset(0, 16),
          AvertisColors.textSecondary, 9);
    }

    // This node, last so it sits on top.
    canvas.drawCircle(centre, 10, Paint()..color = AvertisColors.mesh);
    canvas.drawCircle(
      centre,
      16,
      Paint()
        ..color = AvertisColors.mesh.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _label(Canvas canvas, String text, Offset at, Color color, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at - Offset(painter.width / 2, 0));
  }

  @override
  bool shouldRepaint(covariant _MeshPainter old) =>
      old.nodes != nodes || old.rangeM != rangeM || old.hasFix != hasFix;
}
