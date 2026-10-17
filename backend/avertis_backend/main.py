"""Avertis backend — FastAPI.

Implements the frozen contract in docs/api.md. The gateway endpoint is the
one that matters: it is the only way anything reaches this service, because
during a disaster the mesh is the only thing that works.
"""

from __future__ import annotations

import hashlib
import logging
import os
import pathlib

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .agents.coordinator import Coordinator
from .config import build_reasoner, build_store, load_settings
from .models import (
    GatewayCommand,
    GatewaySyncRequest,
    GatewaySyncResponse,
    RawReport,
    RejectedReport,
    ReportOutcome,
    iso,
    utcnow,
)

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("avertis")

settings = load_settings()
reasoner = build_reasoner(settings)
store = build_store(settings)
coordinator = Coordinator(reasoner, store)

MAX_SYNC_BYTES = 2 * 1024 * 1024  # docs/api.md

app = FastAPI(
    title="Avertis Backend",
    version="1.0",
    description="Disaster-response intelligence. See docs/api.md.",
)

# The command centre is a static page served from anywhere, including file://
# during development.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def require_key(x_avertis_key: str | None = Header(default=None)) -> None:
    """Shared-key check (docs/api.md).

    Not a security claim — it keeps a demo endpoint from being wide open. When
    no key is configured the check is skipped so the service runs with no
    setup at all.
    """
    if not settings.api_key:
        return
    if x_avertis_key != settings.api_key:
        raise HTTPException(status_code=401, detail="bad or missing X-Avertis-Key")


# -- health ------------------------------------------------------------------


@app.get("/api/v1/health")
def health() -> dict:
    """Also states which engines are live, so nothing has to be assumed."""
    return {
        "status": "ok",
        "version": "1.0",
        "reasoning": {
            "engine": reasoner.name,
            "is_model": reasoner.is_model,
            # Say which of the three situations this actually is. "No key" is
            # the wrong message when a key was supplied and something else
            # stopped it working — that sends someone hunting for a missing
            # key they already set.
            "note": _reasoning_note(),
        },
        "store": store.name,
    }


def _reasoning_note() -> str:
    if reasoner.is_model:
        return "Gemini is configured and in use."
    if settings.gemini_configured:
        return (
            "GEMINI_API_KEY is set but Gemini did not start — most often "
            "because google-genai is not installed (pip install google-genai). "
            "Reasoning fell back to deterministic rules; see the server log "
            "for the exact reason."
        )
    return (
        "No GEMINI_API_KEY — reasoning with deterministic rules. Incidents "
        "and recommendations are labelled accordingly."
    )


# -- gateway -----------------------------------------------------------------


@app.post(
    "/api/v1/gateway/sync",
    response_model=GatewaySyncResponse,
    dependencies=[Depends(require_key)],
)
def gateway_sync(request: GatewaySyncRequest) -> GatewaySyncResponse:
    """Absorb one connectivity window's worth of mesh state and reports."""
    result = coordinator.ingest_sync(request)

    commands: list[GatewayCommand] = [
        GatewayCommand(type="SYNC_ACK", report_id=report_id, incident_id=incident_id)
        for report_id, incident_id, _ in result["outcomes"]
    ]

    # Ask for the bytes behind any media descriptor we have not yet received.
    held = store.list_media()
    for report in request.incidents:
        for media in report.media:
            if media.media_id not in held:
                commands.append(
                    GatewayCommand(type="REQUEST_MEDIA", media_id=media.media_id)
                )

    return GatewaySyncResponse(
        received_at=iso(utcnow()),
        accepted=result["accepted"],
        rejected=[
            RejectedReport(report_id=rid, reason=reason)
            for rid, reason in result["rejected"]
        ],
        incidents=[
            ReportOutcome(
                report_id=report_id, incident_id=incident_id, fused_into=fused
            )
            for report_id, incident_id, fused in result["outcomes"]
        ],
        commands=commands,
    )


@app.post("/api/v1/media/upload", dependencies=[Depends(require_key)])
async def media_upload(
    media_id: str = Form(...),
    report_id: str = Form(...),
    sha256: str = Form(""),
    file: UploadFile = File(...),
) -> dict:
    """Store the bytes behind a media descriptor.

    Integrity is verified rather than trusted: a photo that arrived corrupted
    over a lossy mesh should not be presented to an operator as evidence.
    """
    payload = await file.read()
    digest = hashlib.sha256(payload).hexdigest()

    if sha256 and digest != sha256:
        raise HTTPException(
            status_code=400,
            detail=f"sha256 mismatch: declared {sha256[:12]}…, got {digest[:12]}…",
        )

    directory = pathlib.Path(settings.media_dir)
    directory.mkdir(parents=True, exist_ok=True)
    suffix = pathlib.Path(file.filename or "").suffix or ".bin"
    path = directory / f"{media_id}{suffix}"
    path.write_bytes(payload)

    descriptor = {
        "media_id": media_id,
        "report_id": report_id,
        "sha256": digest,
        "bytes": len(payload),
        "content_type": file.content_type,
        "uri": str(path),
    }
    store.put_media(media_id, descriptor)
    return {"media_id": media_id, "uri": descriptor["uri"]}


@app.get("/api/v1/media/{media_id}")
def media_fetch(media_id: str):
    """Serve a stored file back, so the command centre can show evidence."""
    descriptor = store.list_media().get(media_id)
    if descriptor is None:
        raise HTTPException(status_code=404, detail="unknown media_id")
    path = pathlib.Path(descriptor["uri"])
    if not path.exists():
        raise HTTPException(status_code=410, detail="media record exists, file gone")
    return FileResponse(path, media_type=descriptor.get("content_type"))


# -- incidents ---------------------------------------------------------------


@app.post("/api/v1/incident/analyze", dependencies=[Depends(require_key)])
def incident_analyze(report: RawReport) -> dict:
    """One raw report in, one structured incident out (plan Phase 4)."""
    incident, fused = coordinator.incidents.ingest(report)
    coordinator.replan_all()
    return {
        "incident": incident.model_dump(mode="json"),
        "fused": fused,
        "reasoned_by": incident.reasoned_by,
    }


@app.get("/api/v1/incidents")
def list_incidents() -> dict:
    incidents = store.list_incidents()
    return {
        "count": len(incidents),
        "by_severity": {
            severity: sum(1 for i in incidents if i.severity.value == severity)
            for severity in
            ("LIFE_CRITICAL", "EMERGENCY", "OPERATIONAL", "NORMAL")
        },
        "incidents": [i.model_dump(mode="json") for i in incidents],
    }


@app.get("/api/v1/incidents/{incident_id}")
def get_incident(incident_id: str) -> dict:
    incident = store.get_incident(incident_id)
    if incident is None:
        raise HTTPException(status_code=404, detail="unknown incident_id")
    recommendation = coordinator.recommendation_for(incident_id)
    return {
        "incident": incident.model_dump(mode="json"),
        "recommendation": (
            recommendation.model_dump(mode="json") if recommendation else None
        ),
    }


# -- response ----------------------------------------------------------------


@app.post("/api/v1/response/recommend", dependencies=[Depends(require_key)])
def recommend(body: dict) -> dict:
    """Recommend a responder for one incident, with a WHY (plan §25)."""
    incident_id = body.get("incident_id")
    if not incident_id:
        raise HTTPException(status_code=400, detail="incident_id is required")

    incident = store.get_incident(incident_id)
    if incident is None:
        raise HTTPException(status_code=404, detail="unknown incident_id")

    recommendation = coordinator.response.recommend(
        incident, store.list_responders(), coordinator.network_view()
    )
    recommendation = coordinator.safety.review(incident, recommendation)
    coordinator._recommendations[incident_id] = recommendation
    return recommendation.model_dump(mode="json")


# -- world model and feed ----------------------------------------------------


@app.get("/api/v1/world")
def world() -> dict:
    """The combined physical + network state (plan §23)."""
    return coordinator.world()


@app.get("/api/v1/activity")
def activity(limit: int = 100) -> dict:
    return {
        "activity": [
            a.model_dump(mode="json") for a in store.list_activity(limit)
        ],
        "reasoned_by": reasoner.name,
    }


@app.get("/api/v1/summary")
def summary() -> dict:
    return {"summary": coordinator.summary(), "reasoned_by": reasoner.name}


@app.get("/api/v1/metrics")
def metrics() -> dict:
    incidents = store.list_incidents()
    view = coordinator.network_view()
    fused = sum(1 for i in incidents if i.source_count > 1)
    return {
        "incidents_total": len(incidents),
        "incidents_fused": fused,
        "reports_total": sum(i.source_count for i in incidents),
        "duplicate_reports_absorbed": sum(
            i.source_count - 1 for i in incidents if i.source_count > 1
        ),
        "network": view.summary(),
        "media_stored": len(store.list_media()),
        "reasoned_by": reasoner.name,
    }


# -- command centre ----------------------------------------------------------
#
# Served from this same service, mounted last so every /api/v1 route is
# matched first. One deployment instead of two, and because the page resolves
# its API base from location.origin there is no cross-origin request and
# nothing to configure: open the service URL and it works.
#
# Skipped silently when the directory is absent, so the backend still runs
# from a checkout that does not have it.
# In a checkout the command centre sits beside backend/. In a container it
# is wherever the image put it, so the location is overridable rather than
# assumed — guessing wrong means deploying an API with no dashboard and no
# error to say so.
_COMMAND_CENTRE = pathlib.Path(
    os.environ.get(
        "COMMAND_CENTRE_DIR",
        pathlib.Path(__file__).resolve().parent.parent.parent / "command-center",
    )
)
if _COMMAND_CENTRE.is_dir():
    app.mount(
        "/",
        StaticFiles(directory=_COMMAND_CENTRE, html=True),
        name="command-centre",
    )
    log.info("serving the command centre from %s", _COMMAND_CENTRE)
else:
    log.info("command centre not found at %s — API only", _COMMAND_CENTRE)
