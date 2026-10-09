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

To switch Gemini on:

```bash
pip install google-genai
GEMINI_API_KEY=... .venv/bin/python -m uvicorn avertis_backend.main:app --port 8000
```

## Persistence

In-memory by default — state is lost on restart. Set `FIRESTORE_PROJECT` and
install `google-cloud-firestore` to persist.

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
