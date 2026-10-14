"""Rule-based reasoning — the engine that runs without credentials.

This is a real implementation, not a stub. It reads the same evidence Gemini
would and produces the same shapes, using keyword extraction, geography and
time. It is weaker than a model at ambiguous language, and it says so: nothing
it produces is ever labelled as model output.

The plan explicitly wants deterministic rules for obvious cases anyway (§21),
so a good share of this would be worth keeping even with Gemini available.
"""

from __future__ import annotations

import math
import re
from typing import Any

from ..models import (
    Incident,
    IncidentType,
    Priority,
    RawReport,
    ResponderAssessment,
)
from .base import Reasoner

# Keyword → incident type. Ordered: the first match wins, so the more specific
# phrasings are listed before the general ones.
_TYPE_PATTERNS: list[tuple[IncidentType, tuple[str, ...]]] = [
    (IncidentType.FLOOD_RESCUE,
     # "water is rising" is at least as common as "water rising", and the
     # difference is two characters of natural phrasing — missing it would
     # classify an obvious flood as UNKNOWN.
     ("flood", "flooded", "water ris", "water is ris", "rising water",
      "water level", "drown", "submerg", "swept away")),
    (IncidentType.STRUCTURAL_COLLAPSE,
     ("collapse", "collapsed", "rubble", "debris", "building fell", "bridge")),
    (IncidentType.FIRE, ("fire", "burning", "smoke", "blaze")),
    (IncidentType.MEDICAL,
     ("injured", "injury", "bleeding", "unconscious", "wound", "hurt",
      "breathing", "heart")),
    (IncidentType.TRAPPED_PERSON,
     ("trapped", "stuck", "pinned", "buried", "cannot get out", "can't get out")),
    (IncidentType.INFRASTRUCTURE,
     ("power", "road blocked", "bridge out", "tower", "pipeline", "outage")),
]

# Phrases that raise severity regardless of type.
_CRITICAL_PHRASES = (
    "dying", "not breathing", "unconscious", "drowning", "bleeding badly",
    "severe", "critical", "trapped", "buried", "cannot breathe",
    "can't breathe", "water ris",
)
_EMERGENCY_PHRASES = (
    "injured", "hurt", "help", "urgent", "stranded", "fire", "flood",
    "collapsed",
)

_NUMBER_WORDS = {
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "dozen": 12,
}

_PEOPLE_NOUNS = (
    "people", "persons", "person", "adults", "children", "kids", "men",
    "women", "family", "families", "survivors", "casualties", "victims",
)

_EARTH_RADIUS_M = 6371000.0


def haversine_m(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> float:
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = p2 - p1
    dl = math.radians(b_lon - a_lon)
    h = (math.sin(dp / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return 2 * _EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(h)))


def extract_people_count(text: str) -> int | None:
    """Pull a people count out of free text, or None if it does not say one.

    None matters: "some people are trapped" must not become a confident 1.
    An invented count changes how many rescuers are sent.
    """
    lowered = text.lower()

    # "3 people", "12 survivors"
    digit = re.search(r"\b(\d{1,3})\s+(?:" + "|".join(_PEOPLE_NOUNS) + r")\b",
                      lowered)
    if digit:
        return int(digit.group(1))

    # "three people", "a family"
    words = "|".join(_NUMBER_WORDS)
    worded = re.search(
        r"\b(" + words + r")\s+(?:" + "|".join(_PEOPLE_NOUNS) + r")\b", lowered
    )
    if worded:
        return _NUMBER_WORDS[worded.group(1)]

    return None


def classify_type(text: str) -> IncidentType:
    lowered = text.lower()
    for incident_type, patterns in _TYPE_PATTERNS:
        if any(p in lowered for p in patterns):
            return incident_type
    return IncidentType.UNKNOWN


def classify_severity(text: str, reported: Priority) -> Priority:
    """Severity from the words, never below what the reporter chose.

    A survivor who marked something life-critical knows more about their
    situation than a keyword list does, so the reporter's own judgement is a
    floor. Rules may raise it; they may not quietly lower it.
    """
    lowered = text.lower()
    inferred = Priority.NORMAL
    if any(p in lowered for p in _CRITICAL_PHRASES):
        inferred = Priority.LIFE_CRITICAL
    elif any(p in lowered for p in _EMERGENCY_PHRASES):
        inferred = Priority.EMERGENCY

    return inferred if inferred.rank < reported.rank else reported


def _tokens(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z]{4,}", text.lower())}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


class DeterministicReasoner(Reasoner):
    name = "deterministic"
    is_model = False

    # Two reports fuse when they are close in space, close in time, and share
    # vocabulary. These thresholds are deliberately conservative: wrongly
    # merging two separate emergencies hides one of them, which is worse than
    # showing a duplicate an operator can merge by eye.
    fuse_radius_m = 250.0
    fuse_window_s = 1800.0
    fuse_similarity = 0.25

    def structure_report(self, report: RawReport) -> dict[str, Any]:
        text = " ".join(
            part for part in (report.text, report.transcript) if part
        ).strip()

        if not text:
            # An SOS with no words is still a real emergency — the button was
            # pressed. It just cannot be described.
            if report.kind == "SOS":
                stated = report.people_count
                return {
                    "type": IncidentType.UNKNOWN,
                    "severity": Priority.LIFE_CRITICAL,
                    "people_affected": stated,
                    "description": (
                        f"SOS: {stated} person(s) need help, no description."
                        if stated is not None
                        else "SOS with no description."
                    ),
                    # Being told a headcount is real evidence, even with no
                    # words around it.
                    "confidence": 0.45 if stated is not None else 0.3,
                }
            return {"confidence": 0.1}

        incident_type = classify_type(text)
        severity = classify_severity(text, report.priority)
        if report.kind == "SOS" and severity.rank > Priority.LIFE_CRITICAL.rank:
            severity = Priority.LIFE_CRITICAL

        # What the person stated beats what we guessed from their wording.
        people = report.people_count
        if people is None:
            people = extract_people_count(text)

        return {
            "type": incident_type,
            "severity": severity,
            "people_affected": people,
            "description": text,
            "confidence": self._confidence(report, incident_type, text),
        }

    def _confidence(
        self, report: RawReport, incident_type: IncidentType, text: str
    ) -> float:
        """Confidence from evidence actually present, not a guess.

        Plan §20 is explicit that confidence must come from system evidence.
        Each term below is something observable about the report.
        """
        score = 0.2
        if incident_type is not IncidentType.UNKNOWN:
            score += 0.2            # the words matched a known situation
        if report.location is not None:
            score += 0.2            # we know where
        if len(text.split()) >= 6:
            score += 0.1            # more than a fragment
        if report.media:
            score += 0.1            # there is an attachment
        if report.people_count is not None or extract_people_count(text):
            score += 0.1            # a countable detail
        if report.hop_count <= 3:
            score += 0.1            # arrived with less opportunity for loss
        return round(min(score, 0.95), 2)

    def should_fuse(self, incident: Incident, report: RawReport) -> tuple[bool, str]:
        report_text = " ".join(
            p for p in (report.text, report.transcript) if p
        ).strip()

        if incident.location and report.location:
            distance = haversine_m(
                incident.location.lat, incident.location.lon,
                report.location.lat, report.location.lon,
            )
            if distance > self.fuse_radius_m:
                return False, (
                    f"{distance:.0f} m apart, beyond the "
                    f"{self.fuse_radius_m:.0f} m fusion radius"
                )
        else:
            distance = None

        newest = max((e.created_at for e in incident.evidence),
                     default=incident.created_at)
        gap = abs((report.created_at - newest).total_seconds())
        if gap > self.fuse_window_s:
            return False, f"{gap / 60:.0f} min apart, outside the fusion window"

        similarity = jaccard(_tokens(incident.description), _tokens(report_text))
        type_matches = classify_type(report_text) is incident.type

        # Shared vocabulary, or the same classified situation in the same
        # place, is enough. Either alone in the same place and time is a
        # reasonable merge; neither is not.
        if similarity >= self.fuse_similarity or (
            type_matches and incident.type is not IncidentType.UNKNOWN
        ):
            where = f", {distance:.0f} m apart" if distance is not None else ""
            return True, (
                f"same situation{where}, {gap / 60:.0f} min apart, "
                f"wording overlap {similarity:.0%}"
            )

        return False, (
            f"wording overlap only {similarity:.0%} and the described "
            "situation differs"
        )

    def explain_choice(
        self,
        incident: Incident,
        chosen: ResponderAssessment,
        alternatives: list[ResponderAssessment],
    ) -> str:
        """Build the WHY from the assessments, stating only measured facts."""
        parts: list[str] = []

        closer = [
            a for a in alternatives
            if a.responder_id != chosen.responder_id
            and a.distance_m is not None
            and chosen.distance_m is not None
            and a.distance_m < chosen.distance_m
        ]

        if closer:
            nearest = min(closer, key=lambda a: a.distance_m or 0.0)
            gap = (chosen.distance_m or 0) - (nearest.distance_m or 0)
            parts.append(
                f"{nearest.responder_id} is closer by {gap:.0f} m but has "
                f"{nearest.network_reliability:.0%} network reliability to "
                f"this incident's partition"
                + ("" if nearest.reachable else " and is currently unreachable")
                + "."
            )
            parts.append(
                f"{chosen.responder_id} is {chosen.distance_m:.0f} m away with "
                f"{chosen.network_reliability:.0%} reliability over a stable "
                "path."
            )
        else:
            distance = (
                f"{chosen.distance_m:.0f} m away"
                if chosen.distance_m is not None
                else "at an unknown distance"
            )
            parts.append(
                f"{chosen.responder_id} is {distance} with "
                f"{chosen.network_reliability:.0%} network reliability."
            )
            if len(alternatives) <= 1:
                parts.append("No other responder is available.")

        if chosen.hazard_exposure != "UNKNOWN":
            parts.append(f"Route hazard exposure is {chosen.hazard_exposure.lower()}.")

        return " ".join(parts)
