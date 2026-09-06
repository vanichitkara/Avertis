"""Replay (plan §34).

The replay file is just the event log — the same events the UI consumed live.
That is deliberate: the replay cannot drift from what happened, because it is
not a separate narrative.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterable

from ..events import Event, EventBus

# Events that belong on the human-facing timeline. The rest (per-packet
# forwarding chatter) stays in the file for analysis but is not narrated.
TIMELINE_EVENTS = {
    "SCENARIO_STARTED", "SCENARIO_MARKER", "SCENARIO_ENDED",
    "GATEWAY_UP", "GATEWAY_DOWN",
    "NODE_DOWN", "NODE_RECOVERED",
    "PARTITION_DETECTED", "PARTITION_HEALED",
    "RELAY_ELECTED", "ROUTE_CHANGED",
    "INCIDENT_CREATED", "RESPONSE_RECOMMENDED", "HAZARD_CHANGED",
    "SYNC_STARTED", "SYNC_COMPLETED",
}

_LABELS = {
    "SCENARIO_STARTED": lambda d: f"SCENARIO: {d.get('scenario', '')}",
    "SCENARIO_MARKER": lambda d: d.get("label", "marker"),
    "SCENARIO_ENDED": lambda d: "SCENARIO COMPLETE",
    "GATEWAY_DOWN": lambda d: f"GATEWAY OFFLINE ({d.get('reason', 'window closed')})",
    "GATEWAY_UP": lambda d: (
        f"GATEWAY AVAILABLE ({d['window_seconds']}s window)"
        if d.get("window_seconds") else "GATEWAY AVAILABLE"
    ),
    "NODE_DOWN": lambda d: (
        f"NODE LOST {d.get('peer') or ''} {d.get('reason', '')}".strip()
    ),
    "NODE_RECOVERED": lambda d: "NODE RECOVERED",
    "PARTITION_DETECTED": lambda d: f"PARTITION DETECTED ({d.get('partitions')} parts)",
    "PARTITION_HEALED": lambda d: "NETWORK HEALED",
    "RELAY_ELECTED": lambda d: f"RELAY MIGRATED → {d.get('relay')}",
    "ROUTE_CHANGED": lambda d: (
        f"ROUTE CHANGED ({d.get('packets_requeued', 0)} packets rerouted)"
    ),
    "INCIDENT_CREATED": lambda d: (
        f"{d.get('priority')} REPORTED ({d.get('reporters')} reporters, "
        f"{d.get('kind')})"
    ),
    "RESPONSE_RECOMMENDED": lambda d: (
        f"RESPONSE: {d.get('chosen')} ({d.get('reason', '')})"
    ),
    "HAZARD_CHANGED": lambda d: f"HAZARD {d.get('action', '')} {d.get('kind', '')}",
    "SYNC_STARTED": lambda d: (
        f"SYNC STARTED ({d.get('batched')}/{d.get('queued')} queued)"
    ),
    "SYNC_COMPLETED": lambda d: (
        f"SYNC COMPLETE ({d.get('accepted', 0)} accepted, "
        f"{d.get('deferred', 0)} deferred)"
    ),
}


class ReplayRecorder:
    def __init__(self, bus: EventBus, scenario: str):
        self.bus = bus
        self.scenario = scenario

    def mark(self, world: "World", label: str, **data: Any) -> None:
        self.bus.emit(
            Event("SCENARIO_MARKER", world.now(), "scenario",
                  {"label": label, **data})
        )

    def write(self, path: str | Path) -> Path:
        return self.bus.write_replay(path)

    def timeline(self) -> list[tuple[str, str]]:
        return render_timeline(self.bus.log)


def render_timeline(events: Iterable[Event | dict[str, Any]]
                    ) -> list[tuple[str, str]]:
    """The plan §34 view: a clock and a short line per significant moment."""
    out: list[tuple[str, str]] = []
    for e in events:
        data = e.to_json() if isinstance(e, Event) else e
        name = data["event"]
        if name not in TIMELINE_EVENTS:
            continue
        clock = data["at"][11:19]
        label = _LABELS.get(name, lambda d: name)(data)
        if out and out[-1] == (clock, label):
            continue  # collapse identical repeats within the same second
        out.append((clock, label))
    return out


def load_replay(path: str | Path) -> list[dict[str, Any]]:
    with Path(path).open(encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]
