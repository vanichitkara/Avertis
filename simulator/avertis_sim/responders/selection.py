"""Network-aware responder selection.

This is the deterministic core of the Avertis signature behaviour (plan §6, §7).

Two important boundaries:

1. **This is not the AI.** My teammate's Response Agent does the contextual
   reasoning and writes the operator-facing WHY. What lives here is the
   measured evidence that agent reasons over — distance, hazard exposure, and
   *actual* network reachability computed from live link state — plus a
   transparent baseline scorer so the loop is demonstrable and benchmarkable
   without the backend. Anything this module reports is measured, never
   invented (plan §20, §25).

2. **Two selectors on purpose.** `DistanceOnlySelector` is the conventional
   approach and the benchmark baseline; `NetworkAwareSelector` is Avertis.
   The demo moment is the two disagreeing after a relay dies.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

from ..protocol import Priority
from ..topology.partition import hop_distance, partition_map, path_reliability


@dataclass
class ResponderAssessment:
    """Everything measured about one responder for one incident."""

    responder_id: str
    node_id: str
    capability: str
    distance_m: float
    eta_s: float
    # Measured from live link stabilities along the best path — not a guess.
    network_reliability: float
    hops: int | None
    reachable: bool
    same_partition: bool
    hazard_exposure: float
    battery: float

    def to_json(self) -> dict[str, Any]:
        return {
            "responder_id": self.responder_id,
            "node_id": self.node_id,
            "capability": self.capability,
            "distance_m": round(self.distance_m, 1),
            "eta_s": round(self.eta_s, 1),
            "network_reliability": round(self.network_reliability, 3),
            "hops": self.hops,
            "reachable": self.reachable,
            "same_partition": self.same_partition,
            "hazard_exposure": round(self.hazard_exposure, 3),
            "battery": round(self.battery, 3),
        }


@dataclass
class Recommendation:
    incident_id: str
    chosen: ResponderAssessment | None
    considered: list[ResponderAssessment] = field(default_factory=list)
    why: str = ""
    selector: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "incident_id": self.incident_id,
            "selector": self.selector,
            "chosen": self.chosen.to_json() if self.chosen else None,
            "considered": [a.to_json() for a in self.considered],
            "why": self.why,
        }


def assess(world: "World", pool: "ResponderPool", incident_node: str
           ) -> list[ResponderAssessment]:
    """Measure every available responder against one incident's node."""
    graph = world.graph()
    pmap = partition_map(graph)
    incident_partition = pmap.get(incident_node, -1)
    inc = world.nodes.get(incident_node)
    out: list[ResponderAssessment] = []

    for responder in pool.available():
        node = world.nodes.get(responder.node_id)
        if node is None or not node.alive or inc is None:
            continue
        distance = math.hypot(node.x - inc.x, node.y - inc.y)
        exposure = pool.hazard_exposure(node.x, node.y, inc.x, inc.y)
        # Hazards slow travel as well as endangering the responder.
        effective_speed = responder.speed_mps * (1.0 - 0.6 * exposure)
        eta = distance / max(effective_speed, 0.4)

        reliability = path_reliability(graph, responder.node_id, incident_node)
        hops = hop_distance(graph, responder.node_id, incident_node)
        partition = pmap.get(responder.node_id, -2)

        out.append(ResponderAssessment(
            responder_id=responder.responder_id,
            node_id=responder.node_id,
            capability=responder.capability,
            distance_m=distance,
            eta_s=eta,
            network_reliability=reliability,
            hops=hops,
            reachable=hops is not None,
            same_partition=partition == incident_partition,
            hazard_exposure=exposure,
            battery=node.battery,
        ))
    return out


class DistanceOnlySelector:
    """The conventional approach: send whoever is closest.

    This is the benchmark baseline (plan §33), not a straw man — it is what
    most dispatch systems actually do.
    """

    name = "distance_only"

    def select(self, incident_id: str,
               assessments: list[ResponderAssessment]) -> Recommendation:
        if not assessments:
            return Recommendation(incident_id, None, [], "No responder available.",
                                  self.name)
        chosen = min(assessments, key=lambda a: (a.distance_m, a.responder_id))
        return Recommendation(
            incident_id, chosen, assessments,
            f"{chosen.responder_id} is the closest responder "
            f"({chosen.distance_m / 1000:.1f} km).",
            self.name,
        )


class NetworkAwareSelector:
    """Avertis: physical access *and* communication reachability.

    The weights are deliberately explicit and few — this is a transparent
    decision rule, not a learned model, and the demo depends on being able to
    explain exactly why the answer changed.
    """

    name = "network_aware"

    # A responder who cannot be communicated with at all is not simply a
    # lower score — coordinating a rescue blind is a different kind of risk.
    UNREACHABLE_PENALTY = 0.55
    RELIABILITY_FLOOR = 0.25

    def __init__(self, w_eta: float = 0.40, w_network: float = 0.35,
                 w_hazard: float = 0.25):
        total = w_eta + w_network + w_hazard
        self.w_eta = w_eta / total
        self.w_network = w_network / total
        self.w_hazard = w_hazard / total

    def score(self, a: ResponderAssessment, worst_eta: float) -> float:
        eta_score = 1.0 - (a.eta_s / worst_eta if worst_eta > 0 else 0.0)
        network_score = a.network_reliability
        hazard_score = 1.0 - a.hazard_exposure
        score = (self.w_eta * eta_score
                 + self.w_network * network_score
                 + self.w_hazard * hazard_score)
        if not a.reachable:
            score -= self.UNREACHABLE_PENALTY
        return score

    def select(self, incident_id: str,
               assessments: list[ResponderAssessment]) -> Recommendation:
        if not assessments:
            return Recommendation(incident_id, None, [],
                                  "No responder available.", self.name)
        worst_eta = max(a.eta_s for a in assessments) or 1.0
        ranked = sorted(
            assessments,
            key=lambda a: (-self.score(a, worst_eta), a.responder_id),
        )
        chosen = ranked[0]
        return Recommendation(incident_id, chosen, ranked,
                              self.explain(chosen, ranked), self.name)

    def explain(self, chosen: ResponderAssessment,
                ranked: list[ResponderAssessment]) -> str:
        """Build the WHY from measured state only (plan §25).

        Every number quoted here came from the live link graph or the world
        geometry. Nothing is fabricated for narrative effect.
        """
        parts = [
            f"{chosen.responder_id} recommended: "
            f"{chosen.distance_m / 1000:.1f} km out, "
            f"{chosen.network_reliability:.0%} measured network reliability "
            f"to the incident"
        ]
        if chosen.hops is not None:
            parts[0] += f" over {chosen.hops} mesh hop{'s' if chosen.hops != 1 else ''}"
        parts[0] += f", hazard exposure {_band(chosen.hazard_exposure)}."

        # The interesting case: somebody closer was passed over.
        closer = [a for a in ranked[1:] if a.distance_m < chosen.distance_m]
        if closer:
            other = min(closer, key=lambda a: a.distance_m)
            if not other.reachable:
                parts.append(
                    f"{other.responder_id} is closer "
                    f"({other.distance_m / 1000:.1f} km) but is currently in a "
                    f"separate network partition and cannot be reached through "
                    f"the mesh."
                )
            elif other.network_reliability < self.RELIABILITY_FLOOR:
                parts.append(
                    f"{other.responder_id} is closer "
                    f"({other.distance_m / 1000:.1f} km) but its communication "
                    f"path to the incident is unreliable "
                    f"({other.network_reliability:.0%})."
                )
            elif other.hazard_exposure > chosen.hazard_exposure + 0.15:
                parts.append(
                    f"{other.responder_id} is closer "
                    f"({other.distance_m / 1000:.1f} km) but its route has "
                    f"higher hazard exposure "
                    f"({_band(other.hazard_exposure)})."
                )
            else:
                parts.append(
                    f"{other.responder_id} is closer "
                    f"({other.distance_m / 1000:.1f} km) but scores lower "
                    f"overall once communication reliability "
                    f"({other.network_reliability:.0%}) and hazard exposure "
                    f"are included."
                )
        return " ".join(parts)


def _band(exposure: float) -> str:
    if exposure < 0.10:
        return "LOW"
    if exposure < 0.35:
        return "MEDIUM"
    return "HIGH"
