# Avertis Architecture (Phase 0)

## Golden principle

> **Gemini reasons *about* the network; deterministic code *operates* the network.**

| Deterministic (my side)                | AI / ADK (teammate's side)          |
|----------------------------------------|--------------------------------------|
| packet forwarding, TTL, dedup, ACKs     | report interpretation, multimodal fusion |
| heartbeat, failure + partition detection| semantic prioritization              |
| relay scoring and election              | response recommendation              |
| routing, queues, store-and-forward      | network-aware reasoning, WHY explanations |

No LLM is ever in the packet-hop path.

---

## Component map

```text
        mobile/ (Flutter, Android)            simulator/ (Python)
        ┌──────────────────────┐              ┌──────────────────────┐
        │ features/ (UI)       │              │ scenarios/           │
        │  home sos reports    │              │ metrics/ replay/     │
        │  mesh map            │              │ incidents/ responders│
        ├──────────────────────┤              ├──────────────────────┤
        │ mesh/ MeshEngine     │  same algo   │ mesh/ MeshEngine     │
        │  router queue relay  │◄────────────►│  router queue relay  │
        │  topology healing    │  same proto  │  topology healing    │
        ├──────────────────────┤              ├──────────────────────┤
        │ MeshTransport (abs)  │              │ MeshTransport (abs)  │
        │  ├ MockMeshTransport │              │  └ SimTransport      │
        │  └ BleMeshTransport  │              │     (radio model)    │
        └──────────┬───────────┘              └──────────┬───────────┘
                   │           GatewayClient             │
                   └──────────────────┬──────────────────┘
                                      ▼
                          POST /api/v1/gateway/sync
                                      ▼
                    backend/ FastAPI · ADK · Gemini · Firestore
                                      ▼
                              command-center/
```

The **transport abstraction is the critical seam**: the mesh engine has no
Bluetooth dependency, so every routing, healing and partition behaviour is
developed and tested on the laptop long before physical BLE works, and the same
logic then runs unchanged on the phones.

---

## The two implementations, and why

There are deliberately two mesh engines — Dart (on device) and Python (in the
simulator) — rather than one shared core:

- The **phones** must prove the protocol works over real BLE with real radios.
- The **simulator** must prove scale (100–1000 nodes), repeatable failures and
  benchmark numbers, which phones cannot.

They are kept honest by `docs/protocol.md` plus shared JSON fixtures in
`docs/fixtures/`: both sides must produce byte-identical packets and identical
relay scores for the fixture inputs. That check runs in both test suites.

---

## World model split

```text
PHYSICAL STATE                    NETWORK STATE
├ incidents                       ├ nodes (battery, role, location)
├ hazards                         ├ links (stability, rssi)
├ responders                      ├ partitions (connected components)
├ shelters / hospitals            ├ gateways + connectivity windows
└ routes                          └ reachability, queue depth
```

My side **produces** the network state (from the real mesh or the simulator)
and ships it in every `gateway/sync`. My teammate's Response Agent **consumes**
both halves. The signature behaviour — kill a relay, the recommended responder
changes — is exactly this: my side reports a topology change, their side
re-plans on it.

---

## Data flow for the signature demo

```text
1. survivor taps SOS on the phone
2. MeshEngine persists locally (Drift/SQLite) then broadcasts SOS packet
3. packet multi-hops; each hop dedups, decrements TTL, appends path
4. gateway node receives it, queues it for sync
5. connectivity window opens → critical-first sync → backend
6. Gemini structures + fuses → INC-1042
7. Response Agent picks responder A (close, well connected)
8. simulator kills relay R7
9. mesh detects DOWN → partition → re-elects relay → emits events
10. next sync carries the new topology: responder A now unreachable
11. Response Agent re-plans → responder B, with a WHY grounded in real state
```

Steps 1–5 and 8–10 are mine. Steps 6–7 and 11 are my teammate's.

---

## Repository layout

```text
avertis/
├── docs/           protocol.md · api.md · architecture.md · fixtures/
├── mobile/         Flutter app + Dart mesh engine
├── simulator/      Python mesh simulator, scenarios, metrics, replay
├── backend/        (teammate) FastAPI · ADK · Gemini
└── command-center/ (teammate) web dashboard
```

---

## Non-goals (see plan §42)

Satellite links, drone hardware, medical diagnosis, RL, custom model training,
iOS parity, city-scale deployment, real emergency-authority integration. The
command center is explicitly a **simulated** disaster-management centre.
