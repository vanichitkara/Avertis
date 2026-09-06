"""Gateway client — the bridge from mesh to backend.

Implements the client half of `POST /api/v1/gateway/sync` (docs/api.md).
The same logic exists in Dart at mobile/lib/services/gateway_client.dart.

The interesting behaviour here is **critical-first sync under a time budget**:
a connectivity window is short, so what goes first matters.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Protocol

import httpx

from .events import Event, EventBus
from .protocol import MessageType, Packet, Priority, iso

# What one second of a *recovered but degraded* uplink carries, in bytes.
# A brief opportunistic window during a disaster is congested and shared, so
# this is deliberately conservative (~24 kbit/s) rather than nominal LTE. If
# the window is better than this, the only cost is that we under-fill it and
# catch up next window; assuming the opposite would lose reports.
ASSUMED_UPLINK_BYTES_PER_S = 3_000
MAX_SYNC_BYTES = 2 * 1024 * 1024
# Never let the topology snapshot crowd out the reports themselves.
MAX_TOPOLOGY_FRACTION = 0.35


class SyncBackend(Protocol):
    """Anything that can accept a sync body. Lets scenarios run offline."""

    def post_sync(self, body: dict[str, Any]) -> dict[str, Any]: ...


@dataclass
class InMemoryBackend:
    """Stand-in for my teammate's FastAPI service.

    Accepts everything, assigns incident IDs, and deduplicates by report_id so
    that a retransmitted report (custody retry) is not counted twice — which is
    exactly what the real backend must do.
    """

    accepted_reports: dict[str, str] = field(default_factory=dict)
    syncs: list[dict[str, Any]] = field(default_factory=list)
    _next_id: int = 1042

    def post_sync(self, body: dict[str, Any]) -> dict[str, Any]:
        self.syncs.append(body)
        accepted, incidents = [], []
        for report in body.get("incidents", []):
            rid = report["report_id"]
            if rid in self.accepted_reports:
                # Idempotent: a retry is acknowledged, not re-ingested.
                incidents.append({"report_id": rid,
                                  "incident_id": self.accepted_reports[rid],
                                  "fused_into": None})
                accepted.append(rid)
                continue
            incident_id = f"INC-{self._next_id}"
            self._next_id += 1
            self.accepted_reports[rid] = incident_id
            accepted.append(rid)
            incidents.append({"report_id": rid, "incident_id": incident_id,
                              "fused_into": None})
        return {
            "received_at": body.get("sent_at"),
            "accepted": accepted,
            "rejected": [],
            "incidents": incidents,
            "commands": [
                {"type": "SYNC_ACK", "report_id": i["report_id"],
                 "incident_id": i["incident_id"]}
                for i in incidents
            ],
        }


class HttpBackend:
    """Real backend over HTTP."""

    def __init__(self, base_url: str, api_key: str = "", timeout: float = 10.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def post_sync(self, body: dict[str, Any]) -> dict[str, Any]:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["X-Avertis-Key"] = self.api_key
        r = httpx.post(f"{self.base_url}/api/v1/gateway/sync",
                       json=body, headers=headers, timeout=self.timeout)
        r.raise_for_status()
        return r.json()

    def health(self) -> bool:
        try:
            r = httpx.get(f"{self.base_url}/api/v1/health", timeout=3.0)
            return r.status_code == 200
        except httpx.HTTPError:
            return False


@dataclass
class SyncResult:
    attempted: int
    accepted: int
    deferred: int
    bytes_sent: int
    incident_ids: list[str] = field(default_factory=list)
    error: str | None = None


class GatewayClient:
    """Drains a gateway node's held reports to the backend, critical first."""

    def __init__(self, world: "World", gateway_id: str,
                 backend: SyncBackend, bus: EventBus | None = None):
        self.world = world
        self.gateway_id = gateway_id
        self.backend = backend
        self.bus = bus or world.bus
        self.synced_report_ids: set[str] = set()

    # -- ordering -------------------------------------------------------

    def _held_reports(self) -> list[Packet]:
        """Reports the gateway holds, one copy per report.

        Custody retransmissions mean the same report can arrive several times
        by different routes. Each copy is a legitimate packet, but they are one
        report — sending all of them would spend a scarce connectivity window
        on duplicates. The earliest copy wins, and its hop count is the one
        that actually got through first.
        """
        node = self.world.nodes[self.gateway_id]
        unique: dict[str, Packet] = {}
        for packet in node.engine.state.pending_reports:
            report_id = packet.payload.get("report_id")
            if report_id is None:
                continue
            existing = unique.get(report_id)
            if existing is None or packet.created_at < existing.created_at:
                unique[report_id] = packet
        return list(unique.values())

    @staticmethod
    def sync_order(packets: list[Packet]) -> list[Packet]:
        """LIFE_CRITICAL first, then oldest first (docs/protocol.md §4)."""
        return sorted(packets,
                      key=lambda p: (p.priority.rank, p.created_at))

    def _report_body(self, packet: Packet) -> dict[str, Any]:
        p = packet.payload
        return {
            "report_id": p.get("report_id"),
            "origin_node": packet.origin_node,
            "created_at": iso(packet.created_at),
            "priority": packet.priority.value,
            "kind": "SOS" if packet.message_type is MessageType.SOS else "REPORT",
            "location": p.get("location"),
            "text": p.get("text") or p.get("note"),
            "transcript": p.get("transcript"),
            "media": p.get("media", []),
            "hop_count": packet.hop_count,
            "path": list(packet.path),
        }

    # -- the sync itself -------------------------------------------------

    def sync(self, window_seconds: float) -> SyncResult:
        """Spend a connectivity window. Returns what actually happened.

        The budget is real: reports that do not fit stay queued and go in the
        next window. Nothing is reported as sent that was not sent.
        """
        node = self.world.nodes[self.gateway_id]
        if not node.alive or not node.internet:
            return SyncResult(0, 0, len(self._held_reports()), 0,
                              error="NO_CONNECTIVITY")

        pending = [p for p in self._held_reports()
                   if p.payload.get("report_id") not in self.synced_report_ids]
        ordered = self.sync_order(pending)

        budget_bytes = min(int(window_seconds * ASSUMED_UPLINK_BYTES_PER_S),
                           MAX_SYNC_BYTES)
        snapshot = self.world.world_snapshot()

        # Reports come first. The topology snapshot is valuable — it is what
        # makes the response network-aware — but a life-critical report that
        # misses this window may not get another one, so topology is fitted
        # into what is left over rather than the other way round.
        body: dict[str, Any] = {
            "gateway_id": self.gateway_id,
            "sent_at": iso(self.world.now()),
            "connectivity_window_seconds": round(window_seconds, 1),
            "nodes": [],
            "links": [],
            "incidents": [],
            "messages": [],
            "metrics": snapshot["metrics"],
        }
        used = len(json.dumps(body).encode())
        report_budget = budget_bytes - int(budget_bytes * MAX_TOPOLOGY_FRACTION)
        batch: list[Packet] = []

        for packet in ordered:
            report = self._report_body(packet)
            size = len(json.dumps(report).encode())
            if used + size > report_budget and batch:
                break
            body["incidents"].append(report)
            batch.append(packet)
            used += size

        # Whatever is left goes to topology, truncated if it does not fit.
        topology_budget = budget_bytes - used
        nodes_json = json.dumps(snapshot["nodes"]).encode()
        links_json = json.dumps(snapshot["links"]).encode()
        if len(nodes_json) + len(links_json) <= topology_budget:
            body["nodes"] = snapshot["nodes"]
            body["links"] = snapshot["links"]
            used += len(nodes_json) + len(links_json)
        else:
            # Send the nodes that matter most to a response decision: the ones
            # that are unreachable or carrying a backlog.
            def priority_of(n: dict[str, Any]) -> tuple[int, int]:
                return (0 if not n.get("reachable") else 1,
                        -int(n.get("queue_depth", 0)))

            kept: list[dict[str, Any]] = []
            spent = 0
            for node_snapshot in sorted(snapshot["nodes"], key=priority_of):
                size = len(json.dumps(node_snapshot).encode())
                if spent + size > topology_budget:
                    break
                kept.append(node_snapshot)
                spent += size
            body["nodes"] = kept
            body["topology_truncated"] = True
            body["topology_total_nodes"] = len(snapshot["nodes"])
            used += spent

        self.bus.emit(
            Event("SYNC_STARTED", self.world.now(), self.gateway_id,
                  {"window_seconds": round(window_seconds, 1),
                   "queued": len(ordered),
                   "batched": len(batch),
                   "budget_bytes": budget_bytes})
        )

        if not batch:
            self.bus.emit(
                Event("SYNC_COMPLETED", self.world.now(), self.gateway_id,
                      {"accepted": 0, "deferred": len(ordered)})
            )
            return SyncResult(0, 0, len(ordered), used)

        try:
            response = self.backend.post_sync(body)
        except Exception as exc:  # noqa: BLE001 - any failure means "keep it"
            self.bus.emit(
                Event("SYNC_COMPLETED", self.world.now(), self.gateway_id,
                      {"accepted": 0, "deferred": len(ordered),
                       "error": type(exc).__name__})
            )
            return SyncResult(len(batch), 0, len(ordered), used,
                              error=str(exc))

        accepted = set(response.get("accepted", []))
        self.synced_report_ids |= accepted
        incident_ids = [i["incident_id"] for i in response.get("incidents", [])]

        # Anything acknowledged is no longer the gateway's problem.
        engine = node.engine
        engine.state.pending_reports = type(engine.state.pending_reports)(
            p for p in engine.state.pending_reports
            if p.payload.get("report_id") not in accepted
        )

        self._apply_commands(response.get("commands", []))

        self.bus.emit(
            Event("SYNC_COMPLETED", self.world.now(), self.gateway_id,
                  {"accepted": len(accepted),
                   "deferred": len(ordered) - len(batch),
                   "bytes": used,
                   "incident_ids": incident_ids[:10]})
        )
        return SyncResult(len(batch), len(accepted),
                          len(ordered) - len(batch), used, incident_ids)

    def _apply_commands(self, commands: list[dict[str, Any]]) -> None:
        """Inject backend commands back into the mesh (docs/api.md)."""
        engine = self.world.nodes[self.gateway_id].engine
        for cmd in commands:
            kind = cmd.get("type")
            if kind == "SYNC_ACK":
                continue  # already handled via `accepted`
            if kind == "BROADCAST":
                engine.originate(
                    message_type=MessageType.INCIDENT,
                    priority=Priority(cmd.get("priority", "OPERATIONAL")),
                    destination="*",
                    payload={"report_id": f"cmd-{cmd.get('text','')[:8]}",
                             "node_id": self.gateway_id,
                             "text": cmd.get("text", ""),
                             "from_command_center": True},
                )
            # Unknown command types are ignored by design (forward-compat).
