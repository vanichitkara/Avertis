"""Incident structuring and fusion.

Fusion is the part with real consequences in both directions: failing to
merge buries one incident under twenty duplicates, and over-merging hides a
separate emergency entirely. Both failures are tested here.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from avertis_backend.agents.incident import IncidentAgent
from avertis_backend.llm.deterministic import (
    DeterministicReasoner,
    classify_severity,
    classify_type,
    extract_people_count,
)
from avertis_backend.models import GeoPoint, IncidentType, Priority, RawReport
from avertis_backend.store.memory import MemoryStore

BRIDGE = GeoPoint(lat=12.9716, lon=77.5946)
FAR = GeoPoint(lat=13.0716, lon=77.5946)  # ~11 km north
T0 = datetime(2026, 9, 6, 12, 0, tzinfo=timezone.utc)


def report(
    rid: str, text: str, *, node="node-01", at=None, loc=BRIDGE,
    priority=Priority.NORMAL, kind="REPORT",
) -> RawReport:
    return RawReport(
        report_id=rid,
        origin_node=node,
        created_at=at or T0,
        priority=priority,
        kind=kind,
        location=loc,
        text=text,
    )


@pytest.fixture
def agent() -> IncidentAgent:
    return IncidentAgent(DeterministicReasoner(), MemoryStore())


# -- extraction --------------------------------------------------------------


class TestExtraction:
    @pytest.mark.parametrize("text,expected", [
        ("3 people trapped near the bridge", 3),
        ("three people trapped", 3),
        ("twelve survivors on the roof", 12),
        ("a family is stuck inside", 1),
        ("2 children and help needed", 2),
    ])
    def test_counts_that_are_stated(self, text, expected):
        assert extract_people_count(text) == expected

    @pytest.mark.parametrize("text", [
        "people are trapped",
        "someone needs help",
        "the bridge collapsed",
        "",
    ])
    def test_counts_that_are_not_stated_stay_unknown(self, text):
        # An invented count changes how many rescuers are sent. Unknown must
        # stay unknown.
        assert extract_people_count(text) is None

    @pytest.mark.parametrize("text,expected", [
        ("water is rising fast", IncidentType.FLOOD_RESCUE),
        ("the building collapsed", IncidentType.STRUCTURAL_COLLAPSE),
        ("there is smoke and fire", IncidentType.FIRE),
        ("my father is bleeding", IncidentType.MEDICAL),
        ("I am pinned under a beam", IncidentType.TRAPPED_PERSON),
        ("the power is out", IncidentType.INFRASTRUCTURE),
        ("hello there", IncidentType.UNKNOWN),
    ])
    def test_classification(self, text, expected):
        assert classify_type(text) == expected

    def test_severity_never_drops_below_what_the_reporter_chose(self):
        # A survivor knows more about their situation than a keyword list.
        assert classify_severity(
            "everything is calm here", Priority.LIFE_CRITICAL
        ) == Priority.LIFE_CRITICAL

    def test_severity_can_be_raised_by_the_words(self):
        assert classify_severity(
            "someone is not breathing", Priority.NORMAL
        ) == Priority.LIFE_CRITICAL


# -- structuring -------------------------------------------------------------


class TestStructuring:
    def test_a_report_becomes_an_incident(self, agent):
        incident, fused = agent.ingest(
            report("rpt-1", "three people trapped near the flooded bridge")
        )
        assert not fused
        assert incident.type == IncidentType.FLOOD_RESCUE
        assert incident.people_affected == 3
        assert incident.source_count == 1
        assert incident.incident_id.startswith("INC-")

    def test_a_wordless_sos_is_still_life_critical(self, agent):
        incident, _ = agent.ingest(
            RawReport(
                report_id="rpt-sos",
                origin_node="node-09",
                created_at=T0,
                kind="SOS",
                priority=Priority.LIFE_CRITICAL,
                location=BRIDGE,
            )
        )
        # The button was pressed. That is the evidence.
        assert incident.severity == Priority.LIFE_CRITICAL
        # But we should not be confident about *what* is happening.
        assert incident.confidence <= 0.5

    def test_confidence_reflects_evidence_not_drama(self, agent):
        vague, _ = agent.ingest(
            RawReport(report_id="rpt-v", origin_node="n1", created_at=T0,
                      text="help", location=None)
        )
        detailed, _ = agent.ingest(
            report("rpt-d", "three people trapped on the roof of the flooded "
                            "school building on the east side")
        )
        assert detailed.confidence > vague.confidence

    def test_the_same_report_twice_is_idempotent(self, agent):
        first, _ = agent.ingest(report("rpt-1", "flooded bridge, people trapped"))
        second, fused = agent.ingest(report("rpt-1", "flooded bridge, people trapped"))

        # Custody retransmission means this happens routinely.
        assert fused
        assert second.incident_id == first.incident_id
        assert second.source_count == 1, "re-sync must not duplicate evidence"


# -- fusion ------------------------------------------------------------------


class TestFusion:
    def test_the_plan_example_fuses_into_one_incident(self, agent):
        """Plan §20: four reports of one bridge collapse become one incident."""
        agent.ingest(report("rpt-a", "3 people trapped near bridge",
                            node="node-01"))
        agent.ingest(report("rpt-b", "people trapped after bridge collapsed",
                            node="node-02", at=T0 + timedelta(minutes=2)))
        agent.ingest(report("rpt-c", "bridge area flooded, 3 people need help",
                            node="node-03", at=T0 + timedelta(minutes=5)))

        incidents = agent.store.list_incidents()
        assert len(incidents) == 1, "one event should be one incident"

        incident = incidents[0]
        assert incident.source_count == 3
        assert incident.people_affected == 3

    def test_corroboration_raises_confidence(self, agent):
        first, _ = agent.ingest(report("rpt-a", "bridge collapsed, people trapped",
                                       node="node-01"))
        alone = first.confidence

        agent.ingest(report("rpt-b", "bridge collapsed, people trapped",
                            node="node-02", at=T0 + timedelta(minutes=1)))
        corroborated = agent.store.list_incidents()[0].confidence

        assert corroborated > alone
        # Corroboration must never reach certainty.
        assert corroborated <= 0.95

    def test_repeats_from_one_node_do_not_inflate_confidence(self, agent):
        agent.ingest(report("rpt-a", "bridge collapsed people trapped",
                            node="node-01"))
        one_source = agent.store.list_incidents()[0].confidence

        agent.ingest(report("rpt-b", "bridge collapsed people trapped",
                            node="node-01", at=T0 + timedelta(minutes=1)))
        still_one_source = agent.store.list_incidents()[0].confidence

        # Same person saying it twice is not independent corroboration.
        assert still_one_source == one_source

    def test_distant_events_do_not_merge(self, agent):
        agent.ingest(report("rpt-a", "building collapsed, people trapped",
                            loc=BRIDGE))
        agent.ingest(report("rpt-b", "building collapsed, people trapped",
                            loc=FAR, node="node-07"))

        # Two collapses 11 km apart are two emergencies. Merging would hide
        # one of them entirely.
        assert len(agent.store.list_incidents()) == 2

    def test_events_far_apart_in_time_do_not_merge(self, agent):
        agent.ingest(report("rpt-a", "fire in the market"))
        agent.ingest(report("rpt-b", "fire in the market",
                            node="node-02", at=T0 + timedelta(hours=4)))
        assert len(agent.store.list_incidents()) == 2

    def test_different_situations_in_one_place_do_not_merge(self, agent):
        agent.ingest(report("rpt-a", "the power lines are down on this street"))
        agent.ingest(report("rpt-b", "my neighbour is bleeding badly",
                            node="node-02", at=T0 + timedelta(minutes=1)))

        # Same street, same minute, entirely different emergencies.
        assert len(agent.store.list_incidents()) == 2

    def test_severity_rises_on_worse_news_and_does_not_fall_back(self, agent):
        agent.ingest(report("rpt-a", "the street is flooded"))
        agent.ingest(report("rpt-b", "someone is drowning in the flooded street",
                            node="node-02", at=T0 + timedelta(minutes=1)))

        incident = agent.store.list_incidents()[0]
        assert incident.severity == Priority.LIFE_CRITICAL

        agent.ingest(report("rpt-c", "the flooded street is still flooded",
                            node="node-03", at=T0 + timedelta(minutes=2)))
        # A calmer later report must not downgrade a known life-critical event.
        assert agent.store.list_incidents()[0].severity == Priority.LIFE_CRITICAL

    def test_headcount_takes_the_larger_estimate(self, agent):
        agent.ingest(report("rpt-a", "2 people trapped in the collapsed building"))
        agent.ingest(report("rpt-b", "5 people trapped in the collapsed building",
                            node="node-02", at=T0 + timedelta(minutes=1)))

        # Under-dispatching is the more dangerous error.
        assert agent.store.list_incidents()[0].people_affected == 5


# -- ordering ----------------------------------------------------------------


def test_sync_order_is_critical_first_then_oldest(agent):
    agent.ingest(report("rpt-normal", "the power is out", at=T0))
    agent.ingest(report("rpt-critical", "someone is not breathing",
                        node="node-09", loc=FAR, at=T0 + timedelta(minutes=10)))

    ordered = IncidentAgent.sync_order(agent.store.list_incidents())
    assert ordered[0].severity == Priority.LIFE_CRITICAL
