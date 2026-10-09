"""In-memory store — the default.

Everything lives in dicts. That is a deliberate choice for a hackathon demo:
no emulator, no credentials, no network. The cost is that state is lost on
restart, which the command centre states plainly rather than hiding.
"""

from __future__ import annotations

import threading

from ..models import AgentActivity, Incident, LinkSnapshot, NodeSnapshot, Responder
from .base import Store


class MemoryStore(Store):
    name = "memory"

    def __init__(self) -> None:
        # The API is served by a threadpool for sync handlers, so the shared
        # dicts need a lock. Contention is irrelevant at demo scale.
        self._lock = threading.RLock()
        self._incidents: dict[str, Incident] = {}
        self._report_index: dict[str, str] = {}
        # Keyed by the gateway that reported them, so one gateway's view can
        # be replaced without erasing another's.
        self._nodes_by_gateway: dict[str, dict[str, NodeSnapshot]] = {}
        self._links_by_gateway: dict[str, dict[tuple[str, str], LinkSnapshot]] = {}
        self._responders: dict[str, Responder] = {}
        self._activity: list[AgentActivity] = []
        self._media: dict[str, dict] = {}

    def put_incident(self, incident: Incident) -> None:
        with self._lock:
            self._incidents[incident.incident_id] = incident

    def get_incident(self, incident_id: str) -> Incident | None:
        with self._lock:
            return self._incidents.get(incident_id)

    def list_incidents(self) -> list[Incident]:
        with self._lock:
            return sorted(
                self._incidents.values(),
                key=lambda i: (i.severity.rank, i.created_at),
            )

    def incident_for_report(self, report_id: str) -> str | None:
        with self._lock:
            return self._report_index.get(report_id)

    def link_report(self, report_id: str, incident_id: str) -> None:
        with self._lock:
            self._report_index[report_id] = incident_id

    def replace_network(
        self,
        gateway_id: str,
        nodes: list[NodeSnapshot],
        links: list[LinkSnapshot],
    ) -> None:
        with self._lock:
            self._nodes_by_gateway[gateway_id] = {n.node_id: n for n in nodes}
            self._links_by_gateway[gateway_id] = {
                tuple(sorted((l.a, l.b))): l for l in links
            }

    def list_nodes(self) -> list[NodeSnapshot]:
        with self._lock:
            merged: dict[str, NodeSnapshot] = {}
            for view in self._nodes_by_gateway.values():
                merged.update(view)
            return sorted(merged.values(), key=lambda n: n.node_id)

    def list_links(self) -> list[LinkSnapshot]:
        with self._lock:
            merged: dict[tuple[str, str], LinkSnapshot] = {}
            for view in self._links_by_gateway.values():
                merged.update(view)
            return list(merged.values())

    def put_responder(self, responder: Responder) -> None:
        with self._lock:
            self._responders[responder.responder_id] = responder

    def list_responders(self) -> list[Responder]:
        with self._lock:
            return sorted(self._responders.values(), key=lambda r: r.responder_id)

    def append_activity(self, activity: AgentActivity) -> None:
        with self._lock:
            self._activity.append(activity)
            # The feed is a rolling window; an operator reads the recent end.
            if len(self._activity) > 2000:
                del self._activity[:1000]

    def list_activity(self, limit: int = 100) -> list[AgentActivity]:
        with self._lock:
            return list(reversed(self._activity[-limit:]))

    def put_media(self, media_id: str, descriptor: dict) -> None:
        with self._lock:
            self._media[media_id] = descriptor

    def list_media(self) -> dict[str, dict]:
        with self._lock:
            return dict(self._media)
