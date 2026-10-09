"""Safety Agent — checks recommendations before an operator sees them.

Plan §39: Gemini recommends, humans approve. This agent is where that policy
is enforced in code rather than asserted in a slide. It does not block
anything — it attaches flags so the command centre can show *why* a
recommendation deserves scrutiny, and requires human approval for the
high-impact ones.
"""

from __future__ import annotations

from ..models import AgentActivity, Incident, Recommendation
from ..store.base import Store

# An incident the system is this unsure about should not be acted on without
# someone reading the underlying reports.
LOW_CONFIDENCE = 0.5

# Below this, dispatching means sending someone who cannot be contacted.
POOR_RELIABILITY = 0.4


class SafetyAgent:
    name = "safety"

    def __init__(self, store: Store) -> None:
        self.store = store

    def review(
        self, incident: Incident, recommendation: Recommendation
    ) -> Recommendation:
        flags: list[str] = list(recommendation.safety_flags)

        if incident.confidence < LOW_CONFIDENCE:
            flags.append("LOW_CONFIDENCE_EVIDENCE")

        if incident.location is None:
            flags.append("NO_LOCATION")

        if incident.source_count == 1:
            flags.append("SINGLE_SOURCE")

        chosen = recommendation.chosen
        if chosen is not None:
            if not chosen.reachable:
                flags.append("RECOMMENDED_RESPONDER_UNREACHABLE")
            elif chosen.network_reliability < POOR_RELIABILITY:
                flags.append("WEAK_COMMUNICATION_PATH")
            if chosen.hazard_exposure == "HIGH":
                flags.append("HIGH_HAZARD_ROUTE")
            if chosen.distance_m is None:
                flags.append("RESPONDER_POSITION_UNKNOWN")

        if incident.people_affected is None:
            flags.append("UNKNOWN_HEADCOUNT")

        recommendation.safety_flags = flags
        # Every dispatch is a human decision (plan §39). The flags say how
        # much scrutiny it needs, not whether a human is involved.
        recommendation.requires_human_approval = True

        if flags:
            self.store.append_activity(AgentActivity(
                agent=self.name,
                action="SAFETY_REVIEW",
                detail=f"{incident.incident_id}: {', '.join(flags)}",
                incident_id=incident.incident_id,
            ))

        return recommendation
