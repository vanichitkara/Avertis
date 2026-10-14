# Avertis backend

FastAPI service implementing `docs/api.md`. Incident intelligence, the
network-aware Response Agent, and the world model.

## Run it

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m uvicorn avertis_backend.main:app --port 8000
```

No credentials are needed. `GET /api/v1/health` reports which engines are
actually live.

## Reasoning engine

| | without credentials | with `GEMINI_API_KEY` |
|---|---|---|
| structuring | keyword + geography rules | Gemini, validated against the rules |
| fusion | distance, time, vocabulary overlap | Gemini, with the rules as fallback |
| WHY text | generated from the assessments | Gemini, grounded in the same figures |
| responder choice | deterministic scoring | **deterministic scoring — unchanged** |

The responder choice is never made by a model. It must be auditable and give
the same answer for the same state, which is what makes the signature demo
(plan §7) a system reacting rather than a model improvising. The model
explains the decision; it does not make it.

Everything carries `reasoned_by`, and the command centre shows which engine
produced what. Rule output is never presented as model output.

## Turning Gemini on

Two steps, and **both** are required — the key alone does nothing.

```bash
cd backend
cp .env.example .env            # then put your key in GEMINI_API_KEY=
.venv/bin/pip install google-genai
```

Get a key from <https://aistudio.google.com/apikey>.

`backend/.env` is gitignored. Never commit a real key: this repository is
shared, and a key committed once remains in the git history even after it is
deleted from the file.

Restart the backend and check it took:

```bash
curl -s localhost:8000/api/v1/health | python3 -m json.tool
```

`reasoning.is_model` must be `true`. If it is `false`, `reasoning.note` says
which of the two steps is missing — the command centre header shows the same
thing, and neither will claim Gemini is running when it is not.

### If the model is busy

Flagship models get rate-spiked. A 503 or 504 degrades to rules, which is safe
but loses the Gemini story mid-demo. Switch models in `.env`:

```
GEMINI_MODEL=gemini-3.1-flash-lite
```

Every call is capped at 12 seconds (the API's own minimum deadline is 10),
because without a cap the SDK retries internally for minutes and the incident
pipeline blocks behind it.

### What the model is and is not allowed to do

Model output is validated, not trusted:

- **severity may only be raised.** The sender's priority, the rules and the
  model all get a say, and the most severe wins. Observed live: the model
  rated "three people in the water, one is not moving" as EMERGENCY while the
  rules rated it LIFE_CRITICAL. Under-triage is the dangerous direction.
- **confidence is capped at 0.95.** A live call returned 1.0 for a single
  unverified sentence; "100% confidence" beside one stranger's report misleads
  whoever is deciding what to send.
- **an unrecognised incident type is discarded** in favour of the rules.
- **a headcount outside 1–999 is ignored**, and a count the sender stated
  outright always wins.

## Persistence

In-memory by default — state is lost on restart. To persist, set
`FIRESTORE_PROJECT` in `backend/.env`, install `google-cloud-firestore`, and
run `gcloud auth application-default login`.

## Deploy

```bash
gcloud run deploy avertis-backend --source . --region asia-south1 \
  --allow-unauthenticated \
  --set-env-vars GEMINI_API_KEY=...,FIRESTORE_PROJECT=...
```

## Tests

```bash
.venv/bin/python -m pytest -q
```

`tests/test_network_aware_response.py::TestSignatureLoop` is the one to read
first: it kills a relay and asserts the recommended responder changes, with
the geography held constant throughout.
