"""Phase 1 target: A -> B -> C, TTL, dedup, store-and-forward."""

from __future__ import annotations

import pytest

from avertis_sim.events import EventBus
from avertis_sim.protocol import (
    MessageType, NodeRole, Packet, Priority, payload_hash,
)
from avertis_sim.topology import World, WorldConfig
from avertis_sim.transport.sim_transport import RadioModel


def line_world(spacing_m: float = 100.0) -> World:
    """A -- B -- C in a line: A and C are out of range of each other."""
    cfg = WorldConfig(seed=7, radio=RadioModel(range_m=120.0, base_loss=0.0,
                                               edge_loss=0.0))
    w = World(cfg)
    w.add_node("node-a", role=NodeRole.SURVIVOR, x=0, y=0, battery=1.0)
    w.add_node("node-b", role=NodeRole.RELAY, x=spacing_m, y=0, battery=1.0)
    w.add_node("node-c", role=NodeRole.GATEWAY, x=2 * spacing_m, y=0, battery=1.0)
    return w


def test_line_topology_is_actually_multihop():
    w = line_world()
    assert w.peers_of("node-a") == ["node-b"]
    assert w.peers_of("node-c") == ["node-b"]
    assert sorted(w.peers_of("node-b")) == ["node-a", "node-c"]


def test_a_to_c_via_b():
    w = line_world()
    w.run_for(10)  # let beacons establish neighbours

    packet = w.nodes["node-a"].engine.send_sos(note="trapped, water rising")
    w.run_for(10)

    c = w.nodes["node-c"].engine
    delivered = [p for p in c.state.delivered
                 if p.packet_id == packet.packet_id]
    assert delivered, "SOS never reached the gateway"
    got = delivered[0]
    assert got.hop_count == 1, f"expected one relay hop, got {got.hop_count}"
    assert got.path == ("node-b",)
    assert got.origin_node == "node-a"
    assert got.priority is Priority.LIFE_CRITICAL


def test_origin_receives_ack():
    w = line_world()
    w.run_for(10)
    packet = w.nodes["node-a"].engine.send_sos(note="help")
    w.run_for(15)
    a = w.nodes["node-a"].engine
    acks = [p for p in a.state.delivered
            if p.message_type is MessageType.ACK
            and p.payload["ack_packet_id"] == packet.packet_id]
    assert acks, "origin never got an ACK for its SOS"
    assert acks[0].payload["by_node"] == "node-c"


def test_dedup_drops_repeat_of_same_packet_id():
    w = line_world()
    w.run_for(10)
    b = w.nodes["node-b"].engine
    packet = w.nodes["node-a"].engine.send_sos(note="dup test")
    w.run_for(5)
    before = b.packets_dropped_dup
    # Replay the identical frame at B.
    b.on_packet("node-a", packet)
    assert b.packets_dropped_dup == before + 1


def test_ttl_expiry_drops_packet():
    w = line_world()
    w.run_for(10)
    b = w.nodes["node-b"].engine
    dying = Packet.create(
        packet_id="pkt-deadbeefdeadbeef",
        origin_node="node-a",
        destination="node-zzz",  # nobody
        message_type=MessageType.INCIDENT,
        priority=Priority.NORMAL,
        created_at=w.now(),
        payload={"text": "x"},
        ttl=1,
    )
    b.on_packet("node-a", dying)
    assert b.packets_dropped_ttl == 1
    dropped = [e for e in w.bus.of_type("PACKET_DROPPED")
               if e.data.get("reason") == "TTL_EXPIRED"]
    assert dropped


def test_payload_hash_is_stable_and_content_addressed():
    a = {"b": 1, "a": "ü", "c": [1, 2]}
    b = {"c": [1, 2], "a": "ü", "b": 1}
    assert payload_hash(a) == payload_hash(b)
    assert payload_hash(a) != payload_hash({"a": "u", "b": 1, "c": [1, 2]})
    assert len(payload_hash(a)) == 16


def test_store_and_forward_holds_until_a_route_exists():
    """C is out of range; A must hold the packet, then deliver when B arrives."""
    cfg = WorldConfig(seed=3, radio=RadioModel(range_m=120.0, base_loss=0.0,
                                               edge_loss=0.0))
    w = World(cfg)
    w.add_node("node-a", role=NodeRole.SURVIVOR, x=0, y=0, battery=1.0)
    w.add_node("node-c", role=NodeRole.GATEWAY, x=200, y=0, battery=1.0)
    w.run_for(6)

    w.nodes["node-a"].engine.send_sos(note="isolated")
    w.run_for(10)
    a = w.nodes["node-a"].engine
    assert len(a.state.queue) >= 1, "packet should be held, not lost"
    assert not w.nodes["node-c"].engine.state.delivered

    # A relay walks into the gap.
    w.add_node("node-b", role=NodeRole.RELAY, x=100, y=0, battery=1.0)
    w.run_for(20)

    delivered = [p for p in w.nodes["node-c"].engine.state.delivered
                 if p.message_type is MessageType.SOS]
    assert delivered, "queued SOS was not delivered once a route appeared"


def test_priority_queue_orders_critical_first():
    w = line_world()
    w.run_for(10)
    a = w.nodes["node-a"].engine
    # Stall the radio so packets pile up in the queue.
    a.transport.stop()
    a.originate(message_type=MessageType.INCIDENT, priority=Priority.NORMAL,
                payload={"text": "normal"})
    a.originate(message_type=MessageType.INCIDENT, priority=Priority.OPERATIONAL,
                payload={"text": "ops"})
    a.send_sos(note="critical")
    order = [e.packet.priority for e in a.state.queue.peek_all()]
    assert order[0] is Priority.LIFE_CRITICAL
    assert order == sorted(order, key=lambda p: p.rank)
