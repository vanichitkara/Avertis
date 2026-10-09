"""Gemini-backed reasoning.

Active only when credentials exist (see config.py). Every method falls back to
the deterministic engine on any failure — a model outage must degrade the
quality of reasoning, never take the incident pipeline down with it. When a
fallback happens the result is labelled ``deterministic``, so the activity
feed never shows rule output as model output.

Prompts here follow the plan's constraints: ground everything in the evidence
supplied, never invent telemetry (§25), and never invent a confidence number
(§20).
"""

from __future__ import annotations

import json
import logging
from typing import Any

from ..models import Incident, RawReport, ResponderAssessment
from .base import Reasoner
from .deterministic import DeterministicReasoner

log = logging.getLogger(__name__)

_STRUCTURE_PROMPT = """\
You are the Incident Agent of a disaster-response system. Convert one raw \
field report into structured fields.

Rules:
- Use ONLY what the report states. Never invent details.
- people_affected must be null unless the report gives a countable number.
- confidence in [0,1] reflects how much the report actually supports the \
structure, not how serious it sounds.
- severity is one of LIFE_CRITICAL, EMERGENCY, OPERATIONAL, NORMAL, and must \
not be lower than the reporter's own priority.
- type is one of FLOOD_RESCUE, STRUCTURAL_COLLAPSE, FIRE, MEDICAL, \
TRAPPED_PERSON, INFRASTRUCTURE, UNKNOWN.

Report:
  priority as sent: {priority}
  kind: {kind}
  has location: {has_location}
  text: {text}

Reply with JSON only:
{{"type": "...", "severity": "...", "people_affected": null, \
"description": "...", "confidence": 0.0}}
"""

_FUSE_PROMPT = """\
You decide whether a new field report describes an incident already known.

Merging two different emergencies hides one of them, so require real evidence \
that they are the same event. Being nearby is not enough on its own.

Known incident:
  type: {incident_type}
  description: {incident_description}
  location: {incident_location}

New report:
  text: {report_text}
  location: {report_location}
  minutes apart: {minutes_apart}
  metres apart: {metres_apart}

Reply with JSON only:
{{"fuse": true/false, "reason": "one short sentence"}}
"""

_EXPLAIN_PROMPT = """\
Explain, for a command-centre operator, why one responder was chosen.

Use ONLY the figures below. Do not invent distances, reliabilities or \
hazards. Two or three sentences, plain language, no preamble.

Incident {incident_id}: {incident_description}

Chosen: {chosen}

Alternatives considered: {alternatives}
"""


class GeminiReasoner(Reasoner):
    name = "gemini"
    is_model = True

    def __init__(self, api_key: str, model: str = "gemini-2.5-flash") -> None:
        from google import genai  # imported lazily: optional dependency

        self._client = genai.Client(api_key=api_key)
        self._model = model
        self.name = f"gemini:{model}"
        self._fallback = DeterministicReasoner()

    # -- plumbing ----------------------------------------------------------

    def _ask_json(self, prompt: str) -> dict[str, Any] | None:
        """One JSON round-trip. None on any failure, so callers can fall back."""
        try:
            response = self._client.models.generate_content(
                model=self._model,
                contents=prompt,
                config={"response_mime_type": "application/json"},
            )
            text = (response.text or "").strip()
            if not text:
                return None
            return json.loads(text)
        except json.JSONDecodeError:
            log.warning("gemini returned unparseable JSON")
            return None
        except Exception as exc:  # noqa: BLE001 - any model failure degrades
            log.warning("gemini call failed: %s", exc)
            return None

    def _ask_text(self, prompt: str) -> str | None:
        try:
            response = self._client.models.generate_content(
                model=self._model, contents=prompt
            )
            text = (response.text or "").strip()
            return text or None
        except Exception as exc:  # noqa: BLE001
            log.warning("gemini call failed: %s", exc)
            return None

    # -- Reasoner ----------------------------------------------------------

    def structure_report(self, report: RawReport) -> dict[str, Any]:
        text = " ".join(p for p in (report.text, report.transcript) if p).strip()
        if not text:
            return self._fallback.structure_report(report)

        raw = self._ask_json(_STRUCTURE_PROMPT.format(
            priority=report.priority.value,
            kind=report.kind,
            has_location=report.location is not None,
            text=text[:2000],
        ))
        if raw is None:
            return self._fallback.structure_report(report)

        # Validate against the deterministic result rather than trusting the
        # model's enums blindly: a hallucinated type would otherwise reach the
        # operator unchallenged.
        baseline = self._fallback.structure_report(report)
        out: dict[str, Any] = dict(baseline)
        out["reasoned_by"] = self.name

        from ..models import IncidentType, Priority

        if isinstance(raw.get("type"), str):
            try:
                out["type"] = IncidentType(raw["type"])
            except ValueError:
                pass
        if isinstance(raw.get("severity"), str):
            try:
                proposed = Priority(raw["severity"])
                # The reporter's own priority stays a floor, as in the rules.
                if proposed.rank <= report.priority.rank:
                    out["severity"] = proposed
            except ValueError:
                pass
        count = raw.get("people_affected")
        if isinstance(count, int) and 0 < count < 1000:
            out["people_affected"] = count
        if isinstance(raw.get("description"), str) and raw["description"].strip():
            out["description"] = raw["description"].strip()
        confidence = raw.get("confidence")
        if isinstance(confidence, (int, float)) and 0.0 <= confidence <= 1.0:
            out["confidence"] = round(float(confidence), 2)

        return out

    def should_fuse(self, incident: Incident, report: RawReport) -> tuple[bool, str]:
        from .deterministic import haversine_m

        metres = None
        if incident.location and report.location:
            metres = haversine_m(
                incident.location.lat, incident.location.lon,
                report.location.lat, report.location.lon,
            )

        newest = max((e.created_at for e in incident.evidence),
                     default=incident.created_at)
        minutes = abs((report.created_at - newest).total_seconds()) / 60.0

        raw = self._ask_json(_FUSE_PROMPT.format(
            incident_type=incident.type.value,
            incident_description=incident.description[:600],
            incident_location=_fmt_point(incident.location),
            report_text=(report.text or report.transcript or "")[:600],
            report_location=_fmt_point(report.location),
            minutes_apart=f"{minutes:.0f}",
            metres_apart="unknown" if metres is None else f"{metres:.0f}",
        ))
        if raw is None or not isinstance(raw.get("fuse"), bool):
            return self._fallback.should_fuse(incident, report)

        reason = raw.get("reason")
        return raw["fuse"], (reason if isinstance(reason, str) else "model decision")

    def explain_choice(
        self,
        incident: Incident,
        chosen: ResponderAssessment,
        alternatives: list[ResponderAssessment],
    ) -> str:
        text = self._ask_text(_EXPLAIN_PROMPT.format(
            incident_id=incident.incident_id,
            incident_description=incident.description[:600],
            chosen=_fmt_assessment(chosen),
            alternatives="; ".join(_fmt_assessment(a) for a in alternatives)
            or "none",
        ))
        if not text:
            return self._fallback.explain_choice(incident, chosen, alternatives)
        return text

    def summarize(self, incidents: list[Incident]) -> str:
        if not incidents:
            return "No open incidents."
        lines = "\n".join(
            f"- {i.incident_id} {i.severity.value} {i.type.value}: "
            f"{i.description[:120]}"
            for i in incidents[:40]
        )
        text = self._ask_text(
            "Summarise the current operational picture for a command-centre "
            "operator in two or three sentences. Use only these incidents, "
            "and do not invent figures.\n\n" + lines
        )
        return text or super().summarize(incidents)


def _fmt_point(point: Any) -> str:
    if point is None:
        return "unknown"
    return f"{point.lat:.5f},{point.lon:.5f}"


def _fmt_assessment(a: ResponderAssessment) -> str:
    distance = "unknown distance" if a.distance_m is None else f"{a.distance_m:.0f} m"
    return (
        f"{a.responder_id}: {distance}, "
        f"network reliability {a.network_reliability:.0%}, "
        f"{'reachable' if a.reachable else 'unreachable'}, "
        f"hazard {a.hazard_exposure.lower()}"
    )
