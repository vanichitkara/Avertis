# Pre-submission end-to-end test

Work through this once, in order, before recording the demo video. Every
command here has been run on this machine; where something is known to be
flaky, it says so and says what to do.

Budget roughly **90 minutes**, plus however long the BLE section takes — that
part is genuinely unpredictable.

Tick the boxes as you go. Anything that fails, stop and fix before recording:
a demo video is the worst place to discover a problem.

---

## 0. Before you start

```bash
cd ~/Documents/Avertis
source tool/env.sh
```

That puts Flutter, `adb`, the emulator and JDK 17 on `PATH` **for that shell
only**. Every later step assumes you ran it in that terminal.

- [ ] It prints four lines: flutter, adb, java, and `avds avertis_test`.

> **zsh note.** Quote any URL containing `?` — `curl "http://…?limit=40"`.
> Unquoted, zsh tries to glob it and the command fails confusingly.

### Free the ports first

A server left running from an earlier session will refuse the next start
with `[Errno 48] address already in use`, and uvicorn prints that *after*
"Application startup complete", which reads as if it worked.

```bash
lsof -ti:8000 -ti:8080 | xargs kill -9 2>/dev/null; true
```

- [ ] `lsof -ti:8000; lsof -ti:8080` prints nothing.

---

## 1. The automated gate (2 minutes)

```bash
(cd mobile && flutter test) \
  && (cd simulator && .venv/bin/python -m pytest -q) \
  && (cd backend && .venv/bin/python -m pytest -q)
```

- [ ] **109** mobile, **53** simulator, **106** backend — all passing.

If any fail, nothing below is meaningful. These never touch the network and
never call Gemini, so a failure is a real code problem, not a flaky API.

---

## 2. Backend and command centre (5 minutes)

Three terminals from here on. Terminal 1:

```bash
cd ~/Documents/Avertis/backend
.venv/bin/python -m uvicorn avertis_backend.main:app --host 0.0.0.0 --port 8000
```

Terminal 2:

```bash
cd ~/Documents/Avertis/command-center
python3 -m http.server 8080
```

Terminal 3 is where you run everything else.

```bash
curl -s http://127.0.0.1:8000/api/v1/health | python3 -m json.tool
```

- [ ] `status: ok`
- [ ] `reasoning.is_model: true` and the engine names a Gemini model.

**If `is_model` is false**, read `reasoning.note` — it says which step is
missing. Usually either the key is absent from `backend/.env` or
`google-genai` is not installed. Do not proceed: the Gemini story is a large
part of the judging.

**If you get 503 or 504 from Gemini**, the flagship model is rate-spiked. This
happened repeatedly during testing. Put this in `backend/.env` and restart:

```
GEMINI_MODEL=gemini-3.1-flash-lite
```

That model responded reliably. The backend falls back to rules on any model
failure, so a spike degrades quality rather than breaking the demo — but you
lose the Gemini narrative, which is the point of having it.

---

## 3. The signature moment (10 minutes) — **the most important step**

This is §7 of the plan and the 1:55 beat of the demo. If only one thing
works, make it this.

Open <http://127.0.0.1:8080/index.html?api=http://127.0.0.1:8000> and leave it
visible. Then in terminal 3:

```bash
cd ~/Documents/Avertis/simulator
.venv/bin/python -m avertis_sim run response_adaptation --api http://127.0.0.1:8000
```

The flag is `--api`, not `--gateway`.

Watch the **AI activity** panel. You are looking for this sequence:

```
RECOMMENDATION        resp-a for INC-0001 (100% reliability, 200 m)
PARTITION DETECTED    network split into 3 partitions (was 1)
RECOMMENDATION        resp-b for INC-0001 (70% reliability, 300 m)
RESPONSE REPLANNED    INC-0001: resp-a → resp-b
PARTITION HEALED      network rejoined into 1 partition(s)
RESPONSE REPLANNED    INC-0001: resp-b → resp-a
```

- [ ] `RESPONSE REPLANNED` appears **at least twice**.
- [ ] The decision panel's recommended responder changes on screen.
- [ ] **WHY?** opens and names a real figure — a distance or a percentage.

The claim to make in the video is narrow and true: *Responder A stayed
closer the whole time. Only the network changed, and the recommendation
followed it.* Do not claim the AI chose the responder — the selection is
deterministic by design so the same state always gives the same answer.
Gemini explains it and does the language work.

---

## 4. Incident fusion and scale (5 minutes)

```bash
.venv/bin/python -m avertis_sim run mass_incident --api http://127.0.0.1:8000
```

- [ ] The incidents panel shows a line like *"N duplicate report(s) absorbed
      into M incident(s)"*. Expect roughly 160 reports becoming ~60 incidents.
- [ ] Several incidents show more than one source.
- [ ] The topology canvas draws nodes in more than one colour — each colour is
      a partition, and a split network is visible as colours no link crosses.

Quote the absorbed-duplicates number in the video. It is measured, and it is
the clearest evidence of the information-overload argument.

---

## 5. Resilience benchmark (5 minutes)

```bash
.venv/bin/python -m avertis_sim benchmark
```

- [ ] It completes and prints the selector comparison.

**Read the caveats it prints, and quote the contested-decision number, not the
average.** On a healthy mesh both selectors agree and should — the value is
concentrated where the closest responder is cut off. Last run: the
distance-only baseline dispatched an unreachable responder in 11 of 11
contested decisions, the network-aware one in 0 of 11. That is the honest,
strong claim.

---

## 6. Replay (3 minutes)

```bash
.venv/bin/python -m avertis_sim run tower_failure --replay /tmp/run.jsonl
.venv/bin/python -m avertis_sim replay /tmp/run.jsonl
```

- [ ] A timeline prints with timestamps and events.

---

## 7. The app on the emulator (20 minutes)

```bash
emulator -avd avertis_test -no-snapshot-load &
adb wait-for-device
cd ~/Documents/Avertis/mobile
flutter run --dart-define=AVERTIS_API_BASE=http://10.0.2.2:8000
```

`10.0.2.2` is how the emulator reaches your Mac's localhost. Grant every
permission when prompted.

Give it a location: `adb emu geo fix 77.5946 12.9716`

- [ ] Home shows `Internet OFFLINE`, `simulated radio`, and a battery figure.
- [ ] **SOS** → pick a number of people → send. A report id appears.
- [ ] **Mesh screen** (hub icon) → GATEWAY card says *"1 report(s) waiting"*.
- [ ] **SYNC NOW** → the result line reports 1 delivered.
- [ ] The command centre shows that incident, **with the headcount you chose**.

That last point matters: the headcount travelling end to end was broken until
recently, and it is the easiest thing to regress.

Then check the honest-failure paths:

- [ ] **Report incident** → record a voice note; the elapsed counter and the
      60-second cap are visible.
- [ ] **Situation view** (radar icon) → range rings, north-up, your node
      centred, and "no nodes in range" (a lone emulator has no peers).
- [ ] Force-quit and reopen → unacknowledged reports are still there.

Background relaying:

```bash
adb shell dumpsys activity services com.avertis.avertis | grep -i isForeground
```

- [ ] `isForeground=true` with `types=0x00000010`.

Then revoke permissions and confirm it degrades rather than crashes:

```bash
for p in BLUETOOTH_SCAN BLUETOOTH_CONNECT POST_NOTIFICATIONS; do
  adb shell pm revoke com.avertis.avertis android.permission.$p
done
adb shell am force-stop com.avertis.avertis
adb shell am start -n com.avertis.avertis/.MainActivity
```

- [ ] The amber warning appears on the home screen and the app does not crash.
- [ ] Grant them back afterwards, or the next step will mislead you.

---

## 8. Two phones over real BLE — **unproven, allow real time**

Nothing in this project has ever run on a physical radio. Emulators have no
BLE, and two emulator instances cannot substitute — each app process has its
own in-process mock radio, so they do not see each other.

Two Android phones, developer mode and USB debugging on.

```bash
adb devices          # expect two serials
cd ~/Documents/Avertis/mobile
flutter run -d <serial-A>      # terminal A
flutter run -d <serial-B>      # terminal B
```

On each phone: mesh screen → **RADIO** → switch to **Bluetooth**. It confirms
first, because switching restarts the node.

In order, and expect to debug:

- [ ] `Nearby nodes` reaches 1 on both. If one stays at 0, check the mesh
      screen for the advertising warning — some handsets cannot advertise at
      all, and the app says so. `adb logcat | grep AvertisBle` gives the
      reason.
- [ ] Send an SOS from A; it appears in B's mesh activity.
- [ ] Attach a photo and send — this exercises fragmentation and reassembly,
      where MTU assumptions break.
- [ ] Three phones: put C out of A's range, confirm A→B→C.
- [ ] Lock B's screen and confirm it still relays for A.

Known unknowns, none visible from a laptop: the 180-byte fragment assumption
may be wrong for a given pair, Android 12+ permission behaviour differs by
manufacturer, and background scan throttling varies. **Budget real time. This
is the classic place a BLE project loses a day.**

If BLE does not work in time, the honest fallback is to demo the mesh through
the simulator and say plainly that physical BLE is implemented but unproven.
That is a far better position than a video that implies otherwise.

---

## 9. Before you record

- [ ] Restart the backend so the command centre starts from a clean state —
      an empty dashboard filling up is much stronger than one already full.
- [ ] Decide your Gemini model now and confirm `is_model: true` one last time.
- [ ] Check the header badge reads `reasoning: gemini:…`, not `rules`. If it
      says rules, **do not describe the output as Gemini's** — the badge is on
      screen and a judge may well read it.
- [ ] Have `mass_incident` already run if you want impressive fusion numbers,
      or run it live if you prefer showing the loop.

### Claims that are safe to make

- The recommendation changes when the network changes — measured, reproducible.
- N duplicate reports absorbed into M incidents — measured.
- The contested-decision benchmark numbers — measured.
- Gemini does multimodal-ready structuring, fusion judgement and the WHY text.
- Severity can only ever be raised: sender, rules and model all get a say and
  the most severe wins.

### Claims to avoid

- That Gemini chooses the responder. It does not, deliberately.
- Any BLE claim you have not seen work on the phones that day.
- Confidence as certainty. It is capped at 0.95 and derived from evidence.
- Integration with any real emergency authority. The command centre is
  explicitly a simulated one.
