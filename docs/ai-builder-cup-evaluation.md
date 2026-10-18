# Avertis — AI Builder Cup winning-potential assessment

**Verdict: finalist-capable; not yet a safe winner.**

Based on the published AI Builder Cup 2026 criteria and the evidence currently
in this repository, Avertis has a credible path to a strong shortlist or final.
Its sharpest advantage is not that it combines AI and disaster mesh networking;
that is established territory. Its distinctive claim is that **communication
topology changes the operational response decision**: when a relay failure
partitions the mesh, Avertis can recommend a farther responder who is still
reachable, then switch back when the network heals.

The assessment score below is a positioning estimate, not a prediction of
judges' votes. It assumes the submitted build can demonstrate live Gemini use
and is deployed through Cloud Run or Firebase.

## Rubric scorecard

The official judging weights are [published here](https://aibuildercup.com/themes.html):

| Criterion | Weight | Estimate | Evidence and assessment |
| --- | ---: | ---: | --- |
| Technical Merit & GenAI Implementation | 40% | **33 / 40** | Strong engineering depth: offline custody, mesh simulation, deterministic network-aware selection, replay, validation and test coverage. Gemini is used for incident structuring, fusion, operational summaries and grounded explanations. The deduction is important: Gemini does not make the signature responder decision, so the demo must make the model's contribution visibly consequential rather than decorative. |
| Problem Alignment & Impact | 25% | **23 / 25** | Excellent fit for Sustainability & Social Impact: disaster resilience, degraded connectivity, emergency reporting and safer responder coordination. The human-approval model is especially appropriate for a high-stakes setting. |
| Innovation & Creativity | 25% | **20 / 25** | The closed-loop response adaptation is a compelling differentiator. The pitch must avoid claiming that “AI + mesh” is novel; make the novelty the use of network state in responder planning and the measured before/after result. |
| User Experience & Solution Design | 10% | **7 / 10** | The SOS-to-command-centre flow, plain-language WHY explanation, and transparent fallback badge are strong. Real multi-phone BLE has not yet been demonstrated, and the command centre has no automated tests. |
| **Total** | **100%** | **83 / 100** | A defensible finalist-level submission if the live prototype and Gemini story are rehearsed and reliable. |

## Why Avertis can win

### One memorable proof, not a feature tour

The strongest sequence is already implemented in the `response_adaptation`
scenario:

1. An incident has two responders: A is closer than B.
2. A relay fails and the mesh partitions.
3. A becomes unreachable despite still being physically closer.
4. Avertis changes the recommendation from A to B because B can communicate
   with the incident.
5. When the relay recovers, Avertis recommends A again.

This is much stronger than claiming “we use Gemini” or showing a generic
dashboard. It demonstrates an intelligible operational consequence from a
changing network state, and it contrasts cleanly with a distance-only baseline
that continues to select unreachable responder A.

### There is substantive implementation behind the claim

The repository contains a Flutter application, BLE mesh implementation,
deterministic simulator, FastAPI backend, Gemini-backed reasoning layer and
command-centre interface. On 18 October 2026, the backend suite passed
**163 tests** (with two optional tests skipped), and the signature simulator
scenario ran successfully. Its observed output showed:

- 100% critical delivery in that scenario;
- a switch from responder A to B during the partition;
- a distance-only baseline still selecting unreachable responder A;
- a return to A when the relay recovered.

The documented benchmark gives a useful, more conservative result for the
video: on contested decisions—where the closest responder is cut off while
another is reachable—the baseline selected an unreachable responder in
**11 of 11** cases, versus **0 of 11** for Avertis. See
[the resilience benchmark](benchmarks.md).

### The safety boundary is persuasive

Gemini is not allowed to autonomously dispatch anyone. It structures and fuses
messy incident reports and turns measured facts into explanations, while
deterministic code controls packet forwarding, topology analysis and the final
responder score. Recommendations require an operator approval and include
safety flags. This is a compelling high-stakes AI design choice, provided the
presentation frames it as purposeful engineering rather than a limitation.

## What could keep it off the podium

### 1. GenAI may look secondary

Technical Merit & GenAI is the largest rubric category at 40%. The flagship
demo is deliberately deterministic, which is correct for auditability and
safety, but makes it easy for judges to perceive the product as an excellent
systems project with Gemini added afterward.

**Mitigation:** show Gemini early and visibly. Start with an ambiguous,
multimodal or duplicate report; show it become a structured, fused incident;
then show the model-grounded WHY explanation in the command centre. State
exactly what Gemini contributed and show the live `reasoning.is_model: true`
health state before recording.

### 2. The physical mesh proof is incomplete

The project documentation candidly states that BLE has not yet been validated
between two physical phones. The simulator validates the logic at scale; it
does not prove real radio discovery, MTU negotiation or sustained transport.

**Mitigation:** either rehearse and capture a real two-phone exchange before
submission, or keep the video centred on the verified simulator-to-backend
loop. Never overclaim the physical-radio result.

### 3. Demo reliability may undermine a strong concept

The proposal relies on deployment details that must be confirmed immediately
before recording: Cloud Run availability, Gemini credentials/rate limits,
Firestore persistence, durable media storage and a working public judge path.

**Mitigation:** record a clean fallback video from a reproducible seed, retain
the live deployment for judging, and verify the deployed health endpoint and
Gemini badge on the same build used for submission.

### 4. Submission assets are as important as code

The competition requires a working Google-AI-enabled prototype deployed via
Cloud Run or Firebase, a proposal deck/PDF, and a public three-minute video.
The project must also be submitted under an eligible theme and team. See the
[official requirements](https://aibuildercup.com/themes.html) and
[event overview](https://aibuildercup.com/). This assessment did not verify
the actual submitted deck, public video or eligibility.

## Recommended three-minute video structure

| Time | What to show | The judging job it does |
| --- | --- | --- |
| 0:00–0:30 | “The closest responder is not always the best responder if they cannot communicate.” Establish disaster failure and Sustainability & Social Impact. | Alignment and impact |
| 0:30–1:15 | An incoming report becomes a Gemini-structured and fused incident. Show the model attribution and validation safeguards. | Meaningful GenAI implementation |
| 1:15–2:20 | Run the R7 relay-failure loop beside the distance-only baseline. Make the A → B → A decision change unmistakable. | Technical merit and innovation |
| 2:20–2:45 | Quote the contested-decision benchmark, explain human approval and transparent fallback. | Evidence, safety and credibility |
| 2:45–3:00 | Show the deployed command centre, confirm Cloud Run/Firebase and give a scale path. | Feasibility and solution design |

## Final recommendation

Present Avertis as **network-aware disaster-response intelligence**, not as a
generic AI emergency app or a novel mesh protocol.

> When the world changes, the network changes. When the network changes, the
> best response can change. Avertis makes that response visible, explainable
> and human-controlled.

If live Gemini is clearly demonstrated, the deployment is reliable, and the
relay-failure sequence is the centrepiece, Avertis has genuine winning
potential. If Gemini is unavailable or hidden behind a mostly deterministic
demo, it remains a strong technical project but becomes less competitive for
the rubric's highest-weighted category.
