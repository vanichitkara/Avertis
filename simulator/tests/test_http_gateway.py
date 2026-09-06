"""The gateway client against a real HTTP server, not an in-process stub.

This exercises the parts an in-memory backend cannot: JSON serialisation over
the wire, HTTP status handling, and idempotency across separate requests.
"""

from __future__ import annotations

import threading
from http.server import HTTPServer

import pytest

from avertis_sim.gateway_client import GatewayClient, HttpBackend
from avertis_sim.mock_gateway_server import STATE, Handler
from avertis_sim.protocol import NodeRole
from avertis_sim.topology import World, WorldConfig
from avertis_sim.transport.sim_transport import RadioModel


@pytest.fixture
def server():
    STATE.reports.clear()
    STATE.syncs.clear()
    STATE.nodes.clear()
    STATE.next_incident = 1042

    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{httpd.server_port}"
    httpd.shutdown()
    httpd.server_close()


@pytest.fixture
def world():
    cfg = WorldConfig(seed=17, area_m=400.0,
                      radio=RadioModel(range_m=250.0, base_loss=0.0,
                                       edge_loss=0.0))
    w = World(cfg)
    w.add_node("gw-01", role=NodeRole.GATEWAY, x=0, y=0, battery=1.0)
    for i in range(4):
        w.add_node(f"node-{i:02d}", role=NodeRole.SURVIVOR, battery=0.9)
    w.run_for(12)
    return w


def test_health_endpoint(server):
    assert HttpBackend(server).health() is True


def test_sync_over_http_creates_incidents(server, world):
    world.nodes["node-00"].engine.send_sos(note="trapped, water rising")
    world.nodes["node-01"].engine.send_incident("road blocked by debris")
    world.run_for(20)

    world.set_internet("gw-01", True, 30)
    client = GatewayClient(world, "gw-01", HttpBackend(server))
    result = client.sync(30)

    assert result.error is None
    assert result.accepted >= 1
    assert all(i.startswith("INC-") for i in result.incident_ids)
    assert len(STATE.reports) == result.accepted


def test_resubmitting_a_report_id_is_idempotent(server):
    """The contract my teammate's backend has to honour.

    Custody retransmission means the same report_id legitimately arrives more
    than once, by different routes and across different windows. It must map
    to one incident, not several — otherwise a partitioned network inflates
    the incident count exactly when command can least afford confusion.
    """
    import httpx

    body = {
        "gateway_id": "gw-01",
        "incidents": [
            {"report_id": "rpt-abc", "location": {"lat": 12.97, "lon": 77.59}},
        ],
    }
    first = httpx.post(f"{server}/api/v1/gateway/sync", json=body,
                       timeout=5.0).json()
    second = httpx.post(f"{server}/api/v1/gateway/sync", json=body,
                        timeout=5.0).json()

    assert first["accepted"] == ["rpt-abc"]
    assert second["accepted"] == ["rpt-abc"], (
        "a resubmitted report must still be acknowledged, so the client can "
        "stop retrying it"
    )
    assert (second["incidents"][0]["incident_id"]
            == first["incidents"][0]["incident_id"])
    assert len(STATE.reports) == 1, "one report became two incidents"


def test_accepted_reports_are_not_offered_again(server, world):
    """Once acknowledged, a report stops consuming connectivity windows."""
    world.nodes["node-00"].engine.send_sos(note="trapped")
    world.run_for(20)
    world.set_internet("gw-01", True, 30)

    backend = HttpBackend(server)
    client = GatewayClient(world, "gw-01", backend)
    first = client.sync(30)
    assert first.accepted >= 1

    second = client.sync(30)
    assert second.attempted == 0, (
        "already-acknowledged reports should not be resent"
    )
    assert len(STATE.reports) == first.accepted


def test_malformed_location_is_rejected_not_silently_accepted(server):
    import httpx

    response = httpx.post(
        f"{server}/api/v1/gateway/sync",
        json={
            "gateway_id": "gw-01",
            "incidents": [
                {"report_id": "rpt-good", "location": {"lat": 1.0, "lon": 2.0}},
                {"report_id": "rpt-bad", "location": {"lat": 1.0}},
            ],
        },
        timeout=5.0,
    )
    body = response.json()
    assert body["accepted"] == ["rpt-good"]
    assert body["rejected"] == [
        {"report_id": "rpt-bad", "reason": "MALFORMED_LOCATION"}
    ]


def test_backend_returning_an_error_retains_the_queue(world):
    """A 404 host means nothing was accepted and nothing is discarded."""
    world.nodes["node-00"].engine.send_sos(note="trapped")
    world.run_for(20)
    world.set_internet("gw-01", True, 30)
    held_before = len(world.nodes["gw-01"].engine.state.pending_reports)

    client = GatewayClient(world, "gw-01",
                           HttpBackend("http://127.0.0.1:9"))  # nothing there
    result = client.sync(30)

    assert result.accepted == 0
    assert result.error is not None
    assert len(world.nodes["gw-01"].engine.state.pending_reports) == held_before
