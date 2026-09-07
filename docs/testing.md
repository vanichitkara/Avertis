# Testing Avertis yourself

Everything below has been run on this machine. Commands are from the repo root.

```bash
source tool/env.sh
```

That puts Flutter, `adb`, the emulator and JDK 17 on `PATH` **for that shell
only** — nothing was written to your `~/.zshrc`. To make it permanent, copy the
three `export` lines out of `tool/env.sh`.

---

## 1. The fastest check that nothing is broken

```bash
source tool/env.sh
(cd mobile && flutter test) && (cd simulator && .venv/bin/python -m pytest -q)
```

Expect **84 Dart tests** and **51 Python tests**, all passing, in about five
seconds. If either fails, stop — everything below assumes these pass.

---

## 2. The simulator (no phone, no emulator, no backend)

This is where the mesh is actually proven, and it needs nothing but Python.

```bash
cd simulator
.venv/bin/python -m avertis_sim list          # the 7 scenarios from plan §32
.venv/bin/python -m avertis_sim run relay_failure
```

`relay_failure` is the one to look at first: it kills a relay mid-run, and you
should see partitions form, replacement relays elected, and delivery continue.
The `FINDINGS` block at the end names the specific node it killed and what that
cost.

Run everything, then the benchmark:

```bash
.venv/bin/python -m avertis_sim run all
.venv/bin/python -m avertis_sim benchmark
```

The benchmark compares a distance-only responder selector against the
network-aware one under node loss. **Read its caveats** — it prints them
itself. The headline is not the overall average (the two selectors agree on a
healthy mesh, and should); it is the *contested* decisions, where the closest
responder is cut off. That is the signature claim, and it is measured rather
than asserted.

Replay a run as a timeline:

```bash
.venv/bin/python -m avertis_sim run tower_failure --replay /tmp/run.jsonl
.venv/bin/python -m avertis_sim replay /tmp/run.jsonl
```

### Simulator against a gateway

There is a mock gateway server implementing the frozen `/api/v1/gateway/sync`
contract, so the sync path is testable before the real backend exists:

```bash
.venv/bin/python -m avertis_sim.mock_gateway_server        # terminal 1
.venv/bin/python -m avertis_sim run gateway_recovery \
    --gateway http://127.0.0.1:8787                        # terminal 2
```

The mock server also implements `POST /api/v1/media/upload`, so the mobile
upload path is testable before the backend exists:

```bash
curl -X POST http://127.0.0.1:8787/api/v1/media/upload \
  -F media_id=med-1 -F report_id=rpt-1 -F sha256=abc -F file=@some.jpg
curl http://127.0.0.1:8787/api/v1/debug/state    # media count should rise
```

When your teammate's backend is up, point `--gateway` at it instead. If the
contract in `docs/api.md` holds, nothing else changes.

### Pointing the app at a backend

The app has no backend by default, which is the honest default for something
built to work without one. Supply it at build time:

```bash
flutter run --dart-define=AVERTIS_API_BASE=http://10.0.2.2:8787
```

`10.0.2.2` is how the Android emulator reaches your Mac's localhost. Without
this the mesh runs exactly as it otherwise would, holding reports in custody
until a gateway appears.

---

## 3. The app on an emulator

```bash
source tool/env.sh
emulator -avd avertis_test -no-snapshot-load &
adb wait-for-device
cd mobile && flutter run
```

The emulator has **no Bluetooth radio**, so the app runs on the mock transport
— the home screen says `simulated radio`, so you are never misled about which
one you are looking at. What you can check here:

- SOS, incident reports, voice recording, photo attachment
- reports persisting across a force-quit (custody is on disk)
- the situation view's range rings and its "no nodes in range" state
- location: `adb emu geo fix 77.5946 12.9716`, then reopen the situation view

To see the background-relay warning, deny the permissions:

```bash
for p in BLUETOOTH_SCAN BLUETOOTH_CONNECT POST_NOTIFICATIONS; do
  adb shell pm revoke com.avertis.avertis android.permission.$p
done
adb shell am force-stop com.avertis.avertis
adb shell am start -n com.avertis.avertis/.MainActivity
```

The home screen should show the amber warning, and the app should not crash.
After granting them back, confirm the foreground service is genuinely in the
foreground rather than merely started:

```bash
adb shell dumpsys activity services com.avertis.avertis | grep -i isForeground
```

You want `isForeground=true` with `types=0x00000010`. A `startForegroundCount=0`
means it started but never entered the foreground — that is the failure mode
that silently stops background relaying, and it is what caught the crash during
development.

---

## 4. Two phones over real BLE — the part that is unproven

**This has never been run.** Emulators have no BLE, and two emulator instances
cannot substitute either: each app process has its own in-process mock radio,
so they do not see each other. Only handsets can close this.

You need two Android phones with developer mode and USB debugging enabled.

```bash
source tool/env.sh
adb devices                      # expect two serials
cd mobile
flutter run -d <serial-A>        # terminal 1
flutter run -d <serial-B>        # terminal 2
```

Grant every permission when prompted — Bluetooth is refused silently
otherwise. Then switch each phone to the BLE transport from the mesh screen.

Work through it in this order, and expect to debug:

1. **Do they see each other?** `Nearby nodes` should reach 1 on both. If one
   stays at 0, check the mesh screen for the advertising warning — some
   handsets cannot advertise at all, which the app reports rather than hides.
   If neither sees the other, the peripheral half is not running:
   `adb logcat | grep AvertisBle` will say why.
2. **Does one packet cross?** Send an SOS from A. It should appear in B's mesh
   activity feed.
3. **Does a large one cross?** Attach a photo. This exercises fragmentation and
   reassembly, which is where MTU assumptions break.
4. **Three phones, two hops.** Put C out of A's range and confirm A→B→C. This
   is the actual multi-hop claim.
5. **Screen off.** Lock B and confirm it still relays for A. This is what the
   foreground service exists for.

Things that plausibly go wrong, none of which are visible from a laptop: the
180-byte fragment assumption being wrong for a given pair, Android 12+
permission behaviour differing by manufacturer, a handset that cannot
advertise, and background scan throttling. Budget real time for this — it is
the classic place a BLE project loses a day.

---

## 5. What a green test run does and does not prove

Proven: the protocol (both implementations agree on the shared fixtures),
routing, TTL, dedup, queueing, partition detection, relay election, healing,
custody across restarts, the gateway sync contract, BLE framing, and the app's
screens.

Not proven: that two real Android radios talk to each other. Everything above
the transport is transport-agnostic and is exercised against the mock radio,
which is the point of the abstraction — but the abstraction is exactly what a
real radio gets to violate.
