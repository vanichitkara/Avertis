"""Where media bytes actually live.

A photo of a collapsed building is evidence. On Cloud Run the container's
local disk is discarded on every restart and is not shared between instances,
so writing there means the evidence survives exactly as long as one container
does — and the incident record keeps pointing at a file that no longer exists.

Two implementations behind one interface: local disk (the default, zero
setup) and Cloud Storage (when a bucket is configured). The API layer does
not know which it has.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass(frozen=True)
class StoredMedia:
    """Where a stored object ended up."""

    media_id: str
    uri: str
    bytes: int
    content_type: str | None


class MediaStorage(ABC):
    name: str = "unknown"

    #: True when the bytes outlive the process that wrote them.
    durable: bool = False

    @abstractmethod
    def save(
        self,
        media_id: str,
        payload: bytes,
        *,
        content_type: str | None = None,
        filename: str | None = None,
    ) -> StoredMedia:
        """Persist the bytes and return where they went."""

    @abstractmethod
    def load(self, media_id: str) -> tuple[bytes, str | None] | None:
        """Read the bytes back, or None if they are gone.

        Returns (payload, content_type). "Gone" is a normal outcome, not an
        error: local files are cleared, and a bucket object can be deleted
        out from under a record that still references it.
        """

    @abstractmethod
    def exists(self, media_id: str) -> bool: ...
