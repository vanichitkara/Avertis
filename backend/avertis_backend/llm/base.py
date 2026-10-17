"""The reasoning seam.

Everything the plan assigns to Gemini goes through this interface, and there
are two implementations:

  * :class:`GeminiReasoner`        — the real thing, when credentials exist
  * :class:`DeterministicReasoner` — rules, when they do not

The second is not a mock and not a placeholder returning fake text. It is a
working implementation that produces real output from real evidence, so the
whole system runs end to end with no credentials at all. What it will not do
is *pretend* to be the model: every incident and recommendation carries
``reasoned_by``, the API reports which engine is live, and the command centre
labels it. A demo that quietly shows rule output as Gemini reasoning would be
exactly the fabrication the plan warns against (§20, §25).
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from ..models import Incident, RawReport, Recommendation, ResponderAssessment


class Reasoner(ABC):
    """What the backend needs from a reasoning engine."""

    #: Short name recorded on everything this engine produces.
    name: str = "unknown"

    #: True when this engine is a real language model.
    is_model: bool = False

    @abstractmethod
    def structure_report(self, report: RawReport) -> dict[str, Any]:
        """Turn one raw report into incident fields.

        Returns a dict with any of: type, severity, people_affected,
        description, confidence. Missing keys mean "no opinion" and the caller
        keeps its own value.
        """

    @abstractmethod
    def should_fuse(self, incident: Incident, report: RawReport) -> tuple[bool, str]:
        """Is this report describing the incident we already have?

        Returns (fuse, reason). The reason is recorded in the activity feed so
        an operator can see why two reports were merged — or were not.
        """

    @abstractmethod
    def explain_choice(
        self,
        incident: Incident,
        chosen: ResponderAssessment,
        alternatives: list[ResponderAssessment],
    ) -> str:
        """The WHY text for a recommendation (plan §25).

        Must be grounded in the assessments given. Never invent telemetry.
        """

    def summarize(self, incidents: list[Incident]) -> tuple[str, str]:
        """An operational summary, with who actually wrote it.

        Returns (text, written_by). The second value matters: a model call
        can fail and fall back to this default, and crediting the model for
        a sentence it did not write is the same misrepresentation as
        labelling any other rule output as model output.
        """
        if not incidents:
            return "No open incidents.", "deterministic"
        critical = sum(1 for i in incidents if i.severity.name == "LIFE_CRITICAL")
        return (
            f"{len(incidents)} open incident(s), {critical} life-critical.",
            "deterministic",
        )


def describe_recommendation(rec: Recommendation) -> str:
    """One-line rendering, used in the activity feed."""
    if rec.recommended_responder is None:
        return f"{rec.incident_id}: no responder can be recommended"
    return f"{rec.incident_id}: {rec.recommended_responder}"
