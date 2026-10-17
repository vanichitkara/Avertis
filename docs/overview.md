# Avertis — project overview

Written for a submission form, a pitch, and anyone who has to defend the
claims in a Q&A. Every number here comes from a command in this repository,
and each one says which.

---

## 1. The problem

When a disaster destroys communication infrastructure, two things degrade at
once, and systems usually model only the first.

**The physical situation changes.** People become trapped, roads flood,
hazards spread, responders move, new incidents appear continuously.

**The communication network changes too.** Towers fail, relay devices run out
of battery or move away, the mesh splits into partitions, and parts of the
affected area become unreachable — not physically, but *informationally*.

Conventional disaster-response tooling treats communications as an invisible
dependency: a transport layer that either works or doesn't. So it can dispatch
a responder who is physically closest while having no way to reach them, no
way for them to report back, and no way to redirect them when the situation
changes. In a disaster, a rescue nobody can coordinate is often not a rescue.

There is a second, quieter problem. When connectivity does return, it returns
as a narrow window — seconds, not minutes — and whatever is queued floods
through it. A command centre receiving two hundred overlapping accounts of
the same collapsed bridge has an information-overload problem on top of an
emergency.

---

## 2. What Avertis is

An adaptive disaster-response platform with three layers:

**A resilient mesh.** Phones relay for each other over Bluetooth LE with no
infrastructure: multi-hop forwarding, TTL, deduplication, store-and-forward
custody, acknowledgements, heartbeat failure detection, partition detection,
and automatic re-election of a replacement relay when one dies.

**Situational intelligence.** Reports — typed, spoken, or photographed —
become structured incidents, and multiple accounts of the same event are
fused into one with its sources attached.

**Network-aware response.** The system recommends who should respond, using
both the physical picture *and* the current state of the communication
network, and re-plans automatically when either changes.

A simulator drives 100–1000 virtual nodes with repeatable failures, so
resilience can be measured rather than asserted. A command centre gives a
human operator the combined picture and the final say.

---

## 3. The core claim, stated carefully

**We do not claim that combining AI with disaster mesh networking is new.** It
isn't. Existing work — ResQMesh AI and others — already demonstrates BLE
disaster mesh, offline SOS, AI message prioritisation, offline speech
recognition, image analysis and battery-aware relay selection. Claiming
novelty there would be both false and easy to disprove.

The distinction we do make:

> Existing systems use AI to make **communication** smarter — deciding which
> message is most urgent, and getting it through a resilient network.
>
> Avertis makes the **response decision itself** network-aware: the
> communication topology is part of the operational state used to decide who
> responds, and when the topology changes, the recommendation changes.

Concretely, instead of:

```
incident → AI → message priority
```

Avertis does:

```
incident + hazards + responders + network topology
    → recommendation → the network changes → re-plan
```

### The signature behaviour

Two responders, one incident:

- **Responder A** — 200 m away, the obvious choice.
- **Responder B** — 300 m away, slightly further.

On a healthy mesh Avertis recommends A, and so would any distance-based
system. Then a relay node fails. Nothing physical changes — A is still
closer — but A is now in a different network partition, unreachable from the
incident site. Avertis detects the partition, re-evaluates, and switches the
recommendation to B, with an explanation grounded in the measured figures.

When the relay recovers, it switches back.

That whole loop is observable in the command centre's activity feed:

```
RECOMMENDATION      resp-a for INC-1042 (100% reliability, 200 m)
PARTITION DETECTED  network split into 3 partitions (was 1)
RECOMMENDATION      resp-b for INC-1042 (70% reliability, 300 m)
RESPONSE REPLANNED  INC-1042: resp-a → resp-b
PARTITION HEALED    network rejoined into 1 partition(s)
RESPONSE REPLANNED  INC-1042: resp-b → resp-a
```

Reproduce with:

```bash
.venv/bin/python -m avertis_sim run response_adaptation --api http://127.0.0.1:8000
```

### What makes it defensible rather than a demo trick

The decision is **deterministic**. The same operational state always produces
the same recommendation. That is what makes the change above attributable to
the network rather than to a model's mood, and it is why the selection
deliberately does not use an LLM (see §5).

---

## 4. Evidence

All measured by the simulator, none estimated. `avertis_sim benchmark`:

**Responder selection under 30% node loss, 150 dispatch decisions:**

| | distance-only baseline | Avertis |
|---|---|---|
| dispatched an unreachable responder | 16/150 (11%) | 5/150 (3%) |
| mean network reliability of the chosen responder | 80% | 89% |

**The honest reading, and the number worth quoting:** on a healthy mesh both
selectors agree, and they should. The value concentrates in *contested*
decisions — where the closest responder is cut off but another is reachable:

| | baseline | Avertis |
|---|---|---|
| contested decisions (11 of 150) | | |
| dispatched an unreachable responder | **11/11 (100%)** | **0/11 (0%)** |

Cost: when they disagree, Avertis sends someone 68 m further on average.

**Other measured figures:**

- Mass-incident run: ~166 raw reports fused into ~60 incidents, 106 duplicates
  absorbed (`avertis_sim run mass_incident`).
- Relay-failure scenario: 100% critical delivery, 0.5 s recovery, 39
  replacement relay elections, delivery continuing through a 3-way partition.
- Scale: 100+ simulated nodes with deterministic seeds, so every run is
  repeatable.

---

## 5. Where LLMs are used — and where they are deliberately not

This is the question most worth answering precisely, because the boundary is
a design decision rather than an implementation detail.

Gemini is called in exactly **four** places. Everything else is deterministic
code.

### Gemini does

| Task | What it does | Where |
|---|---|---|
| **Incident structuring** | free text or a transcript → event type, severity, people affected, a clean description, a confidence | `llm/gemini.py` `structure_report` |
| **Fusion judgement** | decides whether a new report describes an incident already known | `should_fuse` |
| **WHY explanation** | turns the measured assessment figures into a sentence an operator can read | `explain_choice` |
| **Operational summary** | a short situation summary across open incidents | `summarize` |

### Gemini does not

- **Packet forwarding, TTL, deduplication, acknowledgements, queueing.**
- **Relay scoring and election.** A transparent weighted score over battery,
  neighbour count, gateway proximity, link stability and mobility.
- **Partition detection and reachability.** Connected components, and a
  widest-path search where reliability compounds along a route — five hops at
  0.9 is 0.59, not 0.9, which is why hop count matters.
- **Choosing the responder.** The decision is a weighted score over
  reachability, distance and hazard. In the code the choice is made at
  `response.py:141` and the model is called at `:143` — purely to explain a
  decision that has already been made.

**Why keep selection out of the model.** Three reasons, all defensible:

1. *Determinism.* The signature demo only means something if the same state
   gives the same answer. A model that varies between identical inputs would
   make the change attributable to the model, not the network.
2. *Auditability.* A dispatch decision affecting someone's survival should be
   reconstructible from numbers, not from a prompt.
3. *Availability.* During a partition the model may be exactly what is
   unreachable. The mesh and the decision logic have to work regardless.

This follows the architectural rule the project was built around: **Gemini
reasons about the network; deterministic code operates the network.**

### Model output is validated, never trusted

Observed from real API calls during testing, and now enforced in code:

- **Severity may only be raised.** The sender's own priority, the rules and
  the model each get a say and the most severe wins. A live call rated "three
  people in the water, one is not moving" as EMERGENCY while the rules rated
  it LIFE_CRITICAL. Under-triage is the dangerous direction.
- **Confidence is capped at 0.95.** A live call returned 1.0 for a single
  unverified sentence. No single source justifies certainty.
- **An unrecognised incident type is discarded** in favour of the rules.
- **A stated headcount always wins** over anything inferred from wording, and
  an implausible one from the model is ignored.
- **Every model call is capped at 12 seconds** and falls back to rules, because
  a connectivity window is measured in seconds and a hanging call would block
  the pipeline.

### It runs without any model at all

With no API key the whole system still works: a rule-based engine does
structuring, fusion and explanation from the same evidence. It is weaker on
ambiguous language, and it never pretends otherwise — every incident and
recommendation carries `reasoned_by`, `/api/v1/health` reports which engine is
live, and the command centre shows it in the header.

This matters beyond convenience. A disaster-response tool that stops working
when an external API is unavailable has misunderstood its own problem.

---

## 6. Human-in-the-loop

Gemini recommends; it never dispatches. Every recommendation is marked
`requires_human_approval`, and a Safety Agent attaches flags an operator can
act on: `LOW_CONFIDENCE_EVIDENCE`, `SINGLE_SOURCE`,
`RECOMMENDED_RESPONDER_UNREACHABLE`, `WEAK_COMMUNICATION_PATH`,
`HIGH_HAZARD_ROUTE`, `UNKNOWN_HEADCOUNT`.

---

## 7. What is built, and what is not

**Working and tested** — 268 automated tests (106 backend, 53 simulator, 109
mobile):

- Flutter Android app: SOS, text/voice/photo reports, local persistence,
  offline-first, background relaying via a foreground service, an offline
  situation view drawn from real GPS bearings
- Dart mesh engine and Python mesh engine, agreeing on a frozen wire protocol
- Simulator: 7 scenarios, failure injection, resilience benchmark, replay
- FastAPI backend: 5 agents, world model, gateway sync, media upload
- Command centre: operational decision panel, live topology by partition,
  incident list, AI activity feed
- Verified end to end: app → mesh custody → gateway sync → HTTP → Gemini →
  incident → recommendation → command centre

**Honest gaps:**

- **BLE has never run on physical handsets.** Both roles are implemented —
  including a Kotlin peripheral layer, because `flutter_blue_plus` cannot
  advertise — and the framing is unit-tested, but no two real radios have
  exchanged a packet. Emulators have no BLE. This is the one claim to avoid
  making until it has been seen working.
- Firestore persistence is implemented but unexercised; the default store is
  in-memory and loses state on restart.
- The command centre has no automated tests.

---

## 8. One-sentence versions

**Pitch:** Avertis is a disaster-response platform that understands both the
disaster and the communication network, and continuously adapts who responds
and what information gets through when infrastructure fails.

**Innovation claim:** Unlike systems that use AI to prioritise messages over a
resilient network, Avertis makes the network itself part of the response
decision — so when connectivity changes, the recommended responder changes
automatically.

**The principle:** When the world changes, the network changes. When the
network changes, the best response can change. Avertis connects those two
facts.
