"""Media on local disk — the default, and the right choice for development.

Not durable on Cloud Run: the container filesystem is per-instance and is
discarded on restart. `durable` is False so the API can say so rather than
implying the evidence is safe.
"""

from __future__ import annotations

import mimetypes
import pathlib

from .base import MediaStorage, StoredMedia


class LocalMediaStorage(MediaStorage):
    name = "local"
    durable = False

    def __init__(self, directory: str) -> None:
        self.directory = pathlib.Path(directory)

    def _path_for(self, media_id: str) -> pathlib.Path | None:
        matches = sorted(self.directory.glob(f"{_safe(media_id)}.*"))
        return matches[0] if matches else None

    def save(
        self,
        media_id: str,
        payload: bytes,
        *,
        content_type: str | None = None,
        filename: str | None = None,
    ) -> StoredMedia:
        self.directory.mkdir(parents=True, exist_ok=True)
        suffix = _suffix(content_type, filename)
        path = self.directory / f"{_safe(media_id)}{suffix}"
        path.write_bytes(payload)
        return StoredMedia(
            media_id=media_id,
            uri=str(path),
            bytes=len(payload),
            content_type=content_type,
        )

    def load(self, media_id: str) -> tuple[bytes, str | None] | None:
        path = self._path_for(media_id)
        if path is None or not path.exists():
            return None
        guessed, _ = mimetypes.guess_type(path.name)
        return path.read_bytes(), guessed

    def exists(self, media_id: str) -> bool:
        return self._path_for(media_id) is not None


def _safe(media_id: str) -> str:
    """Media ids come off the network, so they do not get to pick a path.

    Without this, an id of "../../etc/passwd" would write outside the media
    directory.
    """
    return "".join(c for c in media_id if c.isalnum() or c in "-_")[:128]


def _suffix(content_type: str | None, filename: str | None) -> str:
    if filename and "." in filename:
        return pathlib.Path(filename).suffix[:10]
    if content_type:
        guessed = mimetypes.guess_extension(content_type.split(";")[0].strip())
        if guessed:
            return guessed
    return ".bin"
