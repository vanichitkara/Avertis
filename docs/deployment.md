# Deploying Avertis

Two artefacts to ship: **one Cloud Run service** carrying the backend and the
command centre together, and **an Android APK** pointed at it.

Everything below except the `gcloud` calls themselves has been run on this
machine. The `gcloud` steps are written out but **not executed** — deploying
costs money and uses your account, so that is your call.

---

## 1. The command centre

**It deploys with the backend.** No separate hosting, no CORS configuration,
no API URL to set.

The page resolves its API base from `location.origin`, so when the backend
serves it the dashboard and the API share one origin and simply work. The
backend mounts `command-center/` at `/`, after every `/api/v1/...` route, so
the API keeps priority.

Verify locally:

```bash
cd backend
.venv/bin/python -m uvicorn avertis_backend.main:app --port 8000
```

Then open <http://127.0.0.1:8000/> — the dashboard, not JSON.

> The startup log says which it is doing: *"serving the command centre
> from …"* or *"command centre not found … — API only"*. If you see the
> second one in production, the image was built without the dashboard.

### If you would rather host it separately

Any static host works — Firebase Hosting, Netlify, GitHub Pages. The page
then needs to be told where the API is, because the origins differ:

```
https://your-host/index.html?api=https://avertis-xxxx.run.app
```

The backend already sends permissive CORS headers, so this works, but it is
strictly more moving parts for a demo. Prefer the single service.

---

## 2. Backend + command centre to Cloud Run

The `Dockerfile` is at the **repository root**, not in `backend/`, because the
image needs both directories. Deploying from `backend/` would produce an API
with no dashboard and no error saying so.

> **Billing must be enabled on the project.** Cloud Run and Cloud Storage both
> require it, free tier included. The Avertis project
> (`gen-lang-client-0373165899`) had no billing account attached until one was
> linked; without it, bucket creation fails with *"The billing account for the
> owning project is disabled in state absent"* and `gcloud run deploy` fails
> similarly.

```bash
cd ~/Documents/Avertis

gcloud config set project gen-lang-client-0373165899

gcloud run deploy avertis \
  --source . \
  --region asia-south1 \
  --allow-unauthenticated \
  --memory 1Gi \
  --set-env-vars "GEMINI_API_KEY=$(grep '^GEMINI_API_KEY=' backend/.env | cut -d= -f2-)" \
  --set-env-vars "GEMINI_MODEL=gemini-3.8-flash"
```

**Live service:** <https://avertis-687930058257.asia-south1.run.app>

First deploy needs three APIs enabled (`run`, `cloudbuild`,
`artifactregistry`) and, on a new project, the default compute service
account needs build permissions — without them the build fails with
`PERMISSION_DENIED … could not resolve source`:

```bash
SA=687930058257-compute@developer.gserviceaccount.com
for ROLE in roles/cloudbuild.builds.builder roles/storage.objectAdmin \
            roles/logging.logWriter roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding gen-lang-client-0373165899 \
    --member="serviceAccount:$SA" --role="$ROLE" --condition=None
done
```

### The write key

The deployed service sets `AVERTIS_API_KEY`. Reads — the dashboard,
`/incidents`, `/world`, `/activity`, `/health` — are open, so anyone with
the link can look. Writes (`/gateway/sync`, `/incident/analyze`,
`/media/upload`, `/response/recommend`) require the key as `X-Avertis-Key`,
so a stranger who finds the URL cannot run up Gemini charges.

Cloud Run holds the authoritative copy — it was set there at deploy time, so
read it back rather than keeping a second copy that can drift:

```bash
./tool/write-key.sh
```

Use it directly in a command:

```bash
KEY=$(./tool/write-key.sh)

# drive the deployed service
cd simulator
.venv/bin/python -m avertis_sim run response_adaptation \
  --api https://avertis-687930058257.asia-south1.run.app --api-key "$KEY"

# build an APK that can sync
cd mobile
flutter build apk --release --split-per-abi \
  --dart-define=AVERTIS_API_BASE=https://avertis-687930058257.asia-south1.run.app \
  --dart-define=AVERTIS_API_KEY="$KEY"
```

For the dashboard's **approve & dispatch** button, open it with the key in
the URL:

```
https://avertis-687930058257.asia-south1.run.app/?key=<the key>
```

Give judges the plain URL. Reads — the whole dashboard — need no key; only
writes do.

Pass it to the simulator with `--api-key`, and into an APK build with
`--dart-define=AVERTIS_API_KEY=...`.

**On the key.** The command above reads it out of `backend/.env` so it is
never typed into your shell history. `.dockerignore` excludes `backend/.env`,
so the key reaches the service as an environment variable and is not baked
into the image. For anything beyond a hackathon use Secret Manager
(`--set-secrets GEMINI_API_KEY=avertis-gemini:latest`) instead.

Afterwards:

```bash
gcloud run services describe avertis --region asia-south1 \
  --format='value(status.url)'
```

Check it:

```bash
curl -s https://avertis-xxxx.run.app/api/v1/health | python3 -m json.tool
```

- `status: ok`
- `reasoning.is_model: true` — if false, the key did not arrive; the `note`
  field says which step is missing.

Then open the same URL in a browser for the dashboard.

### Persistence — Firestore

The default store is in-memory, so **state is lost whenever Cloud Run scales
to zero or restarts** — which it will, between a rehearsal and the real demo.

```bash
gcloud firestore databases create --location=asia-south1

gcloud run services update avertis --region asia-south1 \
  --set-env-vars FIRESTORE_PROJECT=gen-lang-client-0373165899
```

Cloud Run's service account needs `roles/datastore.user`. On a personal
project the default compute service account usually has Editor already; if
reads fail with a permission error, that is why.

Firestore is exercised by 14 tests against the real emulator, including the
replace-network behaviour the signature feature depends on, and verified
keeping incidents across a backend restart. Collections: `incidents`,
`report_index`, `nodes`, `links`, `responders`, `activity`, `media`.

To develop against the emulator rather than real Firestore — free, local,
wiped when you stop it:

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@24 \
  gcloud emulators firestore start --host-port=127.0.0.1:8900 --quiet

# in the backend shell
FIRESTORE_EMULATOR_HOST=127.0.0.1:8900 FIRESTORE_PROJECT=avertis-dev \
  .venv/bin/python -m uvicorn avertis_backend.main:app --port 8000
```

The emulator needs Java 21+; the project's Java 17 will not start it.

### Durable media — Cloud Storage

Without a bucket, photos and voice clips go to the container's local disk.
Cloud Run discards that on restart and does not share it between instances,
so an incident record ends up pointing at evidence that no longer exists.

```bash
gcloud storage buckets create gs://avertis-media-0373165899 \
  --location=asia-south1 --uniform-bucket-level-access

gcloud run services update avertis --region asia-south1 \
  --set-env-vars STORAGE_BUCKET=avertis-media-0373165899
```

Cloud Run's service account needs `roles/storage.objectAdmin` on the bucket.

The bucket stays private. Media is read back through `/api/v1/media/{id}`
rather than handed out as a public URL — a photo from a disaster scene is
not something to expose on a guessable link.

`/api/v1/health` reports which backend is live and whether it is durable:

```json
"media": { "backend": "gcs:avertis-media-0373165899", "durable": true }
```

The bucket `gs://avertis-media-0373165899` already exists in
`gen-lang-client-0373165899` (asia-south1, uniform access) and has been
verified: an 89 KB photo uploaded through the API, read back byte-identical,
and still there after a backend restart. Seven integration tests run against
it on demand:

```bash
cd backend
AVERTIS_TEST_BUCKET=avertis-media-0373165899 \
  .venv/bin/python -m pytest tests/test_gcs_integration.py -q
```

They are skipped unless that variable is set, so the default suite stays
hermetic and costs nothing.

### If Google APIs reject everything

```
User project specified in the request is invalid.
```

The application-default credentials carry a `quota_project_id` that no longer
exists — this happened here, pointing at a deleted project, and it fails
every Google API call including Firestore:

```bash
gcloud auth application-default set-quota-project gen-lang-client-0373165899
```

### Pointing the simulator at it

```bash
cd simulator
.venv/bin/python -m avertis_sim run relay_failure --api https://avertis-xxxx.run.app
```

---

## 3. The Android app

### Build a release APK

```bash
cd ~/Documents/Avertis
source tool/env.sh

cd mobile
flutter build apk --release \
  --dart-define=AVERTIS_API_BASE=https://avertis-xxxx.run.app
```

Output: `build/app/outputs/flutter-apk/app-release.apk` (~57 MB).

The backend URL is compiled in at build time, so **a build pointed at
localhost cannot talk to Cloud Run.** Rebuild when the URL changes.

Verified: the release build installs, runs, and completes SOS → mesh custody
→ sync → backend with no crashes. R8 does not break the Kotlin platform
channels or the Drift database.

### Smaller APKs

57 MB is one fat binary carrying every CPU architecture. Split it:

```bash
flutter build apk --release --split-per-abi \
  --dart-define=AVERTIS_API_BASE=https://avertis-xxxx.run.app
```

That produces one APK per architecture (~20 MB each). For modern phones,
`app-arm64-v8a-release.apk` is the one to install.

### Install on a phone

No Mac required. `adb` is convenient when the phone is plugged in, but the
APK is just a file:

```bash
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

To install without a cable, put the APK somewhere the phone can reach —
Google Drive, WhatsApp to yourself, email, or a USB cable in file-transfer
mode — open it on the phone, and allow installing from unknown sources when
asked. Android 8+ asks per app, so it will name whichever app you opened it
from (Files, Drive, Chrome).

---

## 3b. Giving the APK to judges

This is worth getting right, because an APK that cannot reach a backend
tells a judge much less than one that can.

### The backend URL is compiled in

There is no settings screen for it. Whatever `--dart-define` you build with
is what that APK will talk to, forever. So:

- **A build pointed at `10.0.2.2`** works only on an emulator.
- **A build pointed at `192.168.1.165`** works only on your Wi-Fi. A judge
  at home gets nothing.
- **A build pointed at your Cloud Run URL** works anywhere with internet.
  This is the one to distribute.

Which means: **deploy to Cloud Run before you build the judges' APK.** Until
then there is no address that works off your network.

```bash
URL=$(gcloud run services describe avertis --region asia-south1 \
        --format='value(status.url)')

cd mobile
flutter build apk --release --split-per-abi --dart-define=AVERTIS_API_BASE=$URL
```

### Which file to give them

| File | Size | Who it is for |
|---|---|---|
| `app-arm64-v8a-release.apk` | 20 MB | **Almost every phone since ~2017.** Give them this. |
| `app-armeabi-v7a-release.apk` | 18 MB | Older 32-bit devices |
| `app-release.apk` (no split) | 55 MB | One file that runs anywhere, if you would rather not explain architectures |

Upload to Drive, set the link to "anyone with the link", and put it in the
submission. Mention the phone will warn about an unknown developer — it is
signed with debug keys (see above), which is normal for a hackathon build
and worth stating plainly rather than letting them wonder.

### What a judge can test with one phone and no backend

Most of the app, as it happens. It is offline-first by design — verified
with the backend deliberately unreachable, no crash:

- SOS, including the headcount and the location state
- Incident reports with voice and photo
- My reports, surviving a force-quit
- The mesh screen, the radio switch, the situation view
- The honest messaging: *"No nodes in range yet. It is saved on this device
  and will be sent automatically when one appears."*

What needs the backend: **SYNC NOW** and anything appearing in the command
centre. What needs **two phones**: the mesh actually carrying anything.

Say this in the submission. A judge with one phone who taps SOS and sees
"saved, will send when a node appears" has understood the product. A judge
who taps SYNC NOW against a dead URL and sees a failure has learned nothing
except that your backend is down.

### Suggested wording for the submission

> **Android APK** (arm64, 20 MB) — install and open; no account needed.
> Signed with debug keys, so Android will warn about an unknown developer.
>
> One phone, no setup: SOS, voice and photo reports, the mesh screen and the
> situation view all work offline — that is the point of the app.
> **Two phones** in Bluetooth range show the mesh relaying between them.
> **SYNC NOW** on the mesh screen pushes incidents to the live command
> centre at <your Cloud Run URL>, which you can open in a browser.

### Signing — read this before distributing

The release build is **signed with debug keys**. That is the Flutter template
default and nobody changed it:

```kotlin
// android/app/build.gradle.kts
release {
    // TODO: Add your own signing config for the release build.
    signingConfig = signingConfigs.getByName("debug")
}
```

For a hackathon this is fine: the APK installs and runs, and judges are not
checking certificates. What it means in practice:

- it **cannot** go on the Play Store,
- it should not be presented as production-ready,
- anyone can rebuild an APK with the same identity, so do not treat it as
  evidence of authorship.

To sign properly:

```bash
keytool -genkey -v -keystore ~/avertis-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias avertis
```

Then create `mobile/android/key.properties` (**gitignore it** — it holds
passwords):

```
storePassword=...
keyPassword=...
keyAlias=avertis
storeFile=/Users/you/avertis-release.jks
```

and load it in `build.gradle.kts` in place of the debug config. Keep the
keystore safe: lose it and you can never update the app under that identity.

### Cleartext HTTP

A Cloud Run URL is HTTPS, so nothing is needed.

The app permits plain HTTP **only** for `10.0.2.2`, `localhost` and
`127.0.0.1` — the emulator's route to your Mac — and refuses it everywhere
else (`android/app/src/main/res/xml/network_security_config.xml`). If you want
a phone on the same Wi-Fi to reach a laptop backend over HTTP, add that
laptop's LAN address to that file and remove it afterwards.

---

## 4. A deployed end-to-end check

```bash
URL=https://avertis-xxxx.run.app

curl -s $URL/api/v1/health | python3 -m json.tool          # is_model: true
cd simulator && .venv/bin/python -m avertis_sim run response_adaptation --api $URL
```

- [ ] `$URL/` shows the dashboard.
- [ ] The activity feed shows `RESPONSE REPLANNED`.
- [ ] A release APK built against `$URL` sends an SOS that appears there.

That last one is the real test: it exercises the whole chain on the
infrastructure you will demo from.

---

## 5. What is not deployed

- **The simulator** runs on your laptop. That is deliberate — it is the test
  harness, not a service.
- **Media uploads** are written to the container's local disk, which Cloud Run
  discards on restart. Cloud Storage is listed in the plan and is not wired
  up; descriptors survive in the incident record, the bytes do not.
- **The mesh** is not deployed anywhere by definition. It only exists between
  devices in Bluetooth range of each other.
