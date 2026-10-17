"""FirestoreStore against the real Firestore emulator.

Skipped unless the emulator is running, so the suite stays hermetic:

    JAVA_HOME=/opt/homebrew/opt/openjdk@24 \\
      gcloud emulators firestore start --host-port=127.0.0.1:8900 --quiet
    FIRESTORE_EMULATOR_HOST=127.0.0.1:8900 .venv/bin/python -m pytest tests/test_firestore_store.py

This matters more than it looks. The in-memory store is what every other
test uses, so Firestore is the implementation most likely to be subtly
wrong — and the one that only reveals it in production, where the state is
real.
"""

from __future__ import annotations

import datetime as dt
import os
import uuid

import pytest

pytest.importorskip("google.cloud.firestore")

if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
    pytest.skip(
        "set FIRESTORE_EMULATOR_HOST to run these",
        allow_module_level=True,
    )

from avertis_backend.models import (  # noqa: E402
    AgentActivity,
    Evidence,
    GeoPoint,
    Incident,
    IncidentStatus,
    IncidentType,
    LinkSnapshot,
    NodeRole,
    NodeSnapshot,
    Priority,
    Responder,
)
from avertis_backend.store.firestore import FirestoreStore  # noqa: E402

T0 = dt.datetime(2026, 9, 6, 12, 0, tzinfo=dt.timezone.utc)


@pytest.fixture
def store() -> FirestoreStore:
    # A fresh project id per test: the emulator keeps them separate, so
    # tests cannot leak state into each other.
    return FirestoreStore(f"test-{uuid.uuid4().hex[:12]}")


def an_incident(**kwargs) -> Incident:
    return Incident(
        incident_id=kwargs.pop("incident_id", "INC-1042"),
        type=kwargs.pop("type", IncidentType.FLOOD_RESCUE),
        severity=kwargs.pop("severity", Priority.LIFE_CRITICAL),
        people_affected=kwargs.pop("people_affected", 3),
        location=GeoPoint(lat=12.9716, lon=77.5946, accuracy_m=12.0),
        description="three people trapped near the flooded bridge",
        evidence=[Evidence(report_id="rpt-1", origin_node="node-07",
                           created_at=T0, excerpt="trapped")],
        confidence=0.9,
        created_at=T0,
        **kwargs,
    )


class TestIncidents:
    def test_an_incident_survives_a_round_trip_intact(self, store):
        store.put_incident(an_incident())
        got = store.get_incident("INC-1042")

        assert got is not None
        assert got.severity == Priority.LIFE_CRITICAL
        assert got.type == IncidentType.FLOOD_RESCUE
        assert got.people_affected == 3
        assert got.confidence == 0.9
        # Nested models must survive serialisation, not just scalars.
        assert got.location.lat == pytest.approx(12.9716)
        assert got.evidence[0].report_id == "rpt-1"
        assert got.evidence[0].created_at == T0

    def test_an_unknown_incident_is_none(self, store):
        assert store.get_incident("INC-nope") is None

    def test_listing_is_critical_first(self, store):
        store.put_incident(an_incident(
            incident_id="INC-low", severity=Priority.NORMAL))
        store.put_incident(an_incident(
            incident_id="INC-high", severity=Priority.LIFE_CRITICAL))

        assert [i.incident_id for i in store.list_incidents()][0] == "INC-high"

    def test_writing_twice_updates_rather_than_duplicates(self, store):
        store.put_incident(an_incident())
        store.put_incident(an_incident(severity=Priority.EMERGENCY))

        incidents = store.list_incidents()
        assert len(incidents) == 1
        assert incidents[0].severity == Priority.EMERGENCY

    def test_a_resolved_status_round_trips(self, store):
        store.put_incident(an_incident(status=IncidentStatus.RESOLVED))
        assert store.get_incident("INC-1042").status == IncidentStatus.RESOLVED


class TestNetworkReplacement:
    """The behaviour the signature feature rests on.

    A link absent from the new view has gone away. If replacement silently
    merged instead, a dead relay would stay in the topology forever and the
    recommendation would never move.
    """

    def test_a_link_that_disappears_is_really_gone(self, store):
        store.replace_network(
            "gw-01",
            [NodeSnapshot(node_id="a"), NodeSnapshot(node_id="b")],
            [LinkSnapshot(a="a", b="b", stability=0.9)],
        )
        assert len(store.list_links()) == 1

        store.replace_network("gw-01", [NodeSnapshot(node_id="a")], [])

        assert store.list_links() == []
        assert [n.node_id for n in store.list_nodes()] == ["a"]

    def test_one_gateway_does_not_erase_another(self, store):
        store.replace_network("gw-01", [NodeSnapshot(node_id="a")], [])
        store.replace_network("gw-02", [NodeSnapshot(node_id="b")], [])

        # Two gateways reporting different corners of the mesh must coexist.
        assert {n.node_id for n in store.list_nodes()} == {"a", "b"}

    def test_node_fields_survive_the_round_trip(self, store):
        store.replace_network("gw-01", [NodeSnapshot(
            node_id="relay-7",
            role=NodeRole.RELAY,
            battery=0.42,
            location=GeoPoint(lat=1.5, lon=2.5),
            neighbors=["a", "b"],
            gateway_distance=3,
            link_stability=0.88,
            reachable=False,
            partition_id=2,
        )], [])

        node = store.list_nodes()[0]
        assert node.role == NodeRole.RELAY
        assert node.battery == pytest.approx(0.42)
        assert node.neighbors == ["a", "b"]
        assert node.gateway_distance == 3
        assert node.reachable is False
        assert node.partition_id == 2

    def test_the_bookkeeping_field_does_not_leak_into_the_model(self, store):
        # reported_by is stored alongside each document; it is not part of
        # the wire contract and must not reach a NodeSnapshot.
        store.replace_network("gw-01", [NodeSnapshot(node_id="a")], [])
        assert not hasattr(store.list_nodes()[0], "reported_by")


class TestRestOfTheStore:
    def test_the_report_index_makes_resync_idempotent(self, store):
        assert store.incident_for_report("rpt-1") is None
        store.link_report("rpt-1", "INC-1042")
        assert store.incident_for_report("rpt-1") == "INC-1042"

    def test_responders_round_trip(self, store):
        store.put_responder(Responder(
            responder_id="resp-a", node_id="node-a",
            location=GeoPoint(lat=1.0, lon=2.0), available=False))

        r = store.list_responders()[0]
        assert r.responder_id == "resp-a"
        assert r.available is False
        assert r.location.lat == pytest.approx(1.0)

    def test_activity_comes_back_newest_first(self, store):
        store.append_activity(AgentActivity(
            agent="incident", action="INCIDENT_CREATED", detail="first",
            at=T0))
        store.append_activity(AgentActivity(
            agent="coordinator", action="RESPONSE_REPLANNED", detail="second",
            at=T0 + dt.timedelta(minutes=1)))

        # The operator reads the recent end of the feed.
        assert [a.action for a in store.list_activity(10)] == [
            "RESPONSE_REPLANNED", "INCIDENT_CREATED",
        ]

    def test_the_activity_limit_is_respected(self, store):
        for i in range(8):
            store.append_activity(AgentActivity(
                agent="x", action="RECOMMENDATION", detail=str(i),
                at=T0 + dt.timedelta(seconds=i)))

        assert len(store.list_activity(3)) == 3

    def test_media_descriptors_round_trip(self, store):
        store.put_media("med-1", {"media_id": "med-1", "bytes": 2048,
                                  "sha256": "abc"})
        assert store.list_media()["med-1"]["bytes"] == 2048
