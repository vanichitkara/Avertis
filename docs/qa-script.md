# User QA — Flutter app and command centre

A manual pass over the two things a person actually touches. The automated
suites cover logic; this covers what only a human notices.

**Why this is worth doing properly:** the command centre has **no automated
tests at all**, and the app has widget tests for only the home and SOS
screens. Everything below is, in testing terms, unexercised. Every bug found
in this project so far has been in a path a human hadn't walked yet.

Allow about an hour. Tick as you go; note anything odd even if it seems
cosmetic.

---

## Setup

```bash
cd ~/Documents/Avertis
lsof -ti:8000 -ti:8080 | xargs kill -9 2>/dev/null; true
source tool/env.sh
```

Terminal 1 — backend (also serves the command centre):

```bash
cd backend && .venv/bin/python -m uvicorn avertis_backend.main:app --port 8000
```

Terminal 2 — emulator and app:

```bash
emulator -avd avertis_test -no-snapshot-load &
adb wait-for-device
cd mobile && flutter run --dart-define=AVERTIS_API_BASE=http://10.0.2.2:8000
```

Command centre: <http://127.0.0.1:8000/>

- [ ] `curl -s localhost:8000/api/v1/health` shows `is_model: true`,
      `store: firestore`, `media.durable: true`.

> **If the dashboard looks wrong after an edit, hard-reload.** Browsers cache
> `app.js` and `style.css` hard enough that a change appears to do nothing.
> The assets carry a `?v=` query for this reason — bump it, or use a
> private window.

---

# Part A — The Flutter app

## A1. First launch and permissions

Start from a clean install: `adb uninstall com.avertis.avertis`, then
`flutter run` again.

- [ ] The app opens **straight to a usable screen** — no sign-in, no setup.
- [ ] Permission prompts appear; **deny them all** the first time.
- [ ] The app does not crash.
- [ ] An amber warning explains that background relaying is unavailable.
- [ ] SOS is still reachable and still works with everything denied.

Now grant them (`adb shell pm grant …` or reinstall and accept).

- [ ] The amber warning disappears.
- [ ] `adb shell dumpsys activity services com.avertis.avertis | grep -i isForeground`
      shows `isForeground=true`.

## A2. Home screen

- [ ] Internet state, mesh state, nearby node count, mesh health, battery.
- [ ] Node id is shown and is **stable across restarts** (not regenerated).
- [ ] It says `simulated radio` — you should never be unsure which radio is in use.
- [ ] Mesh activity shows `Node started`.
- [ ] Rotate the device. Nothing overlaps or is cut off.
- [ ] Every button reaches a screen and the back arrow returns.

## A3. SOS — the single most important screen

- [ ] Opens in **one tap** from home.
- [ ] The life-critical warning is unmissable.
- [ ] Headcount buttons 1–5+ select and visibly stay selected.
- [ ] Location line states what is actually known — a fix with accuracy, a
      stale fix, or none. Check it against `adb emu geo fix 77.5946 12.9716`.
- [ ] With no nodes in range it says the SOS is **saved and will be sent**,
      rather than implying it has gone.
- [ ] Sending shows a confirmation with a report id.
- [ ] **Send a second SOS.** It gets a different report id.

Negative cases:

- [ ] Turn location off on the device and open SOS. It says location will not
      be attached, and still lets you send.
- [ ] Send with no description — allowed, it is an SOS.

## A4. Report incident

- [ ] Text field, priority selector, voice, photo, send.
- [ ] Default priority is **EMERGENCY** (not NORMAL).
- [ ] The note about the command centre possibly reclassifying is present.
- [ ] Sending with an empty description and no attachment does nothing (there
      is nothing to report).

**Voice** — the least tested feature in the app:

- [ ] Record starts; a counter runs and shows the remaining time.
- [ ] Stop produces a clip with its duration.
- [ ] Discard removes it and returns to the record button.
- [ ] Record again after discarding — it works a second time.
- [ ] Leave it running to the 60s cap; it stops itself.
- [ ] Record, then press back without sending — no crash, no orphaned state.
- [ ] Send a **voice-only** report. It is labelled "not yet transcribed"
      rather than given invented words.

**Photo:**

- [ ] Add photo opens the picker; a chosen image is attached.
- [ ] Cancel the picker — no crash, nothing attached.
- [ ] Send with both a photo and a voice clip.

## A5. My reports

- [ ] Before sending anything: "You have not sent any reports yet".
- [ ] After sending: each report with its priority and time.
- [ ] Unacknowledged reports show as awaiting, with a retry count if retried.
- [ ] After a successful sync, a report shows its command-centre incident id.
- [ ] **Force-quit and reopen** — reports are still listed.

## A6. Mesh screen

- [ ] Radio switch shows Simulated selected.
- [ ] Node card: id, role, transport, gateway distance, queued, awaiting ack.
- [ ] Counters (forwarded, delivered, dropped) are present and plausible.
- [ ] Neighbours shows "No nodes in range" on a lone emulator.

**Radio switch** — this restarts the node, so it is worth care:

- [ ] Tapping Bluetooth shows a confirmation explaining the restart.
- [ ] Cancel leaves it on Simulated.
- [ ] Confirm switches to Bluetooth; the node card updates to `Bluetooth LE`.
- [ ] A new `Node started` appears in activity.
- [ ] Nearby nodes resets to 0 and the app keeps working.
- [ ] Switch back to Simulated — also works.
- [ ] **Reports you sent earlier are still in My Reports** after switching.

## A7. Gateway sync

- [ ] The GATEWAY card is present (it only appears when a backend is
      configured).
- [ ] With an unsent SOS it says "1 report(s) waiting".
- [ ] SYNC NOW reports how many were delivered.
- [ ] The incident appears in the command centre **with the headcount you
      chose** — this was broken once and is easy to regress.
- [ ] Tap SYNC NOW again — it does not resend the same report.
- [ ] **Stop the backend, then SYNC NOW.** It reports a failure, and the
      report is still held, not lost. Restart the backend and sync again.

## A8. Situation view

- [ ] Range rings, north-up, your node at the centre.
- [ ] "No nodes in range" with no peers.
- [ ] With no location fix it says nodes are placed by signal, not direction.
- [ ] Set a location and reopen — the range figure is sensible.

## A9. Lifecycle and endurance

- [ ] Background the app for two minutes, return — still working, no crash.
- [ ] Lock the screen for two minutes, unlock — mesh still running.
- [ ] Leave it open for ten minutes — no runaway battery warning, no freeze.
- [ ] Aeroplane mode on, send an SOS, aeroplane mode off, sync — it arrives.
- [ ] `adb shell am force-stop …` then reopen — custody survives.

---

# Part B — The command centre

## B1. Empty state

With a fresh backend and no data:

- [ ] "No incidents yet. Waiting for a gateway sync."
- [ ] Network and incident counters show zero rather than blank.
- [ ] Nothing shows invented or placeholder data.

## B2. Header badges — check these before quoting anything

- [ ] Left badge names the reasoning engine. Green with a model name means
      Gemini; amber "rules (no Gemini key)" means it is not.
- [ ] Right badge shows the backend is up and the node count.
- [ ] **Stop the backend.** Within a few seconds: the right badge turns red
      ("backend unreachable"), the left reads "engine unknown", and the
      footer says it is showing the last known state.
- [ ] Restart the backend — both badges recover without a page reload.

That last pair matters more than it looks. If the backend hiccups mid-demo,
the dashboard must not keep implying Gemini is live.

## B3. With data

```bash
cd simulator
.venv/bin/python -m avertis_sim run mass_incident --api http://127.0.0.1:8000
```

- [ ] Incident counts by severity, coloured, and they add up to the total.
- [ ] "N duplicate report(s) absorbed into M incident(s)".
- [ ] The incident list scrolls **inside its panel** rather than stretching
      the page.
- [ ] Clicking an incident selects it and the decision panel follows.
- [ ] The selected row stays highlighted.

## B4. Topology canvas

- [ ] Nodes are drawn, coloured by partition.
- [ ] With multiple partitions, no link crosses between colours.
- [ ] Gateways and responders are labelled.
- [ ] Unreachable nodes are drawn hollow.
- [ ] The caption gives link count, mean stability and the partition note.

## B5. Decision panel and WHY

- [ ] Incident id, severity pill, source count, confidence, headcount.
- [ ] "headcount unknown" where none was given — never a guess.
- [ ] Recommended responder, reachability, distance, hazard.
- [ ] **WHY?** opens and closes; the text names real figures.
- [ ] Safety flags are shown and readable.
- [ ] "requires human approval" is always present.
- [ ] Alternatives list below, with unreachable ones in red.

## B6. The signature moment

```bash
.venv/bin/python -m avertis_sim run response_adaptation --api http://127.0.0.1:8000
```

- [ ] `RESPONSE REPLANNED` appears in the activity feed, at least twice.
- [ ] The recommended responder visibly changes.
- [ ] `PARTITION DETECTED` then `PARTITION HEALED` appear.
- [ ] Colour coding makes the replan lines stand out.

## B7. Live update

- [ ] Leave the dashboard open and send an SOS from the phone, then sync.
      It appears **without reloading the page**.
- [ ] The activity feed scrolls inside its panel.

## B8. Presentation

You will be showing this on a projector or in a recording.

- [ ] Full screen on your demo display: nothing clipped, no horizontal scroll.
- [ ] Readable from a few feet away.
- [ ] Browser zoom at 125% and 150% still holds together.
- [ ] Narrow window (half screen) — panels stack rather than overlap.
- [ ] No console errors (open devtools, reload, look).

---

## What to do with what you find

Anything that crashes, loses a report, or shows something untrue — fix before
recording. Cosmetic issues can wait; note them.

Pay particular attention to anything where the UI **claims something it does
not know**: a headcount that was never given, a location implied without a
fix, Gemini credited when the badge says rules. Those are the failures that
would matter in the field and the ones a judge is most likely to probe.
