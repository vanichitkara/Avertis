"""Resilience benchmark (plan §33).

Two things are measured, and they are different questions:

1. **Mesh resilience under failure** — what fraction of critical traffic still
   gets through at 0/20/50% node loss, how long recovery takes, what it costs
   in battery. This is measured by running the same seeded world under
   increasing damage.

2. **Response quality: conventional baseline vs Avertis** — how often the
   distance-only selector dispatches a responder who cannot actually be
   communicated with. This is the differentiator, stated as a number.

Every figure is produced by running the simulator. Nothing is hardcoded, and
where a run produces an unflattering result it is reported as-is.
"""

from __future__ import annotations

import json
import statistics
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .incidents import IncidentGenerator
from .metrics import MetricsCollector
from .protocol import MessageType, NodeRole, Priority
from .responders import Responder, ResponderPool
from .responders.selection import (
    DistanceOnlySelector, NetworkAwareSelector, assess,
)
from .topology import World, WorldConfig
from .topology.partition import partition_map
from .transport.sim_transport import RadioModel


import math


def build_world(seed: int, nodes: int) -> tuple[World, ResponderPool]:
    """A standard city used by every benchmark condition."""
    cfg = WorldConfig(seed=seed, area_m=1000.0, radio=RadioModel(range_m=180.0))
    world = World(cfg)
    pool = ResponderPool()
    half = cfg.area_m / 2

    gateways, responders = 5, 10
    for i in range(gateways):
        angle = 2 * math.pi * i / gateways
        world.add_node(f"gw-{i+1:02d}", role=NodeRole.GATEWAY,
                       x=0.55 * half * math.cos(angle),
                       y=0.55 * half * math.sin(angle), battery=1.0)
    for i in range(responders):
        node_id = f"resp-{i+1:02d}"
        world.add_node(node_id, role=NodeRole.RESPONDER, battery=0.95)
        pool.add(Responder(f"Responder {chr(65 + i)}", node_id,
                           capability=["RESCUE", "MEDICAL", "FIRE",
                                       "LOGISTICS"][i % 4]))
    for i in range(max(0, nodes - gateways - responders)):
        world.add_node(f"node-{i+1:03d}", role=NodeRole.SURVIVOR)
    return world, pool


@dataclass
class ConditionResult:
    condition: str
    critical_delivery_rate: float | None
    overall_delivery_rate: float | None
    critical_latency_p50_s: float | None
    recovery_time_s: float | None
    network_coverage: float
    partitions: int
    battery_consumed_mean: float
    custody_outstanding: int

    @staticmethod
    def average(label: str, runs: list["ConditionResult"]) -> "ConditionResult":
        def mean_of(attr: str) -> float | None:
            vals = [getattr(r, attr) for r in runs
                    if getattr(r, attr) is not None]
            return statistics.mean(vals) if vals else None

        return ConditionResult(
            condition=label,
            critical_delivery_rate=mean_of("critical_delivery_rate"),
            overall_delivery_rate=mean_of("overall_delivery_rate"),
            critical_latency_p50_s=mean_of("critical_latency_p50_s"),
            recovery_time_s=mean_of("recovery_time_s"),
            network_coverage=mean_of("network_coverage") or 0.0,
            partitions=round(mean_of("partitions") or 0),
            battery_consumed_mean=mean_of("battery_consumed_mean") or 0.0,
            custody_outstanding=round(mean_of("custody_outstanding") or 0),
        )

    def to_json(self) -> dict[str, Any]:
        return dict(self.__dict__)


def run_condition(seed: int, nodes: int, kill_fraction: float,
                  kill_gateways: int = 0) -> ConditionResult:
    """One seeded run under one damage level."""
    world, _pool = build_world(seed, nodes)
    generator = IncidentGenerator(world, seed=seed + 1)
    metrics = MetricsCollector(world, label=f"seed{seed}")
    world.run_for(30)

    # Steady-state reporting before damage.
    for _ in range(6):
        generator.random_event()
        world.run_for(4)

    if kill_fraction:
        world.kill_random_nodes(kill_fraction, exclude_roles=[NodeRole.GATEWAY])
    for i in range(kill_gateways):
        gws = sorted(world.gateways())
        if gws:
            world.kill_node(gws[0], reason="MANUAL")
    world.run_for(25)

    # Reporting continues through the damage — that is the real test.
    for _ in range(10):
        generator.random_event()
        world.run_for(4)
    world.run_for(60)

    metrics.observe_reports(generator)
    b = metrics.collect(generator)
    label = f"{int(kill_fraction * 100)}% node loss"
    if kill_gateways:
        label += f" + {kill_gateways} gateway(s) lost"
    if not kill_fraction and not kill_gateways:
        label = "no failures"
    return ConditionResult(
        condition=label,
        critical_delivery_rate=b.critical_delivery_rate,
        overall_delivery_rate=b.overall_delivery_rate,
        critical_latency_p50_s=b.critical_latency_p50_s,
        recovery_time_s=b.recovery_time_s,
        network_coverage=b.network_coverage,
        partitions=b.partitions,
        battery_consumed_mean=b.battery_consumed_mean,
        custody_outstanding=b.custody_outstanding,
    )


@dataclass
class SelectorComparison:
    """How often each selector dispatches an unreachable responder."""

    trials: int = 0
    baseline_unreachable: int = 0
    avertis_unreachable: int = 0
    disagreements: int = 0
    # "Contested" decisions are the ones the differentiator is actually about:
    # the physically closest responder cannot be reached through the mesh, but
    # some other responder can. On every other decision the two selectors
    # agree, and they should.
    contested_trials: int = 0
    contested_baseline_unreachable: int = 0
    contested_avertis_unreachable: int = 0
    baseline_mean_reliability: list[float] = field(default_factory=list)
    avertis_mean_reliability: list[float] = field(default_factory=list)
    avertis_mean_extra_distance_m: list[float] = field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        return {
            "trials": self.trials,
            "baseline_dispatched_unreachable": self.baseline_unreachable,
            "avertis_dispatched_unreachable": self.avertis_unreachable,
            "disagreements": self.disagreements,
            "contested_trials": self.contested_trials,
            "contested_baseline_dispatched_unreachable":
                self.contested_baseline_unreachable,
            "contested_avertis_dispatched_unreachable":
                self.contested_avertis_unreachable,
            "baseline_mean_reliability": (
                statistics.mean(self.baseline_mean_reliability)
                if self.baseline_mean_reliability else None
            ),
            "avertis_mean_reliability": (
                statistics.mean(self.avertis_mean_reliability)
                if self.avertis_mean_reliability else None
            ),
            "avertis_mean_extra_distance_m": (
                statistics.mean(self.avertis_mean_extra_distance_m)
                if self.avertis_mean_extra_distance_m else None
            ),
        }


def run_selector_comparison(seeds: int, nodes: int,
                            kill_fraction: float = 0.20) -> SelectorComparison:
    """Damage the network, then ask both selectors to dispatch, repeatedly.

    This isolates the claim: does making the response network-aware actually
    stop us sending responders we cannot talk to?

    The damage is **regional** as well as random. Uniformly scattered failures
    barely partition a dense mesh — the network just routes around them, and
    under those conditions the naive baseline is not punished and the two
    selectors agree. Partitions come from a district going dark, which is also
    what actually happens in a disaster.
    """
    baseline, avertis = DistanceOnlySelector(), NetworkAwareSelector()
    cmp = SelectorComparison()

    for seed in range(seeds):
        world, pool = build_world(seed * 17 + 3, nodes)
        world.run_for(30)
        world.kill_random_nodes(kill_fraction,
                                exclude_roles=[NodeRole.GATEWAY,
                                               NodeRole.RESPONDER])
        # Linear damage across the field — a flooded river or a collapsed
        # road. Unlike scattered failures this actually partitions the mesh,
        # which is the only condition under which network-awareness can
        # change a dispatch decision.
        angle = world.rng.uniform(0, math.pi)
        offset = world.rng.uniform(-0.15, 0.15) * world.config.area_m
        world.kill_corridor(angle_rad=angle,
                            width_m=0.20 * world.config.area_m,
                            offset_m=offset,
                            exclude_roles=[NodeRole.RESPONDER])
        world.run_for(25)
        # Sample incident sites along the damage, where connectivity is
        # compromised, rather than in the untouched half of the map.
        nx, ny = -math.sin(angle), math.cos(angle)

        graph = world.graph()
        survivors = [
            n for n in world.nodes.values()
            if n.role is NodeRole.SURVIVOR and n.alive and n.node_id in graph
        ]
        survivors.sort(key=lambda n: abs(n.x * nx + n.y * ny - offset))
        for site in [n.node_id for n in survivors[:30]]:
            assessments = assess(world, pool, site)
            if len(assessments) < 2:
                continue
            b = baseline.select("BENCH", assessments).chosen
            a = avertis.select("BENCH", assessments).chosen
            if b is None or a is None:
                continue
            cmp.trials += 1
            cmp.baseline_unreachable += 0 if b.reachable else 1
            cmp.avertis_unreachable += 0 if a.reachable else 1
            cmp.baseline_mean_reliability.append(b.network_reliability)
            cmp.avertis_mean_reliability.append(a.network_reliability)
            if a.responder_id != b.responder_id:
                cmp.disagreements += 1
                cmp.avertis_mean_extra_distance_m.append(
                    a.distance_m - b.distance_m
                )

            # Is this a decision where network-awareness could matter at all?
            closest = min(assessments, key=lambda x: x.distance_m)
            some_reachable = any(x.reachable for x in assessments)
            if not closest.reachable and some_reachable:
                cmp.contested_trials += 1
                cmp.contested_baseline_unreachable += 0 if b.reachable else 1
                cmp.contested_avertis_unreachable += 0 if a.reachable else 1
    return cmp


def run_benchmark(nodes: int = 100, seeds: int = 5,
                  json_out: str | None = None) -> dict[str, Any]:
    conditions = [
        ("no failures", 0.0, 0),
        ("20% node loss", 0.20, 0),
        ("50% node loss", 0.50, 0),
        ("20% node loss + gateway lost", 0.20, 1),
    ]

    print(f"\nAvertis resilience benchmark — {nodes} nodes, "
          f"{seeds} seed(s) per condition")
    print("Every figure below is produced by running the simulator.\n")

    results: dict[str, Any] = {"nodes": nodes, "seeds": seeds, "conditions": []}
    header = (f"  {'condition':<32}{'crit deliv':>11}{'p50 lat':>10}"
              f"{'recovery':>10}{'coverage':>10}{'parts':>7}{'battery':>9}")
    print(header)
    print("  " + "-" * (len(header) - 2))

    for label, fraction, gateways in conditions:
        runs = [run_condition(seed, nodes, fraction, gateways)
                for seed in range(seeds)]
        avg = ConditionResult.average(label, runs)
        results["conditions"].append(avg.to_json())

        def pct(v):
            return "n/a" if v is None else f"{v:>10.1%}"

        def secs(v):
            return "n/a".rjust(9) if v is None else f"{v:>9.1f}s"

        print(f"  {label:<32}{pct(avg.critical_delivery_rate)}"
              f"{secs(avg.critical_latency_p50_s)}"
              f"{secs(avg.recovery_time_s)}"
              f"{pct(avg.network_coverage)}"
              f"{avg.partitions:>7}"
              f"{avg.battery_consumed_mean:>8.1%}")

    print("\n  Note: 'crit deliv' counts LIFE_CRITICAL reports that reached a")
    print("  gateway. Reports still held in custody are retained for retry and")
    print("  are not counted as delivered.")
    print("\n  Caveat on latency: p50 is measured only over reports that were")
    print("  delivered, so it is subject to survivorship bias — a damaged")
    print("  network can show a *lower* p50 than an intact one, because the")
    print("  slow deliveries it would have made are missing from the sample")
    print("  rather than fast. Read latency alongside the delivery rate, never")
    print("  on its own.\n")

    cmp = run_selector_comparison(seeds=max(seeds, 3), nodes=nodes)
    results["selector_comparison"] = cmp.to_json()
    c = cmp.to_json()
    print("Response selection under 30% node loss "
          f"({c['trials']} dispatch decisions)\n")
    if c["trials"]:
        print(f"  distance-only baseline dispatched an unreachable responder: "
              f"{c['baseline_dispatched_unreachable']}/{c['trials']} "
              f"({c['baseline_dispatched_unreachable'] / c['trials']:.0%})")
        print(f"  Avertis dispatched an unreachable responder:                "
              f"{c['avertis_dispatched_unreachable']}/{c['trials']} "
              f"({c['avertis_dispatched_unreachable'] / c['trials']:.0%})")
        if c["baseline_mean_reliability"] is not None:
            print(f"  mean network reliability of the chosen responder: "
                  f"baseline {c['baseline_mean_reliability']:.0%} → "
                  f"Avertis {c['avertis_mean_reliability']:.0%}")
        print(f"  the two selectors disagreed on {c['disagreements']}/"
              f"{c['trials']} decisions", end="")
        if c["avertis_mean_extra_distance_m"] is not None:
            print(f"; when they did, Avertis travelled "
                  f"{c['avertis_mean_extra_distance_m']:+.0f} m further "
                  f"on average")
        else:
            print()

        contested = c["contested_trials"]
        print(f"\n  Contested decisions — the closest responder is cut off but "
              f"another is reachable:")
        if contested:
            print(f"    {contested}/{c['trials']} decisions were contested")
            print(f"    baseline dispatched an unreachable responder: "
                  f"{c['contested_baseline_dispatched_unreachable']}/{contested} "
                  f"({c['contested_baseline_dispatched_unreachable'] / contested:.0%})")
            print(f"    Avertis  dispatched an unreachable responder: "
                  f"{c['contested_avertis_dispatched_unreachable']}/{contested} "
                  f"({c['contested_avertis_dispatched_unreachable'] / contested:.0%})")
        else:
            print("    none occurred in this run — at this node density the "
                  "mesh\n    stayed connected enough that the closest "
                  "responder was always\n    reachable. Network-awareness "
                  "costs nothing here; it only changes\n    the answer when a "
                  "partition actually isolates the nearest unit.")

        print("\n  Read this honestly: on a well-connected mesh the two "
              "selectors agree,")
        print("  and they should. The value of network-awareness is "
              "concentrated in")
        print("  the contested decisions above, not spread across every "
              "dispatch.\n")

    if json_out:
        Path(json_out).parent.mkdir(parents=True, exist_ok=True)
        Path(json_out).write_text(json.dumps(results, indent=2))
        print(f"  results written to {json_out}\n")
    return results
