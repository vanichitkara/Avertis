# Avertis

**Intelligence that keeps response moving.**

An adaptive disaster-response platform that understands both the physical
disaster and the communication network, and continuously re-plans response as
either one changes.

> Existing research has already demonstrated AI-enhanced disaster mesh
> communication. Avertis builds on that foundation and focuses on a different
> problem: making the **response decision itself network-aware and
> continuously adaptive**.

---

## Repository

```text
avertis/
├── docs/           protocol.md · api.md · architecture.md · benchmarks.md · demo.md
│                   fixtures/  ← shared conformance fixtures
├── mobile/         Flutter app + Dart mesh engine        (this workstream)
├── simulator/      Python mesh simulator + benchmark     (this workstream)
├── backend/        FastAPI · ADK · Gemini                (teammate)
└── command-center/ web dashboard                          (teammate)
```

## Ownership

| Mine | My teammate's |
|---|---|
| Flutter Android app | FastAPI, Cloud Run |
| Mesh engine + protocol | Google ADK, Gemini agents |
| BLE + mock transports | Incident extraction and fusion |
| Store-and-forward, self-healing | Response reasoning, WHY generation |
| Disaster simulator, benchmark, replay | Firestore, Cloud Storage |
| Gateway client | Gateway API server, command centre |

Shared and frozen in Phase 0: `docs/protocol.md`, `docs/api.md`.

## Golden principle

> **Gemini reasons *about* the network; deterministic code *operates* the
> network.**

No LLM is ever in the packet-hop path.

---

## Quick start

### Simulator

```bash
cd simulator && python3 -m venv .venv && .venv/bin/pip install networkx httpx pytest
```

```bash
cd simulator && .venv/bin/python -m avertis_sim run response_adaptation
```

```bash
cd simulator && .venv/bin/python -m avertis_sim benchmark --nodes 100 --seeds 3
```

### Mobile

```bash
cd mobile && flutter pub get && flutter run
```

Requires a HotSpot JDK — the Kotlin compiler fails on IBM Semeru/OpenJ9. See
`docs/demo.md`.

### Tests

```bash
cd simulator && .venv/bin/python -m pytest -q
```

```bash
cd mobile && flutter test
```

---

## Status

**Done and tested**

- Frozen protocol, gateway API and architecture docs (Phase 0)
- Python mesh engine: forwarding, TTL, dedup, ACKs, priority queues,
  store-and-forward, report custody (Phases 1–2)
- Heartbeat failure detection, partition detection, relay election,
  self-healing
- Dart mesh engine, byte-identical to the Python one against shared fixtures
- Mock and BLE transports behind one abstraction. BLE runs **both** roles:
  `flutter_blue_plus` for the central half, and a Kotlin platform channel for
  the peripheral half (advertising + GATT server) it does not implement
- Flutter app: home, SOS, incident report, report list, mesh detail; reports
  persisted to SQLite before transmission, and unacknowledged reports
  re-offered to the mesh on next launch (Phase 3)
- Real GPS via geolocator, with the UI stating exactly what it knows —
  a fix and its accuracy, a stale fix, or no fix at all
- Voice reports (60 s cap, descriptor over the mesh, audio at the gateway)
- Foreground service so the mesh keeps relaying with the screen off, with the
  home screen saying plainly when it is not running
- Offline situation view: live bearings, distances and link quality drawn from
  measured state — no tiles, no API key, no network
- Verified running on an Android emulator: SOS sent, persisted, restored
  after a reinstall, and correctly shown as "waiting to be confirmed"
- Gateway client with critical-first sync under a window budget, both languages
- Seven scenarios, resilience benchmark, replay system
- Mock gateway API server — a reference implementation of the contract for
  the backend workstream, plus HTTP integration tests against it
- 106 backend, 53 simulator and 109 mobile tests, Android APK builds and runs

**Not done**

- **BLE has never run on real radios.** Both roles are implemented and their
  pure logic is tested, but no two physical phones have ever exchanged a
  packet. Emulators have no BLE, so this cannot be closed without hardware —
  it is the one gap that only handsets can close.
- Everything on my teammate's side, and the integration against it
For the pitch and submission text, see `docs/overview.md`.

To deploy, see `docs/deployment.md`.

Before submitting, work through `docs/pre-submission-checklist.md`.

See `docs/demo.md` for what can be demonstrated today and `docs/benchmarks.md`
for measured results, including the ones that are unflattering.
