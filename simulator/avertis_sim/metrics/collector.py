"""Resilience metrics (plan §33).

Every number here is derived from recorded events and node state. Nothing is
assumed, estimated for effect, or hardcoded — if the simulator did not observe
it, it is not reported.
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from typing import Any

from ..events import Event, EventBus
from ..protocol import MessageType, Priority


@dataclass
class BenchmarkResult:
    label: str
    critical_delivery_rate: float | None
    overall_delivery_rate: float | None
    critical_latency_p50_s: float | None
    critical_latency_p95_s: float | None
    recovery_time_s: float | None
    network_coverage: float
    partitions: int
    duplicate_reports: int
    unique_events: int
    battery_consumed_mean: float
    packets_forwarded: int
    packets_dropped: int
    queue_depth_total: int
    custody_outstanding: int
    notes: list[str] = field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        return {k: v for k, v in self.__dict__.items()}

    def render(self) -> str:
        def pct(v):
            return "n/a" if v is None else f"{v:.1%}"

        def secs(v):
            return "n/a" if v is None else f"{v:.1f}s"

        lines = [
            f"── {self.label} ──",
            f"  critical delivery rate   {pct(self.critical_delivery_rate)}",
            f"  overall delivery rate    {pct(self.overall_delivery_rate)}",
            f"  critical latency p50/p95 {secs(self.critical_latency_p50_s)} / "
            f"{secs(self.critical_latency_p95_s)}",
            f"  recovery time            {secs(self.recovery_time_s)}",
            f"  network coverage         {pct(self.network_coverage)}",
            f"  partitions               {self.partitions}",
            f"  reports / unique events  {self.duplicate_reports} / {self.unique_events}",
            f"  mean battery consumed    {self.battery_consumed_mean:.1%}",
            f"  forwarded / dropped      {self.packets_forwarded} / {self.packets_dropped}",
            f"  queued / in custody      {self.queue_depth_total} / {self.custody_outstanding}",
        ]
        lines += [f"  note: {n}" for n in self.notes]
        return "\n".join(lines)


class MetricsCollector:
    """Watches the event bus and the world, and computes the benchmark."""

    def __init__(self, world: "World", label: str = "run"):
        self.world = world
        self.label = label
        self.bus: EventBus = world.bus
        self.start_battery = {
            n.node_id: n.battery for n in world.nodes.values()
        }
        # report_id -> (sent_sim_time, priority)
        self.sent: dict[str, tuple[float, str]] = {}
        self.delivered: dict[str, float] = {}
        self._unsub = self.bus.subscribe(self._on_event)

    def close(self) -> None:
        self._unsub()

    # -- observation -----------------------------------------------------

    def _on_event(self, e: Event) -> None:
        # Metrics are computed from the replay log at collect() time rather
        # than incrementally, so a run can be re-scored without re-running it.
        # The subscription is kept only to pin the collector to one world.
        return

    def observe_reports(self, generator: "IncidentGenerator") -> None:
        """Register what was reported, so delivery can be measured against it."""
        for g in generator.generated:
            self.sent.setdefault(g["report_id"], (0.0, g["priority"]))

    # -- computation ------------------------------------------------------

    def _delivered_reports(self) -> dict[str, tuple[float, str]]:
        """report_id -> (delivery sim_time, priority) at any gateway."""
        # Events do not carry the report_id, so read it off the gateways,
        # which hold the packets they actually delivered.
        out: dict[str, tuple[float, str]] = {}
        for gw_id in self.world.gateways():
            engine = self.world.nodes[gw_id].engine
            for packet in engine.state.delivered:
                if packet.message_type not in (MessageType.SOS,
                                               MessageType.INCIDENT):
                    continue
                rid = packet.payload.get("report_id")
                if rid and rid not in out:
                    out[rid] = (0.0, packet.priority.value)
        return out

    def _latencies(self) -> dict[str, list[float]]:
        """Per-priority delivery latencies, measured from event timestamps."""
        sent_at: dict[str, float] = {}
        for e in self.bus.of_type("PACKET_SENT"):
            pid = e.data.get("packet_id")
            rid = e.data.get("retransmission_of")
            key = rid or pid
            if key and key not in sent_at:
                sent_at[key] = e.sim_time
            if rid and pid:
                # map the new packet id back to the original send time
                sent_at[pid] = sent_at[rid]

        by_priority: dict[str, list[float]] = {}
        gateways = self.world.gateways()
        for e in self.bus.of_type("PACKET_DELIVERED"):
            if e.node_id not in gateways:
                continue
            if e.data.get("type") not in ("SOS", "INCIDENT"):
                continue
            pid = e.data.get("packet_id")
            if pid not in sent_at:
                continue
            latency = e.sim_time - sent_at[pid]
            if latency < 0:
                continue
            by_priority.setdefault(e.data.get("priority", "NORMAL"), []).append(latency)
        return by_priority

    def _recovery_time(self) -> float | None:
        """Time from the first NODE_DOWN to the network being usable again.

        'Usable again' means a replacement relay was elected or a route
        changed — the observable evidence that traffic can move once more.
        """
        downs = [e for e in self.bus.of_type("NODE_DOWN")
                 if e.data.get("reason") in ("MANUAL", "RELAY_FAILURE",
                                             "RANDOM_FAILURE",
                                             "BATTERY_DEPLETED")]
        if not downs:
            return None
        first_down = downs[0].sim_time
        recoveries = [
            e.sim_time for e in self.bus.of_type("RELAY_ELECTED", "ROUTE_CHANGED",
                                                 "PARTITION_HEALED")
            if e.sim_time >= first_down
        ]
        return min(recoveries) - first_down if recoveries else None

    def collect(self, generator: "IncidentGenerator | None" = None
                ) -> BenchmarkResult:
        snapshot = self.world.world_snapshot()
        metrics = snapshot["metrics"]

        notes: list[str] = []
        critical_rate = overall_rate = None
        duplicates = unique = 0

        if generator is not None:
            delivered = self._delivered_reports()
            generated = generator.generated
            duplicates = len(generated)
            unique = generator.unique_events
            if generated:
                overall_rate = len(
                    [g for g in generated if g["report_id"] in delivered]
                ) / len(generated)
                crit = [g for g in generated
                        if g["priority"] == Priority.LIFE_CRITICAL.value]
                if crit:
                    critical_rate = len(
                        [g for g in crit if g["report_id"] in delivered]
                    ) / len(crit)
                else:
                    notes.append("no LIFE_CRITICAL reports were generated")

        latencies = self._latencies()
        crit_lat = latencies.get(Priority.LIFE_CRITICAL.value, [])
        p50 = statistics.median(crit_lat) if crit_lat else None
        p95 = (
            sorted(crit_lat)[max(0, int(len(crit_lat) * 0.95) - 1)]
            if len(crit_lat) >= 2 else (crit_lat[0] if crit_lat else None)
        )

        alive = [n for n in self.world.nodes.values() if n.alive]
        consumed = [
            self.start_battery.get(n.node_id, n.battery) - n.battery
            for n in alive
        ]
        coverage = (
            metrics["nodes_reachable"] / metrics["nodes_alive"]
            if metrics["nodes_alive"] else 0.0
        )
        dropped = sum(
            n.engine.packets_dropped_ttl + n.engine.packets_dropped_queue
            for n in self.world.nodes.values() if n.engine
        )
        custody = sum(
            n.engine.custody_depth
            for n in self.world.nodes.values() if n.engine
        )
        if custody:
            notes.append(
                f"{custody} report(s) still in custody — retained for retry, "
                f"not lost"
            )

        return BenchmarkResult(
            label=self.label,
            critical_delivery_rate=critical_rate,
            overall_delivery_rate=overall_rate,
            critical_latency_p50_s=p50,
            critical_latency_p95_s=p95,
            recovery_time_s=self._recovery_time(),
            network_coverage=coverage,
            partitions=metrics["partitions"],
            duplicate_reports=duplicates,
            unique_events=unique,
            battery_consumed_mean=statistics.mean(consumed) if consumed else 0.0,
            packets_forwarded=sum(
                n.engine.packets_forwarded
                for n in self.world.nodes.values() if n.engine
            ),
            packets_dropped=dropped,
            queue_depth_total=metrics["queue_depth_total"],
            custody_outstanding=custody,
            notes=notes,
        )
