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
from datetime import timedelta

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles

from .agents.coordinator import Coordinator
from .config import (
    build_media_storage,
    build_reasoner,
    build_store,
    load_settings,
)
from .models import (
    AgentActivity,
    GatewayCommand,
    GatewaySyncRequest,
    GatewaySyncResponse,
    IncidentStatus,
    MediaDescriptor,
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
media_storage = build_media_storage(settings)
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
        "media": {
            "backend": media_storage.name,
            # Says plainly whether a photo survives a restart. On Cloud Run
            # local disk does not, and an operator should not believe
            # evidence is safe when it is not.
            "durable": media_storage.durable,
        },
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

    try:
        stored = media_storage.save(
            media_id,
            payload,
            content_type=file.content_type,
            filename=file.filename,
        )
    except Exception as exc:  # noqa: BLE001
        # A storage failure loses a photo. It must not also lose the incident
        # it belongs to, so this is a clean error the client can retry.
        log.warning("could not store %s: %s", media_id, exc)
        raise HTTPException(
            status_code=503, detail="media storage unavailable"
        ) from exc

    descriptor = {
        "media_id": media_id,
        "report_id": report_id,
        "sha256": digest,
        "bytes": stored.bytes,
        "content_type": file.content_type,
        "uri": stored.uri,
        "durable": media_storage.durable,
    }
    store.put_media(media_id, descriptor)

    # Attach it to the incident this report became, so the command centre
    # can actually show it. Bytes and descriptors arrive by different
    # routes and in either order — the mesh carries the descriptor when a
    # report syncs, the bytes follow when a window is wide enough — so the
    # link has to be made whichever lands second. Without this the file is
    # stored, verified, and invisible.
    linked_to = store.incident_for_report(report_id)
    if linked_to:
        incident = store.get_incident(linked_to)
        if incident is not None:
            for evidence in incident.evidence:
                if evidence.report_id != report_id:
                    continue
                known = {m.media_id for m in evidence.media}
                if media_id not in known:
                    evidence.media.append(MediaDescriptor(
                        kind=_kind_for(file.content_type),
                        media_id=media_id,
                        sha256=digest,
                        bytes=stored.bytes,
                        inline=False,
                        uri=stored.uri,
                    ))
                    incident.updated_at = utcnow()
                    store.put_incident(incident)
                break

    return {
        "media_id": media_id,
        "uri": stored.uri,
        "attached_to": linked_to,
    }


def _kind_for(content_type: str | None) -> str:
    if not content_type:
        return "FILE"
    if content_type.startswith("image/"):
        return "IMAGE"
    if content_type.startswith("audio/"):
        return "AUDIO"
    return "FILE"


@app.get("/api/v1/media/{media_id}")
def media_fetch(media_id: str):
    """Serve a stored file back, so the command centre can show evidence.

    Read through the backend rather than handed out as a public URL: a photo
    from a disaster scene is not something to expose on a guessable link.
    """
    descriptor = store.list_media().get(media_id)
    if descriptor is None:
        raise HTTPException(status_code=404, detail="unknown media_id")

    found = media_storage.load(media_id)
    if found is None:
        # The record outlived the bytes — which is exactly what happens when
        # local disk is used on Cloud Run and the instance restarts. Say so
        # distinctly from "never existed".
        raise HTTPException(
            status_code=410,
            detail="media record exists but the stored object is gone",
        )

    payload, content_type = found
    return Response(
        content=payload,
        media_type=content_type or descriptor.get("content_type")
        or "application/octet-stream",
    )


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
    store.put_recommendation(recommendation)
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


#: The summary costs a model call, and the dashboard polls. Without a cache
#: that is one Gemini request every couple of seconds, forever, for a
#: sentence that changes only when the incidents do.
_summary_cache: dict = {
    "text": None, "at": None, "fingerprint": None, "by": None,
}
SUMMARY_TTL = timedelta(seconds=90)


@app.get("/api/v1/summary")
def summary() -> dict:
    incidents = store.list_incidents()
    # Recompute when the picture changes, or when the cached one is old.
    fingerprint = (
        len(incidents),
        tuple(sorted((i.incident_id, i.severity.value, i.status.value)
                     for i in incidents)),
    )
    now = utcnow()
    fresh = (
        _summary_cache["text"] is not None
        and _summary_cache["fingerprint"] == fingerprint
        and _summary_cache["at"] is not None
        and now - _summary_cache["at"] < SUMMARY_TTL
    )
    if not fresh:
        text, written_by = coordinator.summary()
        _summary_cache["text"] = text
        _summary_cache["by"] = written_by
        _summary_cache["at"] = now
        _summary_cache["fingerprint"] = fingerprint

    return {
        "summary": _summary_cache["text"],
        # Who wrote this sentence, which is not always the configured
        # engine: a model call that times out falls back to the rules.
        "written_by": _summary_cache["by"],
        "engine": reasoner.name,
        "generated_at": iso(_summary_cache["at"]),
    }


@app.post(
    "/api/v1/incidents/{incident_id}/dispatch",
    dependencies=[Depends(require_key)],
)
def dispatch(incident_id: str, body: dict) -> dict:
    """Record a human approving a recommendation.

    Plan §39: the system recommends, a person dispatches. Until now that
    was a sentence in the docs and a flag on the response — there was no
    way for anyone to actually approve anything, which makes the
    human-in-the-loop claim unverifiable.

    This does not send anyone anywhere. It records who approved what, so
    the decision has an owner and an audit trail.
    """
    incident = store.get_incident(incident_id)
    if incident is None:
        raise HTTPException(status_code=404, detail="unknown incident_id")

    recommendation = coordinator.recommendation_for(incident_id)
    responder = body.get("responder_id") or (
        recommendation.recommended_responder if recommendation else None
    )
    if not responder:
        raise HTTPException(
            status_code=400,
            detail="no responder to dispatch and none recommended",
        )

    approved_by = (body.get("approved_by") or "command centre").strip()[:80]

    incident.status = IncidentStatus.DISPATCHED
    incident.updated_at = utcnow()
    store.put_incident(incident)

    store.append_activity(AgentActivity(
        agent="operator",
        action="DISPATCH_APPROVED",
        detail=f"{incident_id}: {responder} approved by {approved_by}",
        incident_id=incident_id,
    ))

    return {
        "incident_id": incident_id,
        "status": incident.status.value,
        "responder_id": responder,
        "approved_by": approved_by,
        "approved_at": iso(incident.updated_at),
    }


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
