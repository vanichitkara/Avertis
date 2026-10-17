"""Incident Agent — raw reports become structured incidents, and fuse.

Two jobs, both from the plan:

  §19  turn one report into a structured incident
  §20  recognise when several reports describe the *same* event and merge them

Fusion is the one that earns its place. Twenty people reporting one collapsed
bridge should reach the operator as one incident with twenty sources, not
twenty incidents. Getting it wrong in the other direction is worse, though:
merging two separate emergencies hides one of them, so the bar for merging is
evidence, not proximity.

Confidence is computed from evidence actually present, never invented (§20).
"""

from __future__ import annotations

import itertools

from ..llm.base import Reasoner
from ..llm.deterministic import haversine_m
from ..models import (
    AgentActivity,
    Evidence,
    Incident,
    IncidentType,
    Priority,
    RawReport,
    utcnow,
)
from ..store.base import Store


class IncidentAgent:
    name = "incident"

    def __init__(self, reasoner: Reasoner, store: Store) -> None:
        self.reasoner = reasoner
        self.store = store
        # Seeded lazily from whatever is already stored, not from a fixed
        # start. With a persistent store a fresh in-memory counter would
        # reissue INC-1042 after every restart and overwrite the incident
        # already holding that id — observed destroying a life-critical
        # flood rescue, replaced by an unrelated fire, with no error.
        self._counter: itertools.count | None = None

    FIRST_ID = 1042  # the plan's example starts here

    def _seed_counter(self) -> itertools.count:
        highest = self.FIRST_ID - 1
        for incident in self.store.list_incidents():
            suffix = incident.incident_id.rsplit("-", 1)[-1]
            if suffix.isdigit():
                highest = max(highest, int(suffix))
        return itertools.count(highest + 1)

    def _next_id(self) -> str:
        if self._counter is None:
            self._counter = self._seed_counter()

        # Belt and braces: a concurrent instance may have taken the next id
        # between our seeding and now. Overwriting someone's incident is bad
        # enough to be worth the lookup.
        for _ in range(1000):
            candidate = f"INC-{next(self._counter)}"
            if self.store.get_incident(candidate) is None:
                return candidate
        raise RuntimeError("could not allocate an unused incident id")

    def ingest(self, report: RawReport) -> tuple[Incident, bool]:
        """Process one report.

        Returns (incident, was_fused). Idempotent: re-syncing a report that
        has already been seen returns the same incident without duplicating
        evidence, because a mesh retransmits in custody and the same report
        legitimately arrives more than once.
        """
        existing_id = self.store.incident_for_report(report.report_id)
        if existing_id:
            known = self.store.get_incident(existing_id)
            if known:
                return known, True

        structured = self.reasoner.structure_report(report)

        candidate = self._find_fusion_candidate(report)
        if candidate is not None:
            incident, reason = candidate
            self._merge(incident, report, structured, reason)
            self.store.put_incident(incident)
            self.store.link_report(report.report_id, incident.incident_id)
            return incident, True

        incident = self._create(report, structured)
        self.store.put_incident(incident)
        self.store.link_report(report.report_id, incident.incident_id)
        self.store.append_activity(AgentActivity(
            agent=self.name,
            action="INCIDENT_CREATED",
            detail=(
                f"{incident.type.value} / {incident.severity.value}, "
                f"confidence {incident.confidence:.0%}"
            ),
            incident_id=incident.incident_id,
            reasoned_by=incident.reasoned_by,
        ))
        return incident, False

    # -- creation ----------------------------------------------------------

    def _create(self, report: RawReport, structured: dict) -> Incident:
        return Incident(
            incident_id=self._next_id(),
            type=structured.get("type", IncidentType.UNKNOWN),
            severity=structured.get("severity", report.priority),
            people_affected=structured.get("people_affected"),
            location=report.location,
            description=structured.get("description", report.text or ""),
            evidence=[self._evidence(report)],
            confidence=structured.get("confidence", 0.2),
            created_at=report.created_at,
            updated_at=utcnow(),
            reasoned_by=structured.get("reasoned_by", self.reasoner.name),
        )

    @staticmethod
    def _evidence(report: RawReport) -> Evidence:
        text = report.text or report.transcript or ""
        return Evidence(
            report_id=report.report_id,
            origin_node=report.origin_node,
            created_at=report.created_at,
            excerpt=text[:240] if text else None,
            media=report.media,
            hop_count=report.hop_count,
        )

    # -- fusion ------------------------------------------------------------

    #: Only incidents within this radius are even considered for fusion.
    #: Generous compared with the reasoner's own threshold, because this is a
    #: cheap pre-filter — it exists to avoid asking about obviously unrelated
    #: events, not to make the decision.
    CANDIDATE_RADIUS_M = 1000.0
    CANDIDATE_WINDOW_S = 3600.0

    #: At most this many incidents are put to the reasoner for one report.
    #: With a language model each question is a network round trip, so asking
    #: about every open incident turns one report into a minutes-long stall:
    #: sixty incidents meant sixty sequential API calls. Geography narrows it
    #: to the handful that could plausibly be the same event.
    MAX_CANDIDATES = 5

    def _plausible_candidates(self, report: RawReport) -> list[Incident]:
        """Open incidents near enough in space and time to be worth asking about.

        Pure arithmetic, no model calls. Nearest first, so the most likely
        match is judged before the budget runs out.
        """
        scored: list[tuple[float, Incident]] = []

        for incident in self.store.list_incidents():
            if incident.status.value == "RESOLVED":
                continue

            newest = max((e.created_at for e in incident.evidence),
                         default=incident.created_at)
            if abs((report.created_at - newest).total_seconds()) > \
                    self.CANDIDATE_WINDOW_S:
                continue

            distance = 0.0
            if incident.location and report.location:
                distance = haversine_m(
                    incident.location.lat, incident.location.lon,
                    report.location.lat, report.location.lon,
                )
                if distance > self.CANDIDATE_RADIUS_M:
                    continue
            # An incident with no location cannot be excluded on geography,
            # so it stays a candidate and sorts last.
            elif incident.location is None or report.location is None:
                distance = self.CANDIDATE_RADIUS_M

            scored.append((distance, incident))

        scored.sort(key=lambda pair: pair[0])
        return [incident for _, incident in scored[:self.MAX_CANDIDATES]]

    def _find_fusion_candidate(
        self, report: RawReport
    ) -> tuple[Incident, str] | None:
        """The first plausible incident the reasoner agrees this belongs to."""
        for incident in self._plausible_candidates(report):
            fuse, reason = self.reasoner.should_fuse(incident, report)
            if fuse:
                return incident, reason
        return None

    def _merge(
        self, incident: Incident, report: RawReport, structured: dict, reason: str
    ) -> None:
        """Fold a report into an incident, and let it sharpen what we know."""
        incident.evidence.append(self._evidence(report))
        incident.updated_at = utcnow()

        # Severity only ever rises on new evidence. If one person says
        # "flooded street" and the next says "someone is drowning", the
        # incident is now life-critical, and nothing later should walk that
        # back on the strength of a calmer report.
        proposed = structured.get("severity")
        if proposed is not None and proposed.rank < incident.severity.rank:
            incident.severity = proposed

        # A countable detail beats no detail; disagreement keeps the larger
        # number, because under-dispatching is the more dangerous error.
        count = structured.get("people_affected")
        if count is not None:
            incident.people_affected = (
                count if incident.people_affected is None
                else max(incident.people_affected, count)
            )

        if incident.type is IncidentType.UNKNOWN:
            proposed_type = structured.get("type")
            if proposed_type and proposed_type is not IncidentType.UNKNOWN:
                incident.type = proposed_type

        # First known position wins. Averaging would need per-evidence
        # coordinates, which the Evidence record deliberately does not carry.
        if incident.location is None and report.location is not None:
            incident.location = report.location

        incident.confidence = self._fused_confidence(incident)

        self.store.append_activity(AgentActivity(
            agent=self.name,
            action="REPORTS_FUSED",
            detail=(
                f"{report.report_id} merged into {incident.incident_id} "
                f"({incident.source_count} sources): {reason}"
            ),
            incident_id=incident.incident_id,
            reasoned_by=self.reasoner.name,
        ))

    @staticmethod
    def _fused_confidence(incident: Incident) -> float:
        """Independent corroboration raises confidence, with diminishing return.

        Two people reporting the same thing is meaningfully stronger than one.
        Ten is not five times stronger than two, and must never reach
        certainty — so this saturates well below 1.0.
        """
        distinct_nodes = {e.origin_node for e in incident.evidence}
        base = incident.confidence
        bonus = min(0.3, 0.1 * (len(distinct_nodes) - 1))
        return round(min(0.95, base + bonus), 2)

    # -- prioritisation ----------------------------------------------------

    @staticmethod
    def sync_order(incidents: list[Incident]) -> list[Incident]:
        """LIFE_CRITICAL first, then oldest (docs/protocol.md §4)."""
        return sorted(incidents, key=lambda i: (i.severity.rank, i.created_at))
