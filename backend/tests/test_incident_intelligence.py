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
import itertools

from avertis_backend.models import (
    GeoPoint,
    Incident,
    IncidentType,
    Priority,
    RawReport,
)
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


class TestStatedHeadcount:
    """A count the sender gave us outright must never be thrown away.

    The SOS screen asks "how many people need help?" and the protocol carries
    the answer (§5). Losing it means dispatching for an unknown number when we
    were told the number — the opposite failure to inventing one, and just as
    consequential.
    """

    def test_a_wordless_sos_keeps_its_stated_count(self, agent):
        incident, _ = agent.ingest(RawReport(
            report_id="rpt-sos",
            origin_node="node-09",
            created_at=T0,
            kind="SOS",
            priority=Priority.LIFE_CRITICAL,
            location=BRIDGE,
            people_count=3,
        ))
        assert incident.people_affected == 3

    def test_a_stated_count_beats_one_inferred_from_wording(self, agent):
        incident, _ = agent.ingest(RawReport(
            report_id="rpt-1",
            origin_node="node-01",
            created_at=T0,
            kind="SOS",
            location=BRIDGE,
            text="a family is trapped on the roof",   # would infer 1
            people_count=5,                            # but they told us 5
        ))
        assert incident.people_affected == 5

    def test_no_stated_count_still_falls_back_to_the_text(self, agent):
        incident, _ = agent.ingest(
            report("rpt-2", "three people trapped near the bridge")
        )
        assert incident.people_affected == 3

    def test_being_told_a_count_raises_confidence(self, agent):
        without, _ = agent.ingest(RawReport(
            report_id="rpt-a", origin_node="n1", created_at=T0,
            kind="SOS", priority=Priority.LIFE_CRITICAL, location=BRIDGE,
        ))
        with_count, _ = agent.ingest(RawReport(
            report_id="rpt-b", origin_node="n2", created_at=T0,
            kind="SOS", priority=Priority.LIFE_CRITICAL, location=FAR,
            people_count=4,
        ))
        assert with_count.confidence > without.confidence


class TestUnresponsivePhrasing:
    @pytest.mark.parametrize("text", [
        "three people in the water, one is not moving",
        "my neighbour is unresponsive",
        "he is not responding",
        "she won't wake up",
    ])
    def test_describing_someone_unresponsive_is_life_critical(self, agent, text):
        # Found by comparing the rules against a live Gemini call: the model
        # rated these life-critical and the rules rated them NORMAL. The
        # rules are the default engine, so that gap mattered.
        incident, _ = agent.ingest(report("rpt-x", text))
        assert incident.severity == Priority.LIFE_CRITICAL


class TestIdAllocation:
    """Ids must not be reissued when the store outlives the process.

    With the in-memory store a restart cleared everything, so a counter
    starting from a fixed number was safe. Persistence removed that safety:
    the second run reissued INC-1042 and silently overwrote a life-critical
    incident with an unrelated one.
    """

    def test_ids_continue_from_what_is_already_stored(self):
        store = MemoryStore()
        first = IncidentAgent(DeterministicReasoner(), store)
        first.ingest(report("rpt-1", "flooded bridge, people trapped"))
        first.ingest(report("rpt-2", "fire in the market", loc=FAR,
                            node="node-02"))
        existing = {i.incident_id for i in store.list_incidents()}

        # A new agent over the same store — the restart case.
        restarted = IncidentAgent(DeterministicReasoner(), store)
        restarted.ingest(report("rpt-3", "collapsed wall on the highway",
                                loc=GeoPoint(lat=14.0, lon=78.0), node="node-03"))

        new_ids = {i.incident_id for i in store.list_incidents()} - existing
        assert len(new_ids) == 1
        assert not (new_ids & existing), "an id was reissued"
        assert len(store.list_incidents()) == 3, "an incident was overwritten"

    def test_the_first_incident_is_numbered_one(self):
        # Not 1042. A first incident numbered in the thousands claims a
        # history the system does not have.
        agent = IncidentAgent(DeterministicReasoner(), MemoryStore())
        incident, _ = agent.ingest(report("rpt-1", "flooded bridge"))
        assert incident.incident_id == "INC-0001"

    def test_ids_are_padded_so_they_sort(self):
        store = MemoryStore()
        agent = IncidentAgent(DeterministicReasoner(), store)
        for i in range(3):
            agent.ingest(report(f"rpt-{i}", "fire in the market",
                                node=f"node-{i}",
                                loc=GeoPoint(lat=20.0 + i, lon=70.0 + i)))
        ids = sorted(i.incident_id for i in store.list_incidents())
        assert ids == ["INC-0001", "INC-0002", "INC-0003"]

    def test_an_id_already_taken_is_skipped(self):
        store = MemoryStore()
        # Something else holds the id our counter would hand out next.
        store.put_incident(Incident(incident_id="INC-0001",
                                    description="pre-existing"))

        agent = IncidentAgent(DeterministicReasoner(), store)
        agent._counter = itertools.count(1)   # force the collision
        incident, _ = agent.ingest(
            report("rpt-1", "unrelated fire", loc=FAR, node="node-09")
        )

        assert incident.incident_id != "INC-0001"
        assert store.get_incident("INC-0001").description == "pre-existing"
