# Avertis Gateway API v1 (FROZEN — Phase 0)

Status: **frozen**. This is the contract between my side (mobile gateway client
+ simulator gateway client) and my teammate's FastAPI backend.

Base URL: `${AVERTIS_API_BASE}` (e.g. `https://avertis-687930058257.asia-south1.run.app`)
All paths are prefixed `/api/v1`.

Auth (MVP): `X-Avertis-Key: <shared key>` header. Not a security claim — it
just keeps the demo endpoint from being open.

---

## POST /api/v1/gateway/sync

Called by a node acting as gateway when a connectivity window opens. This is a
**batch, best-effort, idempotent** handoff: the client may re-send anything it
did not see acknowledged.

### Request

```json
{
  "gateway_id": "gw-01",
  "sent_at": "2026-09-06T12:04:00.000Z",
  "connectivity_window_seconds": 18,
  "nodes": [
    {
      "node_id": "node-07",
      "role": "SURVIVOR",
      "battery": 0.67,
      "location": {"lat": 12.9716, "lon": 77.5946, "accuracy_m": 12.0},
      "neighbors": ["node-04", "node-12"],
      "last_seen": "2026-09-06T12:03:58.000Z",
      "gateway_distance": 3,
      "link_stability": 0.88,
      "mobility": 0.12,
      "queue_depth": 4,
      "reachable": true,
      "partition_id": 0
    }
  ],
  "links": [
    {"a": "node-07", "b": "node-12", "stability": 0.88, "rssi": -71}
  ],
  "incidents": [
    {
      "report_id": "rpt-8a1f2c",
      "origin_node": "node-07",
      "created_at": "2026-09-06T12:00:00.000Z",
      "priority": "LIFE_CRITICAL",
      "kind": "SOS",
      "location": {"lat": 12.97, "lon": 77.59, "accuracy_m": 20.0},
      "text": "three people trapped near the bridge",
      "transcript": null,
      "media": [],
      "hop_count": 3,
      "path": ["node-07", "node-12", "node-31"]
    }
  ],
  "messages": [],
  "metrics": {
    "nodes_total": 100,
    "nodes_reachable": 64,
    "partitions": 2,
    "queue_depth_total": 213
  }
}
```

Notes:

- `incidents[].kind` ∈ `SOS` | `REPORT`. These are **raw reports**, not
  backend incidents — Gemini turns them into `INC-####` incidents.
- `report_id` is client-generated and stable, so a retried sync is a no-op.
- `nodes` + `links` together are the **network half of the world model**. Send
  the full current view (not a delta) — it is small and makes the backend
  stateless about topology.
- `messages` carries any non-incident packets that need to reach command
  (mesh events, status). Same envelope as §2 of `docs/protocol.md`.
- Payload is capped at 2 MB. If the client has more, it sends the highest
  priority first (critical-first sync) and retries the rest next window.

### Response — 200

```json
{
  "received_at": "2026-09-06T12:04:01.100Z",
  "accepted": ["rpt-8a1f2c"],
  "rejected": [
    {"report_id": "rpt-1111", "reason": "MALFORMED_LOCATION"}
  ],
  "incidents": [
    {"report_id": "rpt-8a1f2c", "incident_id": "INC-0001", "fused_into": null}
  ],
  "commands": [
    {"type": "SYNC_ACK", "report_id": "rpt-8a1f2c", "incident_id": "INC-0001"},
    {"type": "SET_PRIORITY", "report_id": "rpt-1112", "priority": "EMERGENCY"},
    {"type": "REQUEST_MEDIA", "media_id": "med-1"},
    {"type": "BROADCAST", "priority": "OPERATIONAL",
     "text": "Shelter open at Central School"}
  ]
}
```

- `incidents[].fused_into` is set when the backend merged this report into an
  existing incident (see fusion, plan §20).
- `commands` is the backend's only channel for pushing work back into the mesh.
  The client injects each command as a packet with the stated priority.
  Unknown command types are ignored (forward-compat).

### Errors

`400` malformed body · `401` bad key · `413` payload too large ·
`503` backend unavailable (client keeps everything queued and retries).

The client treats **any** non-200 as "nothing was accepted" and retains its
queue. Partial acceptance is expressed only through `accepted`/`rejected`.

---

## POST /api/v1/media/upload

Multipart upload of a media descriptor's bytes, used when a gateway window is
wide enough. `media_id`, `report_id`, `sha256` as form fields, `file` as the
part. Returns `{"media_id": "...", "uri": "gs://..."}`. Fire-and-forget: a
failed media upload never blocks incident sync.

---

## GET /api/v1/health

`{"status": "ok", "version": "..."}`. Used by the gateway client to detect that
a connectivity window is genuinely usable before spending it on a large sync.

---

## Endpoints owned by my teammate (listed here so the contract is in one place)

- `POST /api/v1/incident/analyze` — raw report → structured incident (Gemini).
- `GET  /api/v1/incidents` — command center incident list.
- `POST /api/v1/response/recommend` — world model → responder + route + WHY.
- `GET  /api/v1/world` — current combined physical + network world model.

My side does not call these directly; the simulator may call
`/response/recommend` in the integration scenario to demonstrate the
network-change → re-plan loop.
