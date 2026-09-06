"""Responders and hazards — the physical half of the world model."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Iterable

from ..protocol import Location


@dataclass
class Hazard:
    """A zone that makes travel through it slower and more dangerous."""

    hazard_id: str
    kind: str                # FLOOD | FIRE | DEBRIS | COLLAPSE
    x: float
    y: float
    radius_m: float
    severity: float = 0.5    # 0..1

    def contains(self, x: float, y: float) -> bool:
        return math.hypot(x - self.x, y - self.y) <= self.radius_m

    def exposure_for_segment(self, x1: float, y1: float,
                             x2: float, y2: float, samples: int = 24) -> float:
        """Fraction of a straight route that passes through this hazard,
        weighted by its severity."""
        inside = sum(
            1 for i in range(samples + 1)
            if self.contains(x1 + (x2 - x1) * i / samples,
                             y1 + (y2 - y1) * i / samples)
        )
        return (inside / (samples + 1)) * self.severity

    def to_json(self) -> dict[str, Any]:
        return {"hazard_id": self.hazard_id, "kind": self.kind,
                "x": round(self.x, 1), "y": round(self.y, 1),
                "radius_m": self.radius_m, "severity": round(self.severity, 3)}


@dataclass
class Responder:
    """A responder is also a mesh node — that is what couples the two worlds."""

    responder_id: str
    node_id: str
    capability: str = "RESCUE"   # RESCUE | MEDICAL | FIRE | LOGISTICS
    speed_mps: float = 4.0
    available: bool = True

    def to_json(self) -> dict[str, Any]:
        return {"responder_id": self.responder_id, "node_id": self.node_id,
                "capability": self.capability, "available": self.available}


@dataclass
class ResponderPool:
    responders: dict[str, Responder] = field(default_factory=dict)
    hazards: dict[str, Hazard] = field(default_factory=dict)

    def add(self, responder: Responder) -> Responder:
        self.responders[responder.responder_id] = responder
        return responder

    def add_hazard(self, hazard: Hazard) -> Hazard:
        self.hazards[hazard.hazard_id] = hazard
        return hazard

    def remove_hazard(self, hazard_id: str) -> None:
        self.hazards.pop(hazard_id, None)

    def available(self) -> list[Responder]:
        return [r for r in self.responders.values() if r.available]

    def hazard_exposure(self, x1: float, y1: float,
                        x2: float, y2: float) -> float:
        """Total severity-weighted hazard exposure along a straight route."""
        return min(1.0, sum(h.exposure_for_segment(x1, y1, x2, y2)
                            for h in self.hazards.values()))
