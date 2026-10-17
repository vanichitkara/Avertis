"""Firestore-backed store.

Used only when FIRESTORE_PROJECT is set. The collection layout matches the
plan's schema so the command centre and the backend agree:

    incidents/{incident_id}
    report_index/{report_id}      -> {incident_id}
    nodes/{node_id}
    links/{a__b}
    responders/{responder_id}
    activity/{auto}
    media/{media_id}

Network state is overwritten on every sync rather than appended: the mesh
sends its whole current view, and history lives in the replay log.
"""

from __future__ import annotations

from ..models import (
    AgentActivity,
    Incident,
    LinkSnapshot,
    NodeSnapshot,
    Responder,
    utcnow,
)
from .base import Store

try:  # optional dependency; only needed when Firestore is configured
    from google.cloud.firestore_v1.base_query import FieldFilter
except ImportError:  # pragma: no cover - exercised only without the SDK
    FieldFilter = None  # type: ignore[assignment]


class FirestoreStore(Store):
    name = "firestore"

    def __init__(self, project: str) -> None:
        from google.cloud import firestore  # optional dependency

        self._db = firestore.Client(project=project)
        self.project = project

    def put_incident(self, incident: Incident) -> None:
        self._db.collection("incidents").document(incident.incident_id).set(
            incident.model_dump(mode="json")
        )

    def get_incident(self, incident_id: str) -> Incident | None:
        snap = self._db.collection("incidents").document(incident_id).get()
        return Incident(**snap.to_dict()) if snap.exists else None

    def list_incidents(self) -> list[Incident]:
        incidents = [
            Incident(**doc.to_dict())
            for doc in self._db.collection("incidents").stream()
        ]
        return sorted(incidents, key=lambda i: (i.severity.rank, i.created_at))

    def incident_for_report(self, report_id: str) -> str | None:
        snap = self._db.collection("report_index").document(report_id).get()
        return snap.to_dict().get("incident_id") if snap.exists else None

    def link_report(self, report_id: str, incident_id: str) -> None:
        self._db.collection("report_index").document(report_id).set(
            {"incident_id": incident_id}
        )

    def replace_network(
        self,
        gateway_id: str,
        nodes: list[NodeSnapshot],
        links: list[LinkSnapshot],
    ) -> None:
        # Delete this gateway's previous view, then write the new one. A link
        # that is absent from the new view has gone away, and leaving it
        # behind would hide a failed relay from the Response Agent.
        batch = self._db.batch()
        for collection in ("nodes", "links"):
            stale = (
                self._db.collection(collection)
                .where(filter=FieldFilter("reported_by", "==", gateway_id))
                .stream()
            )
            for doc in stale:
                batch.delete(doc.reference)

        stamped = utcnow()
        for node in nodes:
            batch.set(
                self._db.collection("nodes").document(node.node_id),
                {
                    **node.model_copy(
                        update={"received_at": stamped}
                    ).model_dump(mode="json"),
                    "reported_by": gateway_id,
                },
            )
        for link in links:
            key = "__".join(sorted((link.a, link.b)))
            batch.set(
                self._db.collection("links").document(key),
                {**link.model_dump(mode="json"), "reported_by": gateway_id},
            )
        batch.commit()

    def list_nodes(self) -> list[NodeSnapshot]:
        return [
            NodeSnapshot(**_strip(doc.to_dict()))
            for doc in self._db.collection("nodes").stream()
        ]

    def list_links(self) -> list[LinkSnapshot]:
        return [
            LinkSnapshot(**_strip(doc.to_dict()))
            for doc in self._db.collection("links").stream()
        ]

    def put_responder(self, responder: Responder) -> None:
        self._db.collection("responders").document(responder.responder_id).set(
            responder.model_dump(mode="json")
        )

    def list_responders(self) -> list[Responder]:
        return [
            Responder(**doc.to_dict())
            for doc in self._db.collection("responders").stream()
        ]

    def append_activity(self, activity: AgentActivity) -> None:
        self._db.collection("activity").add(activity.model_dump(mode="json"))

    def list_activity(self, limit: int = 100) -> list[AgentActivity]:
        from google.cloud import firestore

        query = (
            self._db.collection("activity")
            .order_by("at", direction=firestore.Query.DESCENDING)
            .limit(limit)
        )
        return [AgentActivity(**doc.to_dict()) for doc in query.stream()]

    def put_media(self, media_id: str, descriptor: dict) -> None:
        self._db.collection("media").document(media_id).set(descriptor)

    def list_media(self) -> dict[str, dict]:
        return {
            doc.id: doc.to_dict()
            for doc in self._db.collection("media").stream()
        }


def _strip(data: dict) -> dict:
    """Drop the bookkeeping field before building a model."""
    return {k: v for k, v in data.items() if k != "reported_by"}
