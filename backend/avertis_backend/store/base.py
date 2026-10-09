"""Persistence seam.

Two implementations: in-memory (default, zero setup) and Firestore (when a
project is configured). The API layer never knows which it has.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

from ..models import AgentActivity, Incident, LinkSnapshot, NodeSnapshot, Responder


class Store(ABC):
    name: str = "unknown"

    # -- incidents --
    @abstractmethod
    def put_incident(self, incident: Incident) -> None: ...

    @abstractmethod
    def get_incident(self, incident_id: str) -> Incident | None: ...

    @abstractmethod
    def list_incidents(self) -> list[Incident]: ...

    # -- report → incident mapping, for idempotent re-sync --
    @abstractmethod
    def incident_for_report(self, report_id: str) -> str | None: ...

    @abstractmethod
    def link_report(self, report_id: str, incident_id: str) -> None: ...

    # -- network state --
    @abstractmethod
    def replace_network(
        self,
        gateway_id: str,
        nodes: list[NodeSnapshot],
        links: list[LinkSnapshot],
    ) -> None:
        """Install one gateway's current view of the mesh, replacing its last.

        Replacement, not merge. Each sync carries the gateway's *whole*
        current view (docs/api.md), so a link that is absent has gone away —
        which is exactly how a dead relay is detected. Merging would leave
        failed links in the topology forever and the response would never
        re-plan.

        Scoped per gateway so that two gateways reporting different corners
        of the mesh do not erase each other.
        """

    @abstractmethod
    def list_nodes(self) -> list[NodeSnapshot]: ...

    @abstractmethod
    def list_links(self) -> list[LinkSnapshot]: ...

    # -- responders --
    @abstractmethod
    def put_responder(self, responder: Responder) -> None: ...

    @abstractmethod
    def list_responders(self) -> list[Responder]: ...

    # -- activity feed --
    @abstractmethod
    def append_activity(self, activity: AgentActivity) -> None: ...

    @abstractmethod
    def list_activity(self, limit: int = 100) -> list[AgentActivity]: ...

    # -- media --
    @abstractmethod
    def put_media(self, media_id: str, descriptor: dict) -> None: ...

    @abstractmethod
    def list_media(self) -> dict[str, dict]: ...
