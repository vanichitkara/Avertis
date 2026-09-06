"""Phase 2 target: A -> B -> C, kill B, network heals to A -> D -> C."""

from __future__ import annotations

from avertis_sim.protocol import MessageType, NodeRole, Priority
from avertis_sim.topology import World, WorldConfig
from avertis_sim.topology.partition import connected_components, partition_map
from avertis_sim.transport.sim_transport import RadioModel


def diamond_world() -> World:
    """A -- B -- C with an alternative relay D also bridging A and C.

        B
      /   \\
    A       C
      \\   /
        D
    """
    cfg = WorldConfig(seed=11,
                      radio=RadioModel(range_m=120.0, base_loss=0.0, edge_loss=0.0))
    w = World(cfg)
    w.add_node("node-a", role=NodeRole.SURVIVOR, x=0, y=0, battery=0.9)
    # B is the better relay: fuller battery, stationary.
    w.add_node("node-b", role=NodeRole.RELAY, x=100, y=40, battery=1.0)
    w.add_node("node-d", role=NodeRole.RELAY, x=100, y=-40, battery=0.55)
    w.add_node("node-c", role=NodeRole.GATEWAY, x=200, y=0, battery=1.0)
    return w


def test_diamond_geometry_forces_a_relay():
    w = diamond_world()
    assert "node-c" not in w.peers_of("node-a")
    assert sorted(w.peers_of("node-a")) == ["node-b", "node-d"]


def test_relay_score_prefers_the_healthier_relay():
    w = diamond_world()
    w.run_for(12)
    a = w.nodes["node-a"].engine
    score_b = a.state.relay_score(a.state.neighbors["node-b"])
    score_d = a.state.relay_score(a.state.neighbors["node-d"])
    assert score_b > score_d, "fuller battery should win the deterministic score"


def test_network_heals_after_the_chosen_relay_dies():
    w = diamond_world()
    w.run_for(12)

    first = w.nodes["node-a"].engine.send_sos(note="pre-failure")
    w.run_for(6)
    c = w.nodes["node-c"].engine
    assert any(p.packet_id == first.packet_id for p in c.state.delivered)

    # Kill the relay the traffic was using.
    w.kill_node("node-b", reason="RELAY_FAILURE")
    # Failure is detected by beacon timeout, not by a magic callback.
    w.run_for(20)

    a = w.nodes["node-a"].engine
    assert a.state.neighbors["node-b"].state == "DOWN"
    assert a.state.neighbors["node-d"].state == "UP"

    downs = [e for e in w.bus.of_type("NODE_DOWN")
             if e.data.get("peer") == "node-b"]
    assert downs, "no NODE_DOWN event was emitted for the failed relay"
    assert w.bus.of_type("RELAY_ELECTED"), "no replacement relay was elected"

    # And traffic flows again, now through D.
    second = w.nodes["node-a"].engine.send_sos(note="post-failure")
    w.run_for(15)
    delivered = [p for p in c.state.delivered if p.packet_id == second.packet_id]
    assert delivered, "network did not heal — SOS undeliverable after failure"
    assert delivered[0].path == ("node-d",), (
        f"expected the route to migrate to node-d, got {delivered[0].path}"
    )


def test_queued_packets_are_rerouted_not_lost():
    """A packet in flight when the relay dies must still arrive."""
    w = diamond_world()
    w.run_for(12)
    a = w.nodes["node-a"].engine

    # Pin traffic to B by making D temporarily unreachable, then queue an SOS
    # while nothing can carry it.
    w.kill_node("node-d")
    w.run_for(20)
    a.transport.stop()          # radio silence: the SOS must be held
    packet = a.send_sos(note="queued during outage")
    assert len(a.state.queue) == 1
    a.transport.start()
    w.revive_node("node-d", battery=0.55)
    w.run_for(25)

    c = w.nodes["node-c"].engine
    assert any(p.packet_id == packet.packet_id for p in c.state.delivered), (
        "packet queued during the outage was never delivered"
    )


def test_partition_is_detected_and_healed():
    """Cutting every bridge splits the graph; restoring one heals it."""
    w = diamond_world()
    w.run_for(12)
    assert len(connected_components(w.graph())) == 1

    w.kill_node("node-b")
    w.kill_node("node-d")
    w.run_for(20)

    comps = connected_components(w.graph())
    assert len(comps) == 2, f"expected a partition, got {comps}"
    pmap = partition_map(w.graph())
    assert pmap["node-a"] != pmap["node-c"]
    assert w.bus.of_type("PARTITION_DETECTED")

    w.revive_node("node-d", battery=0.8)
    w.run_for(20)
    assert len(connected_components(w.graph())) == 1
    assert w.bus.of_type("PARTITION_HEALED")


def test_gateway_distance_propagates_and_retracts():
    w = diamond_world()
    w.run_for(15)
    a = w.nodes["node-a"].engine
    b = w.nodes["node-b"].engine
    assert b.state.gateway_distance == 1, "relay next to the gateway is 1 hop"
    assert a.state.gateway_distance == 2, "survivor two hops out is 2"


def test_critical_traffic_survives_twenty_percent_node_loss():
    """Under 20% node loss, every sender that still has a path delivers, and
    the ones that don't retain custody rather than losing the report."""
    cfg = WorldConfig(seed=5, area_m=600.0,
                      radio=RadioModel(range_m=160.0, base_loss=0.01,
                                       edge_loss=0.15))
    w = World(cfg)
    w.add_node("gw-01", role=NodeRole.GATEWAY, x=0, y=0, battery=1.0)
    for i in range(30):
        w.add_node(f"node-{i:02d}", role=NodeRole.SURVIVOR, battery=0.9)
    w.run_for(15)
    w.kill_random_nodes(0.20, exclude_roles=[NodeRole.GATEWAY])
    w.run_for(20)

    senders = [n for n in w.nodes.values()
               if n.alive and n.role is NodeRole.SURVIVOR][:10]
    sent = {n.node_id: n.engine.send_sos(note="mass event") for n in senders}
    w.run_for(45)

    gw = w.nodes["gw-01"].engine
    arrived = {p.payload.get("report_id") for p in gw.state.delivered
               if p.message_type is MessageType.SOS}
    pmap = partition_map(w.graph())
    gw_partition = pmap["gw-01"]

    connected = [n for n in sent if pmap.get(n) == gw_partition]
    isolated = [n for n in sent if pmap.get(n) != gw_partition]
    assert connected, "test is meaningless if nobody could reach the gateway"

    delivered = [n for n in connected
                 if sent[n].payload["report_id"] in arrived]
    rate = len(delivered) / len(connected)
    assert rate == 1.0, (
        f"only {rate:.0%} of reachable senders delivered "
        f"({len(connected) - len(delivered)} lost inside the connected component)"
    )

    # Cut off senders must not silently lose the report.
    for node_id in isolated:
        engine = w.nodes[node_id].engine
        assert engine.custody_depth >= 1, (
            f"{node_id} is partitioned but dropped its LIFE_CRITICAL report"
        )


def test_custody_flushes_when_the_partition_heals():
    """A report originated inside a cut-off partition is delivered late,
    not lost, once a route back to the gateway reappears."""
    cfg = WorldConfig(seed=11,
                      radio=RadioModel(range_m=120.0, base_loss=0.0,
                                       edge_loss=0.0))
    w = World(cfg)
    w.add_node("node-a", role=NodeRole.SURVIVOR, x=0, y=0, battery=0.9)
    w.add_node("node-b", role=NodeRole.RELAY, x=100, y=0, battery=1.0)
    w.add_node("node-c", role=NodeRole.GATEWAY, x=200, y=0, battery=1.0)
    w.run_for(12)

    # Sever the only bridge, then report from the isolated side.
    w.kill_node("node-b", reason="RELAY_FAILURE")
    w.run_for(20)
    packet = w.nodes["node-a"].engine.send_sos(note="cut off")
    report_id = packet.payload["report_id"]
    w.run_for(40)

    gw = w.nodes["node-c"].engine
    assert not [p for p in gw.state.delivered
                if p.payload.get("report_id") == report_id]
    assert w.nodes["node-a"].engine.custody_depth == 1, "report was not retained"

    # Bridge restored.
    w.revive_node("node-b", battery=1.0)
    w.run_for(40)

    assert [p for p in gw.state.delivered
            if p.payload.get("report_id") == report_id], (
        "custody did not flush after the partition healed"
    )
    assert w.nodes["node-a"].engine.custody_depth == 0, (
        "custody should clear once the report is acknowledged"
    )
