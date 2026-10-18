# Testing on two physical phones

This is the part of the project that has never run. Everything above the
radio is proven against the mock transport and the simulator; whether two
real Android radios find each other is genuinely unknown. Treat this as
bring-up, not verification, and give it real time.

---

## 1. Prepare each phone

On both:

1. **Settings → About phone →** tap **Build number** seven times.
2. **Settings → System → Developer options →** turn on **USB debugging**.
3. Connect by USB and accept the "Allow USB debugging?" prompt (tick
   "Always allow from this computer").

```bash
cd ~/Documents/Avertis && source tool/env.sh
adb devices
```

You should see two serials and `device` beside each. `unauthorized` means
the prompt was not accepted on that phone.

---

## 2. Build the APK

The backend URL is **compiled in**, and `10.0.2.2` is an emulator-only
address — a phone cannot reach it. Use your Mac's LAN address:

```bash
ipconfig getifaddr en0        # right now: 192.168.1.165
```

```bash
cd ~/Documents/Avertis && source tool/env.sh
cd mobile
flutter build apk --debug --dart-define=AVERTIS_API_BASE=http://192.168.1.165:8000
```

Against **Cloud Run** rather than a laptop, pass the write key as well:

```bash
cd ~/Documents/Avertis
KEY=$(./tool/write-key.sh)
cd mobile
flutter build apk --release --split-per-abi \
  --dart-define=AVERTIS_API_BASE=https://avertis-687930058257.asia-south1.run.app \
  --dart-define=AVERTIS_API_KEY="$KEY"
```

**Leave the key out and nothing syncs.** Reads are open, writes are not, so
the health check passes, the home screen can look healthy, and every sync
comes back 401. The app now names that case — "the command centre rejected
this app's credentials … this build is missing its API key" — rather than
reporting it as no internet, which is what it used to do and what sent a
whole afternoon into Wi-Fi settings.

Requirements for that to work:

- The Mac and both phones on **the same Wi-Fi** (not a guest network, which
  usually blocks device-to-device traffic).
- The backend started with `--host 0.0.0.0`, which it is.
- macOS firewall off, or Python allowed through. Yours is off.

Check from the Mac first:

```bash
curl -s http://192.168.1.165:8000/api/v1/health
```

> **The LAN address changes.** DHCP will hand you a different one at a
> different venue, and the APK has the old one baked in. Re-check and rebuild
> on the day — this is the single most likely reason the phones "stop talking
> to the backend" at a new location.

### Why plain HTTP works here

Android blocks cleartext by default. Debug builds use
`android/app/src/debug/res/xml/network_security_config.xml`, which permits
it, so a laptop backend on the LAN is reachable. Release builds use the
strict config and allow cleartext only for emulator loopback — a release APK
must talk to an HTTPS backend such as Cloud Run. Both were verified by
inspecting the built APKs.

---

## 3. Install on both

```bash
adb devices        # note the two serials

adb -s <serial-A> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <serial-B> install -r build/app/outputs/flutter-apk/app-debug.apk
```

Or copy `app-debug.apk` to each phone and open it — the phone will ask to
allow installing from unknown sources.

Grant permissions on each, either by accepting the prompts or:

```bash
for P in BLUETOOTH_SCAN BLUETOOTH_CONNECT BLUETOOTH_ADVERTISE \
         POST_NOTIFICATIONS ACCESS_FINE_LOCATION; do
  adb -s <serial> shell pm grant com.avertis.avertis android.permission.$P
done
```

**Bluetooth and Location must both be switched on in the phone's own
settings.** Android will not scan for BLE devices with Location off, even
with the permission granted — a confusing failure, because scanning simply
returns nothing.

To watch logs from one phone:

```bash
adb -s <serial> logcat | grep -iE "avertis|flutter"
```

---

## 4. First: prove each phone works alone

Before blaming BLE, confirm the basics on each handset separately.

- [ ] App opens, home screen shows node id and `simulated radio`.
- [ ] Send an SOS — it is saved.
- [ ] Mesh screen → **SYNC NOW** → the incident appears in the command
      centre at <http://192.168.1.165:8000/>.

If that fails, it is networking, not Bluetooth. Fix it before continuing.

---

## 5. Then: the BLE bring-up

A phone with a Bluetooth adapter now **starts on Bluetooth by itself**, and
whatever you pick is remembered across restarts. The mesh screen says which
of those happened under the RADIO switch ("Defaulted to Bluetooth because
this device has a radio", or "Restored from your last choice on this
phone").

So there is usually nothing to do here. Check it anyway on both phones —
mesh screen (hub icon) → **RADIO** — because a handset left on **Simulated**
is the single most common reason two phones never find each other, and it
used to be the default on every launch. The simulated radio is an in-memory
space inside one app process with one node in it: a phone on it cannot
discover a peer, ever.

Work in this order. Each step depends on the one before, so do not skip.

### 5.1 Discovery — the step most likely to fail

Hold the phones within a metre of each other.

- [ ] `Nearby nodes` reaches **1** on both, within about 30 seconds.

If one stays at 0:

- **Grant the Bluetooth permission when the app asks on first launch.**
  Android refuses a scan without BLUETOOTH_SCAN and an advertisement
  without BLUETOOTH_ADVERTISE, and a radio that was refused stays refused.
  The app now asks before it starts the radio, and retries when you come
  back from system settings having granted it — but a phone where it was
  denied and never granted will sit on "searching" with Bluetooth plainly
  switched on, which looks like a radio fault and is not one.
- Check the mesh screen for an advertising warning. Some handsets cannot
  advertise at all; the app says so rather than hiding it. Such a phone can
  still scan and relay for others, but will never be discovered — pair it
  with a phone that can advertise.
- **Read the radio line on the mesh screen of each phone.** It says which
  step has not happened, and the four possibilities need four different
  responses:

  | What it says | What it means |
  |---|---|
  | `no scan has run yet` | the transport never started — check permissions |
  | `no Avertis advertisement has been heard` | *this* phone is scanning fine. The other one is not being heard: check its own screen for an advertising failure, and that it is on Bluetooth rather than Simulated |
  | `could not read a node id` | heard, but the scan response is not arriving — a handset or stack limitation |
  | `no connection succeeded` | found each other, GATT is failing; the message carries the platform's reason |

  The counts beside it (`N scan(s) · N advert(s) heard · N peer(s)
  identified · N/N connection(s) made`) are raw figures from the radio.
  **Both phones reporting "no Avertis advertisement has been heard" means
  neither is advertising**, which is a different fault from one of them
  being deaf — and it is the case worth checking first.
- `adb -s <serial> logcat | grep AvertisBle` gives the reason. Expect
  entries about advertising starting, or failing with a named cause.
- Confirm Bluetooth **and** Location are on in system settings.
- Toggle Bluetooth off and on, then switch the radio back and forth.

This half of the stack — advertising and the GATT server — is Kotlin behind
a platform channel, because `flutter_blue_plus` cannot advertise at all. It
compiles and its framing is unit-tested, but it has never driven a real
radio.

### 5.2 One packet across

- [ ] Send an SOS from phone A. It appears in **B's mesh activity feed**.
- [ ] B's forwarded/delivered counters move.

### 5.3 A large packet

- [ ] Send a report from A with a **photo attached**.

This is the one that exercises fragmentation and reassembly. The framing
assumes a safe 180-byte payload per write; if a particular pair negotiates
something smaller, this is where it shows. A text SOS fits in one fragment
and will not reveal it.

### 5.4 Multi-hop — the actual claim

With three phones. Two is not enough to prove a mesh.

- [ ] Place C out of A's range (different rooms, or a floor apart) with B
      between them.
- [ ] A's SOS reaches C.
- [ ] C's mesh activity shows it arriving with `hop_count` 2.

With only two phones you can demonstrate device-to-device, which is still
worth showing — just do not call it multi-hop.

### 5.5 Relay failure

- [ ] With A→B→C working, switch B's radio to Simulated (or turn its
      Bluetooth off).
- [ ] A and C detect the loss within about 15 seconds.
- [ ] Bring B back; the link re-establishes.

### 5.6 Screen off

- [ ] Lock B and confirm it still relays for A. This is what the foreground
      service exists for, and its notification should be visible on B's lock
      screen.

### 5.7 Out through the phone that has signal

The scenario the whole mesh exists for: A has Bluetooth only, B has
Bluetooth and Wi-Fi.

- [ ] Turn Wi-Fi and mobile data **off** on A. Its home screen reads
      `Internet OFFLINE`.
- [ ] Leave B online. Within 20 seconds its home screen reads
      `Internet ONLINE`, and its mesh activity feed shows a **GATEWAY UP**
      entry saying it can reach the command centre.
- [ ] Send an SOS from A.
- [ ] A's report moves from waiting to **acknowledged** — that is B taking
      custody, not the backend.
- [ ] Within 20 seconds the incident appears on the command centre, with
      `origin_node` set to **A's** node id, not B's.
- [ ] The command centre's network panel shows **both** phones and the link
      between them, sourced `DEVICE`.

The role is not configured anywhere: whichever phone can reach the backend
promotes itself to gateway and hands the role back when it cannot. Turn B's
Wi-Fi off and its feed shows **GATEWAY DOWN** on the next check.

If A's report stays at waiting while B is online, the two phones are not
actually linked — go back to §5.1. The report reaching B is a mesh problem;
the report reaching the backend is a sync problem, and the acknowledgement
is what tells you which one you have.

---

## 6. What to do if BLE does not come up

Say so, and demo the mesh through the simulator instead. The simulator
proves routing, partitioning, self-healing and the response loop at a scale
phones never could, and the honest framing is strong:

> Physical BLE is implemented for both roles, including the Kotlin
> peripheral layer Flutter does not provide. It is not yet proven on
> handsets. Everything above the transport runs unchanged on either radio,
> which is the point of the abstraction.

That is a much better position than a video implying something that did not
happen. Do not claim multi-hop over BLE unless you have watched it.

---

## 7. Known unknowns

None of these are visible from a laptop:

- The 180-byte fragment assumption may be wrong for a given pair.
- Android 12+ Bluetooth permission behaviour differs by manufacturer.
- Background scanning is throttled, and aggressively so on some vendors.
- Some handsets cannot advertise; others limit concurrent advertisers.
- Battery optimisation may kill the foreground service on vendor ROMs —
  Settings → Apps → Avertis → Battery → Unrestricted.
