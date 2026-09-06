/// The situation view's geometry is the one thing on that screen a responder
/// might act on, so the maths is pinned down rather than eyeballed.
library;

import 'package:avertis/features/map/mesh_map_screen.dart';
import 'package:avertis/mesh/node_state.dart';
import 'package:avertis/mesh/protocol/packet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;

const bengaluru = GeoPoint(12.9716, 77.5946);

double degrees(double radians) {
  var d = radians * 180 / math.pi;
  return d < 0 ? d + 360 : d;
}

void main() {
  group('distance', () {
    test('is zero at the same point', () {
      expect(distanceM(bengaluru, bengaluru), closeTo(0, 0.001));
    });

    test('matches a known separation', () {
      // 0.001 degrees of latitude is ~111.2 m anywhere on Earth.
      const north = GeoPoint(12.9726, 77.5946);
      expect(distanceM(bengaluru, north), closeTo(111.2, 1.0));
    });

    test('is symmetric', () {
      const other = GeoPoint(12.9800, 77.6000);
      expect(distanceM(bengaluru, other),
          closeTo(distanceM(other, bengaluru), 0.001));
    });

    test('is plausible over a city-scale distance', () {
      const other = GeoPoint(13.0716, 77.5946); // 0.1 deg north
      expect(distanceM(bengaluru, other), closeTo(11120, 30));
    });
  });

  group('bearing', () {
    test('due north is 0 degrees', () {
      expect(degrees(bearingRad(bengaluru, const GeoPoint(12.9816, 77.5946))),
          closeTo(0, 0.5));
    });

    test('due east is 90 degrees', () {
      expect(degrees(bearingRad(bengaluru, const GeoPoint(12.9716, 77.6046))),
          closeTo(90, 0.5));
    });

    test('due south is 180 degrees', () {
      expect(degrees(bearingRad(bengaluru, const GeoPoint(12.9616, 77.5946))),
          closeTo(180, 0.5));
    });

    test('due west is 270 degrees', () {
      expect(degrees(bearingRad(bengaluru, const GeoPoint(12.9716, 77.5846))),
          closeTo(270, 0.5));
    });
  });

  group('plotting', () {
    Neighbor neighbor(String id, {GeoPoint? at, double stability = 1.0}) {
      return Neighbor(id)
        ..location = at
        ..stability = stability
        ..role = NodeRole.relay;
    }

    test('a neighbour with a position is located', () {
      final plotted = plotNeighbors(
        [neighbor('node-b', at: const GeoPoint(12.9726, 77.5946))],
        bengaluru,
      );
      expect(plotted.single.located, isTrue);
      expect(plotted.single.distanceM, closeTo(111.2, 1.0));
      expect(degrees(plotted.single.bearingRad!), closeTo(0, 0.5));
    });

    test('a neighbour without a position is kept but not located', () {
      // It must still appear — it is a real, reachable node — but the UI must
      // never imply a bearing it does not have.
      final plotted = plotNeighbors([neighbor('node-c')], bengaluru);
      expect(plotted.single.located, isFalse);
      expect(plotted.single.distanceM, isNull);
      expect(plotted.single.bearingRad, isNull);
    });

    test('nothing is located when this node has no fix', () {
      final plotted = plotNeighbors(
        [neighbor('node-b', at: const GeoPoint(12.9726, 77.5946))],
        null,
      );
      expect(plotted.single.located, isFalse,
          reason: 'a peer position is useless without our own',
      );
    });

    test('link state and battery are carried through unchanged', () {
      final n = neighbor('node-d', stability: 0.42)
        ..battery = 0.31
        ..state = LinkState.suspect;
      final plotted = plotNeighbors([n], bengaluru).single;
      expect(plotted.stability, 0.42);
      expect(plotted.battery, 0.31);
      expect(plotted.state, LinkState.suspect);
    });
  });
}
