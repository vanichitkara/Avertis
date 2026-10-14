"""Gateway sync: critical-first ordering, budgets, idempotency."""

from __future__ import annotations

from avertis_sim.gateway_client import (
    GatewayClient, InMemoryBackend, ASSUMED_UPLINK_BYTES_PER_S,
)
from avertis_sim.protocol import MessageType, NodeRole, Priority
from avertis_sim.topology import World, WorldConfig
from avertis_sim.transport.sim_transport import RadioModel


def small_world() -> World:
    cfg = WorldConfig(seed=13, area_m=400.0,
                      radio=RadioModel(range_m=250.0, base_loss=0.0,
                                       edge_loss=0.0))
    w = World(cfg)
    w.add_node("gw-01", role=NodeRole.GATEWAY, x=0, y=0, battery=1.0)
    for i in range(6):
        w.add_node(f"node-{i:02d}", role=NodeRole.SURVIVOR, battery=0.9)
    w.run_for(12)
    return w


def test_sync_order_is_critical_first_then_oldest():
    w = small_world()
    engine = w.nodes["node-00"].engine
    normal = engine.send_incident("shelter is full", Priority.NORMAL)
    w.run_for(2)
    critical = engine.send_sos(note="trapped")
    w.run_for(2)
    emergency = engine.send_incident("injured person", Priority.EMERGENCY)
    w.run_for(10)

    ordered = GatewayClient.sync_order([normal, critical, emergency])
    assert [p.priority for p in ordered] == [
        Priority.LIFE_CRITICAL, Priority.EMERGENCY, Priority.NORMAL
    ]


def test_sync_delivers_and_is_idempotent():
    w = small_world()
    w.nodes["node-00"].engine.send_sos(note="trapped")
    w.run_for(15)

    backend = InMemoryBackend()
    w.set_internet("gw-01", True, 20)
    client = GatewayClient(w, "gw-01", backend)

    first = client.sync(20)
    assert first.accepted >= 1
    assert len(backend.accepted_reports) == first.accepted

    # A repeated window must not create duplicate incidents.
    second = client.sync(20)
    assert len(backend.accepted_reports) == first.accepted
    assert second.accepted == 0, "already-synced reports should not resend"


def test_no_connectivity_means_nothing_is_claimed_as_sent():
    w = small_world()
    w.nodes["node-00"].engine.send_sos(note="trapped")
    w.run_for(15)
    client = GatewayClient(w, "gw-01", InMemoryBackend())
    result = client.sync(20)   # internet was never switched on
    assert result.error == "NO_CONNECTIVITY"
    assert result.accepted == 0


def test_backend_failure_retains_the_queue():
    class Failing:
        def post_sync(self, body):
            raise RuntimeError("backend down")

    w = small_world()
    w.nodes["node-00"].engine.send_sos(note="trapped")
    w.run_for(15)
    w.set_internet("gw-01", True, 20)
    held_before = len(w.nodes["gw-01"].engine.state.pending_reports)

    result = GatewayClient(w, "gw-01", Failing()).sync(20)
    assert result.accepted == 0
    assert result.error
    assert len(w.nodes["gw-01"].engine.state.pending_reports) == held_before, (
        "a failed sync must not discard anything"
    )


def test_short_window_defers_and_sends_critical_first():
    w = small_world()
    for i in range(6):
        engine = w.nodes[f"node-{i:02d}"].engine
        engine.send_incident("road blocked by debris" * 8, Priority.NORMAL)
        engine.send_incident("shelter nearly full" * 8, Priority.OPERATIONAL)
    w.run_for(10)
    w.nodes["node-00"].engine.send_sos(note="trapped, water rising")
    w.run_for(20)

    backend = InMemoryBackend()
    w.set_internet("gw-01", True, 2)
    client = GatewayClient(w, "gw-01", backend)
    queued = len(client._held_reports())
    result = client.sync(2)   # a deliberately tiny window

    assert result.deferred > 0, (
        f"a 2s window should not carry all {queued} reports"
    )
    # Whatever did fit, the critical report must be among it.
    sent_priorities = [
        r["priority"] for r in backend.syncs[-1]["incidents"]
    ]
    assert Priority.LIFE_CRITICAL.value in sent_priorities, (
        "the life-critical report was left behind in a constrained window"
    )
    assert sent_priorities[0] == Priority.LIFE_CRITICAL.value


def test_duplicate_copies_of_one_report_cost_one_slot():
    w = small_world()
    engine = w.nodes["node-00"].engine
    packet = engine.send_sos(note="trapped")
    w.run_for(30)   # custody retries deliver extra copies

    gw = w.nodes["gw-01"].engine
    copies = [p for p in gw.state.pending_reports
              if p.payload.get("report_id") == packet.payload["report_id"]]
    client = GatewayClient(w, "gw-01", InMemoryBackend())
    unique = [p for p in client._held_reports()
              if p.payload.get("report_id") == packet.payload["report_id"]]
    assert len(unique) == 1, "the window must be spent once per report"
    assert len(copies) >= len(unique)


def test_truncated_topology_still_carries_links():
    """A node list with no links tells the backend nothing about reachability.

    Under a tight window the topology gets truncated. If that truncation drops
    links, every node arrives looking isolated, every responder looks
    unreachable, and the network-aware recommendation quietly stops working —
    with no error anywhere to show for it.
    """
    cfg = WorldConfig(seed=7, area_m=500.0,
                      radio=RadioModel(range_m=300.0, base_loss=0.0,
                                       edge_loss=0.0))
    world = World(cfg)
    world.add_node("gw-01", role=NodeRole.GATEWAY, x=0, y=0, battery=1.0)
    for i in range(30):
        world.add_node(f"node-{i:02d}", role=NodeRole.SURVIVOR, battery=0.9)
    world.run_for(12)

    # Traffic, so there is something to sync at all.
    for i in range(5):
        world.nodes[f"node-{i:02d}"].engine.send_sos(note="trapped")
    world.run_for(15)

    backend = InMemoryBackend()
    world.set_internet("gw-01", True, 20)
    client = GatewayClient(world, "gw-01", backend)

    # A window far too small to carry the full topology alongside the reports.
    client.sync(2.0)

    assert backend.syncs, "the sync should have been attempted"
    body = backend.syncs[-1]

    if body.get("topology_truncated"):
        assert body["nodes"], "truncation should still send some nodes"
        node_ids = {n["node_id"] for n in body["nodes"]}
        # Links may be empty only if no kept pair is actually connected.
        for link in body["links"]:
            assert link["a"] in node_ids and link["b"] in node_ids, (
                "a link to a node we did not send cannot be reasoned about"
            )
        connected_pairs_exist = any(
            l["a"] in node_ids and l["b"] in node_ids
            for l in world.world_snapshot()["links"]
        )
        if connected_pairs_exist:
            assert body["links"], (
                "nodes were sent without any links between them — the "
                "backend would see them as isolated"
            )


def test_a_topology_change_syncs_even_with_no_new_reports():
    """The network is half the world model, and it changes on its own.

    A relay failing generates no report. If the gateway only talks to the
    backend when it has reports to send, the backend never learns the
    topology changed and the recommended responder never moves — which is
    the one behaviour the whole project exists to demonstrate.
    """
    w = small_world()
    w.nodes["node-00"].engine.send_sos(note="trapped")
    w.run_for(15)

    backend = InMemoryBackend()
    w.set_internet("gw-01", True, 20)
    client = GatewayClient(w, "gw-01", backend)

    first = client.sync(20)
    assert first.accepted >= 1
    assert len(backend.syncs) == 1

    # Nothing new to report, but the mesh has changed shape.
    w.kill_node("node-01", reason="RELAY_FAILURE")
    w.run_for(20)
    w.set_internet("gw-01", True, 20)
    second = client.sync(20)

    assert second.accepted == 0, "there were no new reports"
    assert len(backend.syncs) == 2, (
        "the topology change must still reach the backend"
    )
    assert backend.syncs[-1]["nodes"], "the second sync carried node state"
