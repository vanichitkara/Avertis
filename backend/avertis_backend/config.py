"""Backend configuration, resolved once at startup.

The guiding rule: the backend must run with no credentials at all. Gemini and
Firestore are upgrades, not requirements. What it must never do is run in the
degraded mode while *claiming* the full one, so the active engine is reported
by /api/v1/health and shown in the command centre.
"""

from __future__ import annotations

import logging
import os
import pathlib
from dataclasses import dataclass

log = logging.getLogger(__name__)

#: Credentials live in backend/.env, which is gitignored. Keys must never be
#: committed: this repository is going to be shared, and a key in git history
#: stays there even after it is deleted.
ENV_FILE = pathlib.Path(__file__).resolve().parent.parent / ".env"


def _load_env_file() -> None:
    """Read backend/.env into the environment, if it exists.

    Real environment variables win, so a key exported in the shell or set by
    Cloud Run overrides the file rather than being silently replaced by it.
    """
    if not ENV_FILE.exists():
        return
    try:
        from dotenv import load_dotenv

        load_dotenv(ENV_FILE, override=False)
        log.info("loaded settings from %s", ENV_FILE)
        return
    except ImportError:
        pass

    # python-dotenv is optional; a tiny parser keeps .env working without it.
    for raw in ENV_FILE.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value
    log.info("loaded settings from %s", ENV_FILE)


@dataclass(frozen=True)
class Settings:
    api_key: str = ""
    gemini_api_key: str = ""
    gemini_model: str = "gemini-3.8-flash"
    firestore_project: str = ""
    storage_bucket: str = ""
    media_dir: str = "out/media"

    @property
    def gemini_configured(self) -> bool:
        return bool(self.gemini_api_key)

    @property
    def firestore_configured(self) -> bool:
        return bool(self.firestore_project)

    @property
    def storage_configured(self) -> bool:
        return bool(self.storage_bucket)


def load_settings() -> Settings:
    _load_env_file()
    return Settings(
        api_key=os.environ.get("AVERTIS_API_KEY", ""),
        gemini_api_key=os.environ.get("GEMINI_API_KEY", "")
        or os.environ.get("GOOGLE_API_KEY", ""),
        gemini_model=os.environ.get("GEMINI_MODEL", "gemini-3.8-flash"),
        firestore_project=os.environ.get("FIRESTORE_PROJECT", ""),
        storage_bucket=os.environ.get("STORAGE_BUCKET", ""),
        media_dir=os.environ.get("AVERTIS_MEDIA_DIR", "out/media"),
    )


def build_reasoner(settings: Settings):
    """Pick the reasoning engine, announcing which one is live."""
    from .llm.deterministic import DeterministicReasoner

    if not settings.gemini_configured:
        log.info(
            "GEMINI_API_KEY not set — reasoning with deterministic rules. "
            "Incidents and recommendations will be labelled accordingly."
        )
        return DeterministicReasoner()

    try:
        from .llm.gemini import GeminiReasoner

        reasoner = GeminiReasoner(
            settings.gemini_api_key, settings.gemini_model
        )
        log.info("reasoning with %s", reasoner.name)
        return reasoner
    except ImportError:
        log.warning(
            "GEMINI_API_KEY is set but google-genai is not installed "
            "(pip install google-genai) — falling back to rules."
        )
        return DeterministicReasoner()
    except Exception as exc:  # noqa: BLE001
        log.warning("could not start Gemini (%s) — falling back to rules", exc)
        return DeterministicReasoner()


def build_store(settings: Settings):
    """Pick the persistence layer."""
    from .store.memory import MemoryStore

    if not settings.firestore_configured:
        log.info("FIRESTORE_PROJECT not set — using the in-memory store.")
        return MemoryStore()

    try:
        from .store.firestore import FirestoreStore

        store = FirestoreStore(settings.firestore_project)
        log.info("persisting to Firestore project %s", settings.firestore_project)
        return store
    except ImportError:
        log.warning(
            "FIRESTORE_PROJECT is set but google-cloud-firestore is not "
            "installed — using the in-memory store."
        )
        return MemoryStore()
    except Exception as exc:  # noqa: BLE001
        log.warning("could not reach Firestore (%s) — using memory", exc)
        return MemoryStore()


def build_media_storage(settings: Settings):
    """Pick where media bytes live, announcing whether they will survive."""
    from .storage.local import LocalMediaStorage

    if not settings.storage_configured:
        log.info(
            "STORAGE_BUCKET not set — media goes to %s on local disk. On "
            "Cloud Run that disk is per-instance and is discarded on "
            "restart.",
            settings.media_dir,
        )
        return LocalMediaStorage(settings.media_dir)

    try:
        from .storage.gcs import GcsMediaStorage

        storage = GcsMediaStorage(
            settings.storage_bucket, settings.firestore_project or None
        )
        log.info("media goes to gs://%s", settings.storage_bucket)
        return storage
    except ImportError:
        log.warning(
            "STORAGE_BUCKET is set but google-cloud-storage is not installed "
            "(pip install google-cloud-storage) — falling back to local disk."
        )
        return LocalMediaStorage(settings.media_dir)
    except Exception as exc:  # noqa: BLE001
        log.warning(
            "could not reach bucket %s (%s) — falling back to local disk",
            settings.storage_bucket, exc,
        )
        return LocalMediaStorage(settings.media_dir)
