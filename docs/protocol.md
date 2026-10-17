# Avertis Mesh Protocol v1.0 (FROZEN — Phase 0)

Status: **frozen**. Changes require agreement between mobile/mesh owner and backend owner.

This document is the single source of truth for the on-the-wire packet format used by:

- the Dart mesh engine (`mobile/lib/mesh/`)
- the Python simulator (`simulator/avertis_sim/`)
- the backend gateway endpoint (`backend/`)

Both implementations MUST serialize/deserialize identically. Fixture files in
`docs/fixtures/` are the conformance tests.

---

## 1. Encoding

- Development / simulator / gateway HTTP: **JSON**, UTF-8.
- BLE transport: same JSON, but framed (see §7). A binary/CBOR encoding is a
  post-MVP optimization; the field names and semantics below do not change.

Timestamps are **ISO-8601 UTC with `Z` suffix**, millisecond precision:
`2026-09-06T12:00:00.000Z`.

Identifiers are lowercase, hyphen-namespaced strings: `node-07`, `pkt-9f3a...`,
`gw-01`, `INC-0001` (incident IDs are uppercase, they come from the backend).

---

## 2. Packet

```json
{
  "packet_id": "pkt-3f9c1a7b2d",
  "origin_node": "node-07",
  "destination": "gateway-01",
  "message_type": "INCIDENT",
  "priority": "LIFE_CRITICAL",
  "ttl": 8,
  "hop_count": 2,
  "created_at": "2026-09-06T12:00:00.000Z",
  "payload_hash": "a1b2c3d4e5f60718",
  "path": ["node-07", "node-12"],
  "payload": {}
}
```

| Field          | Type     | Req | Meaning |
|----------------|----------|-----|---------|
| `packet_id`    | string   | yes | Globally unique. `pkt-` + 16 hex chars. Used for dedup + ACK correlation. Never rewritten by relays. |
| `origin_node`  | string   | yes | Node that created the packet. Never rewritten. |
| `destination`  | string   | yes | Target node ID, `"gateway"` for *any* gateway (anycast), or `"*"` for broadcast. |
| `message_type` | enum     | yes | See §3. |
| `priority`     | enum     | yes | See §4. |
| `ttl`          | int      | yes | Remaining hops. Decremented by each forwarder. Dropped at 0. |
| `hop_count`    | int      | yes | Hops taken so far. Incremented by each forwarder. |
| `created_at`   | ISO-8601 | yes | Origin clock. Used for age-based expiry and critical-first ordering. |
| `payload_hash` | string   | yes | 16 hex chars. `sha256(canonical_json(payload))[:16]`. Integrity + content dedup. |
| `path`         | string[] | no  | Hop trace, appended by each forwarder. Capped at 16 entries. Demo/visualization + loop avoidance. |
| `payload`      | object   | yes | Type-specific, see §5. May be `{}`. |

### Canonical JSON (for `payload_hash`)

Keys sorted ascending, no insertive whitespace (`separators=(',',':')`),
non-ASCII not escaped, UTF-8 encoded. Both Dart and Python implement this
identically; `docs/fixtures/payload_hash.json` pins the expected values.

### Default TTL by priority

| Priority        | Default TTL |
|-----------------|-------------|
| LIFE_CRITICAL   | 10 |
| EMERGENCY       | 8  |
| OPERATIONAL     | 6  |
| NORMAL          | 4  |

`HELLO` is always TTL 1 (never forwarded — it is a link-local beacon).

---

## 3. Message types

```text
HELLO               link-local beacon, TTL=1, never forwarded
NODE_STATUS         battery/role/location/neighbor summary, propagated
INCIDENT            a structured or raw incident report
SOS                 minimal life-critical distress packet
ACK                 acknowledgement of a previously seen packet_id
ROUTE_REQUEST       reactive route discovery toward a destination
ROUTE_RESPONSE      reply carrying a discovered path
GATEWAY_AVAILABLE   a gateway announces an open connectivity window
SYNC                node → gateway batch handoff
SYNC_ACK            gateway → node confirmation of accepted items
```

Unknown `message_type` values MUST be forwarded normally (forward-compat) but
not otherwise interpreted.

---

## 4. Priority

```text
LIFE_CRITICAL   life at immediate risk
EMERGENCY       urgent, not immediately life-threatening
OPERATIONAL     coordination / logistics traffic
NORMAL          background, status, telemetry
```

Ordering for queues and gateway sync is `LIFE_CRITICAL > EMERGENCY >
OPERATIONAL > NORMAL`, then **oldest `created_at` first** within a class.

Priority is assigned at origin by deterministic rules (SOS is always
LIFE_CRITICAL). The backend may *re-classify* an incident after Gemini
analysis; that re-classification never rewrites an in-flight packet.

---

## 5. Payloads

### `HELLO`
```json
{ "node_id": "node-07", "role": "SURVIVOR", "battery": 0.67,
  "location": {"lat": 12.9716, "lon": 77.5946, "accuracy_m": 12.0},
  "gateway_distance": 3, "seq": 481 }
```
`gateway_distance` is hops to the nearest known gateway, or `null` if unknown.
`seq` is a monotonically increasing beacon counter used for link-stability and
freshness estimation.

### `NODE_STATUS`
Same shape as `HELLO` plus `"neighbors": ["node-04","node-12"]` and
`"queue_depth": 14`.

### `SOS`
```json
{ "report_id": "rpt-8a1f...", "node_id": "node-07",
  "location": {"lat": 12.97, "lon": 77.59, "accuracy_m": 20.0},
  "created_at": "2026-09-06T12:00:00.000Z",
  "people_count": null, "note": "trapped, water rising" }
```

### `INCIDENT`
```json
{ "report_id": "rpt-8a1f...", "node_id": "node-07",
  "created_at": "2026-09-06T12:00:00.000Z",
  "location": {"lat": 12.97, "lon": 77.59, "accuracy_m": 20.0},
  "text": "three people trapped near the bridge",
  "transcript": null,
  "media": [ {"kind": "IMAGE", "media_id": "med-1", "sha256": "...",
              "bytes": 84213, "inline": false} ],
  "reported_priority": "LIFE_CRITICAL" }
```
Media is **not** carried inline over the mesh for MVP (`inline: false`): only
the descriptor travels, and the bytes are uploaded when a gateway window opens.
This keeps LIFE_CRITICAL text traffic fast under partition.

### `ACK`
```json
{ "ack_packet_id": "pkt-3f9c1a7b2d", "by_node": "node-12",
  "status": "DELIVERED" }
```
`status` ∈ `DELIVERED` (reached destination) | `RELAYED` (hop-by-hop custody).

### `ROUTE_REQUEST` / `ROUTE_RESPONSE`
```json
{ "target": "gateway", "request_id": "rrq-...", "path": ["node-07","node-12"] }
```

### `GATEWAY_AVAILABLE`
```json
{ "gateway_id": "gw-01", "window_seconds": 18,
  "announced_at": "2026-09-06T12:04:00.000Z" }
```

### `SYNC` / `SYNC_ACK`
Carry the gateway API bodies described in `docs/api.md`.

---

## 6. Forwarding rules (deterministic — no AI in this path)

A node receiving a packet applies, in order:

1. **Dedup** — if `packet_id` is in the seen-set, drop. Seen-set is an LRU of
   4096 IDs with a 30-minute time bound.
2. **Loop check** — if own `node_id` is already in `path`, drop.
3. **Deliver** — if `destination` is own ID, or `"*"`, or (`"gateway"` and this
   node is a gateway) → deliver locally. `"*"` also continues to forward.
4. **TTL** — decrement. If `ttl <= 0` after decrement, drop.
5. **Forward** — increment `hop_count`, append own ID to `path` (cap 16),
   enqueue to the selected next hop(s) (see §8).
6. **ACK** — if the packet was delivered locally and its type is `SOS` or
   `INCIDENT`, emit an `ACK` back toward `origin_node`.

Packets that cannot be forwarded immediately (no viable neighbor) are held in
the **store-and-forward queue** and retried on every topology change and on a
5 s timer, subject to the queue policy in §8.

---

## 7. BLE framing

- Service UUID: `a5e7f1c0-1c2b-4c9a-9f10-avertis00001` (placeholder until the
  BLE transport lands; the mesh engine never hardcodes it — see
  `mobile/lib/mesh/transport/ble_mesh_transport.dart`).
- MTU is negotiated; assume a **safe 180-byte payload** per write.
- Frame: `[2-byte total length][1-byte fragment index][1-byte fragment count][bytes]`.
- Reassembly buffer is dropped after 10 s of inactivity.
- Advertised manufacturer data carries `node_id` (6 bytes) + `role` (1 byte) +
  `battery` (1 byte, 0–255) so neighbors can be scored before connecting.

---

## 8. Queues and relay selection

Each node keeps one priority queue keyed by (priority, created_at). Capacity is
512 packets; on overflow the **lowest-priority, oldest** packet is dropped and a
`QUEUE_DROP` event is emitted.

Relay score (deterministic baseline — explicitly *not* claimed as novel AI):

```text
relay_score = 0.30*battery
            + 0.20*normalized_neighbor_count
            + 0.20*gateway_proximity
            + 0.15*link_stability
            + 0.15*mobility_score
```

- `battery` ∈ [0,1]
- `normalized_neighbor_count` = min(neighbors, 8) / 8
- `gateway_proximity` = 1 / (1 + gateway_distance_hops), 0 if unknown
- `link_stability` = EWMA of beacon delivery ratio ∈ [0,1]
- `mobility_score` = 1 − min(avg_speed_mps, 5) / 5  (stationary scores highest)

The scoring weights live in exactly one place per implementation and are
identical across Dart and Python.

---

## 9. Failure detection

- `HELLO` beacon interval: **3 s** (jittered ±20%).
- A neighbor is **SUSPECT** after 3 missed beacons (≈9 s), **DOWN** after 5
  (≈15 s).
- On transition to DOWN: remove link, recompute topology, run partition
  detection (connected components), re-elect relays for affected routes,
  requeue packets whose next hop was the failed node.
- All of the above emits events (see §10) so the UI and command center can show
  the recovery.

---

## 10. Events (mesh → UI / command center)

```text
NODE_JOINED        NODE_SUSPECT      NODE_DOWN        NODE_RECOVERED
LINK_UP            LINK_DOWN
PACKET_SENT        PACKET_FORWARDED  PACKET_DELIVERED PACKET_DROPPED
QUEUE_DROP
PARTITION_DETECTED PARTITION_HEALED
RELAY_ELECTED      ROUTE_CHANGED
GATEWAY_UP         GATEWAY_DOWN      SYNC_STARTED     SYNC_COMPLETED
```

Every event carries `{ "event": <name>, "at": <ISO-8601>, "node_id": <str>, ... }`
and is appended to the replay log verbatim.
