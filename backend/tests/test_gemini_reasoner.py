"""The Gemini path, with a stubbed client.

This code only runs when a key is present, which means it is the least
exercised and most dangerous part of the backend: it runs for the first time
at the moment someone turns Gemini on, usually right before a demo.

Nothing here touches the network. What is tested is the part that is actually
ours — how a model response is validated, and what happens when the model
misbehaves. The guiding rule is that a model failure must degrade the quality
of reasoning and never take the pipeline down, and that a model must not be
able to assert something the evidence does not support.
"""

from __future__ import annotations

import datetime as dt

import pytest

from avertis_backend.llm.gemini import GeminiReasoner
from avertis_backend.models import (
    GeoPoint,
    Incident,
    IncidentType,
    Priority,
    RawReport,
    ResponderAssessment,
)

T0 = dt.datetime(2026, 9, 6, 12, 0, tzinfo=dt.timezone.utc)


class StubResponse:
    def __init__(self, text: str | None) -> None:
        self.text = text


class StubModels:
    """Stands in for client.models, recording calls and replaying answers."""

    def __init__(self, answers: list[object]) -> None:
        self.answers = list(answers)
        self.calls: list[str] = []

    def generate_content(self, *, model, contents, config=None):
        self.calls.append(contents)
        if not self.answers:
            return StubResponse(None)
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return StubResponse(answer)


def reasoner_with(*answers: object) -> GeminiReasoner:
    """A GeminiReasoner whose network layer is replaced wholesale."""
    instance = GeminiReasoner.__new__(GeminiReasoner)
    instance._model = "stub-model"
    instance.name = "gemini:stub-model"

    from avertis_backend.llm.deterministic import DeterministicReasoner

    instance._fallback = DeterministicReasoner()

    class StubClient:
        models = StubModels(list(answers))

    instance._client = StubClient()
    return instance


def report(text: str, **kwargs) -> RawReport:
    return RawReport(
        report_id=kwargs.pop("report_id", "rpt-1"),
        origin_node="node-07",
        created_at=T0,
        location=GeoPoint(lat=12.9716, lon=77.5946),
        text=text,
        **kwargs,
    )


def incident(**kwargs) -> Incident:
    return Incident(
        incident_id="INC-1042",
        type=kwargs.pop("type", IncidentType.FLOOD_RESCUE),
        description=kwargs.pop("description", "flooded bridge, people trapped"),
        location=GeoPoint(lat=12.9716, lon=77.5946),
        created_at=T0,
        **kwargs,
    )


class TestStructuring:
    def test_a_good_response_is_used(self):
        r = reasoner_with(
            '{"type": "FLOOD_RESCUE", "severity": "LIFE_CRITICAL", '
            '"people_affected": 3, "description": "Three trapped by flood", '
            '"confidence": 0.8}'
        )
        out = r.structure_report(report("people trapped by rising water"))

        assert out["type"] == IncidentType.FLOOD_RESCUE
        assert out["severity"] == Priority.LIFE_CRITICAL
        assert out["people_affected"] == 3
        assert out["confidence"] == 0.8
        # Provenance must be recorded, or the UI cannot label it honestly.
        assert out["reasoned_by"] == "gemini:stub-model"

    def test_unparseable_json_falls_back_to_rules(self):
        r = reasoner_with("I'm afraid I can't do that")
        out = r.structure_report(report("three people trapped by flood"))

        assert out["people_affected"] == 3          # the rules still worked
        assert out.get("reasoned_by", "deterministic") == "deterministic"

    def test_an_exception_falls_back_rather_than_propagating(self):
        r = reasoner_with(RuntimeError("503 UNAVAILABLE"))
        # A model outage must never surface as a failed incident ingest.
        out = r.structure_report(report("bridge collapsed, people trapped"))
        assert out["type"] == IncidentType.STRUCTURAL_COLLAPSE

    def test_an_empty_response_falls_back(self):
        r = reasoner_with(None)
        out = r.structure_report(report("fire in the market"))
        assert out["type"] == IncidentType.FIRE

    def test_an_invented_type_is_rejected(self):
        r = reasoner_with(
            '{"type": "ALIEN_INVASION", "severity": "EMERGENCY", '
            '"description": "x", "confidence": 0.5}'
        )
        out = r.structure_report(report("the building collapsed"))
        # A hallucinated enum must not reach the operator; the rules decide.
        assert out["type"] == IncidentType.STRUCTURAL_COLLAPSE

    def test_the_model_cannot_downgrade_the_reporter_s_priority(self):
        r = reasoner_with(
            '{"type": "MEDICAL", "severity": "NORMAL", '
            '"description": "x", "confidence": 0.9}'
        )
        out = r.structure_report(
            report("my father is unconscious", priority=Priority.LIFE_CRITICAL)
        )
        # The person who pressed the button knows more than the model does.
        assert out["severity"] == Priority.LIFE_CRITICAL

    def test_the_model_may_raise_severity(self):
        r = reasoner_with(
            '{"type": "MEDICAL", "severity": "LIFE_CRITICAL", '
            '"description": "x", "confidence": 0.9}'
        )
        out = r.structure_report(
            report("he is not responding", priority=Priority.NORMAL)
        )
        assert out["severity"] == Priority.LIFE_CRITICAL

    @pytest.mark.parametrize("bad", [-1, 0, 5000, "three", None])
    def test_an_implausible_headcount_is_ignored(self, bad):
        r = reasoner_with(
            '{"type": "FLOOD_RESCUE", "severity": "EMERGENCY", '
            f'"people_affected": {bad if isinstance(bad, int) else "null"}, '
            '"description": "x", "confidence": 0.5}'
        )
        out = r.structure_report(report("people trapped by water"))
        assert out["people_affected"] in (None,)

    @pytest.mark.parametrize("bad", ["1.5", "-0.2"])
    def test_an_out_of_range_confidence_is_ignored(self, bad):
        r = reasoner_with(
            '{"type": "FIRE", "severity": "EMERGENCY", '
            f'"description": "x", "confidence": {bad}}}'
        )
        out = r.structure_report(report("there is a fire"))
        assert 0.0 <= out["confidence"] <= 1.0

    def test_a_stated_headcount_is_given_to_the_model(self):
        r = reasoner_with('{"type": "FLOOD_RESCUE", "severity": "EMERGENCY", '
                          '"people_affected": 4, "description": "x", '
                          '"confidence": 0.7}')
        r.structure_report(report("people in the water", people_count=4))

        prompt = r._client.models.calls[0]
        assert "people stated by sender: 4" in prompt, (
            "the model must be told what the sender stated, or it will "
            "contradict it"
        )


class TestFusion:
    def test_a_clear_yes_is_honoured(self):
        r = reasoner_with('{"fuse": true, "reason": "same bridge"}')
        fuse, reason = r.should_fuse(incident(), report("bridge is flooded"))
        assert fuse is True
        assert reason == "same bridge"

    def test_a_clear_no_is_honoured(self):
        r = reasoner_with('{"fuse": false, "reason": "different street"}')
        fuse, _ = r.should_fuse(incident(), report("fire two streets away"))
        assert fuse is False

    def test_a_malformed_answer_falls_back_to_the_rules(self):
        r = reasoner_with('{"maybe": "who knows"}')
        # Must not crash, and must not guess.
        fuse, reason = r.should_fuse(incident(), report("unrelated event"))
        assert isinstance(fuse, bool)
        assert reason

    def test_an_outage_falls_back(self):
        r = reasoner_with(RuntimeError("timeout"))
        fuse, reason = r.should_fuse(
            incident(), report("flooded bridge, people trapped")
        )
        assert isinstance(fuse, bool)


class TestExplanation:
    def test_the_model_text_is_used_when_present(self):
        r = reasoner_with("Responder B has a stable path to the incident.")
        why = r.explain_choice(
            incident(),
            ResponderAssessment(responder_id="B", distance_m=3800,
                                network_reliability=0.91, reachable=True),
            [],
        )
        assert why == "Responder B has a stable path to the incident."

    def test_a_failure_still_produces_a_grounded_explanation(self):
        r = reasoner_with(RuntimeError("down"))
        why = r.explain_choice(
            incident(),
            ResponderAssessment(responder_id="B", distance_m=3800,
                                network_reliability=0.91, reachable=True),
            [
                ResponderAssessment(responder_id="A", distance_m=2100,
                                    network_reliability=0.05, reachable=False),
                ResponderAssessment(responder_id="B", distance_m=3800,
                                    network_reliability=0.91, reachable=True),
            ],
        )
        # The WHY button must never be empty, and must cite real figures.
        assert "A" in why and "%" in why

    def test_only_the_supplied_figures_reach_the_prompt(self):
        r = reasoner_with("explanation")
        r.explain_choice(
            incident(),
            ResponderAssessment(responder_id="B", distance_m=3800,
                                network_reliability=0.91, reachable=True,
                                hazard_exposure="LOW"),
            [],
        )
        prompt = r._client.models.calls[0]
        assert "3800 m" in prompt
        assert "91%" in prompt
        # The instruction not to invent telemetry must actually be sent.
        assert "Do not invent" in prompt


class TestConfidenceCeiling:
    def test_the_model_cannot_assert_certainty(self):
        r = reasoner_with(
            '{"type": "FLOOD_RESCUE", "severity": "LIFE_CRITICAL", '
            '"description": "x", "confidence": 1.0}'
        )
        out = r.structure_report(report("people in the water"))

        # Observed from a real call: the model returned 1.0 for a single
        # unverified sentence. "100% confidence" next to one stranger's
        # report misleads whoever is deciding what to send.
        assert out["confidence"] <= 0.95

    def test_a_modest_confidence_is_left_alone(self):
        r = reasoner_with(
            '{"type": "FIRE", "severity": "EMERGENCY", '
            '"description": "x", "confidence": 0.6}'
        )
        out = r.structure_report(report("there is a fire"))
        assert out["confidence"] == 0.6


class TestSeverityIsNeverTalkedDown:
    """Three judges, and the most severe wins.

    The sender's own priority, the deterministic rules and the model can all
    disagree. Under-triage is the direction that gets someone killed, so none
    of them may lower what another has raised.
    """

    def test_the_model_cannot_undercut_the_rules(self):
        # Observed against the live API: the model returned EMERGENCY for a
        # report the rules read as LIFE_CRITICAL.
        r = reasoner_with(
            '{"type": "INFRASTRUCTURE", "severity": "EMERGENCY", '
            '"people_affected": 3, "description": "x", "confidence": 0.9}'
        )
        out = r.structure_report(
            report("the bridge collapsed, three people in the water, "
                   "one is not moving")
        )
        assert out["severity"] == Priority.LIFE_CRITICAL

    def test_the_model_can_still_raise_above_the_rules(self):
        r = reasoner_with(
            '{"type": "MEDICAL", "severity": "LIFE_CRITICAL", '
            '"description": "x", "confidence": 0.8}'
        )
        out = r.structure_report(report("my father looks very unwell"))
        assert out["severity"] == Priority.LIFE_CRITICAL

    def test_agreement_is_left_alone(self):
        r = reasoner_with(
            '{"type": "FIRE", "severity": "EMERGENCY", '
            '"description": "x", "confidence": 0.7}'
        )
        out = r.structure_report(report("there is a fire in the market"))
        assert out["severity"] == Priority.EMERGENCY
