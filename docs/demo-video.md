# The three-minute video

Narration and shot list. Timings are budgets, not suggestions — the whole
thing is 180 seconds and every section below is already at its limit.

The argument, in one line: **the dispatch decision changes because of the
network, and a distance-only system gets it wrong.** Gemini is what turns
raw human reports into something that decision can be made on, and what
explains the decision afterwards. Everything else is evidence that this is
real rather than a mock-up.

**Word budget.** 425 words of narration at a clear 155 wpm is about 165
seconds, which leaves ~15 seconds of deliberate silence. Spend that silence
on the two beats where the picture is the argument: the SOS landing on the
dashboard, and the recommendation flipping from A to B. Do not fill them.
If you rewrite a section, count the words — going over is how a 3-minute
video becomes a rushed 3:40.

---

## 0:00 – 0:14 · 2026 made the case for us (36 words)

[Fast montage: flooding, damaged roads, emergency teams. Land on a map.]

> "2026 has already shown how quickly disasters isolate communities. Floods
> cut road access across Mozambique. A magnitude 7.7 earthquake struck
> Panama. The same operational problem appears every time: people need help
> precisely when communications fail."

Three disasters was one too many for the clock. Two concrete ones land
harder than a list.

## 0:14 – 0:30 · The problem, and what we built (45 words)

[Cut to the command centre, populated and clean.]

> "Emergency teams send the closest responder. In a disaster, the closest
> responder may be unreachable, because the communication network has split
> apart. Avertis is network-aware disaster-response intelligence: report
> emergencies offline, turn fragmented reports into incidents, and
> recommend a responder who can actually be coordinated."

## 0:30 – 0:52 · The report arrives with no internet (40 words + 5s silence)

Handheld, both phones in frame, **uncut**. This is the credibility shot and
it is also Gemini's input, so it earns its place twice.

1. Phone 1: Wi-Fi and mobile data off — hold on the status bar for a beat.
   Home screen reads `Internet OFFLINE · Mesh CONNECTED`.
2. Phone 2 beside it: online, role `GATEWAY`.
3. Phone 1: one tap, SOS sent. It reads *waiting for acknowledgement*.
4. Phone 1 flips to *acknowledged*.
5. Cut to the dashboard: the incident appears, already triaged.

> "This phone has no internet — no Wi-Fi, no mobile data. One tap sends an
> SOS. It travels over Bluetooth to a phone that does have signal, and that
> phone puts it on the network. Nothing here is mocked."

Then **stop talking** for five seconds while the incident lands on the
board. Do not film the SOS form being filled in — pre-fill it.

## 0:52 – 1:32 · Gemini (95 words)

The heaviest-weighted section of the rubric, and the one where the stated
risk is that the model looks decorative. Every sentence below names
something Gemini decided that changes what the operator sees.

[Show raw reports entering. The `Reasoning engine: gemini-…` badge must be
legible on screen — hold the frame long enough to read it.]

> "What reaches the command centre is raw: incomplete, emotional,
> repetitive. Gemini is central to turning it into action. It structures
> each report into incident type, severity, people affected and an
> operational description."

[Show several duplicate reports collapsing into one fused incident, with
the source count rising.]

> "It judges whether separate reports describe the same event, so operators
> see one evidence-backed incident instead of a flood of duplicates."

[Hit **WHY?**, then open the evidence disclosure.]

> "Gemini writes the grounded WHY explanation and the situation summary.
> And its output is bounded: confidence saturates below certainty, severity
> can only ever rise on new evidence, and the interface always names
> whether Gemini or fallback rules produced the result."

Those three guardrails are real and you can defend them if challenged:
confidence saturates at 0.95 in `_fused_confidence`
(`backend/avertis_backend/agents/incident.py:296`); severity only moves up
in `_merge` (`incident.py:252`), so a calmer later report cannot walk back
"someone is drowning"; and `SafetyAgent.review` sets
`requires_human_approval = True` unconditionally (`safety.py:58`).

## 1:32 – 2:20 · The signature demo (105 words + 10s silence)

Screen recording. Terminal beside the browser.

```bash
cd simulator && .venv/bin/python -m avertis_sim run response_adaptation
```

It completes in about **0.2 seconds** — far too fast to read on camera.
Record it once, then cut to the lines that carry the argument and hold each
long enough to read.

> "Now the part that makes Avertis different. One incident, two responders.
> Responder A is two hundred metres away, Responder B three hundred. On a
> healthy network, Avertis recommends A."

[Show the recommendation for Responder A.]

> "We fail relay R7. Nothing physical changes — same incident, same
> hazards, the responders do not move. But the mesh partitions."

[Show `PARTITION DETECTED`. **Silence here.**]

> "Responder A is still closer. A is no longer reachable. Avertis replans
> to Responder B: the responder who can still receive instructions and
> report back. Gemini writes the explanation."

[Hold on the recommendation changing A → B, then the WHY text:]

```
[network_aware] INC-142 → Responder B
    WHY: Responder B recommended: 0.3 km out, 77% measured network
    reliability to the incident over 3 mesh hops, hazard exposure LOW.
    Responder A is closer (0.2 km) but is currently in a separate network
    partition and cannot be reached through the mesh.

[distance_only] INC-142 → Responder A
    WHY: Responder A is the closest responder (0.2 km).
```

> "A distance-only system keeps dispatching unreachable Responder A. When
> R7 recovers, Avertis detects the healed network and switches back."

Showing the switch back matters more than it looks: it is what makes this
read as a mechanism rather than a scripted one-way trick.

## 2:20 – 2:44 · Division of labour, safety and scale (52 words)

[Expand the network topology graph. Let the node and partition counts show.]

> "Gemini handles intelligence and explanation. Deterministic code handles
> packet forwarding, topology and responder scoring — so the
> safety-critical decision stays auditable and keeps working during
> connectivity loss. Every recommendation carries safety flags and requires
> human approval. Offline-first app, Cloud Run backend, and a simulator
> that reproduces failures at hundred-node scale."

## 2:44 – 3:00 · Close (52 words)

Pre-run this; it takes about 11 seconds, so capture the output beforehand.

```bash
.venv/bin/python -m avertis_sim benchmark --nodes 100 --seeds 3
```

> "In contested simulations, where the closest responder was cut off and
> another was reachable, a distance-only baseline dispatched an unreachable
> responder eleven times out of eleven. Avertis, zero.
>
> When the world changes, the network changes. When the network changes,
> the best response changes. Avertis makes that visible, explainable, and
> human-controlled."

End on `https://avertis.web.app` — the plain URL, never the `?key=` form.

---

## Before you record

- [ ] `./tool/reset-demo.sh` — the live board currently shows stale nodes
      and several partitions left over from testing, which reads as a
      broken system on camera. **Close the app on every phone first**, or
      the 20-second sync repopulates the board mid-wipe and it looks like
      the reset failed.
- [ ] Then generate 3–4 incidents fresh, including two that describe the
      same event, so the fusion shot has something to fuse.
- [ ] Confirm the badge reads `gemini-…` and not the fallback. If Gemini is
      unreachable at record time the whole 0:52 section is wrong.
- [ ] Both phones on the current APK, permissions granted, app opened once
      already so the mesh has settled.
- [ ] Phone 1 on battery, not plugged in — a cable invites the question of
      what else it is doing.
- [ ] Check the gateway's Mesh screen shows non-zero packets decoded before
      you roll. That one number is the whole relay.
- [ ] Pre-run the simulator scenario and the benchmark; have both captured.

## What not to film

Code. Tests. The architecture diagram. The permissions dialog. Scrolling
documentation. The SOS form being typed into. Anything that takes longer to
explain than it takes to show.

## What not to claim

- That "AI plus mesh" is novel. The novelty is using network state in
  responder planning, and the measured before/after that proves it.
- That network-aware dispatch helps in general. It changes nothing on a
  healthy mesh, and `docs/benchmarks.md` says so with the numbers. Saying
  it first is stronger than being asked.
- That the simulator's radio model predicts real BLE throughput.
