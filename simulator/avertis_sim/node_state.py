"""Per-node mesh state: neighbours, link quality, queues, seen-set.

Everything here is deterministic bookkeeping. No AI touches this file.
"""

from __future__ import annotations

import heapq
import itertools
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from typing import Iterator

from .protocol import Location, NodeRole, Packet, Priority

# See docs/protocol.md §9
BEACON_INTERVAL_S = 3.0
SUSPECT_AFTER_MISSED = 3
DOWN_AFTER_MISSED = 5

SEEN_CAPACITY = 4096
SEEN_TTL_S = 30 * 60
QUEUE_CAPACITY = 512


class LinkState(str):
    UP = "UP"
    SUSPECT = "SUSPECT"
    DOWN = "DOWN"


@dataclass
class Neighbor:
    """One node's view of a directly reachable peer."""

    node_id: str
    role: NodeRole = NodeRole.SURVIVOR
    battery: float = 1.0
    location: Location | None = None
    gateway_distance: int | None = None
    last_seen: float = 0.0
    last_seq: int = -1
    # EWMA of beacon delivery ratio, docs/protocol.md §8
    stability: float = 1.0
    rssi: int = -70
    state: str = LinkState.UP
    # Set once NODE_DOWN has been announced, so route recovery runs exactly
    # once per failure. Cleared when the peer comes back.
    down_announced: bool = False

    def observe_beacon(self, now: float, seq: int, alpha: float = 0.3) -> None:
        """Fold one received beacon into the link-stability estimate."""
        missed = 0
        if self.last_seq >= 0:
            missed = max(0, seq - self.last_seq - 1)
        # Each miss pulls stability down, each hit pulls it up.
        for _ in range(min(missed, 5)):
            self.stability = (1 - alpha) * self.stability
        self.stability = (1 - alpha) * self.stability + alpha * 1.0
        self.stability = max(0.0, min(1.0, self.stability))
        self.last_seq = seq
        self.last_seen = now
        self.state = LinkState.UP
        self.down_announced = False

    def age_out(self, now: float) -> str:
        """Recompute UP/SUSPECT/DOWN from silence. Returns the new state."""
        silent_for = now - self.last_seen
        missed = silent_for / BEACON_INTERVAL_S
        if missed >= DOWN_AFTER_MISSED:
            self.state = LinkState.DOWN
        elif missed >= SUSPECT_AFTER_MISSED:
            self.state = LinkState.SUSPECT
        return self.state


class SeenSet:
    """Time- and size-bounded packet-ID dedup cache (docs/protocol.md §6.1)."""

    def __init__(self, capacity: int = SEEN_CAPACITY, ttl_s: float = SEEN_TTL_S):
        self._items: OrderedDict[str, float] = OrderedDict()
        self._capacity = capacity
        self._ttl = ttl_s

    def seen(self, packet_id: str, now: float) -> bool:
        ts = self._items.get(packet_id)
        if ts is None:
            return False
        if now - ts > self._ttl:
            del self._items[packet_id]
            return False
        return True

    def add(self, packet_id: str, now: float) -> None:
        self._items[packet_id] = now
        self._items.move_to_end(packet_id)
        while len(self._items) > self._capacity:
            self._items.popitem(last=False)

    def __len__(self) -> int:
        return len(self._items)


@dataclass(order=True)
class _QueueEntry:
    sort_key: tuple[int, float, int]
    packet: Packet = field(compare=False)
    next_hop: str | None = field(default=None, compare=False)
    attempts: int = field(default=0, compare=False)
    last_attempt: float = field(default=0.0, compare=False)


class PacketQueue:
    """Priority queue: LIFE_CRITICAL first, then oldest-first within a class.

    Overflow drops the lowest-priority, oldest packet (docs/protocol.md §8).
    """

    def __init__(self, capacity: int = QUEUE_CAPACITY):
        self._heap: list[_QueueEntry] = []
        self._capacity = capacity
        self._counter = itertools.count()
        self._ids: set[str] = set()

    def push(self, packet: Packet, next_hop: str | None = None) -> Packet | None:
        """Enqueue. Returns the packet evicted by overflow, if any."""
        if packet.packet_id in self._ids:
            return None
        entry = _QueueEntry(
            sort_key=(
                packet.priority.rank,
                packet.created_at.timestamp(),
                next(self._counter),
            ),
            packet=packet,
            next_hop=next_hop,
        )
        heapq.heappush(self._heap, entry)
        self._ids.add(packet.packet_id)
        if len(self._heap) > self._capacity:
            return self._evict_worst()
        return None

    def _evict_worst(self) -> Packet:
        worst = max(self._heap)
        self._heap.remove(worst)
        heapq.heapify(self._heap)
        self._ids.discard(worst.packet.packet_id)
        return worst.packet

    def pop(self) -> _QueueEntry | None:
        while self._heap:
            entry = heapq.heappop(self._heap)
            self._ids.discard(entry.packet.packet_id)
            return entry
        return None

    def peek_all(self) -> list[_QueueEntry]:
        """Snapshot in delivery order — used for critical-first gateway sync."""
        return sorted(self._heap)

    def drain(self) -> Iterator[_QueueEntry]:
        while self._heap:
            entry = heapq.heappop(self._heap)
            self._ids.discard(entry.packet.packet_id)
            yield entry

    def remove_where(self, predicate) -> list[Packet]:
        removed = [e for e in self._heap if predicate(e)]
        for e in removed:
            self._heap.remove(e)
            self._ids.discard(e.packet.packet_id)
        heapq.heapify(self._heap)
        return [e.packet for e in removed]

    def requeue_next_hop(self, failed_node: str) -> int:
        """Clear the next-hop pin on packets routed through a failed node."""
        n = 0
        for e in self._heap:
            if e.next_hop == failed_node:
                e.next_hop = None
                e.attempts = 0
                n += 1
        return n

    def __len__(self) -> int:
        return len(self._heap)


@dataclass
class CustodyEntry:
    """A report this node is responsible for until it is acknowledged.

    Store-and-forward at the *report* level rather than the packet level: the
    forwarding queue empties as soon as a frame is handed to a neighbour, but
    that is no guarantee the report ever reached a gateway. Custody is what
    survives a partition — when connectivity returns, these are retransmitted.
    """

    report_id: str
    packet: Packet
    priority: Priority
    created_at: float
    attempts: int = 0
    last_attempt: float = 0.0
    packet_ids: set = field(default_factory=set)
    acked: bool = False


@dataclass
class NodeState:
    """Everything one node knows. Mirrors docs/protocol.md §16."""

    node_id: str
    role: NodeRole = NodeRole.SURVIVOR
    battery: float = 1.0
    location: Location | None = None
    mobility_mps: float = 0.0
    alive: bool = True

    neighbors: dict[str, Neighbor] = field(default_factory=dict)
    seen: SeenSet = field(default_factory=SeenSet)
    queue: PacketQueue = field(default_factory=PacketQueue)
    beacon_seq: int = 0
    gateway_distance: int | None = None
    # Reports this node originated and still owes an end-to-end ACK for.
    custody: dict[str, CustodyEntry] = field(default_factory=dict)
    # Reports a gateway node holds for the next connectivity window.
    pending_reports: deque = field(default_factory=deque)
    delivered: list[Packet] = field(default_factory=list)

    @property
    def is_gateway(self) -> bool:
        return self.role is NodeRole.GATEWAY

    def live_neighbors(self) -> list[Neighbor]:
        return [n for n in self.neighbors.values() if n.state != LinkState.DOWN]

    def relay_score(self, neighbor: Neighbor) -> float:
        """Deterministic relay scoring baseline — docs/protocol.md §8.

        Weights live here and only here (Dart mirrors them in relay_policy.dart).
        """
        battery = neighbor.battery
        # A neighbour's own neighbour count is not directly observable; the
        # number of peers we share with it is the observable proxy.
        neighbor_count = min(_shared_degree(self, neighbor.node_id), 8) / 8
        if neighbor.gateway_distance is None:
            gateway_proximity = 0.0
        else:
            gateway_proximity = 1.0 / (1.0 + neighbor.gateway_distance)
        stability = neighbor.stability
        mobility_score = 1.0 - min(self.mobility_mps, 5.0) / 5.0
        return (
            0.30 * battery
            + 0.20 * neighbor_count
            + 0.20 * gateway_proximity
            + 0.15 * stability
            + 0.15 * mobility_score
        )


def _shared_degree(state: NodeState, neighbor_id: str) -> int:
    """Observable proxy for a neighbour's degree: how many peers we both see."""
    n = state.neighbors.get(neighbor_id)
    if n is None:
        return 0
    # In the simulator the topology layer fills this in; fall back to our own
    # degree, which is the best a real device can do without NODE_STATUS.
    return len(state.live_neighbors())
