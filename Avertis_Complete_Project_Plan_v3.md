# Avertis — Complete Project Plan v3.0

**Tagline:** Intelligence that keeps response moving.

**Core positioning:**  
> **Avertis is an adaptive disaster-response intelligence platform that understands both the physical disaster and the communication network, then continuously adapts response as either one changes.**

---

# 1. Executive Summary

Avertis is an AI-powered disaster-response platform designed for situations where conventional communication infrastructure is unreliable or unavailable.

It combines:

1. **Resilient connectivity** — an offline, multi-hop mesh that can continue carrying critical information when cellular/internet connectivity fails.
2. **Situational intelligence** — Gemini-powered multimodal understanding that converts voice, text, images and network events into structured incidents and a shared operational picture.
3. **Network-aware response** — response recommendations that consider not only physical conditions and responder availability, but also the current communication topology.
4. **Adaptive orchestration** — when a relay disappears, a gateway returns, a hazard changes, or a responder becomes unreachable, Avertis updates the operational picture and response recommendation.

The key thesis is not "AI + disaster mesh."

> **Avertis treats communication resilience as part of the disaster-response state itself.**

The network is therefore not merely a transport layer. Its health, reachability and topology influence operational decisions.

---

# 2. The Problem

During major disasters, two things change simultaneously:

### Physical world
- people become trapped or injured
- roads become blocked
- floods/fire/debris create hazards
- responders move
- shelters and hospitals change capacity
- new incidents appear continuously

### Communication world
- towers fail
- gateways disappear
- devices lose battery
- network partitions form
- relay nodes move or disappear
- some incidents become unreachable
- connectivity quality changes over time

Most systems reason primarily about the first world and treat communications as an invisible infrastructure dependency.

Avertis explicitly models both.

---

# 3. What We Are Building

```text
                    AVERTIS
                       |
        ┌──────────────┼──────────────┐
        |              |              |
   Situation AI   Response AI   Resilience AI
        |              |              |
   What happened?   What should     Can we
                    we do?           communicate?
        |              |              |
        └──────────────┼──────────────┘
                       |
                Adaptive Response
                       |
             Mesh + Responders + Gateway
                       |
                New observations
                       |
                       └──────> Avertis
```

Avertis continuously closes this loop.

---

# 4. Innovation Thesis

## The important correction

We should **not** claim that nobody has combined AI with disaster mesh networks.

Existing work already demonstrates:

- BLE/P2P disaster mesh
- offline SOS
- AI message prioritization
- offline speech recognition
- image analysis
- battery-aware relay policies
- structured emergency reports
- dynamic network optimization
- opportunistic mesh + digital twins

For example, the 2026 ResQMesh AI Platform combines BLE mesh with on-device AI for message prioritization, speech recognition, FEMA-compatible reporting and battery-aware relay policies. It is open source and based on BitChat. 

A separate 2026 research direction explores AI-driven/dynamic network optimization for disaster communications, while TwinSR-AI combines opportunistic mesh, AI and digital-twin-based search and rescue.

Therefore:

> **AI + disaster mesh is not our novelty claim.**

## Avertis's stronger contribution

Avertis focuses on the coupling between:

**incident state + physical environment + responder state + network topology**

and uses that combined state to continuously adapt response decisions.

### Core differentiator

> **Network-aware incident response.**

Instead of:

`Incident → AI → message priority`

Avertis does:

`Incident + hazard + responders + network state → AI → response recommendation → network/incident changes → re-plan`

This is the closed loop we should demonstrate.

---

# 5. Competitive Landscape and Differentiation

| Capability | Existing landscape | Avertis |
|---|---|---|
| Offline/P2P disaster mesh | Established | Uses it |
| Offline SOS | Established | Uses it |
| AI message prioritization | Already demonstrated | Supporting capability |
| Offline speech recognition | Already demonstrated | Supporting capability |
| AI image analysis | Already demonstrated | Supporting capability |
| Battery-aware relay selection | Already demonstrated | Supporting capability |
| Emergency command dashboards | Established | Uses it |
| Opportunistic mesh + digital twin | Emerging research | Related concept |
| AI network optimization | Active research | Related concept |
| **Joint physical + network operational state** | Less common | **Core** |
| **Network-aware responder selection** | Stronger opportunity | **Core** |
| **Network-aware rescue routing** | Stronger opportunity | **Core** |
| **Response changes when network topology changes** | Strong differentiator | **Core** |
| **Closed-loop incident + network adaptation** | Strong differentiator | **Core** |
| **Human-readable WHY explanation for network-aware decisions** | Opportunity | **Core** |

## Existing project we must explicitly differentiate from

### ResQMesh AI Platform

It already demonstrates:
- offline BLE mesh
- AI message classification
- speech recognition
- emergency reporting
- battery-aware relays
- image-to-text compression
- priority queues

Therefore Avertis should **not** compete by claiming better message prioritization.

Our differentiation is:

> ResQMesh AI makes communication smarter.  
> **Avertis makes disaster response network-aware.**

### Other emerging work

TwinSR-AI combines opportunistic mesh, AI and a digital twin for search and rescue.

Avertis should differentiate through the **operational decision loop**:

- Which responder should go?
- Which route should they take?
- Can they communicate along the route?
- What happens when a relay disappears?
- Should the recommendation change?
- Which incidents should reach command first when connectivity returns?

---

# 6. Signature Feature — Network-Aware Incident Response

This should be the central Avertis innovation.

Imagine two responders:

### Responder A
- 2.1 km away
- fastest physical route
- currently disconnected from affected network partition

### Responder B
- 3.8 km away
- slightly slower route
- 91% estimated communication coverage
- reachable through stable mesh relays

A conventional routing system may choose A.

Avertis can recommend B because the response needs both:

- physical access
- communication reachability

The recommendation should be explainable:

> **Responder B recommended. Responder A is closer, but currently has unreliable communication with the affected network partition. Responder B has a stable communication path and lower route hazard exposure.**

---

# 7. Signature Demo — The Recommendation Changes

This should be one of the most important moments in the final presentation.

### Before failure

```text
INCIDENT #142

Responder A
Distance: 2.1 km
Network reliability: 94%
Route hazard: LOW

✓ RECOMMENDED
```

### Kill relay R7

```text
NETWORK CHANGE

R7 FAILED
↓
Partition detected
↓
Responder A becomes poorly reachable
↓
Network topology recomputed
↓
Response recommendation updated
```

### After failure

```text
Responder A
Distance: 2.1 km
Network reliability: 18%

Responder B
Distance: 3.8 km
Network reliability: 91%

✓ NEW RECOMMENDATION: RESPONDER B
```

This proves that Avertis is not producing a static LLM answer.

The system reacts to a changing operational state.

---

# 8. Core Product Pillars

## Pillar 1 — Resilient Connectivity

- BLE multi-hop communication
- store-and-forward
- packet TTL
- deduplication
- acknowledgements
- local queues
- relay selection
- partition detection
- self-healing topology
- gateway discovery
- critical-first synchronization

## Pillar 2 — Situational Intelligence

Gemini handles:

- voice/text understanding
- image understanding
- incident extraction
- severity estimation
- duplicate detection/fusion
- evidence summarization
- semantic prioritization
- confidence assessment
- situation summaries

## Pillar 3 — Adaptive Response

Avertis reasons over:

- incident severity
- responder capability
- responder location
- route safety
- network reachability
- network stability
- battery constraints
- gateway availability
- current topology

Then produces:

- responder recommendation
- route recommendation
- communication strategy
- priority recommendation
- explanation

---

# 9. Golden Architecture Principle

Keep deterministic networking separate from AI reasoning.

### Deterministic code handles

- packet forwarding
- topology
- TTL
- queues
- deduplication
- ACKs
- heartbeat
- failure detection
- partition detection
- relay scoring
- relay election
- routing

### Gemini / ADK handles

- report interpretation
- multimodal fusion
- semantic prioritization
- incident reasoning
- contextual response recommendations
- network-aware reasoning
- explanations

> **Gemini reasons about the network; deterministic code operates the network.**

Do not ask an LLM to decide individual packet hops.

---

# 10. Architecture

```text
                       Avertis
                          |
                 ┌────────┴────────┐
                 |                 |
             Mobile            Simulator
                 |                 |
            Mesh Engine       MockMeshTransport
                 |                 |
          MeshTransport       100–1000 nodes
             /       \
            /         \
 MockMeshTransport   BleMeshTransport
      |                    |
 Simulator            Android BLE
                          |
                    Physical phones
                          |
                     Gateway Client
                          |
                     Gateway API
                          |
                    FastAPI / Cloud Run
                          |
                 ┌────────┴────────┐
                 |                 |
              Gemini             Firestore
              / ADK           Cloud Storage
                 |
          Response Intelligence
                 |
          Command Center
```

---

# 11. Ownership

## You — Mobile + Mesh + Simulator

Own:

- Flutter Android application
- mesh engine
- mesh protocol
- BLE transport
- mock transport
- local persistence
- store-and-forward
- relay selection
- self-healing
- network state
- disaster simulator
- gateway client
- physical Android demo

## Teammate — Backend + AI + Command Center

Own:

- FastAPI
- Google ADK
- Gemini
- AI agents
- incident processing
- response reasoning
- Firestore
- Cloud Storage
- Cloud Run deployment
- gateway API
- command center
- AI activity feed
- backend metrics

## Shared

- protocol/API contract
- integration
- testing
- deployment
- demo
- pitch
- hackathon submission

---

# 12. Transport Abstraction

This is critical.

The mesh engine must not directly depend on Bluetooth.

```text
MeshEngine
    |
MeshTransport
    |
    ├── MockMeshTransport
    |       └── Laptop simulator
    |
    └── BleMeshTransport
            └── Android BLE
```

The same routing/self-healing logic must operate in both modes.

This allows most development to happen before physical BLE works.

---

# 13. Mobile Stack

- Flutter + Dart
- Android-first
- Riverpod
- GoRouter
- Drift + SQLite
- Dio
- flutter_blue_plus
- Geolocator
- Google Maps Flutter
- Record
- image picker/camera
- permission_handler
- secure storage

If Flutter BLE becomes limiting:

- add a small Kotlin Android BLE implementation through Platform Channels
- do not rewrite the entire application

---

# 14. Mobile UX

## Home

Show:

```text
AVERTIS

Internet: OFFLINE
Mesh: CONNECTED

Nearby nodes: 7
Mesh health: 82%
Battery: 67%

[ SOS ]
[ REPORT INCIDENT ]
[ SHARE LOCATION ]
[ SAFE ROUTE ]
```

## SOS

Persist locally:

- incident ID
- node ID
- GPS
- timestamp
- priority
- basic user description

Then broadcast through the mesh.

## Incident report

Allow:

- text
- voice
- photo
- location

No video for MVP.

---

# 15. Mesh Protocol

Development JSON packet:

```json
{
  "packet_id": "pkt-123",
  "origin_node": "node-07",
  "destination": "gateway-01",
  "message_type": "INCIDENT",
  "priority": "LIFE_CRITICAL",
  "ttl": 8,
  "hop_count": 2,
  "created_at": "2026-09-06T12:00:00Z",
  "payload_hash": "abc123",
  "payload": {}
}
```

Message types:

```text
HELLO
NODE_STATUS
INCIDENT
SOS
ACK
ROUTE_REQUEST
ROUTE_RESPONSE
GATEWAY_AVAILABLE
SYNC
SYNC_ACK
```

---

# 16. Mesh State

Each node tracks:

- node ID
- battery
- GPS
- role
- neighbors
- last seen
- gateway distance
- link stability
- mobility
- queued packets
- seen packet IDs

Node roles:

- survivor
- responder
- relay
- gateway

---

# 17. Relay Selection

Start with deterministic scoring:

```text
relay_score =
    0.30 × battery
  + 0.20 × neighbor_count
  + 0.20 × gateway_proximity
  + 0.15 × stability
  + 0.15 × mobility
```

This is not claimed as novel AI.

It is a transparent baseline that can later be compared against alternative policies.

---

# 18. Self-Healing Network

Flow:

```text
Heartbeat timeout
      ↓
Node unavailable
      ↓
Topology recomputation
      ↓
Partition detection
      ↓
Candidate relay scoring
      ↓
Replacement relay elected
      ↓
Queued messages rerouted
      ↓
Network healed
```

Example:

```text
A → B → C

Kill B

A → X → C
```

Emit events so the UI can visualize the recovery.

---

# 19. Incident Intelligence

Backend incident schema:

```json
{
  "incident_id": "INC-1042",
  "type": "FLOOD_RESCUE",
  "severity": "LIFE_CRITICAL",
  "people_affected": 3,
  "location": {},
  "description": "...",
  "evidence": [],
  "confidence": 0.94,
  "status": "OPEN"
}
```

Gemini extracts:

- event type
- severity
- people affected
- location
- hazards
- resource requirements
- confidence
- evidence

---

# 20. Incident Fusion

Multiple users may report the same event.

Example:

```text
Report A:
"3 people trapped near bridge."

Report B:
"People trapped after bridge collapsed."

Report C:
"Bridge area flooded, 3 people need help."

Report D:
Photo showing flooded bridge.
```

Avertis should fuse these into:

```text
INC-1042

Bridge collapse / flood
3 people affected
Confidence: high
4 source reports
```

This reduces information overload.

Important: confidence must be based on actual system evidence. Do not invent confidence numbers for the demo unless the model actually produces them.

---

# 21. Semantic Prioritization

Priority classes:

```text
LIFE_CRITICAL
EMERGENCY
OPERATIONAL
NORMAL
```

Use deterministic rules for obvious cases.

Use Gemini when semantic/contextual interpretation is needed.

This is supporting functionality, not the primary innovation claim.

---

# 22. Avertis Agent Architecture

## Coordinator Agent

Maintains overall operational picture.

## Incident Agent

Understands reports and produces structured incidents.

## Network Agent

Understands:

- topology
- partitions
- gateways
- node health
- reachability

It should **not** operate packet-level routing.

## Response Agent

Reasons about:

- responders
- routes
- hazards
- resources
- network reachability

Produces response recommendations.

## Safety Agent

Checks:

- low-confidence evidence
- contradictions
- unsafe recommendations
- missing information

High-impact recommendations require human approval.

---

# 23. The Avertis World Model

This should become a major architectural concept.

Avertis maintains a combined operational state:

```text
PHYSICAL STATE
├── incidents
├── hazards
├── roads
├── shelters
├── hospitals
├── responders
└── resources

NETWORK STATE
├── nodes
├── links
├── partitions
├── gateways
├── battery
├── reachability
└── network reliability
```

The Response Agent reasons over both.

This is the heart of Avertis.

---

# 24. Network-Aware Rescue Routing

Normal routing considers:

```text
distance + travel time
```

Avertis considers:

```text
physical safety
+ travel time
+ responder capability
+ responder proximity
+ communication coverage
+ network stability
```

Example:

```text
ROUTE A
Flood risk: HIGH
Mesh coverage: 20%
Responder access: MEDIUM

ROUTE B
Flood risk: LOW
Mesh coverage: 92%
Responder access: HIGH

→ RECOMMEND ROUTE B
```

The UI should include a **WHY?** button.

---

# 25. Why-Explanation

Every important AI decision should be explainable.

Example:

> **Why Responder B?**

> Responder A is closer, but currently has poor connectivity to the incident's network partition. Responder B has a stable communication path and lower hazard exposure.

The exact explanation must be generated from actual system state.

Never fabricate telemetry.

---

# 26. Gateway API

Freeze this early.

```http
POST /api/v1/gateway/sync
```

Request:

```json
{
  "gateway_id": "gw-01",
  "connectivity_window_seconds": 18,
  "nodes": [],
  "incidents": [],
  "messages": []
}
```

Response:

```json
{
  "accepted": ["INC-1042"],
  "rejected": [],
  "commands": [
    {
      "type": "SYNC_ACK",
      "incident_id": "INC-1042"
    }
  ]
}
```

---

# 27. Store-and-Forward

During outage:

```text
Internet OFFLINE
      ↓
Reports accumulate locally
      ↓
Mesh propagates reports
```

Gateway returns:

```text
18 seconds available
200 messages queued
```

Avertis:

1. deduplicates
2. fuses
3. prioritizes
4. transmits
5. receives ACKs
6. retries failures

Destination:

> **Simulated disaster-management command center**

Do not claim integration with a real emergency authority.

---

# 28. Command Center

Show:

- map
- incidents
- nodes
- responders
- shelters
- hospitals
- gateways
- hazard zones
- network topology
- network health
- AI activity feed
- response recommendations

Example:

```text
NETWORK

Nodes: 87
Connected: 64
Partitions: 1
Gateway: OFFLINE

INCIDENTS

🔴 Life Critical: 17
🟠 Emergency: 42
🟡 Operational: 81
```

---

# 29. Command Center's Most Important View

Don't make the dashboard just a map.

Create an **Operational Decision Panel**:

```text
INCIDENT #142

Recommended responder:
Responder B

Recommended route:
Route B

Network reachability:
91%

Hazard exposure:
LOW

WHY?
Responder A is closer but currently unreachable
through the affected network partition.
```

This makes the differentiator visible.

---

# 30. Disaster Simulator

Build in Python.

Libraries:

- NetworkX
- deterministic random seeds
- optional WebSocket/live API

Initial scenario:

- 100 virtual nodes
- 5 gateways
- 10 responders
- 20 incidents

Scale toward:

- 100–1000 nodes

Node attributes:

- ID
- GPS
- battery
- mobility
- neighbors
- role
- gateway distance
- stability

---

# 31. Simulator Failure Controls

Include:

- kill random nodes
- kill selected relay
- kill gateways
- create partition
- drain batteries
- restore gateway
- generate incidents
- change hazard zones
- move responders
- alter network coverage

The last three are especially important because they make the **response loop** dynamic rather than merely testing networking.

---

# 32. Key Simulator Scenarios

### Scenario 1 — Normal

Everything connected.

### Scenario 2 — Tower failure

Internet disappears.

### Scenario 3 — Relay failure

Partition forms.

Self-healing activates.

### Scenario 4 — Response adaptation

A responder loses connectivity.

Avertis changes recommendation.

### Scenario 5 — Hazard change

A route becomes unsafe.

Avertis changes route.

### Scenario 6 — Gateway recovery

Gateway becomes available for a short window.

Critical information syncs first.

### Scenario 7 — Mass incident

200 raw reports arrive.

Avertis deduplicates/fuses them before command-center presentation.

---

# 33. Resilience Benchmark

This is important for technical credibility.

Compare:

### Baseline

Conventional routing / static response selection.

### Avertis

Network-aware adaptive response.

Test:

- 20% node failure
- 50% node failure
- gateway disappearance
- battery depletion
- network partition
- responder disconnection

Measure actual results:

- critical message delivery rate
- emergency delivery latency
- recovery time
- network coverage
- battery consumption
- duplicate incidents
- recommendation stability
- response reroute time

Do **not** invent results.

Generate them from the simulator.

---

# 34. Replay System

Record:

- timestamp
- network event
- incident event
- topology change
- AI decision
- route change
- responder change
- gateway state

Example:

```text
08:17:00  NORMAL
08:17:12  TOWER FAILURE
08:17:14  AVERTIS ACTIVATED
08:17:19  SOS RECEIVED
08:17:21  PARTITION DETECTED
08:17:22  RELAY MIGRATED
08:17:23  NETWORK HEALED
08:17:31  RESPONDER A DISCONNECTED
08:17:33  RESPONSE REPLANNED
08:17:41  GATEWAY DETECTED
08:17:59  CRITICAL INCIDENTS SYNCED
```

---

# 35. Physical Demo Strategy

Use:

- 2–3 physical Android phones
- laptop simulator
- command center in browser

Physical phones prove:

- real BLE discovery
- real device-to-device communication
- offline SOS
- real mesh transport

Simulator proves:

- scale
- failures
- topology
- repeatability
- resilience metrics

Do not attempt to create 100 physical mesh devices.

---

# 36. Development Strategy

## Phase 0 — Contract

Both:

- freeze packet schema
- freeze incident schema
- freeze node schema
- freeze gateway API
- freeze ACK semantics
- freeze priority values

Create:

```text
docs/protocol.md
docs/api.md
docs/architecture.md
```

## Phase 1 — Simulator

You:

- graph
- virtual nodes
- links
- packets
- forwarding
- TTL
- dedup
- queues

Target:

```text
A → B → C
```

## Phase 2 — Self-Healing

You:

- heartbeat
- node failure
- partition detection
- relay scoring
- relay election
- recovery

Target:

```text
A → B → C

Kill B

A → D → C
```

## Phase 3 — Flutter

You:

- app shell
- Home
- SOS
- reports
- location
- offline state
- queue

Initially use:

`MockMeshTransport`

## Phase 4 — Backend

Teammate:

- FastAPI
- Firestore
- ADK
- Gemini
- Incident Agent
- `/incident/analyze`

Target:

```text
report → Gemini → structured incident
```

## Phase 5 — Integration

Both:

```text
Simulator
   ↓
Gateway API
   ↓
Backend
   ↓
Command Center
```

Do not wait for physical BLE.

## Phase 6 — Incident Intelligence

Teammate:

- severity
- fusion
- evidence
- confidence
- prioritization

## Phase 7 — Response Intelligence

Teammate:

- responder selection
- route recommendation
- network-aware decisioning
- WHY explanations
- Safety Agent

## Phase 8 — Network-aware loop

Both:

```text
network change
    ↓
world model update
    ↓
response evaluation
    ↓
new recommendation
```

This phase is the heart of the innovation.

## Phase 9 — Real BLE

You:

- implement BleMeshTransport
- Phone A → Phone B
- Phone A → Phone B → Phone C
- offline SOS
- failure testing

## Phase 10 — Integration + Polish

Both:

- simulator
- phones
- command center
- replay
- metrics
- deployment
- demo

---

# 37. Repository Structure

```text
avertis/
├── mobile/
│   ├── lib/
│   │   ├── core/
│   │   ├── data/
│   │   ├── domain/
│   │   ├── services/
│   │   └── features/
│   │       ├── home/
│   │       ├── sos/
│   │       ├── reports/
│   │       ├── mesh/
│   │       ├── incidents/
│   │       ├── routing/
│   │       └── map/
│   └── android/
│
├── backend/
│   ├── api/
│   ├── agents/
│   │   ├── coordinator/
│   │   ├── incident/
│   │   ├── network/
│   │   ├── response/
│   │   └── safety/
│   ├── models/
│   ├── services/
│   └── tests/
│
├── command-center/
│
├── simulator/
│   ├── topology/
│   ├── transport/
│   ├── scenarios/
│   ├── incidents/
│   ├── responders/
│   ├── metrics/
│   └── replay/
│
├── docs/
│   ├── protocol.md
│   ├── api.md
│   ├── architecture.md
│   ├── innovation.md
│   ├── benchmarks.md
│   └── demo.md
│
└── README.md
```

---

# 38. Google Cloud / Gemini Usage

Required platform elements should be visible and meaningful.

Use:

- Gemini
- Google ADK
- Cloud Run
- Firestore
- Cloud Storage
- Google Maps

Gemini should perform meaningful reasoning rather than being a decorative chatbot.

Strong Gemini workloads:

1. multimodal incident understanding
2. incident fusion
3. contextual severity
4. response recommendation
5. network-aware reasoning
6. WHY explanation
7. operational summary

---

# 39. GenAI Safety Architecture

Gemini should recommend, not directly execute dangerous real-world actions.

Human command-center approval should exist for:

- responder deployment
- evacuation recommendations
- high-risk route changes
- resource allocation

Deterministic systems enforce:

- packet safety
- TTL
- deduplication
- network constraints

This gives the system a strong human-in-the-loop story.

---

# 40. Hackathon Positioning

Primary theme:

> **Sustainability & Social Impact**

The project should be presented as infrastructure for disaster resilience and emergency response.

### Judging strategy

## Technical Merit & GenAI — 40%

Emphasize:

- Google ADK
- Gemini
- multimodal reasoning
- network-aware world model
- deterministic mesh engine
- simulator
- real BLE proof
- resilience benchmark

## Problem Alignment & Impact — 25%

Emphasize:

- infrastructure failure
- disaster communication gaps
- responder coordination
- information overload
- degraded connectivity

## Innovation & Creativity — 25%

Emphasize:

> **The communication network itself becomes part of the operational state used for response planning.**

## UX & Solution Design — 10%

Emphasize:

- simple SOS
- command-center map
- WHY explanations
- network-health visualization
- replay

---

# 41. What NOT to Claim

Do not say:

- "Nobody has built AI + mesh."
- "We invented disaster mesh."
- "We are the first AI emergency network."
- "Gemini controls the mesh."
- "This replaces emergency services."
- "This is production-ready nationwide."

Instead say:

> Existing research has demonstrated AI-enhanced disaster mesh communication. Avertis builds on that foundation and focuses on a different problem: making the **response decision itself network-aware and continuously adaptive**.

That is more credible.

---

# 42. What NOT to Build

Do not spend hackathon time on:

- satellite integration
- real drone hardware
- medical diagnosis
- full city-scale deployment
- complex flood physics
- reinforcement learning
- 10+ disaster categories
- production emergency-authority integration
- iOS parity
- elaborate accounts/social features
- hardware beyond phones
- custom LLM training

---

# 43. MVP

The minimum credible Avertis should demonstrate:

### Connectivity

- offline BLE
- multi-hop
- store-and-forward
- failure recovery

### Intelligence

- voice/text incident
- Gemini structuring
- incident fusion
- semantic priority

### Response

- responder selection
- network-aware route
- recommendation changes after network failure
- WHY explanation

### Command

- map
- network state
- incidents
- responders
- AI activity

### Scale

- 100+ simulated nodes
- repeatable failures
- measurable benchmark

---

# 44. Killer Demo Flow

## 0:00 — Normal city

Show:

```text
100 simulated nodes
5 gateways
10 responders
20 incidents
```

## 0:15 — Disaster

Start disaster.

Cell towers disappear.

```text
INTERNET: OFFLINE
AVERTIS MESH: ACTIVE
```

## 0:30 — Survivor report

Speak an emergency report.

Gemini converts it into:

```text
FLOOD RESCUE
3 PEOPLE
LIFE CRITICAL
LOCATION: ...
```

## 0:50 — Mesh propagation

Show the incident traveling across multiple nodes.

## 1:05 — Incident fusion

Multiple reports become one structured incident.

## 1:20 — First response recommendation

Avertis chooses a responder and route.

Show WHY.

## 1:35 — Kill relay

```text
RELAY LOST
PARTITION DETECTED
```

## 1:45 — Self-healing

```text
SELECTING REPLACEMENT
NETWORK HEALED
```

## 1:55 — Response changes

Responder A is now poorly connected.

Avertis changes to Responder B.

This is the **signature moment**.

## 2:10 — Gateway returns

```text
18 SECONDS CONNECTIVITY
200 REPORTS QUEUED
```

## 2:20 — Critical-first sync

```text
LIFE CRITICAL → SYNC
EMERGENCY → SYNC
OPERATIONAL → SYNC
NORMAL → QUEUE
```

## 2:35 — Command center

Show incidents arriving.

## 2:45 — Replay

Replay:

```text
DISASTER
→ NETWORK FAILURE
→ SOS
→ PARTITION
→ SELF-HEAL
→ RESPONSE REPLAN
→ GATEWAY
→ SYNC
```

## Closing line

> **Avertis doesn't just detect a disaster. It continuously adapts the response as both the disaster and the communication network change.**

---

# 45. Definition of Done

Avertis is demo-ready when these work reliably:

1. Launch 3 Android phones.
2. Discover nearby nodes.
3. Disable internet.
4. Send SOS.
5. Route through mesh.
6. Store incident locally.
7. Process report with Gemini.
8. Fuse duplicate reports.
9. Kill relay.
10. Detect partition.
11. Elect replacement relay.
12. Heal network.
13. Update operational state.
14. Detect responder connectivity loss.
15. Recalculate response recommendation.
16. Explain WHY.
17. Restore gateway.
18. Queue large batch of reports.
19. Synchronize critical incidents.
20. Display incidents on command-center map.
21. Show resilience metrics.
22. Replay the event.

If all 22 work consistently:

> **Stop adding features.**

---

# 46. First-Day Checklist

## You

- [ ] Install Flutter
- [ ] Create Android project
- [ ] Run on emulator
- [ ] Create `MeshTransport`
- [ ] Create `MockMeshTransport`
- [ ] Create Node model
- [ ] Create Packet model
- [ ] Build 3-node simulator
- [ ] Implement A → B → C
- [ ] Implement TTL
- [ ] Implement deduplication
- [ ] Commit

## Teammate

- [ ] Create Google Cloud project
- [ ] Create FastAPI project
- [ ] Create ADK project
- [ ] Connect Gemini
- [ ] Create Pydantic Incident model
- [ ] Implement `/incident/analyze`
- [ ] Create Firestore collections
- [ ] Create command-center shell
- [ ] Implement gateway sync endpoint
- [ ] Commit

## Together

- [ ] Freeze protocol
- [ ] Freeze gateway API
- [ ] Create JSON fixtures
- [ ] Test simulator → backend
- [ ] Agree on Git workflow
- [ ] Define benchmark metrics
- [ ] Define first response-replanning scenario

---

# 47. Final Product Story

Avertis is not a Bluetooth mesh product.

It is not merely an AI disaster chatbot.

It is not simply an emergency dashboard.

It is:

> **An adaptive disaster-response intelligence system that maintains situational awareness even when communication infrastructure fails, and continuously replans response as the physical disaster and network topology change.**

The mesh is the resilient communication layer.

Gemini is the reasoning layer.

The simulator proves resilience and scale.

The command center provides human oversight.

The differentiator is the feedback loop between them.

---

# 48. The One-Sentence Pitch

> **Avertis is an AI-powered disaster-response intelligence platform that understands both the disaster and the communication network, continuously adapting who responds, how they reach victims, and what information gets through when infrastructure fails.**

---

# 49. The One-Sentence Innovation Claim

> **Unlike systems that use AI to prioritize disaster messages over a resilient network, Avertis makes the network itself part of the response decision—so when connectivity changes, the recommended responder and rescue route can change automatically.**

---

# 50. The Golden Principle

Build Avertis around one idea:

> **When the world changes, the network changes. When the network changes, the best response can change. Avertis connects those two facts.**
