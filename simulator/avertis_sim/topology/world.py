"""The simulated world: geography, radios, nodes, and the clock that drives them.

Deterministic given a seed — the same scenario replays identically, which is
what makes the resilience benchmark in docs/benchmarks.md meaningful.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

import networkx as nx

from ..events import Event, EventBus
from ..mesh_engine import MeshEngine
from ..node_state import NodeState
from ..protocol import Location, MessageType, NodeRole, Packet, Priority
from ..transport.sim_transport import RadioModel, SimRadioTransport
from .partition import build_graph, partition_map, path_reliability, reachability

EARTH_R = 6_371_000.0


def haversine_m(a: Location, b: Location) -> float:
    p1, p2 = math.radians(a.lat), math.radians(b.lat)
    dp = p2 - p1
    dl = math.radians(b.lon - a.lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(h))


def offset_location(origin: Location, dx_m: float, dy_m: float) -> Location:
    """Move a lat/lon by a local metre offset (flat-earth is fine at city scale)."""
    dlat = dy_m / EARTH_R
    dlon = dx_m / (EARTH_R * math.cos(math.radians(origin.lat)))
    return Location(
        origin.lat + math.degrees(dlat),
        origin.lon + math.degrees(dlon),
        origin.accuracy_m,
    )


@dataclass
class WorldConfig:
    seed: int = 42
    # Bengaluru city centre — arbitrary but real coordinates so the command
    # centre map has something sensible to draw.
    origin: Location = field(
        default_factory=lambda: Location(12.9716, 77.5946, 5.0)
    )
    area_m: float = 1500.0
    tick_s: float = 0.25
    radio: RadioModel = field(default_factory=RadioModel)
    start_time: datetime = field(
        default_factory=lambda: datetime(2026, 9, 6, 8, 17, 0, tzinfo=timezone.utc)
    )


@dataclass
class SimNode:
    """A node as the *world* sees it (position, battery, liveness)."""

    node_id: str
    x: float
    y: float
    role: NodeRole
    battery: float = 1.0
    speed_mps: float = 0.0
    heading: float = 0.0
    alive: bool = True
    # Gateways are alive as nodes but may have no internet window.
    internet: bool = False
    engine: MeshEngine | None = None

    def location(self, origin: Location) -> Location:
        return offset_location(origin, self.x, self.y)


class World:
    """Owns every node, the radio model, and the simulation clock."""

    def __init__(self, config: WorldConfig | None = None,
                 bus: EventBus | None = None):
        self.config = config or WorldConfig()
        self.rng = random.Random(self.config.seed)
        self.t = 0.0
        self.bus = bus or EventBus(clock=lambda: self.t)
        self.nodes: dict[str, SimNode] = {}
        self.radio = self.config.radio
        # in-flight frames: (deliver_at, from, to, packet)
        self._wire: list[tuple[float, str, str, Packet]] = []
        self._link_cache: tuple[float, list[tuple[str, str, float]]] | None = None
        self._last_partitions: dict[str, int] = {}
        self.stats = {
            "frames_offered": 0,
            "frames_lost": 0,
            "frames_delivered": 0,
        }

    # -- clock ----------------------------------------------------------

    def now(self) -> datetime:
        return self.config.start_time + timedelta(seconds=self.t)

    def clock(self) -> float:
        return self.t

    # -- construction ---------------------------------------------------

    def add_node(
        self,
        node_id: str,
        *,
        role: NodeRole = NodeRole.SURVIVOR,
        x: float | None = None,
        y: float | None = None,
        battery: float | None = None,
        speed_mps: float = 0.0,
        internet: bool = False,
    ) -> SimNode:
        half = self.config.area_m / 2
        node = SimNode(
            node_id=node_id,
            x=self.rng.uniform(-half, half) if x is None else x,
            y=self.rng.uniform(-half, half) if y is None else y,
            role=role,
            battery=self.rng.uniform(0.35, 1.0) if battery is None else battery,
            speed_mps=speed_mps,
            heading=self.rng.uniform(0, 2 * math.pi),
            internet=internet,
        )
        state = NodeState(
            node_id=node_id,
            role=role,
            battery=node.battery,
            location=node.location(self.config.origin),
            mobility_mps=speed_mps,
        )
        transport = SimRadioTransport(node_id, self, self.radio)
        engine = MeshEngine(
            state=state,
            transport=transport,
            bus=self.bus,
            clock=self.clock,
            wall_clock=self.now,
        )
        node.engine = engine
        self.nodes[node_id] = node
        engine.start()
        self._link_cache = None
        return node

    # -- radio ----------------------------------------------------------

    def distance(self, a: str, b: str) -> float:
        na, nb = self.nodes[a], self.nodes[b]
        return math.hypot(na.x - nb.x, na.y - nb.y)

    def peers_of(self, node_id: str) -> list[str]:
        node = self.nodes.get(node_id)
        if node is None or not node.alive:
            return []
        out = []
        for other_id, other in self.nodes.items():
            if other_id == node_id or not other.alive:
                continue
            if self.distance(node_id, other_id) < self.radio.range_m:
                out.append(other_id)
        return sorted(out)

    def transmit(self, src: str, dst: str, packet: Packet) -> bool:
        """Put one frame on the wire. Returns False if the link is unusable."""
        s, d = self.nodes.get(src), self.nodes.get(dst)
        if s is None or d is None or not s.alive or not d.alive:
            return False
        dist = self.distance(src, dst)
        if dist >= self.radio.range_m:
            return False

        self.stats["frames_offered"] += 1
        size = len(packet.encode())
        if self.rng.random() < self.radio.loss_probability(dist):
            self.stats["frames_lost"] += 1
            # A lost frame still cost airtime and battery.
            self._spend_battery(src, size)
            return True  # the sender *did* transmit; loss is invisible to it

        latency = self.radio.latency_s + size / self.radio.throughput_bps
        self._wire.append((self.t + latency, src, dst, packet))
        self._spend_battery(src, size)
        return True

    def _spend_battery(self, node_id: str, bytes_sent: int) -> None:
        node = self.nodes[node_id]
        # Rough, transparent model: 1% of battery per 100 KB transmitted.
        node.battery = max(0.0, node.battery - bytes_sent / 100_000 * 0.01)
        if node.engine:
            node.engine.state.battery = node.battery
        if node.battery <= 0.0 and node.alive:
            self.kill_node(node_id, reason="BATTERY_DEPLETED")

    # -- stepping -------------------------------------------------------

    def step(self) -> None:
        dt = self.config.tick_s
        self.t += dt

        self._move_nodes(dt)

        # Deliver everything whose flight time has elapsed.
        due = [f for f in self._wire if f[0] <= self.t]
        if due:
            self._wire = [f for f in self._wire if f[0] > self.t]
            for _, src, dst, packet in due:
                node = self.nodes.get(dst)
                if node is None or not node.alive or node.engine is None:
                    continue
                # A node that moved out of range mid-flight misses the frame.
                if self.distance(src, dst) >= self.radio.range_m:
                    self.stats["frames_lost"] += 1
                    continue
                self.stats["frames_delivered"] += 1
                node.engine.on_packet(src, packet)

        for node in self.nodes.values():
            if node.alive and node.engine:
                node.engine.tick()

        self._link_cache = None
        self._check_partitions()

    def run_for(self, seconds: float) -> None:
        steps = int(seconds / self.config.tick_s)
        for _ in range(steps):
            self.step()

    def _move_nodes(self, dt: float) -> None:
        half = self.config.area_m / 2
        for node in self.nodes.values():
            if not node.alive or node.speed_mps <= 0:
                continue
            node.x += math.cos(node.heading) * node.speed_mps * dt
            node.y += math.sin(node.heading) * node.speed_mps * dt
            # Reflect off the edge of the simulated area.
            if abs(node.x) > half:
                node.x = math.copysign(half, node.x)
                node.heading = math.pi - node.heading
            if abs(node.y) > half:
                node.y = math.copysign(half, node.y)
                node.heading = -node.heading
            if node.engine:
                node.engine.state.location = node.location(self.config.origin)

    # -- failure controls (plan §31) -------------------------------------

    def kill_node(self, node_id: str, reason: str = "MANUAL") -> None:
        node = self.nodes.get(node_id)
        if node is None or not node.alive:
            return
        node.alive = False
        if node.engine:
            node.engine.state.alive = False
            node.engine.stop()
        self.bus.emit(
            Event("NODE_DOWN", self.now(), node_id,
                  {"reason": reason, "role": node.role.value})
        )
        if node.role is NodeRole.GATEWAY:
            self.bus.emit(Event("GATEWAY_DOWN", self.now(), node_id,
                                {"reason": reason}))
        # Peers notice through beacon timeout (protocol §9) — that is the
        # realistic path and it is what the self-healing demo shows. We do not
        # short-circuit it here.
        self._link_cache = None

    def revive_node(self, node_id: str, battery: float | None = None) -> None:
        node = self.nodes.get(node_id)
        if node is None or node.alive:
            return
        node.alive = True
        if battery is not None:
            node.battery = battery
        if node.engine:
            node.engine.state.alive = True
            node.engine.state.battery = node.battery
            node.engine.state.neighbors.clear()
            node.engine.transport.start()
        self.bus.emit(Event("NODE_RECOVERED", self.now(), node_id,
                            {"battery": round(node.battery, 3)}))
        if node.role is NodeRole.GATEWAY:
            self.bus.emit(Event("GATEWAY_UP", self.now(), node_id, {}))
        self._link_cache = None

    def kill_random_nodes(self, fraction: float,
                          exclude_roles: Iterable[NodeRole] = ()) -> list[str]:
        excluded = set(exclude_roles)
        candidates = [
            n for n in self.nodes.values()
            if n.alive and n.role not in excluded
        ]
        k = int(len(candidates) * fraction)
        victims = self.rng.sample(candidates, k) if k else []
        for v in victims:
            self.kill_node(v.node_id, reason="RANDOM_FAILURE")
        return [v.node_id for v in victims]

    def kill_region(self, x: float, y: float, radius_m: float,
                    reason: str = "REGIONAL_DAMAGE",
                    exclude_roles: Iterable[NodeRole] = ()) -> list[str]:
        """Destroy every node inside a circle.

        Real disasters damage a *place* — a flooded district, a collapsed
        block — not a uniform random sample of devices. Regional damage is
        what actually partitions a mesh, so it is what the resilience claims
        need to be tested against.
        """
        excluded = set(exclude_roles)
        victims = [
            n.node_id for n in self.nodes.values()
            if n.alive and n.role not in excluded
            and math.hypot(n.x - x, n.y - y) <= radius_m
        ]
        for node_id in victims:
            self.kill_node(node_id, reason=reason)
        return victims

    def kill_corridor(self, angle_rad: float, width_m: float,
                      offset_m: float = 0.0,
                      reason: str = "CORRIDOR_DAMAGE",
                      exclude_roles: Iterable[NodeRole] = ()) -> list[str]:
        """Destroy every node within `width_m` of a line across the field.

        A circular hole rarely partitions a mesh — the survivors just route
        around it. What actually splits a network in two is linear damage: a
        river bursting its banks, a collapsed elevated road, a fire front. This
        is the failure mode that makes reachability, and therefore
        network-aware dispatch, matter at all.
        """
        excluded = set(exclude_roles)
        # Signed distance from the line through (offset along its normal).
        nx, ny = -math.sin(angle_rad), math.cos(angle_rad)
        victims = [
            n.node_id for n in self.nodes.values()
            if n.alive and n.role not in excluded
            and abs(n.x * nx + n.y * ny - offset_m) <= width_m / 2
        ]
        for node_id in victims:
            self.kill_node(node_id, reason=reason)
        return victims

    def drain_battery(self, node_id: str, to: float) -> None:
        node = self.nodes[node_id]
        node.battery = to
        if node.engine:
            node.engine.state.battery = to
        if to <= 0.0:
            self.kill_node(node_id, reason="BATTERY_DEPLETED")

    def set_internet(self, gateway_id: str, available: bool,
                     window_seconds: int = 18) -> None:
        node = self.nodes[gateway_id]
        node.internet = available
        if available:
            self.bus.emit(
                Event("GATEWAY_UP", self.now(), gateway_id,
                      {"window_seconds": window_seconds})
            )
            if node.engine and node.alive:
                node.engine.originate(
                    message_type=MessageType.GATEWAY_AVAILABLE,
                    priority=Priority.OPERATIONAL,
                    destination="*",
                    payload={"gateway_id": gateway_id,
                             "window_seconds": window_seconds,
                             "announced_at": self.now().isoformat()},
                )
        else:
            self.bus.emit(Event("GATEWAY_DOWN", self.now(), gateway_id, {}))

    def move_node(self, node_id: str, dx_m: float, dy_m: float) -> None:
        node = self.nodes[node_id]
        node.x += dx_m
        node.y += dy_m
        if node.engine:
            node.engine.state.location = node.location(self.config.origin)
        self._link_cache = None
        if node.role is NodeRole.RESPONDER:
            self.bus.emit(
                Event("RESPONDER_MOVED", self.now(), node_id,
                      {"x": round(node.x, 1), "y": round(node.y, 1)})
            )

    # -- observation -----------------------------------------------------

    def links(self) -> list[tuple[str, str, float]]:
        """Live links as (a, b, stability). Stability comes from what the
        nodes actually measured, not from the world's own geometry."""
        if self._link_cache and self._link_cache[0] == self.t:
            return self._link_cache[1]
        out: list[tuple[str, str, float]] = []
        seen: set[tuple[str, str]] = set()
        for node_id, node in self.nodes.items():
            if not node.alive or node.engine is None:
                continue
            for n in node.engine.state.live_neighbors():
                other = self.nodes.get(n.node_id)
                if other is None or not other.alive:
                    continue
                key = tuple(sorted((node_id, n.node_id)))
                if key in seen:
                    continue
                seen.add(key)
                out.append((key[0], key[1], round(n.stability, 3)))
        self._link_cache = (self.t, out)
        return out

    def graph(self) -> nx.Graph:
        alive = [n for n, node in self.nodes.items() if node.alive]
        return build_graph(alive, self.links())

    def gateways(self) -> set[str]:
        return {
            n for n, node in self.nodes.items()
            if node.role is NodeRole.GATEWAY and node.alive
        }

    def _check_partitions(self) -> None:
        pmap = partition_map(self.graph())
        if not pmap:
            return
        count = len(set(pmap.values()))
        prev_count = (
            len(set(self._last_partitions.values()))
            if self._last_partitions else 1
        )
        if count > prev_count:
            sizes: dict[int, int] = {}
            for p in pmap.values():
                sizes[p] = sizes.get(p, 0) + 1
            self.bus.emit(
                Event("PARTITION_DETECTED", self.now(), "world",
                      {"partitions": count,
                       "sizes": [sizes[k] for k in sorted(sizes)]})
            )
        elif count < prev_count:
            self.bus.emit(
                Event("PARTITION_HEALED", self.now(), "world",
                      {"partitions": count})
            )
        self._last_partitions = pmap

    def world_snapshot(self) -> dict[str, Any]:
        """The network half of the Avertis world model (docs/api.md)."""
        g = self.graph()
        pmap = partition_map(g)
        gws = self.gateways()
        reach = reachability(g, gws)
        nodes = []
        for node_id, node in self.nodes.items():
            if node.engine is None:
                continue
            snap = node.engine.snapshot()
            snap["reachable"] = bool(reach.get(node_id, False))
            snap["partition_id"] = pmap.get(node_id, -1)
            snap["last_seen"] = self.now().isoformat()
            nodes.append(snap)
        return {
            "nodes": nodes,
            "links": [
                {"a": a, "b": b, "stability": s,
                 "rssi": self.radio.rssi(self.distance(a, b))}
                for a, b, s in self.links()
            ],
            "metrics": {
                "nodes_total": len(self.nodes),
                "nodes_alive": sum(1 for n in self.nodes.values() if n.alive),
                "nodes_reachable": sum(1 for v in reach.values() if v),
                "partitions": len(set(pmap.values())) if pmap else 0,
                "queue_depth_total": sum(
                    len(n.engine.state.queue)
                    for n in self.nodes.values() if n.engine
                ),
                "gateways_online": sum(
                    1 for n in self.nodes.values()
                    if n.role is NodeRole.GATEWAY and n.alive and n.internet
                ),
            },
        }

    def network_reliability(self, source: str, target: str) -> float:
        """Measured end-to-end path reliability — feeds the WHY explanation."""
        return path_reliability(self.graph(), source, target)
