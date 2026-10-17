# Avertis

> **Intelligence that keeps response moving.**

Avertis is an offline-first disaster-response platform that combines a Bluetooth Low Energy (BLE) mesh, incident intelligence, and network-aware responder recommendations. It is designed for the moments when normal communications are degraded or unavailable: phones relay reports across a local mesh, gateways synchronise when a connectivity window appears, and an operator sees recommendations that account for both the emergency and the state of the network.

The central idea is simple: the closest responder is not always the best responder if they cannot reliably communicate with the incident. Avertis continuously re-evaluates recommendations as the incident picture _or_ mesh topology changes.

## Highlights

- **Offline-first reporting:** create SOS, text, voice, and photo reports without depending on mobile data.
- **Resilient BLE mesh:** multi-hop forwarding, deduplication, acknowledgements, TTL, priority queues, store-and-forward custody, relay election, and partition detection.
- **Network-aware response:** recommendations consider reachability, path reliability, distance, and hazard exposure—not distance alone.
- **Human-in-the-loop operations:** Avertis recommends; an operator reviews and approves a dispatch.
- **Transparent intelligence:** Gemini can structure reports, assist fusion, and explain decisions, while deterministic code remains responsible for routing and responder selection.
- **Measurable resilience:** a repeatable Python simulator provides failure scenarios, benchmarks, and replayable timelines.

## How it works

```text
Mobile node                 Mesh / gateway                 Operations
───────────                 ──────────────                 ──────────
SOS, text, voice, photo → BLE relay network → connectivity window → FastAPI service
     │                            │                                  │
     └─ local SQLite custody      └─ topology + reports               ├─ incident fusion
                                                                  ├─ network-aware recommendation
                                                                  └─ command-centre dashboard
```

The mesh is deliberately independent of the AI layer. If a model or the internet is unavailable, reporting, forwarding, network analysis, and deterministic fallback reasoning continue to work.

## Repository layout

```text
avertis/
├── mobile/           Flutter Android app and Dart mesh engine
├── simulator/        Python mesh simulator, scenarios, metrics, and replay
├── backend/          FastAPI service, deterministic/Gemini reasoning, storage
├── command-center/   Browser-based operational dashboard
├── docs/             Architecture, API, testing, deployment, and demo guides
├── tool/             Local development helpers
└── Dockerfile        One-service Cloud Run image for backend + dashboard
```

## Technology stack

| Area           | Technologies                                                                            |
| -------------- | --------------------------------------------------------------------------------------- |
| Mobile         | Flutter, Dart, Riverpod, GoRouter, Drift/SQLite, Bluetooth LE, Kotlin platform channels |
| Backend        | Python, FastAPI, Pydantic, Uvicorn; optional Gemini, Firestore, and Cloud Storage       |
| Simulation     | Python, NetworkX, HTTPX, pytest                                                         |
| Command centre | HTML, CSS, and vanilla JavaScript                                                       |
| Deployment     | Docker and Google Cloud Run                                                             |
| Quality        | Flutter test, pytest, shared protocol fixtures, integration tests                       |

## Quick start

The fastest way to see Avertis's core behaviour is the deterministic simulator. It requires no cloud credentials, backend, phone, or emulator.

```bash
cd simulator
python3 -m venv .venv
.venv/bin/pip install networkx httpx pytest
.venv/bin/python -m avertis_sim run response_adaptation
```

The `response_adaptation` scenario keeps the physical incident unchanged, fails a relay, detects the partition, and changes the recommended responder based on reachability. Restore the relay and the recommendation changes back.

Explore the remaining scenarios and benchmark with:

```bash
.venv/bin/python -m avertis_sim list
.venv/bin/python -m avertis_sim run relay_failure
.venv/bin/python -m avertis_sim benchmark --nodes 100 --seeds 3
```

## Local development

### Prerequisites

- Python 3.11+ recommended
- Flutter with Dart 3.9+ for the mobile app
- Android SDK, emulator or device for Android development
- A HotSpot JDK (JDK 17 is the tested Android toolchain)
- Docker and the Google Cloud CLI only if you plan to build or deploy the cloud service

The backend runs with no credentials. Gemini, Firestore, Cloud Storage, and a shared API key are optional enhancements.

### Run the backend and command centre

From the repository root, create an isolated Python environment and start FastAPI:

```bash
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m uvicorn avertis_backend.main:app --reload --port 8000
```

Open [http://127.0.0.1:8000](http://127.0.0.1:8000) for the command centre, or check the active local configuration at [http://127.0.0.1:8000/api/v1/health](http://127.0.0.1:8000/api/v1/health). By default, the service uses deterministic rules, in-memory state, and local media storage.

To drive the local dashboard with simulated events, use a second terminal:

```bash
cd simulator
.venv/bin/python -m avertis_sim run response_adaptation --api http://127.0.0.1:8000
```

### Run the mobile app

```bash
cd mobile
flutter pub get
flutter run
```

To let a device or emulator sync to a backend, provide its base URL at build/run time:

```bash
flutter run \
  --dart-define=AVERTIS_API_BASE=http://10.0.2.2:8000
```

`10.0.2.2` is the Android Emulator's route to a service running on the host machine. Use a LAN-reachable host address for a physical device. If the backend has an API key configured, also provide `--dart-define=AVERTIS_API_KEY=...`; do not commit secrets or add them to source files.

### Enable optional cloud-backed capabilities

Copy the template and configure only the services you need:

```bash
cp backend/.env.example backend/.env
```

| Variable            | Effect                                                                                                           |
| ------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `GEMINI_API_KEY`    | Enables Gemini-assisted report structuring, fusion, summaries, and explanations. Install `google-genai` as well. |
| `FIRESTORE_PROJECT` | Persists operational state beyond process restarts. Install `google-cloud-firestore`.                            |
| `STORAGE_BUCKET`    | Stores uploaded media durably in Cloud Storage. Install `google-cloud-storage`.                                  |
| `AVERTIS_API_KEY`   | Requires the `X-Avertis-Key` header for write endpoints.                                                         |

The service advertises its actual reasoning, persistence, and media backends at `/api/v1/health`, so a fallback mode is never represented as a cloud-backed one.

## Testing

Run the relevant suite from each component directory:

```bash
cd simulator && .venv/bin/python -m pytest -q
cd backend && .venv/bin/python -m pytest -q
cd mobile && flutter test
```

The Dart and Python mesh engines share protocol fixtures in [`docs/fixtures/`](docs/fixtures/) to keep packet formats and core calculations aligned.

For a full local verification and end-to-end walkthrough, see [the testing guide](docs/testing.md).

## Architecture and design choices

### Network-aware, not network-dependent

Avertis treats network topology as part of the operating picture. The gateway sends nodes, links, partitions, and report data together; the backend uses this combined view to assess whether a responder is both physically suitable and communicatively reachable.

### Deterministic operations, assistive AI

The project follows one governing rule:

> **Gemini reasons about the network; deterministic code operates the network.**

No model is in the packet-hop path. Routing, forwarding, relay election, partition detection, reachability, and final responder scoring are deterministic and auditable. Model output is validated and can fall back to rules when unavailable.

### Safety and operator control

Recommendations carry supporting measurements and safety flags, but they do not autonomously dispatch responders. Approval is an explicit operator action and recorded in the activity trail.

Read the complete [architecture guide](docs/architecture.md) and [gateway API contract](docs/api.md) for data flow and endpoint details.

## Documentation

- [Project overview and evidence](docs/overview.md)
- [Architecture](docs/architecture.md)
- [Gateway API contract](docs/api.md)
- [Demo runbook](docs/demo.md)
- [Testing guide](docs/testing.md)
- [Two-phone BLE testing](docs/two-phone-testing.md)
- [Deployment guide](docs/deployment.md)
- [Benchmarks and caveats](docs/benchmarks.md)

## Deployment

The root [`Dockerfile`](Dockerfile) packages the backend and command centre in one Cloud Run service. For local work, the in-memory backend needs no credentials. For a durable deployment, configure Firestore and Cloud Storage, then follow the [deployment guide](docs/deployment.md).
