"""The deterministic mesh engine.

Implements docs/protocol.md §6 (forwarding), §8 (queues + relay selection) and
§9 (failure detection). The Dart engine in mobile/lib/mesh/mesh_engine.dart is
a line-for-line sibling of this file — when one changes, both change.

No LLM is ever called from here.
"""

from __future__ import annotations

import secrets
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from typing import Any

from .events import Event, EventBus
from .node_state import (
    BEACON_INTERVAL_S,
    CustodyEntry,
    LinkState,
    Neighbor,
    NodeState,
    PacketQueue,
)
from .protocol import (
    ANY_GATEWAY,
    BROADCAST,
    Location,
    MessageType,
    NodeRole,
    Packet,
    Priority,
)
from .transport.base import MeshTransport

RETRY_INTERVAL_S = 5.0
# How long a report waits for an end-to-end ACK before it is retransmitted.
CUSTODY_RETRY_S = 20.0
MAX_CUSTODY_ATTEMPTS = 12
MAX_FORWARD_ATTEMPTS = 4
# How many best-scoring neighbours a packet is handed to when we have no
# specific route. More than one buys resilience; too many floods the mesh.
FANOUT_DEFAULT = 2
FANOUT_CRITICAL = 3


def new_packet_id() -> str:
    return "pkt-" + secrets.token_hex(8)


def new_report_id() -> str:
    return "rpt-" + secrets.token_hex(6)


class MeshEngine:
    """One node's mesh brain. Owns state, drives a transport, emits events."""

    def __init__(
        self,
        state: NodeState,
        transport: MeshTransport,
        bus: EventBus,
        clock: Callable[[], float],
        wall_clock: Callable[[], datetime] | None = None,
    ):
        self.state = state
        self.transport = transport
        self.bus = bus
        self.clock = clock
        self.wall_clock = wall_clock or (lambda: datetime.now(timezone.utc))
        self._last_beacon = -1e9
        self._last_retry = 0.0
        self.transport.bind(self)

        # Counters used by the benchmark harness.
        self.packets_originated = 0
        self.packets_forwarded = 0
        self.packets_delivered = 0
        self.packets_dropped_ttl = 0
        self.packets_dropped_dup = 0
        self.packets_dropped_queue = 0

    # -- lifecycle ------------------------------------------------------

    @property
    def node_id(self) -> str:
        return self.state.node_id

    def start(self) -> None:
        self.transport.start()
        self.bus.emit(
            Event("NODE_JOINED", self.wall_clock(), self.node_id,
                  {"role": self.state.role.value})
        )

    def stop(self) -> None:
        self.transport.stop()

    # -- origination ----------------------------------------------------

    def originate(
        self,
        *,
        message_type: MessageType,
        priority: Priority,
        payload: dict[str, Any],
        destination: str = ANY_GATEWAY,
        ttl: int | None = None,
    ) -> Packet:
        """Create a packet at this node and put it into the mesh."""
        packet = Packet.create(
            packet_id=new_packet_id(),
            origin_node=self.node_id,
            destination=destination,
            message_type=message_type,
            priority=priority,
            created_at=self.wall_clock(),
            payload=payload,
            ttl=ttl,
        )
        self.packets_originated += 1
        self.state.seen.add(packet.packet_id, self.clock())
        self.bus.emit(
            Event("PACKET_SENT", packet.created_at, self.node_id,
                  {"packet_id": packet.packet_id,
                   "type": message_type.value,
                   "priority": priority.value,
                   "destination": destination})
        )
        if message_type in (MessageType.SOS, MessageType.INCIDENT):
            self._take_custody(packet)

        # A gateway originating for the gateway just holds it for sync.
        if self._is_local_destination(packet):
            self._deliver_locally(packet)
        else:
            self._enqueue(packet)
            self._pump()
        return packet

    def send_sos(self, note: str = "", people_count: int | None = None) -> Packet:
        """The one-tap path. Always LIFE_CRITICAL (docs/protocol.md §4)."""
        loc = self.state.location
        return self.originate(
            message_type=MessageType.SOS,
            priority=Priority.LIFE_CRITICAL,
            payload={
                "report_id": new_report_id(),
                "node_id": self.node_id,
                "location": loc.to_json() if loc else None,
                "created_at": self.wall_clock().isoformat(),
                "people_count": people_count,
                "note": note,
            },
        )

    def send_incident(
        self,
        text: str,
        priority: Priority = Priority.EMERGENCY,
        media: list[dict[str, Any]] | None = None,
    ) -> Packet:
        loc = self.state.location
        return self.originate(
            message_type=MessageType.INCIDENT,
            priority=priority,
            payload={
                "report_id": new_report_id(),
                "node_id": self.node_id,
                "created_at": self.wall_clock().isoformat(),
                "location": loc.to_json() if loc else None,
                "text": text,
                "transcript": None,
                "media": media or [],
                "reported_priority": priority.value,
            },
        )

    # -- reception (TransportListener) ----------------------------------

    def on_packet(self, from_node: str, packet: Packet) -> None:
        if not self.state.alive:
            return
        now = self.clock()

        if packet.message_type is MessageType.HELLO:
            self._handle_hello(from_node, packet, now)
            return

        # 1. dedup
        if self.state.seen.seen(packet.packet_id, now):
            self.packets_dropped_dup += 1
            return
        self.state.seen.add(packet.packet_id, now)

        # 2. loop check
        if self.node_id in packet.path:
            self.packets_dropped_dup += 1
            return

        # 3. deliver
        delivered = False
        if self._is_local_destination(packet):
            self._deliver_locally(packet)
            delivered = True
            if packet.destination != BROADCAST:
                return

        # 4. TTL
        hopped = packet.forwarded_by(self.node_id)
        if hopped.ttl <= 0:
            self.packets_dropped_ttl += 1
            self.bus.emit(
                Event("PACKET_DROPPED", self.wall_clock(), self.node_id,
                      {"packet_id": packet.packet_id, "reason": "TTL_EXPIRED",
                       "hop_count": packet.hop_count})
            )
            return

        # 5. forward
        if not delivered or packet.destination == BROADCAST:
            self._enqueue(hopped)
            self._pump()

    def on_peer_lost(self, node_id: str) -> None:
        self._mark_neighbor_down(node_id)

    # -- handlers -------------------------------------------------------

    def _handle_hello(self, from_node: str, packet: Packet, now: float) -> None:
        p = packet.payload
        neighbor = self.state.neighbors.get(from_node)
        is_new = neighbor is None
        if neighbor is None:
            neighbor = Neighbor(node_id=from_node)
            self.state.neighbors[from_node] = neighbor
        neighbor.role = NodeRole(p.get("role", "SURVIVOR"))
        neighbor.battery = p.get("battery", 1.0)
        neighbor.location = Location.from_json(p.get("location"))
        neighbor.gateway_distance = p.get("gateway_distance")
        neighbor.observe_beacon(now, p.get("seq", 0))

        if is_new:
            self.bus.emit(
                Event("LINK_UP", self.wall_clock(), self.node_id,
                      {"peer": from_node, "role": neighbor.role.value})
            )
            # A new neighbour is a topology change: retry held packets and
            # anything still in custody (this is how a healed partition
            # flushes the reports it could not deliver).
            self._pump()
            for entry in self.state.custody.values():
                entry.last_attempt = -1e9
            self._retry_custody()

        self._recompute_gateway_distance()

    def _deliver_locally(self, packet: Packet) -> None:
        self.packets_delivered += 1
        self.state.delivered.append(packet)
        self.bus.emit(
            Event("PACKET_DELIVERED", self.wall_clock(), self.node_id,
                  {"packet_id": packet.packet_id,
                   "type": packet.message_type.value,
                   "priority": packet.priority.value,
                   "origin": packet.origin_node,
                   "hop_count": packet.hop_count,
                   "path": list(packet.path)})
        )

        if packet.message_type is MessageType.ACK:
            self._resolve_custody(packet.payload.get("ack_packet_id", ""))

        if packet.message_type in (MessageType.SOS, MessageType.INCIDENT):
            # A gateway holds reports for the next connectivity window.
            if self.state.is_gateway:
                self.state.pending_reports.append(packet)
            self._send_ack(packet)

    def _send_ack(self, packet: Packet) -> None:
        """ACK back toward the origin (docs/protocol.md §6.6)."""
        if packet.origin_node == self.node_id:
            return
        ack = Packet.create(
            packet_id=new_packet_id(),
            origin_node=self.node_id,
            destination=packet.origin_node,
            message_type=MessageType.ACK,
            priority=Priority.OPERATIONAL,
            created_at=self.wall_clock(),
            payload={"ack_packet_id": packet.packet_id,
                     "by_node": self.node_id,
                     "status": "DELIVERED"},
        )
        self.state.seen.add(ack.packet_id, self.clock())
        self._enqueue(ack)
        self._pump()

    # -- custody (report-level store-and-forward) -------------------------

    def _take_custody(self, packet: Packet) -> None:
        report_id = packet.payload.get("report_id")
        if not report_id:
            return
        entry = CustodyEntry(
            report_id=report_id,
            packet=packet,
            priority=packet.priority,
            created_at=self.clock(),
            last_attempt=self.clock(),
            packet_ids={packet.packet_id},
        )
        self.state.custody[report_id] = entry

    def _resolve_custody(self, acked_packet_id: str) -> None:
        for entry in self.state.custody.values():
            if acked_packet_id in entry.packet_ids:
                entry.acked = True
                self.state.custody.pop(entry.report_id, None)
                return

    def _retry_custody(self) -> None:
        """Retransmit unacknowledged reports. This is what survives a partition.

        The retransmission carries the same `report_id` (so the gateway and the
        backend deduplicate it) but a fresh `packet_id`, because every relay
        along the way has the old ID in its seen-set and would drop it.
        """
        now = self.clock()
        for entry in list(self.state.custody.values()):
            if now - entry.last_attempt < CUSTODY_RETRY_S:
                continue
            if entry.attempts >= MAX_CUSTODY_ATTEMPTS:
                continue
            if not self.state.live_neighbors():
                # Nobody to hand it to; hold without burning an attempt.
                continue
            entry.attempts += 1
            entry.last_attempt = now
            resent = Packet.create(
                packet_id=new_packet_id(),
                origin_node=entry.packet.origin_node,
                destination=entry.packet.destination,
                message_type=entry.packet.message_type,
                priority=entry.packet.priority,
                created_at=entry.packet.created_at,
                payload=entry.packet.payload,
            )
            entry.packet_ids.add(resent.packet_id)
            self.state.seen.add(resent.packet_id, now)
            self._enqueue(resent)
            self.bus.emit(
                Event("PACKET_SENT", self.wall_clock(), self.node_id,
                      {"packet_id": resent.packet_id,
                       "type": resent.message_type.value,
                       "priority": resent.priority.value,
                       "destination": resent.destination,
                       "retransmission_of": entry.report_id,
                       "attempt": entry.attempts})
            )
        self._pump()

    @property
    def custody_depth(self) -> int:
        return len(self.state.custody)

    # -- routing --------------------------------------------------------

    def _is_local_destination(self, packet: Packet) -> bool:
        d = packet.destination
        if d == self.node_id or d == BROADCAST:
            return True
        return d == ANY_GATEWAY and self.state.is_gateway

    def _enqueue(self, packet: Packet, next_hop: str | None = None) -> None:
        evicted = self.state.queue.push(packet, next_hop)
        if evicted is not None:
            self.packets_dropped_queue += 1
            self.bus.emit(
                Event("QUEUE_DROP", self.wall_clock(), self.node_id,
                      {"packet_id": evicted.packet_id,
                       "priority": evicted.priority.value,
                       "queue_depth": len(self.state.queue)})
            )

    def _select_next_hops(self, packet: Packet) -> list[str]:
        """Deterministic next-hop choice. See docs/protocol.md §8.

        Direct link to the destination always wins. Otherwise hand the packet
        to the best-scoring relays, preferring those closer to a gateway when
        the packet is gateway-bound.
        """
        live = [n for n in self.state.live_neighbors()
                if n.node_id not in packet.path
                and n.node_id != packet.origin_node]
        if not live:
            return []

        # Direct delivery beats any relay heuristic.
        for n in live:
            if n.node_id == packet.destination:
                return [n.node_id]
        if packet.destination == ANY_GATEWAY:
            gateways = [n for n in live if n.role is NodeRole.GATEWAY]
            if gateways:
                return [gateways[0].node_id]

        scored = sorted(
            live, key=lambda n: (-self.state.relay_score(n), n.node_id)
        )
        fanout = (
            FANOUT_CRITICAL
            if packet.priority is Priority.LIFE_CRITICAL
            else FANOUT_DEFAULT
        )
        if packet.destination == BROADCAST:
            return [n.node_id for n in scored]
        return [n.node_id for n in scored[:fanout]]

    def _pump(self) -> None:
        """Try to move everything the queue is holding. Store-and-forward.

        Entries are walked in delivery order in place: a packet that is only
        waiting out its retry interval keeps its existing `last_attempt`, so
        the timer actually elapses.
        """
        if not self.state.alive:
            return
        now = self.clock()
        sent_ids: set[str] = set()
        dropped_ids: set[str] = set()

        for entry in self.state.queue.peek_all():
            packet = entry.packet
            if entry.attempts and now - entry.last_attempt < RETRY_INTERVAL_S:
                continue

            hops = (
                [entry.next_hop]
                if entry.next_hop
                else self._select_next_hops(packet)
            )
            sent_any = False
            for hop in hops:
                if self.transport.send(hop, packet):
                    sent_any = True
                    self.packets_forwarded += 1
                    self.bus.emit(
                        Event("PACKET_FORWARDED", self.wall_clock(), self.node_id,
                              {"packet_id": packet.packet_id,
                               "to": hop,
                               "priority": packet.priority.value,
                               "hop_count": packet.hop_count,
                               "ttl": packet.ttl})
                    )

            entry.attempts += 1
            entry.last_attempt = now

            if sent_any:
                sent_ids.add(packet.packet_id)
            elif entry.attempts >= MAX_FORWARD_ATTEMPTS and packet.priority in (
                Priority.NORMAL,
                Priority.OPERATIONAL,
            ):
                # Low-priority traffic gives up; critical traffic is held until
                # a route exists — that is the whole point of the mesh.
                dropped_ids.add(packet.packet_id)
                self.bus.emit(
                    Event("PACKET_DROPPED", self.wall_clock(), self.node_id,
                          {"packet_id": packet.packet_id,
                           "reason": "NO_ROUTE",
                           "attempts": entry.attempts})
                )

        if sent_ids or dropped_ids:
            done = sent_ids | dropped_ids
            self.state.queue.remove_where(lambda e: e.packet.packet_id in done)

    # -- periodic work ---------------------------------------------------

    def tick(self) -> None:
        """Called once per simulator step (and on a timer on the phone)."""
        if not self.state.alive:
            return
        now = self.clock()

        if now - self._last_beacon >= BEACON_INTERVAL_S:
            self._beacon()
            self._last_beacon = now

        self._age_neighbors(now)

        if now - self._last_retry >= 1.0:
            self._pump()
            self._retry_custody()
            self._last_retry = now

    def _beacon(self) -> None:
        self.state.beacon_seq += 1
        loc = self.state.location
        hello = Packet.create(
            packet_id=new_packet_id(),
            origin_node=self.node_id,
            destination=BROADCAST,
            message_type=MessageType.HELLO,
            priority=Priority.NORMAL,
            created_at=self.wall_clock(),
            payload={
                "node_id": self.node_id,
                "role": self.state.role.value,
                "battery": round(self.state.battery, 3),
                "location": loc.to_json() if loc else None,
                "gateway_distance": self.state.gateway_distance,
                "seq": self.state.beacon_seq,
            },
        )
        self.transport.broadcast(hello)

    def _age_neighbors(self, now: float) -> None:
        for node_id, neighbor in list(self.state.neighbors.items()):
            before = neighbor.state
            after = neighbor.age_out(now)
            if before == after:
                continue
            if after == LinkState.SUSPECT:
                self.bus.emit(
                    Event("NODE_SUSPECT", self.wall_clock(), self.node_id,
                          {"peer": node_id})
                )
            elif after == LinkState.DOWN:
                self._mark_neighbor_down(node_id)

    def _mark_neighbor_down(self, node_id: str) -> None:
        neighbor = self.state.neighbors.get(node_id)
        if neighbor is None or neighbor.down_announced:
            return
        # Ask which relay we preferred *while this peer still counted*.
        was_best_relay = self._preferred_relay() == node_id
        neighbor.state = LinkState.DOWN
        neighbor.down_announced = True
        self.bus.emit(
            Event("NODE_DOWN", self.wall_clock(), self.node_id,
                  {"peer": node_id, "last_seen_stability": round(neighbor.stability, 3)})
        )
        self.bus.emit(
            Event("LINK_DOWN", self.wall_clock(), self.node_id, {"peer": node_id})
        )
        # Self-healing. Packets are not pinned to a next hop in the normal
        # case — they are re-scored at every pump — so the meaningful question
        # is whether losing this peer actually changed our route: either our
        # path to the gateway got longer/shorter, or we were holding traffic
        # that this peer would have carried.
        before_distance = self.state.gateway_distance
        requeued = self.state.queue.requeue_next_hop(node_id)
        self._recompute_gateway_distance()

        route_changed = (
            requeued
            or before_distance != self.state.gateway_distance
            or (was_best_relay and len(self.state.queue) > 0)
        )
        if route_changed:
            self.bus.emit(
                Event("ROUTE_CHANGED", self.wall_clock(), self.node_id,
                      {"reason": "NEXT_HOP_DOWN", "peer": node_id,
                       "packets_requeued": requeued,
                       "queue_depth": len(self.state.queue),
                       "gateway_distance_before": before_distance,
                       "gateway_distance_after": self.state.gateway_distance})
            )
        self._elect_relay(exclude=node_id)
        self._pump()

    def _preferred_relay(self) -> str | None:
        """The neighbour we would hand a gateway-bound packet to right now."""
        live = self.state.live_neighbors()
        if not live:
            return None
        return max(live, key=lambda n: (self.state.relay_score(n), n.node_id)).node_id

    def _elect_relay(self, exclude: str | None = None) -> str | None:
        """Pick the best replacement relay and announce it (protocol §18)."""
        candidates = [
            n for n in self.state.live_neighbors() if n.node_id != exclude
        ]
        if not candidates:
            return None
        best = max(candidates,
                   key=lambda n: (self.state.relay_score(n), n.node_id))
        self.bus.emit(
            Event("RELAY_ELECTED", self.wall_clock(), self.node_id,
                  {"relay": best.node_id,
                   "score": round(self.state.relay_score(best), 4),
                   "replaced": exclude})
        )
        return best.node_id

    def _recompute_gateway_distance(self) -> None:
        """Distance-vector hop count to the nearest known gateway."""
        if self.state.is_gateway:
            new = 0
        else:
            distances = [
                n.gateway_distance + 1
                for n in self.state.live_neighbors()
                if n.gateway_distance is not None
            ]
            direct = [1 for n in self.state.live_neighbors()
                      if n.role is NodeRole.GATEWAY]
            candidates = distances + direct
            new = min(candidates) if candidates else None
        if new != self.state.gateway_distance:
            self.state.gateway_distance = new

    # -- introspection for the world model -------------------------------

    def snapshot(self) -> dict[str, Any]:
        """The per-node half of the network state sent in gateway/sync."""
        loc = self.state.location
        return {
            "node_id": self.node_id,
            "role": self.state.role.value,
            "battery": round(self.state.battery, 3),
            "location": loc.to_json() if loc else None,
            "neighbors": sorted(
                n.node_id for n in self.state.live_neighbors()
            ),
            "gateway_distance": self.state.gateway_distance,
            "link_stability": round(
                sum(n.stability for n in self.state.live_neighbors())
                / max(1, len(self.state.live_neighbors())), 3
            ),
            "mobility": round(self.state.mobility_mps, 3),
            "queue_depth": len(self.state.queue),
            "custody_depth": len(self.state.custody),
            "alive": self.state.alive,
        }
