"""Mesh event bus + replay log.

Every interesting thing the deterministic layer does is emitted here. The UI,
the command center and the replay system all read from this one stream, so
what the demo shows is exactly what the system did — nothing is narrated.
See docs/protocol.md §10 for the event vocabulary.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from .protocol import iso

EVENT_NAMES = {
    "NODE_JOINED", "NODE_SUSPECT", "NODE_DOWN", "NODE_RECOVERED",
    "LINK_UP", "LINK_DOWN",
    "PACKET_SENT", "PACKET_FORWARDED", "PACKET_DELIVERED", "PACKET_DROPPED",
    "QUEUE_DROP",
    "PARTITION_DETECTED", "PARTITION_HEALED",
    "RELAY_ELECTED", "ROUTE_CHANGED",
    "GATEWAY_UP", "GATEWAY_DOWN", "SYNC_STARTED", "SYNC_COMPLETED",
    # scenario-level markers, useful in the replay timeline
    "SCENARIO_STARTED", "SCENARIO_MARKER", "SCENARIO_ENDED",
    "INCIDENT_CREATED", "HAZARD_CHANGED", "RESPONDER_MOVED",
    "RESPONSE_RECOMMENDED",
}


@dataclass(slots=True)
class Event:
    event: str
    at: datetime
    node_id: str
    data: dict[str, Any] = field(default_factory=dict)
    sim_time: float = 0.0

    def to_json(self) -> dict[str, Any]:
        return {
            "event": self.event,
            "at": iso(self.at),
            "sim_time": round(self.sim_time, 3),
            "node_id": self.node_id,
            **self.data,
        }


class EventBus:
    """Fan-out plus an append-only log that is the replay file."""

    def __init__(self, clock: Callable[[], float] | None = None,
                 keep: int = 200_000):
        self._subscribers: list[Callable[[Event], None]] = []
        self.log: list[Event] = []
        self._clock = clock or (lambda: 0.0)
        self._keep = keep
        self.counts: dict[str, int] = {}

    def subscribe(self, fn: Callable[[Event], None]) -> Callable[[], None]:
        self._subscribers.append(fn)
        return lambda: self._subscribers.remove(fn)

    def emit(self, event: Event) -> None:
        if event.event not in EVENT_NAMES:
            raise ValueError(f"unknown event name: {event.event}")
        event.sim_time = self._clock()
        self.log.append(event)
        self.counts[event.event] = self.counts.get(event.event, 0) + 1
        if len(self.log) > self._keep:
            del self.log[: len(self.log) // 4]
        for fn in self._subscribers:
            fn(event)

    def of_type(self, *names: str) -> list[Event]:
        wanted = set(names)
        return [e for e in self.log if e.event in wanted]

    def write_replay(self, path: str | Path) -> Path:
        """Newline-delimited JSON — streamable by the command center."""
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("w", encoding="utf-8") as f:
            for e in self.log:
                f.write(json.dumps(e.to_json(), separators=(",", ":")) + "\n")
        return p
