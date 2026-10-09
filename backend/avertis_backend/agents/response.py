"""Response Agent — the signature feature.

Plan §6, §24: choose a responder and a route using both the physical world
*and* the communication network. A responder who is closer but cannot be
reached is a worse choice than one slightly further away on a stable path,
because a rescue nobody can coordinate is not a rescue.

The decision is deterministic and inspectable. The model's job is to explain
it in human language (§25), not to make it — an LLM picking rescuers from
prose would be unauditable, and would change its mind between identical
states, which is exactly what plan §7 needs *not* to happen.
"""

from __future__ import annotations

from ..llm.base import Reasoner
from ..llm.deterministic import haversine_m
from ..models import (
    AgentActivity,
    Incident,
    Recommendation,
    Responder,
    ResponderAssessment,
)
from ..store.base import Store
from .network import NetworkView

# How far a responder can be before distance starts to dominate. Beyond this,
# travel time outweighs communication quality.
DISTANCE_SATURATION_M = 8000.0

# Weights for the final score. Reachability is weighted hardest because an
# unreachable responder cannot be coordinated at all — that is the project's
# entire thesis, made explicit as a number.
W_REACHABILITY = 0.45
W_DISTANCE = 0.35
W_HAZARD = 0.20

# Below this, a responder is treated as effectively unreachable.
MIN_USABLE_RELIABILITY = 0.25


class ResponseAgent:
    name = "response"

    def __init__(self, reasoner: Reasoner, store: Store) -> None:
        self.reasoner = reasoner
        self.store = store

    def assess(
        self,
        incident: Incident,
        responder: Responder,
        network: NetworkView,
        hazard_lookup=None,
    ) -> ResponderAssessment:
        """What is actually known about sending this responder to this incident."""
        distance = None
        if incident.location and responder.location:
            distance = haversine_m(
                responder.location.lat, responder.location.lon,
                incident.location.lat, incident.location.lon,
            )

        # Reliability is measured between the responder's node and the node
        # that reported the incident — the two ends that have to stay in
        # contact during the rescue.
        reliability = 0.0
        same_partition = False
        incident_node = self._incident_node(incident)
        if responder.node_id and incident_node:
            reliability = network.reliability_between(
                responder.node_id, incident_node
            )
            same_partition = network.same_partition(
                responder.node_id, incident_node
            )

        hazard = "UNKNOWN"
        if hazard_lookup is not None and incident.location and responder.location:
            hazard = hazard_lookup(responder.location, incident.location)

        return ResponderAssessment(
            responder_id=responder.responder_id,
            distance_m=round(distance, 1) if distance is not None else None,
            network_reliability=reliability,
            reachable=reliability >= MIN_USABLE_RELIABILITY,
            hazard_exposure=hazard,
            same_partition=same_partition,
        )

    @staticmethod
    def _incident_node(incident: Incident) -> str | None:
        """The node that first reported this incident."""
        if not incident.evidence:
            return None
        return min(incident.evidence, key=lambda e: e.created_at).origin_node

    @staticmethod
    def score(assessment: ResponderAssessment) -> float:
        """Combine physical access and communication reachability."""
        if assessment.distance_m is None:
            distance_score = 0.3  # unknown position: not disqualifying, not good
        else:
            distance_score = 1.0 - min(
                assessment.distance_m, DISTANCE_SATURATION_M
            ) / DISTANCE_SATURATION_M

        hazard_score = {
            "LOW": 1.0, "MEDIUM": 0.6, "HIGH": 0.2, "UNKNOWN": 0.7
        }.get(assessment.hazard_exposure, 0.7)

        return round(
            W_REACHABILITY * assessment.network_reliability
            + W_DISTANCE * distance_score
            + W_HAZARD * hazard_score,
            4,
        )

    def recommend(
        self,
        incident: Incident,
        responders: list[Responder],
        network: NetworkView,
        hazard_lookup=None,
    ) -> Recommendation:
        available = [r for r in responders if r.available]
        if not available:
            return Recommendation(
                incident_id=incident.incident_id,
                why="No responder is available.",
                requires_human_approval=True,
                safety_flags=["NO_RESPONDER_AVAILABLE"],
                reasoned_by=self.reasoner.name,
            )

        assessments = [
            self.assess(incident, r, network, hazard_lookup) for r in available
        ]
        ranked = sorted(assessments, key=self.score, reverse=True)
        chosen = ranked[0]

        why = self.reasoner.explain_choice(incident, chosen, ranked)

        recommendation = Recommendation(
            incident_id=incident.incident_id,
            recommended_responder=chosen.responder_id,
            alternatives=ranked,
            chosen=chosen,
            why=why,
            requires_human_approval=True,
            reasoned_by=self.reasoner.name,
        )

        self.store.append_activity(AgentActivity(
            agent=self.name,
            action="RECOMMENDATION",
            detail=(
                f"{chosen.responder_id} for {incident.incident_id} "
                f"({chosen.network_reliability:.0%} reliability"
                + (f", {chosen.distance_m:.0f} m" if chosen.distance_m else "")
                + ")"
            ),
            incident_id=incident.incident_id,
            reasoned_by=self.reasoner.name,
        ))
        return recommendation
