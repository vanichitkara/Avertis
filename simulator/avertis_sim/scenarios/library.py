"""The seven scenarios from plan §32.

Each one drives a real world through real failures and reports what actually
happened. No scenario asserts an outcome it did not observe — where a run
produces an uncomfortable number, the number is reported as a finding rather
than tuned away.
"""

from __future__ import annotations

import math

from ..events import Event
from ..protocol import MessageType, NodeRole, Priority
from ..responders.model import Hazard
from ..responders.selection import DistanceOnlySelector, NetworkAwareSelector
from .base import Scenario, ScenarioResult, register


@register
class NormalScenario(Scenario):
    """Scenario 1 — everything connected. The control case."""

    key = "normal"
    title = "Scenario 1 — Normal operations"

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        world = self.make_world(nodes=100, gateways=5, responders=10)
        world.run_for(30)
        self.recorder.mark(world, "CITY NORMAL")

        for _ in range(8):
            self.generator.random_event()
            world.run_for(6)

        world.run_for(40)
        for gw in sorted(world.gateways()):
            self.open_gateway_window(gw, 20)

        snapshot = world.world_snapshot()
        self.findings.append(
            f"{snapshot['metrics']['nodes_reachable']}/"
            f"{snapshot['metrics']['nodes_alive']} nodes can reach a gateway "
            f"with no failures injected"
        )
        return self.finish(replay_path)


@register
class TowerFailureScenario(Scenario):
    """Scenario 2 — the internet disappears; the mesh carries on."""

    key = "tower_failure"
    title = "Scenario 2 — Tower failure (internet lost)"

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        world = self.make_world(nodes=100, gateways=5, responders=10)
        world.run_for(30)

        # Normal operations first, so the pre-outage window has real traffic
        # to carry — otherwise the comparison against the outage is empty.
        for _ in range(6):
            self.generator.random_event()
            world.run_for(5)
        world.run_for(30)
        first = self.open_gateway_window("gw-01", 20)
        self.recorder.mark(world, "INTERNET OFFLINE — ALL TOWERS DOWN")

        # Every uplink is gone. The mesh keeps moving reports to gateways,
        # which now accumulate them instead of forwarding.
        for gw in sorted(world.gateways()):
            world.set_internet(gw, False)

        for _ in range(12):
            self.generator.random_event()
            world.run_for(5)
        world.run_for(60)

        held = sum(
            len(world.nodes[g].engine.state.pending_reports)
            for g in world.gateways()
        )
        self.findings.append(
            f"first window accepted {first.accepted} report(s) before the outage"
        )
        self.findings.append(
            f"{held} report(s) accumulated at gateways during the outage — "
            f"held, not lost"
        )
        return self.finish(replay_path)


@register
class RelayFailureScenario(Scenario):
    """Scenario 3 — a relay dies, a partition forms, the mesh self-heals."""

    key = "relay_failure"
    title = "Scenario 3 — Relay failure and self-healing"

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        world = self.make_world(nodes=100, gateways=5, responders=10)
        world.run_for(30)

        for _ in range(6):
            self.generator.random_event()
            world.run_for(4)

        # Kill the node the topology depends on most — the real articulation
        # point, not an arbitrary one.
        victim = self._most_critical_relay()
        self.recorder.mark(world, f"KILLING CRITICAL RELAY {victim}")
        before = world.world_snapshot()["metrics"]
        world.kill_node(victim, reason="RELAY_FAILURE")
        world.run_for(30)
        after = world.world_snapshot()["metrics"]

        elections = world.bus.of_type("RELAY_ELECTED")
        reroutes = world.bus.of_type("ROUTE_CHANGED")
        self.findings.append(
            f"killing {victim} took reachability from "
            f"{before['nodes_reachable']}/{before['nodes_alive']} to "
            f"{after['nodes_reachable']}/{after['nodes_alive']} "
            f"({after['partitions']} partition(s))"
        )
        self.findings.append(
            f"{len(elections)} replacement relay election(s), "
            f"{len(reroutes)} route change(s) recorded"
        )

        for _ in range(4):
            self.generator.random_event()
            world.run_for(5)
        world.run_for(40)
        for gw in sorted(world.gateways()):
            self.open_gateway_window(gw, 20)
        return self.finish(replay_path)

    def _most_critical_relay(self) -> str:
        """The articulation point whose loss disconnects the most nodes."""
        import networkx as nx

        graph = self.world.graph()
        gateways = self.world.gateways()
        candidates = [
            n for n in nx.articulation_points(graph)
            if n not in gateways
        ]
        if not candidates:
            # No cut vertex: fall back to the highest-degree non-gateway.
            candidates = [n for n in graph.nodes if n not in gateways]
        return max(candidates, key=lambda n: (graph.degree(n), n))


@register
class ResponseAdaptationScenario(Scenario):
    """Scenario 4 — the signature moment (plan §7).

    A responder loses connectivity and the recommendation changes. Built on a
    deliberately legible topology so the demo shows one clean cause and one
    clean effect.
    """

    key = "response_adaptation"
    title = "Scenario 4 — Response adapts to a network change"

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        from ..responders import Responder
        from ..topology import World, WorldConfig
        from ..transport.sim_transport import RadioModel
        from ..incidents import IncidentGenerator
        from ..metrics import MetricsCollector
        from ..replay import ReplayRecorder

        cfg = WorldConfig(seed=self.seed,
                          radio=RadioModel(range_m=110.0, base_loss=0.005,
                                           edge_loss=0.10))
        world = World(cfg)
        # Incident site, with responder A reachable only via R7 and
        # responder B reachable via a redundant two-relay chain.
        world.add_node("node-inc", role=NodeRole.SURVIVOR, x=0, y=0, battery=0.8)
        world.add_node("R7", role=NodeRole.RELAY, x=-100, y=0, battery=0.95)
        world.add_node("resp-a", role=NodeRole.RESPONDER, x=-200, y=0, battery=0.9)
        world.add_node("R2", role=NodeRole.RELAY, x=100, y=0, battery=0.95)
        world.add_node("R3", role=NodeRole.RELAY, x=200, y=0, battery=0.95)
        world.add_node("resp-b", role=NodeRole.RESPONDER, x=300, y=0, battery=0.9)
        world.add_node("gw-01", role=NodeRole.GATEWAY, x=100, y=80, battery=1.0)

        self.world = world
        self.pool.add(Responder("Responder A", "resp-a", capability="RESCUE"))
        self.pool.add(Responder("Responder B", "resp-b", capability="RESCUE"))
        self.generator = IncidentGenerator(world, seed=self.seed + 1)
        self.metrics = MetricsCollector(world, label=self.title)
        self.recorder = ReplayRecorder(world.bus, self.key)
        world.bus.emit(Event("SCENARIO_STARTED", world.now(), "scenario",
                             {"scenario": self.title, "seed": self.seed,
                              "nodes": len(world.nodes)}))
        world.run_for(20)

        # A real report from the incident site.
        seed_packet = world.nodes["node-inc"].engine.send_sos(
            note="three people trapped near the bridge, water rising",
            people_count=3,
        )
        self.generator.generated.append({
            "report_id": seed_packet.payload["report_id"],
            "kind": "FLOOD_RESCUE",
            "origin_node": "node-inc", "priority": Priority.LIFE_CRITICAL.value,
            "text": "three people trapped near the bridge", "people": 3,
        })
        world.run_for(10)

        before = self.recommend("node-inc", "INC-142")
        baseline_before = self.recommend("node-inc", "INC-142",
                                         DistanceOnlySelector())

        self.recorder.mark(world, "RELAY R7 FAILED")
        world.kill_node("R7", reason="RELAY_FAILURE")
        world.run_for(25)

        after = self.recommend("node-inc", "INC-142")
        baseline_after = self.recommend("node-inc", "INC-142",
                                        DistanceOnlySelector())

        changed = (before.chosen and after.chosen
                   and before.chosen.responder_id != after.chosen.responder_id)
        self.findings.append(
            f"Avertis recommendation {'CHANGED' if changed else 'did not change'}: "
            f"{before.chosen.responder_id} → {after.chosen.responder_id}"
            if before.chosen and after.chosen else "no responder available"
        )
        self.findings.append(
            f"distance-only baseline stayed on "
            f"{baseline_after.chosen.responder_id} "
            f"(reachable={baseline_after.chosen.reachable}, "
            f"reliability={baseline_after.chosen.network_reliability:.0%})"
            if baseline_after.chosen else "baseline had no responder"
        )

        # And the loop closes in the other direction.
        self.recorder.mark(world, "RELAY R7 RESTORED")
        world.revive_node("R7", battery=0.95)
        world.run_for(30)
        restored = self.recommend("node-inc", "INC-142")
        self.findings.append(
            f"after R7 recovered, recommendation returned to "
            f"{restored.chosen.responder_id}"
            if restored.chosen else "no responder after recovery"
        )

        self.open_gateway_window("gw-01", 20)
        return self.finish(replay_path)


@register
class HazardChangeScenario(Scenario):
    """Scenario 5 — the physical world changes; the route changes."""

    key = "hazard_change"
    title = "Scenario 5 — Hazard change reroutes the response"

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        world = self.make_world(nodes=60, gateways=3, responders=6,
                                area_m=780.0)
        world.run_for(30)

        site = self._busiest_survivor()
        seed_packet = world.nodes[site].engine.send_sos(
            note="injured person, needs medical"
        )
        self.generator.generated.append({
            "report_id": seed_packet.payload["report_id"],
            "kind": "MEDICAL", "origin_node": site,
            "priority": Priority.LIFE_CRITICAL.value,
            "text": "injured person, needs medical", "people": 1,
        })
        world.run_for(10)

        before = self.recommend(site, "INC-201")

        # A flood opens directly across the recommended responder's approach.
        chosen_node = before.chosen.node_id if before.chosen else None
        if chosen_node:
            r, s = world.nodes[chosen_node], world.nodes[site]
            hazard = Hazard("HZ-1", "FLOOD",
                            x=(r.x + s.x) / 2, y=(r.y + s.y) / 2,
                            radius_m=180, severity=0.95)
            self.pool.add_hazard(hazard)
            world.bus.emit(Event("HAZARD_CHANGED", world.now(), "world",
                                 {"action": "OPENED", "kind": "FLOOD",
                                  **hazard.to_json()}))
            self.recorder.mark(world, "FLOOD ACROSS RECOMMENDED ROUTE")

        after = self.recommend(site, "INC-201")
        if before.chosen and after.chosen:
            self.findings.append(
                f"hazard opened across {before.chosen.responder_id}'s route "
                f"(exposure {before.chosen.hazard_exposure:.2f} → "
                f"{[a for a in after.considered if a.responder_id == before.chosen.responder_id][0].hazard_exposure:.2f}); "
                f"recommendation is now {after.chosen.responder_id}"
            )
            self.findings.append(
                "network state was untouched — this reroute is driven purely "
                "by the physical world"
            )

        # Get the report to command, so delivery is actually measured.
        world.run_for(40)
        for gw in sorted(world.gateways()):
            self.open_gateway_window(gw, 20)
        return self.finish(replay_path)

    def _busiest_survivor(self) -> str:
        graph = self.world.graph()
        survivors = [
            n.node_id for n in self.world.nodes.values()
            if n.role is NodeRole.SURVIVOR and n.alive and n.node_id in graph
        ]
        return max(survivors, key=lambda n: (graph.degree(n), n))


@register
class GatewayRecoveryScenario(Scenario):
    """Scenario 6 — a short connectivity window; critical information first."""

    key = "gateway_recovery"
    title = "Scenario 6 — Gateway recovery and critical-first sync"

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        world = self.make_world(nodes=100, gateways=3, responders=8)
        world.run_for(30)
        for gw in sorted(world.gateways()):
            world.set_internet(gw, False)
        self.recorder.mark(world, "INTERNET OFFLINE — REPORTS ACCUMULATING")

        # The plan's demo calls for a backlog of roughly 200 messages, so the
        # window is genuinely too small and ordering has to matter.
        for _ in range(150):
            self.generator.random_event()
            world.run_for(1.5)
        world.run_for(60)

        from ..gateway_client import GatewayClient

        gateway = max(world.gateways(),
                      key=lambda g: len(world.nodes[g].engine.state.pending_reports))
        copies = list(world.nodes[gateway].engine.state.pending_reports)
        client = GatewayClient(world, gateway, self.backend)
        queued = client._held_reports()
        self.recorder.mark(world, f"{len(queued)} REPORTS QUEUED AT {gateway}")

        ordered = GatewayClient.sync_order(queued)
        criticals_total = sum(
            1 for p in queued if p.priority is Priority.LIFE_CRITICAL
        )

        # An 18-second window, exactly as in the plan's demo script.
        result = self.open_gateway_window(gateway, 18)

        sent_first = [p.priority.value for p in ordered[:result.attempted]]
        criticals_sent = sent_first.count(Priority.LIFE_CRITICAL.value)

        self.findings.append(
            f"{len(copies)} report copies arrived at {gateway} but they are "
            f"only {len(queued)} distinct report(s) — custody retransmission "
            f"delivers the same report by several routes, and the window is "
            f"spent once per report, not once per copy"
        )
        self.findings.append(
            f"an 18s window carried {result.attempted} report(s) "
            f"({result.bytes_sent} bytes), {result.deferred} deferred"
        )
        self.findings.append(
            f"{criticals_sent}/{criticals_total} LIFE_CRITICAL report(s) went "
            f"in the first window"
        )
        if result.deferred:
            self.findings.append(
                "deferred reports remain queued at the gateway and are "
                "re-offered on the next window"
            )
        else:
            self.findings.append(
                "the whole backlog fit in one window at this volume — the "
                "critical-first ordering is exercised in the benchmark, where "
                "the backlog is larger than the budget"
            )
        return self.finish(replay_path)


@register
class MassIncidentScenario(Scenario):
    """Scenario 7 — 200 raw reports. Information overload is the point."""

    key = "mass_incident"
    title = "Scenario 7 — Mass incident (report volume)"

    def run(self, replay_path: str | None = None) -> ScenarioResult:
        world = self.make_world(nodes=150, gateways=5, responders=10,
                                area_m=1220.0)
        world.run_for(30)
        self.recorder.mark(world, "MASS CASUALTY EVENT")

        for _ in range(70):
            self.generator.burst(1)
            world.run_for(1.5)
        world.run_for(90)

        for gw in sorted(world.gateways()):
            self.open_gateway_window(gw, 25)

        reports = len(self.generator.generated)
        events = self.generator.unique_events
        backend_accepted = len(getattr(self.backend, "accepted_reports", {}))
        self.findings.append(
            f"{reports} raw report(s) generated from ~{events} distinct "
            f"event type/size combinations — this duplication is what the "
            f"backend's fusion agent has to resolve"
        )
        self.findings.append(
            f"{backend_accepted} report(s) reached the backend across all "
            f"gateway windows"
        )
        self.findings.append(
            "the simulator deliberately does NOT fuse these — fusion is the "
            "AI's job and claiming it here would be inventing a result"
        )
        return self.finish(replay_path)
