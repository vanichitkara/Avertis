"""Pydantic models for the Avertis backend.

These mirror the frozen contracts in docs/protocol.md and docs/api.md. The
field names are the wire format — if one changes here it changes for the
Dart mesh engine and the Python simulator too, so it does not change.
"""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    """ISO-8601 UTC with milliseconds and a Z suffix (docs/protocol.md §1)."""
    return dt.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


# --- enumerations -----------------------------------------------------------


class Priority(str, Enum):
    LIFE_CRITICAL = "LIFE_CRITICAL"
    EMERGENCY = "EMERGENCY"
    OPERATIONAL = "OPERATIONAL"
    NORMAL = "NORMAL"

    @property
    def rank(self) -> int:
        return _PRIORITY_RANK[self]


_PRIORITY_RANK = {
    Priority.LIFE_CRITICAL: 0,
    Priority.EMERGENCY: 1,
    Priority.OPERATIONAL: 2,
    Priority.NORMAL: 3,
}


class NodeRole(str, Enum):
    SURVIVOR = "SURVIVOR"
    RESPONDER = "RESPONDER"
    RELAY = "RELAY"
    GATEWAY = "GATEWAY"


class IncidentStatus(str, Enum):
    OPEN = "OPEN"
    DISPATCHED = "DISPATCHED"
    RESOLVED = "RESOLVED"


class IncidentType(str, Enum):
    """Deliberately few (plan §42 warns against 10+ disaster categories)."""

    FLOOD_RESCUE = "FLOOD_RESCUE"
    STRUCTURAL_COLLAPSE = "STRUCTURAL_COLLAPSE"
    FIRE = "FIRE"
    MEDICAL = "MEDICAL"
    TRAPPED_PERSON = "TRAPPED_PERSON"
    INFRASTRUCTURE = "INFRASTRUCTURE"
    UNKNOWN = "UNKNOWN"


# --- primitives -------------------------------------------------------------


class GeoPoint(BaseModel):
    lat: float
    lon: float
    accuracy_m: float | None = None


class MediaDescriptor(BaseModel):
    kind: str = "IMAGE"
    media_id: str
    sha256: str | None = None
    bytes: int = 0
    inline: bool = False
    duration_s: int | None = None
    uri: str | None = None


# --- what arrives from the mesh ---------------------------------------------


class RawReport(BaseModel):
    """One report as it left a handset (docs/api.md, `incidents[]`).

    This is *not* an incident. It is one person's account of something, which
    may duplicate, contradict or corroborate others.
    """

    report_id: str
    origin_node: str
    created_at: datetime
    priority: Priority = Priority.NORMAL
    kind: str = "REPORT"  # SOS | REPORT
    location: GeoPoint | None = None
    text: str | None = None
    transcript: str | None = None

    # Stated outright by the person who sent it (docs/protocol.md §5), as
    # opposed to anything inferred from their words. Nothing is more reliable
    # than being told, so this outranks text extraction.
    people_count: int | None = None

    media: list[MediaDescriptor] = Field(default_factory=list)
    hop_count: int = 0
    path: list[str] = Field(default_factory=list)


class NodeSnapshot(BaseModel):
    node_id: str
    role: NodeRole = NodeRole.SURVIVOR
    battery: float = 1.0
    location: GeoPoint | None = None
    neighbors: list[str] = Field(default_factory=list)
    last_seen: datetime | None = None
    gateway_distance: int | None = None
    link_stability: float = 0.0
    mobility: float = 0.0
    queue_depth: int = 0
    reachable: bool = True
    partition_id: int | None = None


class LinkSnapshot(BaseModel):
    a: str
    b: str
    stability: float = 1.0
    rssi: int | None = None


class SyncMetrics(BaseModel):
    nodes_total: int = 0
    nodes_reachable: int = 0
    partitions: int = 0
    queue_depth_total: int = 0


class GatewaySyncRequest(BaseModel):
    gateway_id: str
    sent_at: datetime | None = None
    connectivity_window_seconds: float = 0.0
    nodes: list[NodeSnapshot] = Field(default_factory=list)
    links: list[LinkSnapshot] = Field(default_factory=list)
    incidents: list[RawReport] = Field(default_factory=list)
    messages: list[dict[str, Any]] = Field(default_factory=list)
    metrics: SyncMetrics | None = None


class RejectedReport(BaseModel):
    report_id: str
    reason: str


class ReportOutcome(BaseModel):
    report_id: str
    incident_id: str
    fused_into: str | None = None


class GatewayCommand(BaseModel):
    type: str
    report_id: str | None = None
    incident_id: str | None = None
    priority: Priority | None = None
    media_id: str | None = None
    text: str | None = None


class GatewaySyncResponse(BaseModel):
    received_at: str
    accepted: list[str] = Field(default_factory=list)
    rejected: list[RejectedReport] = Field(default_factory=list)
    incidents: list[ReportOutcome] = Field(default_factory=list)
    commands: list[GatewayCommand] = Field(default_factory=list)


# --- what the backend produces ----------------------------------------------


class Evidence(BaseModel):
    """One piece of grounding for an incident.

    Every claim an incident makes should be traceable to one of these. This is
    what makes a confidence number defensible rather than decorative.
    """

    report_id: str
    origin_node: str
    created_at: datetime
    excerpt: str | None = None
    media: list[MediaDescriptor] = Field(default_factory=list)
    hop_count: int = 0


class Incident(BaseModel):
    incident_id: str
    type: IncidentType = IncidentType.UNKNOWN
    severity: Priority = Priority.NORMAL
    people_affected: int | None = None
    location: GeoPoint | None = None
    description: str = ""
    evidence: list[Evidence] = Field(default_factory=list)
    confidence: float = 0.0
    status: IncidentStatus = IncidentStatus.OPEN
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)

    # Provenance: was this reasoned about by a model, or by rules?
    reasoned_by: str = "deterministic"

    @property
    def source_count(self) -> int:
        return len(self.evidence)


class Responder(BaseModel):
    responder_id: str
    node_id: str | None = None
    capability: str = "GENERAL"
    location: GeoPoint | None = None
    available: bool = True


class ResponderAssessment(BaseModel):
    """What is actually known about sending one responder to one incident."""

    responder_id: str
    distance_m: float | None = None
    network_reliability: float = 0.0
    reachable: bool = False
    hazard_exposure: str = "UNKNOWN"
    same_partition: bool = False


class Recommendation(BaseModel):
    incident_id: str
    recommended_responder: str | None = None
    alternatives: list[ResponderAssessment] = Field(default_factory=list)
    chosen: ResponderAssessment | None = None
    why: str = ""
    requires_human_approval: bool = True
    safety_flags: list[str] = Field(default_factory=list)
    reasoned_by: str = "deterministic"
    generated_at: datetime = Field(default_factory=utcnow)


class AgentActivity(BaseModel):
    """One line of the AI activity feed (plan §28).

    The feed is a log of what the system actually did, in order. It is not
    decorative: it is how an operator sees that a recommendation changed and
    why.
    """

    at: datetime = Field(default_factory=utcnow)
    agent: str
    action: str
    detail: str = ""
    incident_id: str | None = None
    reasoned_by: str = "deterministic"
