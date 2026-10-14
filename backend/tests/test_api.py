"""The HTTP surface, against the frozen contract in docs/api.md.

The mesh side was written against this document by a different implementation
(Dart) and a different language (Python simulator). If the field names here
drift, the integration breaks silently at the worst moment, so the contract
shapes are asserted literally.
"""

from __future__ import annotations

import hashlib

import pytest
from fastapi.testclient import TestClient

from avertis_backend.main import app, coordinator, store


@pytest.fixture
def client() -> TestClient:
    # Each test starts from a clean world.
    store.__init__()  # type: ignore[misc]
    coordinator._recommendations.clear()
    return TestClient(app)


SYNC_BODY = {
    "gateway_id": "gw-01",
    "sent_at": "2026-09-06T12:04:00.000Z",
    "connectivity_window_seconds": 18,
    "nodes": [
        {
            "node_id": "node-07",
            "role": "SURVIVOR",
            "battery": 0.67,
            "location": {"lat": 12.9716, "lon": 77.5946, "accuracy_m": 12.0},
            "neighbors": ["node-12"],
            "last_seen": "2026-09-06T12:03:58.000Z",
            "gateway_distance": 3,
            "link_stability": 0.88,
            "mobility": 0.12,
            "queue_depth": 4,
            "reachable": True,
            "partition_id": 0,
        }
    ],
    "links": [{"a": "node-07", "b": "node-12", "stability": 0.88, "rssi": -71}],
    "incidents": [
        {
            "report_id": "rpt-8a1f2c",
            "origin_node": "node-07",
            "created_at": "2026-09-06T12:00:00.000Z",
            "priority": "LIFE_CRITICAL",
            "kind": "SOS",
            "location": {"lat": 12.97, "lon": 77.59, "accuracy_m": 20.0},
            "text": "three people trapped near the bridge",
            "transcript": None,
            "media": [],
            "hop_count": 3,
            "path": ["node-07", "node-12", "node-31"],
        }
    ],
    "messages": [],
    "metrics": {
        "nodes_total": 100, "nodes_reachable": 64,
        "partitions": 2, "queue_depth_total": 213,
    },
}


class TestHealth:
    def test_health_states_which_engine_is_live(self, client):
        body = client.get("/api/v1/health").json()
        assert body["status"] == "ok"
        # Nothing should have to guess whether Gemini is actually running.
        assert "engine" in body["reasoning"]
        assert isinstance(body["reasoning"]["is_model"], bool)


class TestGatewaySync:
    def test_the_contract_body_is_accepted_verbatim(self, client):
        response = client.post("/api/v1/gateway/sync", json=SYNC_BODY)
        assert response.status_code == 200, response.text

        body = response.json()
        for field in ("received_at", "accepted", "rejected", "incidents",
                      "commands"):
            assert field in body

        assert body["accepted"] == ["rpt-8a1f2c"]
        assert body["incidents"][0]["report_id"] == "rpt-8a1f2c"
        assert body["incidents"][0]["incident_id"].startswith("INC-")

    def test_a_sync_ack_is_returned_for_each_accepted_report(self, client):
        body = client.post("/api/v1/gateway/sync", json=SYNC_BODY).json()
        acks = [c for c in body["commands"] if c["type"] == "SYNC_ACK"]
        assert len(acks) == 1
        assert acks[0]["report_id"] == "rpt-8a1f2c"

    def test_resyncing_is_idempotent(self, client):
        """A mesh in custody retransmits; that must not create duplicates."""
        client.post("/api/v1/gateway/sync", json=SYNC_BODY)
        client.post("/api/v1/gateway/sync", json=SYNC_BODY)

        incidents = client.get("/api/v1/incidents").json()
        assert incidents["count"] == 1

    def test_an_empty_report_is_rejected_not_silently_dropped(self, client):
        body = dict(SYNC_BODY)
        body["incidents"] = [{
            "report_id": "rpt-empty",
            "origin_node": "node-07",
            "created_at": "2026-09-06T12:00:00.000Z",
            "location": None,
            "text": None,
        }]
        response = client.post("/api/v1/gateway/sync", json=body).json()

        assert response["accepted"] == []
        assert response["rejected"][0]["report_id"] == "rpt-empty"

    def test_media_is_requested_when_only_a_descriptor_arrived(self, client):
        body = dict(SYNC_BODY)
        body["incidents"] = [{
            **SYNC_BODY["incidents"][0],
            "media": [{"kind": "IMAGE", "media_id": "med-1", "bytes": 84213,
                       "inline": False}],
        }]
        response = client.post("/api/v1/gateway/sync", json=body).json()

        requests = [c for c in response["commands"] if c["type"] == "REQUEST_MEDIA"]
        assert requests and requests[0]["media_id"] == "med-1"


class TestMedia:
    def test_upload_verifies_integrity(self, client):
        payload = b"pretend jpeg bytes"
        digest = hashlib.sha256(payload).hexdigest()

        response = client.post(
            "/api/v1/media/upload",
            data={"media_id": "med-1", "report_id": "rpt-1", "sha256": digest},
            files={"file": ("photo.jpg", payload, "image/jpeg")},
        )
        assert response.status_code == 200
        assert response.json()["media_id"] == "med-1"

    def test_a_corrupted_upload_is_refused(self, client):
        # A photo mangled on a lossy mesh must not be shown as evidence.
        response = client.post(
            "/api/v1/media/upload",
            data={"media_id": "med-2", "report_id": "rpt-1",
                  "sha256": "0" * 64},
            files={"file": ("photo.jpg", b"different bytes", "image/jpeg")},
        )
        assert response.status_code == 400
        assert "mismatch" in response.json()["detail"]

    def test_an_uploaded_file_can_be_fetched_back(self, client):
        payload = b"evidence"
        client.post(
            "/api/v1/media/upload",
            data={"media_id": "med-3", "report_id": "rpt-1",
                  "sha256": hashlib.sha256(payload).hexdigest()},
            files={"file": ("photo.jpg", payload, "image/jpeg")},
        )
        fetched = client.get("/api/v1/media/med-3")
        assert fetched.status_code == 200
        assert fetched.content == payload


class TestIncidentsAndWorld:
    def test_incident_analyze_structures_one_report(self, client):
        response = client.post(
            "/api/v1/incident/analyze",
            json=SYNC_BODY["incidents"][0],
        )
        assert response.status_code == 200
        incident = response.json()["incident"]
        assert incident["severity"] == "LIFE_CRITICAL"
        assert incident["people_affected"] == 3
        # Provenance travels with the data.
        assert response.json()["reasoned_by"]

    def test_the_world_model_has_both_halves(self, client):
        client.post("/api/v1/gateway/sync", json=SYNC_BODY)
        world = client.get("/api/v1/world").json()

        # Plan §23: the combined state is the heart of the system.
        assert "physical" in world and "network" in world
        assert "incidents" in world["physical"]
        assert "partitions" in world["network"]

    def test_the_activity_feed_records_what_happened(self, client):
        client.post("/api/v1/gateway/sync", json=SYNC_BODY)
        feed = client.get("/api/v1/activity").json()["activity"]
        assert any(a["action"] == "INCIDENT_CREATED" for a in feed)

    def test_metrics_report_fusion(self, client):
        client.post("/api/v1/gateway/sync", json=SYNC_BODY)
        metrics = client.get("/api/v1/metrics").json()
        assert metrics["incidents_total"] == 1
        assert metrics["reports_total"] == 1

    def test_an_unknown_incident_is_a_404(self, client):
        assert client.get("/api/v1/incidents/INC-nope").status_code == 404


class TestReasoningDisclosure:
    """The badge an operator reads must describe the real situation.

    Three states, three messages: no key, key-but-broken, and working. Saying
    "no key" when a key is set sends someone hunting for something they
    already did.
    """

    def test_no_key_says_no_key(self, client, monkeypatch):
        import dataclasses

        from avertis_backend import main

        # Settings is frozen, so swap the whole object.
        monkeypatch.setattr(
            main, "settings",
            dataclasses.replace(main.settings, gemini_api_key=""),
        )
        note = client.get("/api/v1/health").json()["reasoning"]["note"]
        assert "No GEMINI_API_KEY" in note

    def test_a_set_but_broken_key_says_so(self, client, monkeypatch):
        import dataclasses

        from avertis_backend import main

        # A key is present, yet the live engine is the rule-based one — which
        # is exactly what happens when google-genai is missing, the model is
        # retired, or the key is rejected. conftest guarantees the test suite
        # is in that state.
        monkeypatch.setattr(
            main, "settings",
            dataclasses.replace(main.settings, gemini_api_key="abc"),
        )
        body = client.get("/api/v1/health").json()
        assert body["reasoning"]["is_model"] is False
        note = body["reasoning"]["note"]
        assert "is set but" in note
        assert "google-genai" in note

    def test_is_model_is_never_true_without_a_model(self, client):
        body = client.get("/api/v1/health").json()
        if body["reasoning"]["engine"] == "deterministic":
            assert body["reasoning"]["is_model"] is False
