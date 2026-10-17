"""Media in Cloud Storage.

Used when STORAGE_BUCKET is set. Objects are written under a single prefix
so the bucket can carry other things, and read back through the backend
rather than made public: a photo from a disaster scene is not something to
expose on a guessable URL.
"""

from __future__ import annotations

import logging

from .base import MediaStorage, StoredMedia
from .local import _safe, _suffix

log = logging.getLogger(__name__)

PREFIX = "media"


class GcsMediaStorage(MediaStorage):
    name = "gcs"
    durable = True

    def __init__(self, bucket: str, project: str | None = None) -> None:
        from google.cloud import storage  # optional dependency

        self._client = storage.Client(project=project) if project \
            else storage.Client()
        self._bucket = self._client.bucket(bucket)
        self.bucket_name = bucket
        self.name = f"gcs:{bucket}"

    def _blob_name(self, media_id: str, suffix: str = "") -> str:
        return f"{PREFIX}/{_safe(media_id)}{suffix}"

    def save(
        self,
        media_id: str,
        payload: bytes,
        *,
        content_type: str | None = None,
        filename: str | None = None,
    ) -> StoredMedia:
        suffix = _suffix(content_type, filename)
        blob = self._bucket.blob(self._blob_name(media_id, suffix))
        blob.upload_from_string(
            payload, content_type=content_type or "application/octet-stream"
        )
        return StoredMedia(
            media_id=media_id,
            uri=f"gs://{self.bucket_name}/{blob.name}",
            bytes=len(payload),
            content_type=content_type,
        )

    def _find(self, media_id: str):
        """Locate the object without knowing which extension it was given."""
        prefix = self._blob_name(media_id)
        for blob in self._client.list_blobs(self._bucket, prefix=prefix,
                                            max_results=5):
            return blob
        return None

    def load(self, media_id: str) -> tuple[bytes, str | None] | None:
        try:
            blob = self._find(media_id)
            if blob is None:
                return None
            return blob.download_as_bytes(), blob.content_type
        except Exception as exc:  # noqa: BLE001
            # A storage outage must not take the API down; the caller treats
            # this the same as a missing object and says so.
            log.warning("could not read %s from %s: %s",
                        media_id, self.bucket_name, exc)
            return None

    def exists(self, media_id: str) -> bool:
        try:
            return self._find(media_id) is not None
        except Exception as exc:  # noqa: BLE001
            log.warning("could not check %s: %s", media_id, exc)
            return False
