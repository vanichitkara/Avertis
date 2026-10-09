"""Backend configuration, resolved once at startup.

The guiding rule: the backend must run with no credentials at all. Gemini and
Firestore are upgrades, not requirements. What it must never do is run in the
degraded mode while *claiming* the full one, so the active engine is reported
by /api/v1/health and shown in the command centre.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Settings:
    api_key: str = ""
    gemini_api_key: str = ""
    gemini_model: str = "gemini-2.5-flash"
    firestore_project: str = ""
    storage_bucket: str = ""
    media_dir: str = "out/media"

    @property
    def gemini_configured(self) -> bool:
        return bool(self.gemini_api_key)

    @property
    def firestore_configured(self) -> bool:
        return bool(self.firestore_project)


def load_settings() -> Settings:
    return Settings(
        api_key=os.environ.get("AVERTIS_API_KEY", ""),
        gemini_api_key=os.environ.get("GEMINI_API_KEY", "")
        or os.environ.get("GOOGLE_API_KEY", ""),
        gemini_model=os.environ.get("GEMINI_MODEL", "gemini-2.5-flash"),
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
