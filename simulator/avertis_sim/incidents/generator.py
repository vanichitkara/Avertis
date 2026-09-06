"""Incident report generation.

Produces the *raw* reports a survivor would actually send. Deliberately messy
and overlapping: several people report the same event in different words, which
is what gives my teammate's fusion agent something real to fuse (plan §20).

These are inputs to the AI, not AI output. Nothing here classifies or fuses.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

from ..events import Event
from ..protocol import MessageType, NodeRole, Priority


@dataclass
class IncidentTemplate:
    """One real-world event, and the several ways people describe it."""

    kind: str
    priority: Priority
    phrasings: list[str]
    people_range: tuple[int, int] = (1, 4)


TEMPLATES = [
    IncidentTemplate(
        "FLOOD_RESCUE", Priority.LIFE_CRITICAL,
        [
            "{n} people trapped near the bridge, water is rising",
            "people trapped after the bridge collapsed",
            "bridge area flooded, {n} people need help now",
            "we are stuck on the roof near the old bridge, water everywhere",
        ],
        (2, 5),
    ),
    IncidentTemplate(
        "BUILDING_COLLAPSE", Priority.LIFE_CRITICAL,
        [
            "building came down on {n} people at the market",
            "collapse at the market, people under the rubble",
            "market building fell, we can hear someone inside",
        ],
        (1, 6),
    ),
    IncidentTemplate(
        "MEDICAL", Priority.EMERGENCY,
        [
            "elderly man unconscious, needs medical help",
            "injured person bleeding badly near the school",
            "someone is having trouble breathing here",
        ],
        (1, 1),
    ),
    IncidentTemplate(
        "ROAD_BLOCKED", Priority.OPERATIONAL,
        [
            "main road blocked by fallen tree, vehicles cannot pass",
            "road out of the area is under water, not passable",
            "debris blocking the road near the junction",
        ],
        (0, 0),
    ),
    IncidentTemplate(
        "SHELTER_STATUS", Priority.NORMAL,
        [
            "shelter at the school is nearly full",
            "we have drinking water at the community hall",
            "about forty people sheltering here, need blankets",
        ],
        (0, 0),
    ),
]


class IncidentGenerator:
    """Drives survivors to report. Seeded, so a scenario replays identically."""

    def __init__(self, world: "World", seed: int = 99):
        self.world = world
        self.rng = random.Random(seed)
        self.generated: list[dict] = []

    def _survivors(self) -> list[str]:
        return [
            n.node_id for n in self.world.nodes.values()
            if n.alive and n.role in (NodeRole.SURVIVOR, NodeRole.RELAY)
        ]

    def emit_event(self, template: IncidentTemplate, reporters: int = 1,
                   near_node: str | None = None) -> list[str]:
        """One real event reported by `reporters` different people.

        Returns the report_ids. Duplicate coverage of a single event is the
        point — it is what incident fusion has to resolve.
        """
        survivors = self._survivors()
        if not survivors:
            return []
        if near_node and near_node in survivors:
            # Pick reporters physically near the event, as would really happen.
            origin = self.world.nodes[near_node]
            survivors.sort(key=lambda n: (
                (self.world.nodes[n].x - origin.x) ** 2
                + (self.world.nodes[n].y - origin.y) ** 2
            ))
            chosen = survivors[:reporters]
        else:
            chosen = self.rng.sample(survivors, min(reporters, len(survivors)))

        people = self.rng.randint(*template.people_range)
        report_ids = []
        for node_id in chosen:
            phrasing = self.rng.choice(template.phrasings).format(n=people)
            engine = self.world.nodes[node_id].engine
            if template.priority is Priority.LIFE_CRITICAL and self.rng.random() < 0.5:
                packet = engine.send_sos(note=phrasing, people_count=people or None)
            else:
                packet = engine.send_incident(phrasing, priority=template.priority)
            report_id = packet.payload["report_id"]
            report_ids.append(report_id)
            self.generated.append({
                "report_id": report_id,
                "kind": template.kind,
                "origin_node": node_id,
                "priority": template.priority.value,
                "text": phrasing,
                "people": people,
            })
        self.world.bus.emit(
            Event("INCIDENT_CREATED", self.world.now(), chosen[0],
                  {"kind": template.kind,
                   "priority": template.priority.value,
                   "reporters": len(chosen),
                   "report_ids": report_ids})
        )
        return report_ids

    def random_event(self, reporters: int | None = None) -> list[str]:
        template = self.rng.choice(TEMPLATES)
        if reporters is None:
            # Serious events get reported by more people.
            reporters = (
                self.rng.randint(2, 4)
                if template.priority is Priority.LIFE_CRITICAL
                else self.rng.randint(1, 2)
            )
        return self.emit_event(template, reporters=reporters)

    def burst(self, events: int) -> list[str]:
        """A mass-casualty burst — plan §32 scenario 7."""
        out = []
        for _ in range(events):
            out += self.random_event()
        return out

    @property
    def unique_events(self) -> int:
        """How many *real* events were generated, vs. how many reports."""
        return len({(g["kind"], g["people"]) for g in self.generated})
