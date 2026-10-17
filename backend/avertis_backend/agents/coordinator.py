"""Coordinator Agent — holds the world model and closes the loop.

Plan §23 calls the combined physical + network state "the heart of Avertis",
and §8 makes the loop the innovation: when the network changes, the response
can change. This is where that happens.

The important method is :meth:`ingest_sync`. Every gateway sync carries a new
view of the mesh, and after storing it the coordinator **re-evaluates open
incidents** rather than waiting to be asked. That is the difference between a
system that answers questions and one that notices a relay died and changes
its mind — which is the signature demo (§7).
"""

from __future__ import annotations

from ..llm.base import Reasoner
from ..models import (
    AgentActivity,
    GatewaySyncRequest,
    Incident,
    Recommendation,
    Responder,
)
from ..store.base import Store
from .incident import IncidentAgent
from .network import NetworkAgent, NetworkView
from .response import ResponseAgent
from .safety import SafetyAgent

# A recommendation only changes if the new choice is meaningfully better.
# Without this the recommended responder would flicker between two near-equal
# options on every sync, which reads as instability rather than adaptation.
REPLAN_MARGIN = 0.05


class Coordinator:
    name = "coordinator"

    def __init__(self, reasoner: Reasoner, store: Store) -> None:
        self.reasoner = reasoner
        self.store = store
        self.incidents = IncidentAgent(reasoner, store)
        self.network = NetworkAgent()
        self.response = ResponseAgent(reasoner, store)
        self.safety = SafetyAgent(store)

        # Recommendations live in the store, not in this process: Cloud Run
        # scales to zero, and a decision panel that empties on restart
        # while the incidents remain is worse than useless.

    # -- world model -------------------------------------------------------

    def network_view(self) -> NetworkView:
        return self.network.view(self.store.list_nodes(), self.store.list_links())

    def world(self) -> dict:
        """The combined operational state (plan §23)."""
        incidents = self.store.list_incidents()
        view = self.network_view()
        return {
            "physical": {
                "incidents": [i.model_dump(mode="json") for i in incidents],
                "responders": [
                    r.model_dump(mode="json") for r in self.store.list_responders()
                ],
            },
            "network": {
                **view.summary(),
                "nodes": [n.model_dump(mode="json") for n in self.store.list_nodes()],
                "links": [l.model_dump(mode="json") for l in self.store.list_links()],
                "partition_of": {
                    node_id: view.partition_of(node_id)
                    for node_id in view.nodes
                },
            },
            "recommendations": {
                incident_id: rec.model_dump(mode="json")
                for incident_id, rec in self.store.list_recommendations().items()
            },
            "reasoned_by": self.reasoner.name,
        }

    # -- the loop ----------------------------------------------------------

    def ingest_sync(self, request: GatewaySyncRequest) -> dict:
        """Absorb one gateway sync, then re-plan anything it affected."""
        before = self.network_view()

        # Replace this gateway's whole view rather than merging into it: an
        # absent link means the link is gone, and that is how a dead relay
        # reaches the Response Agent at all.
        self.store.replace_network(
            request.gateway_id, request.nodes, request.links,
            source=request.source,
        )

        # Any responder-role node is a responder we can dispatch. The mesh is
        # the only thing that knows where they currently are.
        for node in request.nodes:
            if node.role.value == "RESPONDER":
                self.store.put_responder(Responder(
                    responder_id=node.node_id,
                    node_id=node.node_id,
                    location=node.location,
                    available=node.reachable,
                ))

        accepted: list[str] = []
        rejected: list[tuple[str, str]] = []
        outcomes: list[tuple[str, str, str | None]] = []

        # One model call per report, run as a batch rather than one after
        # another. Fusion still happens in order below, because whether a
        # report joins an existing incident depends on the ones before it.
        usable = [
            r for r in request.incidents
            if r.location is not None or r.text or r.transcript
        ]
        structures = self.incidents.structure_many(usable)

        for report in request.incidents:
            if report.location is None and not (report.text or report.transcript):
                # Nothing to act on and nowhere to send anyone.
                rejected.append((report.report_id, "EMPTY_REPORT"))
                continue
            incident, fused = self.incidents.ingest(
                report, structured=structures.get(report.report_id)
            )
            accepted.append(report.report_id)
            outcomes.append((
                report.report_id,
                incident.incident_id,
                incident.incident_id if fused else None,
            ))

        after = self.network_view()
        self._note_topology_change(before, after)

        changed = self.replan_all()

        return {
            "accepted": accepted,
            "rejected": rejected,
            "outcomes": outcomes,
            "replanned": changed,
        }

    def _note_topology_change(
        self, before: NetworkView, after: NetworkView
    ) -> None:
        """Record partition changes — the trigger for the signature demo."""
        if not before.nodes:
            return
        if after.partition_count > before.partition_count:
            self.store.append_activity(AgentActivity(
                agent=self.network.name,
                action="PARTITION_DETECTED",
                detail=(
                    f"network split into {after.partition_count} partitions "
                    f"(was {before.partition_count})"
                ),
            ))
        elif after.partition_count < before.partition_count:
            self.store.append_activity(AgentActivity(
                agent=self.network.name,
                action="PARTITION_HEALED",
                detail=(
                    f"network rejoined into {after.partition_count} "
                    f"partition(s) (was {before.partition_count})"
                ),
            ))

    def replan_all(self) -> list[str]:
        """Re-evaluate every open incident. Returns the ones that changed."""
        responders = self.store.list_responders()
        view = self.network_view()
        changed: list[str] = []

        for incident in self.store.list_incidents():
            if incident.status.value == "RESOLVED":
                continue
            if self._replan(incident, responders, view):
                changed.append(incident.incident_id)
        return changed

    def _replan(
        self, incident: Incident, responders: list[Responder], view: NetworkView
    ) -> bool:
        previous = self.store.get_recommendation(incident.incident_id)
        fresh = self.response.recommend(
            incident, responders, view, previous=previous
        )
        fresh = self.safety.review(incident, fresh)

        if previous is None:
            self.store.put_recommendation(fresh)
            return False  # first plan is not a *change*

        same = previous.recommended_responder == fresh.recommended_responder
        if same:
            # Keep the newer assessment figures, but it is not a change.
            self.store.put_recommendation(fresh)
            return False

        # Only switch if the new choice is clearly better, so the
        # recommendation does not oscillate between near-equal options.
        old_score = self._score_of(previous, fresh)
        new_score = (
            self.response.score(fresh.chosen) if fresh.chosen else 0.0
        )
        if new_score < old_score + REPLAN_MARGIN:
            return False

        self.store.put_recommendation(fresh)
        self.store.append_activity(AgentActivity(
            agent=self.name,
            action="RESPONSE_REPLANNED",
            detail=(
                f"{incident.incident_id}: {previous.recommended_responder} → "
                f"{fresh.recommended_responder}. {fresh.why}"
            ),
            incident_id=incident.incident_id,
            reasoned_by=self.reasoner.name,
        ))
        return True

    def _score_of(
        self, previous: Recommendation, fresh: Recommendation
    ) -> float:
        """Score the previously-chosen responder under *current* conditions.

        Comparing against its stale score would make any topology change look
        like an improvement.
        """
        for assessment in fresh.alternatives:
            if assessment.responder_id == previous.recommended_responder:
                return self.response.score(assessment)
        return 0.0  # no longer a candidate at all

    def recommendation_for(self, incident_id: str) -> Recommendation | None:
        return self.store.get_recommendation(incident_id)

    def summary(self) -> tuple[str, str]:
        """Returns (text, written_by)."""
        return self.reasoner.summarize(self.store.list_incidents())
