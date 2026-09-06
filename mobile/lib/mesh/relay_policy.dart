/// Deterministic relay scoring — docs/protocol.md §8.
///
/// The weights live here and only here on this side, and are mirrored in
/// simulator/avertis_sim/node_state.py. They are a transparent baseline, not
/// a learned model and not claimed as novel.
library;

const double wBattery = 0.30;
const double wNeighbors = 0.20;
const double wGatewayProximity = 0.20;
const double wStability = 0.15;
const double wMobility = 0.15;

/// Neighbour counts above this stop earning additional score.
const int neighborSaturation = 8;

/// Above this speed a node is treated as fully mobile (worst mobility score).
const double mobilitySaturationMps = 5.0;

double relayScore({
  required double battery,
  required int neighborCount,
  required int? gatewayDistance,
  required double linkStability,
  required double mobilityMps,
}) {
  final neighbors =
      (neighborCount.clamp(0, neighborSaturation)) / neighborSaturation;
  final gatewayProximity =
      gatewayDistance == null ? 0.0 : 1.0 / (1.0 + gatewayDistance);
  final mobilityScore =
      1.0 - (mobilityMps.clamp(0.0, mobilitySaturationMps)) / mobilitySaturationMps;

  return wBattery * battery +
      wNeighbors * neighbors +
      wGatewayProximity * gatewayProximity +
      wStability * linkStability +
      wMobility * mobilityScore;
}
