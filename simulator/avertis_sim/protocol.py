"""Avertis mesh protocol — packet model and canonical encoding.

This module is the Python half of the frozen contract in docs/protocol.md.
The Dart implementation in mobile/lib/mesh/protocol/ must match it byte for
byte; docs/fixtures/ pins the expected encodings for both.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from enum import Enum
from typing import Any

PROTOCOL_VERSION = "1.0"
MAX_PATH = 16
BROADCAST = "*"
ANY_GATEWAY = "gateway"


class MessageType(str, Enum):
    HELLO = "HELLO"
    NODE_STATUS = "NODE_STATUS"
    INCIDENT = "INCIDENT"
    SOS = "SOS"
    ACK = "ACK"
    ROUTE_REQUEST = "ROUTE_REQUEST"
    ROUTE_RESPONSE = "ROUTE_RESPONSE"
    GATEWAY_AVAILABLE = "GATEWAY_AVAILABLE"
    SYNC = "SYNC"
    SYNC_ACK = "SYNC_ACK"


class Priority(str, Enum):
    LIFE_CRITICAL = "LIFE_CRITICAL"
    EMERGENCY = "EMERGENCY"
    OPERATIONAL = "OPERATIONAL"
    NORMAL = "NORMAL"

    @property
    def rank(self) -> int:
        """Lower sorts first. Used by queues and critical-first sync."""
        return _PRIORITY_RANK[self]

    @property
    def default_ttl(self) -> int:
        return _DEFAULT_TTL[self]


_PRIORITY_RANK = {
    Priority.LIFE_CRITICAL: 0,
    Priority.EMERGENCY: 1,
    Priority.OPERATIONAL: 2,
    Priority.NORMAL: 3,
}

_DEFAULT_TTL = {
    Priority.LIFE_CRITICAL: 10,
    Priority.EMERGENCY: 8,
    Priority.OPERATIONAL: 6,
    Priority.NORMAL: 4,
}


class NodeRole(str, Enum):
    SURVIVOR = "SURVIVOR"
    RESPONDER = "RESPONDER"
    RELAY = "RELAY"
    GATEWAY = "GATEWAY"


def canonical_json(obj: Any) -> bytes:
    """Canonical form used for payload hashing. See docs/protocol.md §2."""
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def payload_hash(payload: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(payload)).hexdigest()[:16]


def iso(ts: datetime) -> str:
    """ISO-8601 UTC, millisecond precision, Z suffix."""
    return (
        ts.astimezone(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def parse_iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@dataclass(frozen=True, slots=True)
class Location:
    lat: float
    lon: float
    accuracy_m: float = 10.0

    def to_json(self) -> dict[str, Any]:
        return {"lat": self.lat, "lon": self.lon, "accuracy_m": self.accuracy_m}

    @staticmethod
    def from_json(d: dict[str, Any] | None) -> "Location | None":
        if d is None:
            return None
        return Location(d["lat"], d["lon"], d.get("accuracy_m", 10.0))


@dataclass(frozen=True, slots=True)
class Packet:
    packet_id: str
    origin_node: str
    destination: str
    message_type: MessageType
    priority: Priority
    ttl: int
    hop_count: int
    created_at: datetime
    payload: dict[str, Any] = field(default_factory=dict)
    path: tuple[str, ...] = ()

    # ---- construction -------------------------------------------------

    @staticmethod
    def create(
        *,
        packet_id: str,
        origin_node: str,
        destination: str,
        message_type: MessageType,
        priority: Priority,
        created_at: datetime,
        payload: dict[str, Any] | None = None,
        ttl: int | None = None,
    ) -> "Packet":
        if message_type is MessageType.HELLO:
            ttl = 1
        return Packet(
            packet_id=packet_id,
            origin_node=origin_node,
            destination=destination,
            message_type=message_type,
            priority=priority,
            ttl=ttl if ttl is not None else priority.default_ttl,
            hop_count=0,
            created_at=created_at,
            payload=payload or {},
            path=(),
        )

    # ---- forwarding ---------------------------------------------------

    def forwarded_by(self, node_id: str) -> "Packet":
        """Return the copy a relay puts back on the wire. See protocol §6."""
        new_path = self.path + (node_id,)
        if len(new_path) > MAX_PATH:
            new_path = new_path[-MAX_PATH:]
        return replace(
            self, ttl=self.ttl - 1, hop_count=self.hop_count + 1, path=new_path
        )

    @property
    def payload_hash(self) -> str:
        return payload_hash(self.payload)

    # ---- wire format --------------------------------------------------

    def to_json(self) -> dict[str, Any]:
        return {
            "packet_id": self.packet_id,
            "origin_node": self.origin_node,
            "destination": self.destination,
            "message_type": self.message_type.value,
            "priority": self.priority.value,
            "ttl": self.ttl,
            "hop_count": self.hop_count,
            "created_at": iso(self.created_at),
            "payload_hash": self.payload_hash,
            "path": list(self.path),
            "payload": self.payload,
        }

    @staticmethod
    def from_json(d: dict[str, Any]) -> "Packet":
        return Packet(
            packet_id=d["packet_id"],
            origin_node=d["origin_node"],
            destination=d["destination"],
            message_type=MessageType(d["message_type"]),
            priority=Priority(d["priority"]),
            ttl=d["ttl"],
            hop_count=d["hop_count"],
            created_at=parse_iso(d["created_at"]),
            payload=d.get("payload", {}),
            path=tuple(d.get("path", [])),
        )

    def encode(self) -> bytes:
        return canonical_json(self.to_json())

    @staticmethod
    def decode(raw: bytes) -> "Packet":
        return Packet.from_json(json.loads(raw.decode("utf-8")))

    def integrity_ok(self, claimed_hash: str) -> bool:
        return self.payload_hash == claimed_hash
