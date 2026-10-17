"""The signature feature: the network is part of the response decision.

Plan §6 and §7. The test that matters is `test_killing_a_relay_changes_the
_recommendation`: it reproduces the demo's signature moment end to end,
through the real gateway endpoint, and asserts the chosen responder actually
changes — and that it changes *because* of the network, not the geography,
which is unchanged throughout.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from avertis_backend.agents.coordinator import Coordinator
from avertis_backend.agents.network import NetworkView
from avertis_backend.agents.response import ResponseAgent
from avertis_backend.llm.deterministic import DeterministicReasoner
from avertis_backend.models import (
    GatewaySyncRequest,
    GeoPoint,
    LinkSnapshot,
    NodeSnapshot,
    NodeRole,
    Priority,
    RawReport,
)
from avertis_backend.store.memory import MemoryStore

T0 = datetime(2026, 9, 6, 12, 0, tzinfo=timezone.utc)

# Geography, fixed for every test below. A is nearer the incident than B, and
# stays nearer. Only the network changes.
INCIDENT_AT = GeoPoint(lat=12.9716, lon=77.5946)
RESPONDER_A_AT = GeoPoint(lat=12.9900, lon=77.5946)   # ~2.0 km north
RESPONDER_B_AT = GeoPoint(lat=13.0060, lon=77.5946)   # ~3.8 km north


def node(nid, role=NodeRole.SURVIVOR, loc=None, reachable=True) -> NodeSnapshot:
    return NodeSnapshot(
        node_id=nid, role=role, location=loc, reachable=reachable, battery=0.8
    )


@pytest.fixture
def coordinator() -> Coordinator:
    return Coordinator(DeterministicReasoner(), MemoryStore())


# -- the network view --------------------------------------------------------


class TestNetworkView:
    def test_reliability_compounds_along_a_path(self):
        """Five 0.9 hops are 0.59, not 0.9 — this is why hop count matters."""
        nodes = [node(f"n{i}") for i in range(6)]
        links = [
            LinkSnapshot(a=f"n{i}", b=f"n{i + 1}", stability=0.9)
            for i in range(5)
        ]
        view = NetworkView(nodes, links)
        _, reliability = view.best_path("n0", "n5")
        assert reliability == pytest.approx(0.9 ** 5, abs=0.001)

    def test_the_most_reliable_path_wins_not_the_shortest(self):
        nodes = [node(n) for n in ("a", "b", "c", "d")]
        links = [
            LinkSnapshot(a="a", b="d", stability=0.3),   # one weak hop
            LinkSnapshot(a="a", b="b", stability=0.95),  # three strong hops
            LinkSnapshot(a="b", b="c", stability=0.95),
            LinkSnapshot(a="c", b="d", stability=0.95),
        ]
        view = NetworkView(nodes, links)
        path, reliability = view.best_path("a", "d")
        assert path == ["a", "b", "c", "d"]
        assert reliability > 0.3

    def test_a_severed_network_has_two_partitions(self):
        nodes = [node(n) for n in ("a", "b", "c", "d")]
        links = [
            LinkSnapshot(a="a", b="b", stability=0.9),
            LinkSnapshot(a="c", b="d", stability=0.9),
        ]
        view = NetworkView(nodes, links)
        assert view.partition_count == 2
        assert not view.same_partition("a", "c")
        assert view.reliability_between("a", "c") == 0.0

    def test_an_unusably_weak_link_does_not_join_partitions(self):
        nodes = [node("a"), node("b")]
        links = [LinkSnapshot(a="a", b="b", stability=0.05)]
        view = NetworkView(nodes, links)
        # The link exists but cannot be depended on for a rescue.
        assert view.partition_count == 2


# -- scoring -----------------------------------------------------------------


class TestScoring:
    def test_an_unreachable_responder_scores_below_a_reachable_one(self):
        agent = ResponseAgent(DeterministicReasoner(), MemoryStore())
        from avertis_backend.models import ResponderAssessment

        near_but_cut_off = ResponderAssessment(
            responder_id="A", distance_m=2100, network_reliability=0.05,
            reachable=False, hazard_exposure="LOW",
        )
        further_but_connected = ResponderAssessment(
            responder_id="B", distance_m=3800, network_reliability=0.91,
            reachable=True, hazard_exposure="LOW",
        )
        assert agent.score(further_but_connected) > agent.score(near_but_cut_off)

    def test_when_both_are_reachable_the_closer_one_wins(self):
        agent = ResponseAgent(DeterministicReasoner(), MemoryStore())
        from avertis_backend.models import ResponderAssessment

        near = ResponderAssessment(
            responder_id="A", distance_m=2100, network_reliability=0.90,
            reachable=True, hazard_exposure="LOW",
        )
        far = ResponderAssessment(
            responder_id="B", distance_m=3800, network_reliability=0.91,
            reachable=True, hazard_exposure="LOW",
        )
        # Network-awareness must not mean ignoring geography on a healthy mesh.
        assert agent.score(near) > agent.score(far)


# -- the signature loop ------------------------------------------------------


def _healthy_mesh() -> GatewaySyncRequest:
    """A→relay→incident and B→relay→incident, both well connected."""
    return GatewaySyncRequest(
        gateway_id="gw-01",
        connectivity_window_seconds=18,
        nodes=[
            node("node-victim", loc=INCIDENT_AT),
            node("relay-R7"),
            node("relay-R9"),
            node("resp-A", NodeRole.RESPONDER, RESPONDER_A_AT),
            node("resp-B", NodeRole.RESPONDER, RESPONDER_B_AT),
        ],
        links=[
            LinkSnapshot(a="node-victim", b="relay-R7", stability=0.95),
            LinkSnapshot(a="relay-R7", b="resp-A", stability=0.95),
            LinkSnapshot(a="node-victim", b="relay-R9", stability=0.92),
            LinkSnapshot(a="relay-R9", b="resp-B", stability=0.92),
        ],
        incidents=[
            RawReport(
                report_id="rpt-142",
                origin_node="node-victim",
                created_at=T0,
                priority=Priority.LIFE_CRITICAL,
                kind="SOS",
                location=INCIDENT_AT,
                text="three people trapped near the flooded bridge",
            )
        ],
    )


def _mesh_without_r7() -> GatewaySyncRequest:
    """R7 is gone, so responder A is cut off. Geography is unchanged."""
    return GatewaySyncRequest(
        gateway_id="gw-01",
        connectivity_window_seconds=18,
        nodes=[
            node("node-victim", loc=INCIDENT_AT),
            node("relay-R7", reachable=False),
            node("relay-R9"),
            node("resp-A", NodeRole.RESPONDER, RESPONDER_A_AT),
            node("resp-B", NodeRole.RESPONDER, RESPONDER_B_AT),
        ],
        links=[
            # The R7 links are gone entirely.
            LinkSnapshot(a="node-victim", b="relay-R9", stability=0.92),
            LinkSnapshot(a="relay-R9", b="resp-B", stability=0.92),
        ],
        incidents=[],
    )


class TestSignatureLoop:
    def test_a_healthy_mesh_picks_the_closer_responder(self, coordinator):
        coordinator.ingest_sync(_healthy_mesh())
        incident = coordinator.store.list_incidents()[0]
        rec = coordinator.recommendation_for(incident.incident_id)

        assert rec is not None
        assert rec.recommended_responder == "resp-A", (
            "with both reachable, the closer responder should win"
        )

    def test_killing_a_relay_changes_the_recommendation(self, coordinator):
        """Plan §7, the signature moment, end to end."""
        coordinator.ingest_sync(_healthy_mesh())
        incident = coordinator.store.list_incidents()[0]
        before = coordinator.recommendation_for(incident.incident_id)
        assert before.recommended_responder == "resp-A"

        # Kill R7. Nothing physical changes: A is still the closer responder.
        result = coordinator.ingest_sync(_mesh_without_r7())

        after = coordinator.recommendation_for(incident.incident_id)
        assert after.recommended_responder == "resp-B", (
            "losing the relay should move the recommendation to the reachable "
            "responder"
        )
        assert incident.incident_id in result["replanned"]

        # And it changed for the right reason: A is still nearer.
        a_after = next(
            x for x in after.alternatives if x.responder_id == "resp-A"
        )
        b_after = next(
            x for x in after.alternatives if x.responder_id == "resp-B"
        )
        assert a_after.distance_m < b_after.distance_m
        assert not a_after.reachable
        assert b_after.reachable

    def test_the_change_is_recorded_in_the_activity_feed(self, coordinator):
        coordinator.ingest_sync(_healthy_mesh())
        coordinator.ingest_sync(_mesh_without_r7())

        actions = [a.action for a in coordinator.store.list_activity(50)]
        assert "RESPONSE_REPLANNED" in actions, (
            "an operator must be able to see that the plan changed"
        )

    def test_the_why_names_the_real_reason(self, coordinator):
        coordinator.ingest_sync(_healthy_mesh())
        coordinator.ingest_sync(_mesh_without_r7())
        incident = coordinator.store.list_incidents()[0]
        why = coordinator.recommendation_for(incident.incident_id).why

        # Grounded in actual state: it should mention the closer responder and
        # its reliability, not generic prose.
        assert "resp-A" in why
        assert "%" in why

    def test_a_stable_network_does_not_cause_churn(self, coordinator):
        coordinator.ingest_sync(_healthy_mesh())
        first = coordinator.recommendation_for(
            coordinator.store.list_incidents()[0].incident_id
        ).recommended_responder

        for _ in range(3):
            changed = coordinator.ingest_sync(_healthy_mesh())["replanned"]
            assert changed == [], "an unchanged network must not re-plan"

        still = coordinator.recommendation_for(
            coordinator.store.list_incidents()[0].incident_id
        ).recommended_responder
        assert still == first


# -- safety ------------------------------------------------------------------


class TestSafety:
    def test_every_recommendation_needs_human_approval(self, coordinator):
        coordinator.ingest_sync(_healthy_mesh())
        incident = coordinator.store.list_incidents()[0]
        rec = coordinator.recommendation_for(incident.incident_id)
        # Plan §39: Gemini recommends, a human dispatches.
        assert rec.requires_human_approval

    def test_a_single_source_incident_is_flagged(self, coordinator):
        coordinator.ingest_sync(_healthy_mesh())
        incident = coordinator.store.list_incidents()[0]
        rec = coordinator.recommendation_for(incident.incident_id)
        assert "SINGLE_SOURCE" in rec.safety_flags

    def test_an_unreachable_recommendation_is_flagged(self, coordinator):
        coordinator.ingest_sync(_healthy_mesh())
        # Sever everything: no responder can be reached at all.
        coordinator.ingest_sync(GatewaySyncRequest(
            gateway_id="gw-01",
            nodes=[
                node("node-victim", loc=INCIDENT_AT),
                node("resp-A", NodeRole.RESPONDER, RESPONDER_A_AT),
            ],
            links=[],
        ))
        incident = coordinator.store.list_incidents()[0]
        rec = coordinator.recommendation_for(incident.incident_id)
        assert "RECOMMENDED_RESPONDER_UNREACHABLE" in rec.safety_flags


def test_the_links_key_means_the_same_thing_everywhere(coordinator):
    """One key, one type.

    /api/v1/world puts the link list under "links". The summary used to put a
    count there too, so the same path meant an int on one endpoint and a list
    on another — and whichever a consumer assumed, it would be right half the
    time.
    """
    coordinator.ingest_sync(_healthy_mesh())

    summary = coordinator.network_view().summary()
    assert isinstance(summary["link_count"], int)
    assert "links" not in summary

    world = coordinator.world()
    assert isinstance(world["network"]["links"], list)
    assert world["network"]["link_count"] == len(world["network"]["links"])


class TestExplanationReuse:
    """The WHY is not regenerated when it would say the same thing.

    Every sync re-plans every open incident, and with a model behind the
    explanation that was one API call per incident per sync — a continuous
    spend, and latency inside a connectivity window, for text that had not
    changed.
    """

    class CountingReasoner(DeterministicReasoner):
        def __init__(self):
            super().__init__()
            self.explanations = 0

        def explain_choice(self, incident, chosen, alternatives):
            self.explanations += 1
            return super().explain_choice(incident, chosen, alternatives)

    def test_an_unchanged_plan_does_not_re_explain(self):
        reasoner = self.CountingReasoner()
        c = Coordinator(reasoner, MemoryStore())

        c.ingest_sync(_healthy_mesh())
        after_first = reasoner.explanations
        assert after_first >= 1

        for _ in range(3):
            c.ingest_sync(_healthy_mesh())

        assert reasoner.explanations == after_first, (
            "an unchanged recommendation should reuse its explanation"
        )

    def test_a_changed_plan_gets_a_fresh_explanation(self):
        reasoner = self.CountingReasoner()
        c = Coordinator(reasoner, MemoryStore())

        c.ingest_sync(_healthy_mesh())
        before = reasoner.explanations

        c.ingest_sync(_mesh_without_r7())

        assert reasoner.explanations > before, (
            "the responder changed, so the WHY must be rewritten"
        )
        incident = c.store.list_incidents()[0]
        assert "resp-B" in c.recommendation_for(incident.incident_id).why

    def test_a_material_change_in_reachability_re_explains(self):
        from avertis_backend.agents.response import _materially_same
        from avertis_backend.models import ResponderAssessment

        before = ResponderAssessment(responder_id="A", distance_m=200,
                                     network_reliability=0.95, reachable=True)
        # A percentage point of drift is not worth a model call.
        drift = ResponderAssessment(responder_id="A", distance_m=205,
                                    network_reliability=0.94, reachable=True)
        assert _materially_same(before, drift)

        # Losing reachability is.
        lost = ResponderAssessment(responder_id="A", distance_m=200,
                                   network_reliability=0.05, reachable=False)
        assert not _materially_same(before, lost)
