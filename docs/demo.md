# Avertis Demo Runbook (my half)

What I can demonstrate today, and exactly how to reproduce it. Backend, Gemini
and command centre are my teammate's half and are not covered here.

---

## 0. One-time setup

```bash
cd simulator && python3 -m venv .venv && .venv/bin/pip install networkx httpx pytest
```

```bash
cd mobile && flutter pub get
```

Toolchain notes that cost me time, so they are written down:

- The Kotlin compiler in the Android build **fails on the IBM Semeru (OpenJ9)
  JVM** with `ClassNotFoundException: javaslang.λ`. Use a HotSpot JDK:
  `flutter config --jdk-dir /opt/homebrew/opt/openjdk@17`.
- `record` 5.x pulls a `record_linux` that does not satisfy its own platform
  interface and breaks the Dart build. Pinned to `^6.1.2`.

---

## 1. The signature demo — the recommendation changes (plan §7)

```bash
cd simulator && .venv/bin/python -m avertis_sim run response_adaptation
```

Add `--api <url> --api-key <key> --pace 12` to run it against a real
backend and watch it on the command centre instead of reading it here. The
scenario syncs each state as it reaches it, so the dashboard's own
recommendation moves A → B → A. `--pace` is not optional for that: the
whole run takes 0.2 s otherwise, every state arrives inside one dashboard
poll, and only the last one is ever seen.

Nothing physical moves. The responders stay where they are, the hazards do not
change, the incident does not change. A single relay dies, and the recommended
responder flips:

```
RELAY R7 FAILED
  → NODE LOST R7
  → RELAY MIGRATED → R2
  → RESPONSE: Responder B (92% reliability)

WHY: Responder B recommended: 0.3 km out, 92% measured network reliability to
the incident over 3 mesh hops, hazard exposure LOW. Responder A is closer
(0.2 km) but is currently in a separate network partition and cannot be
reached through the mesh.
```

Then R7 is restored and the recommendation returns to Responder A — the loop
closes in both directions, so it is not a one-way scripted trick.

The distance-only baseline is run side by side and **keeps choosing the
unreachable responder**. That contrast is the whole argument.

## 2. Self-healing (plan §18)

```bash
.venv/bin/python -m avertis_sim run relay_failure
```

Kills the true articulation point of the graph, then shows failure detection by
beacon timeout → partition detection → replacement relay election → route
change → recovery. Recovery time is measured, not asserted.

## 3. Gateway recovery and critical-first sync (plan §32 scenario 6)

```bash
.venv/bin/python -m avertis_sim run gateway_recovery
```

Produces the plan's demo moment with real numbers:

```
252 report copies arrived at gw-01 but they are only 142 distinct reports
an 18s window carried 92 report(s) (53971 bytes), 50 deferred
92/93 LIFE_CRITICAL report(s) went in the first window
```

The window budget genuinely binds — one life-critical report did *not* fit and
waits for the next window. That is the honest result, not a tuned one.

## 4. All seven scenarios

```bash
.venv/bin/python -m avertis_sim run all --replay out/all.jsonl
```

## 5. The resilience benchmark (plan §33)

```bash
.venv/bin/python -m avertis_sim benchmark --nodes 100 --seeds 3
```

Headline, on contested decisions (closest responder cut off, another
reachable): the distance-only baseline dispatches an unreachable responder
**11/11 times**; Avertis **0/11**. Full numbers and caveats in
`docs/benchmarks.md`.

## 6. Replay (plan §34)

```bash
.venv/bin/python -m avertis_sim replay out/all.jsonl
```

The replay file *is* the event log the UI consumed live, so it cannot drift
from what actually happened.

## 7. The phone

```bash
cd mobile && flutter run
```

- Home states connectivity plainly (Internet OFFLINE / Mesh CONNECTED), nearby
  node count, measured mesh health, battery, and anything held in custody.
- SOS is one screen and one tap. It persists to SQLite **before** transmitting,
  so a process death cannot lose it.
- The status shown is deliberately conservative: a report says "waiting for
  acknowledgement" until an end-to-end ACK arrives. It never claims delivery it
  cannot prove.
- Mesh detail shows live neighbours with measured link stability, plus the
  running forwarded/delivered/dropped counters.
- Location is real: the SOS screen states whether it has a fix and its
  accuracy, whether the fix is stale, or that it has none. It never claims a
  location it does not have.

Verified on an Android emulator (Pixel 7, API 35): an SOS was sent with no
nodes in range, persisted to SQLite, survived an app reinstall, was
re-offered to the mesh on next launch, and was shown throughout as "waiting
to be confirmed" rather than delivered.

### Multi-phone mesh demo (Phase 9)

Set the transport to BLE (`transportModeProvider` → `TransportMode.ble`) and
install on 2–3 phones. Phone A → Phone B → Phone C with B's Bluetooth turned
off mid-demo shows detection, re-election and recovery on real radios.

**Status.** Both BLE roles are now implemented. `flutter_blue_plus` provides
only the central half — it cannot advertise or host a GATT server — so a
Kotlin platform channel supplies the peripheral half. Before that was added
the transport could not have worked at all: every node scanned for a service
nothing advertised.

It has still **never run on physical handsets**. Emulators have no BLE radio,
so this cannot be closed here at any level of effort — it needs two phones.
What is proven: the framing (fragmentation, out-of-order reassembly, corrupt
and runt frames), the channel contract and its failure modes, and every layer
above the transport against the mock radio. What is unproven: that two real
Android radios discover each other, negotiate an MTU, and sustain a
connection. Budget real time for this; it is the classic place a BLE project
loses a day.

Note also that two emulator instances cannot substitute: each app process has
its own in-process `MockRadioSpace`, so they do not see each other either.

### Background relaying

Verified on the emulator both ways. With permissions granted the service
reports `isForeground=true` with the `connectedDevice` type and an ongoing
notification that mirrors neighbours, queue depth and custody. With every
permission denied the app runs normally, zero crashes, and the home screen
says the phone will only relay while Avertis is open.

---

## What I would not claim on stage

- That the mesh routes better than established protocols — the forwarding
  policy is a deliberately transparent baseline (docs/protocol.md §8).
- That the simulator's radio model predicts real BLE throughput.
- That network-aware dispatch helps in general. It changes nothing on a
  well-connected mesh, and `docs/benchmarks.md` says so with the numbers that
  show it.
