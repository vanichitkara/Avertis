"""Scenario framework.

A scenario builds a world, drives it through a scripted sequence of failures
and events, and reports what actually happened. Everything is seeded, so a
scenario is repeatable — which is what makes the benchmark defensible.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Callable

from ..events import Event
from ..gateway_client import GatewayClient, InMemoryBackend, SyncBackend
from ..incidents import IncidentGenerator
from ..metrics import BenchmarkResult, MetricsCollector
from ..protocol import Location, NodeRole
from ..replay import ReplayRecorder
from ..responders import Responder, ResponderPool
from ..responders.selection import (
    DistanceOnlySelector, NetworkAwareSelector, Recommendation, assess,
)
from ..topology import World, WorldConfig
from ..transport.sim_transport import RadioModel

SCENARIOS: dict[str, type["Scenario"]] = {}


def register(cls: type["Scenario"]) -> type["Scenario"]:
    SCENARIOS[cls.key] = cls
    return cls


def get_scenario(key: str) -> type["Scenario"]:
    if key not in SCENARIOS:
        raise KeyError(
            f"unknown scenario {key!r}; available: {', '.join(sorted(SCENARIOS))}"
        )
    return SCENARIOS[key]


@dataclass
class ScenarioResult:
    key: str
    title: str
    benchmark: BenchmarkResult
    timeline: list[tuple[str, str]]
    recommendations: list[Recommendation] = field(default_factory=list)
    findings: list[str] = field(default_factory=list)
    replay_path: str | None = None

    def render(self) -> str:
        lines = [f"\n{'=' * 68}", f"  {self.title}", f"{'=' * 68}"]
        lines.append("\nTIMELINE")
        for clock, label in self.timeline:
            lines.append(f"  {clock}  {label}")
        if self.recommendations:
            lines.append("\nRESPONSE RECOMMENDATIONS")
            for rec in self.recommendations:
                chosen = rec.chosen.responder_id if rec.chosen else "none"
                lines.append(f"  [{rec.selector}] {rec.incident_id} → {chosen}")
                lines.append(f"      WHY: {rec.why}")
        lines.append("")
        lines.append(self.benchmark.render())
        if self.findings:
            lines.append("\nFINDINGS")
            lines += [f"  • {f}" for f in self.findings]
        if self.replay_path:
            lines.append(f"\n  replay written to {self.replay_path}")
        return "\n".join(lines)


class Scenario:
    """Base class. Subclasses implement `build` and `run`."""

    key = "base"
    title = "Base scenario"
    seed = 42

    def __init__(self, seed: int | None = None,
                 backend: SyncBackend | None = None):
        self.seed = seed if seed is not None else self.seed
        self.world: World = None       # type: ignore[assignment]
        self.pool = ResponderPool()
        self.generator: IncidentGenerator = None  # type: ignore[assignment]
        self.metrics: MetricsCollector = None     # type: ignore[assignment]
        self.recorder: ReplayRecorder = None      # type: ignore[assignment]
        self.backend = backend or InMemoryBackend()
        self.recommendations: list[Recommendation] = []
        self.findings: list[str] = []

    # -- helpers available to every scenario ------------------------------

    def make_world(self, *, nodes: int = 100, gateways: int = 5,
                   responders: int = 10, area_m: float = 1000.0,
                   range_m: float = 180.0, mobile_fraction: float = 0.15
                   ) -> World:
        cfg = WorldConfig(
            seed=self.seed,
            area_m=area_m,
            radio=RadioModel(range_m=range_m),
        )
        world = World(cfg)
        half = area_m / 2

        # Gateways spread out so coverage is not trivially uniform.
        for i in range(gateways):
            angle = 2 * math.pi * i / max(gateways, 1)
            world.add_node(
                f"gw-{i+1:02d}", role=NodeRole.GATEWAY,
                x=0.55 * half * math.cos(angle),
                y=0.55 * half * math.sin(angle),
                battery=1.0, internet=False,
            )

        for i in range(responders):
            node_id = f"resp-{i+1:02d}"
            world.add_node(node_id, role=NodeRole.RESPONDER,
                           battery=0.95, speed_mps=0.0)
            self.pool.add(Responder(
                responder_id=f"Responder {chr(65 + i)}" if i < 26 else node_id,
                node_id=node_id,
                capability=["RESCUE", "MEDICAL", "FIRE", "LOGISTICS"][i % 4],
            ))

        survivors = max(0, nodes - gateways - responders)
        for i in range(survivors):
            moving = world.rng.random() < mobile_fraction
            world.add_node(
                f"node-{i+1:03d}", role=NodeRole.SURVIVOR,
                speed_mps=world.rng.uniform(0.6, 1.6) if moving else 0.0,
            )

        self.world = world
        self.generator = IncidentGenerator(world, seed=self.seed + 1)
        self.metrics = MetricsCollector(world, label=self.title)
        self.recorder = ReplayRecorder(world.bus, self.key)
        world.bus.emit(Event("SCENARIO_STARTED", world.now(), "scenario",
                             {"scenario": self.title, "seed": self.seed,
                              "nodes": len(world.nodes)}))
        return world

    def recommend(self, incident_node: str, incident_id: str,
                  selector=None) -> Recommendation:
        """Run a response recommendation and record it on the timeline."""
        selector = selector or NetworkAwareSelector()
        rec = selector.select(incident_id, assess(self.world, self.pool,
                                                  incident_node))
        self.recommendations.append(rec)
        self.world.bus.emit(Event(
            "RESPONSE_RECOMMENDED", self.world.now(), incident_node,
            {"incident_id": incident_id,
             "chosen": rec.chosen.responder_id if rec.chosen else None,
             "selector": rec.selector,
             "reason": (
                 f"{rec.chosen.network_reliability:.0%} reliability"
                 if rec.chosen else "no responder"
             ),
             "why": rec.why},
        ))
        return rec

    def open_gateway_window(self, gateway_id: str, seconds: float
                            ) -> "SyncResult":
        """Give a gateway a connectivity window and spend it."""
        self.world.set_internet(gateway_id, True, int(seconds))
        client = GatewayClient(self.world, gateway_id, self.backend)
        result = client.sync(seconds)
        self.world.run_for(seconds)
        self.world.set_internet(gateway_id, False)
        return result

    def finish(self, replay_path: str | None = None) -> ScenarioResult:
        self.world.bus.emit(Event("SCENARIO_ENDED", self.world.now(),
                                  "scenario", {}))
        self.metrics.observe_reports(self.generator)
        benchmark = self.metrics.collect(self.generator)
        path = None
        if replay_path:
            path = str(self.recorder.write(replay_path))
        return ScenarioResult(
            key=self.key, title=self.title, benchmark=benchmark,
            timeline=self.recorder.timeline(),
            recommendations=self.recommendations,
            findings=self.findings, replay_path=path,
        )

    # -- to implement ------------------------------------------------------

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        raise NotImplementedError
