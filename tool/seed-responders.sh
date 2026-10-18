#!/usr/bin/env bash
# Put responders on the board.
#
# Responders are not configured anywhere — the backend derives them from the
# mesh itself: any node a gateway reports with role RESPONDER becomes a
# responder it can dispatch (agents/coordinator.py). Two handsets running as
# SURVIVOR and GATEWAY therefore produce zero responders, and every incident
# reads "no responders available".
#
# This registers responders the same way a real responder handset would: a
# gateway sync carrying their nodes and their links into the mesh. It posts
# under its own gateway id, so it adds to the phones' view rather than
# replacing it, and it declares source=SIMULATED so the dashboard can still
# tell a real handset from a seeded one. Do not pass these off as devices.
#
#   ./tool/seed-responders.sh                 # link to the newest incident
#   ./tool/seed-responders.sh n2b5cd          # link to a specific node
#   ./tool/seed-responders.sh n2b5cd --cut    # responder A unreachable
#
# --cut drops the link to responder A, which is the signature demo on live
# data: A is closer, A is now in another partition, the recommendation moves
# to B. Re-run without --cut to heal it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
API="${AVERTIS_API:-https://avertis.web.app}"
KEY="${AVERTIS_API_KEY:-$("$HERE/tool/write-key.sh")}"

NODE="${1:-}"
CUT="no"
for arg in "$@"; do [ "$arg" = "--cut" ] && CUT="yes"; done
[ "${NODE:-}" = "--cut" ] && NODE=""

# Both the node to link to and the place to put the responders come from the
# newest incident. Responders 11 km away because the script hardcoded a city
# centre is not a demo, it is a bug with coordinates.
read -r FOUND_NODE LAT LON <<<"$(curl -fsS "$API/api/v1/incidents" | python3 -c '
import json, sys
incidents = json.load(sys.stdin)
incidents = incidents if isinstance(incidents, list) else incidents.get("incidents", [])
node, lat, lon = "", "", ""
for incident in incidents:
    where = incident.get("location")
    origins = [e["origin_node"] for e in incident.get("evidence", [])
               if e.get("origin_node")]
    if origins:
        node = origins[0]
    if where:
        lat, lon = where["lat"], where["lon"]
print(node, lat, lon)
')"

NODE="${NODE:-$FOUND_NODE}"
if [ -z "$NODE" ] || [ -z "$LAT" ]; then
  echo "no located incident to attach responders to — send an SOS with a" >&2
  echo "location fix first, or name the node:" >&2
  echo "  ./tool/seed-responders.sh n2b5cd" >&2
  exit 1
fi

echo "anchoring responders to $NODE at $LAT,$LON (cut=$CUT)"

python3 - "$API" "$KEY" "$NODE" "$CUT" "$LAT" "$LON" <<'PY'
import json, sys, urllib.request
from datetime import datetime, timezone

api, key, node, cut = sys.argv[1:5]
lat, lon = float(sys.argv[5]), float(sys.argv[6])
now = datetime.now(timezone.utc).isoformat()

# Roughly 200 m and 300 m from the incident, which is the geometry the
# signature scenario uses: A is closer, B is better connected. One degree
# of latitude is about 111 km anywhere on Earth.
M = 1.0 / 111_320.0
responders = [
    ("resp-a", lat + 200 * M, lon),
    ("resp-b", lat - 300 * M, lon),
]

nodes = [{
    "node_id": rid, "role": "RESPONDER", "battery": 0.9,
    "location": {"lat": rlat, "lon": rlon},
    "last_seen": now, "link_stability": 0.95, "reachable": True,
} for rid, rlat, rlon in responders]

# A relay each, so the two responders reach the incident by different paths
# and cutting one does not strand both.
nodes += [{
    "node_id": relay, "role": "RELAY", "battery": 0.95,
    "location": {"lat": lat + offset * M, "lon": lon},
    "last_seen": now, "link_stability": 0.95, "reachable": True,
} for relay, offset in (("relay-a", 100), ("relay-b", -150))]

links = [
    {"a": node, "b": "relay-b", "stability": 0.95},
    {"a": "relay-b", "b": "resp-b", "stability": 0.92},
]
if cut != "yes":
    links = [
        {"a": node, "b": "relay-a", "stability": 0.98},
        {"a": "relay-a", "b": "resp-a", "stability": 0.97},
    ] + links

body = {
    "gateway_id": "gw-responders",
    "source": "SIMULATED",
    "sent_at": now,
    "connectivity_window_seconds": 20,
    "nodes": nodes,
    "links": links,
    "incidents": [],
}

req = urllib.request.Request(
    f"{api}/api/v1/gateway/sync",
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "X-Avertis-Key": key},
)
with urllib.request.urlopen(req, timeout=30) as response:
    json.load(response)

print(f"  {len(nodes)} node(s), {len(links)} link(s) registered")
if cut == "yes":
    print("  responder A is cut off — the recommendation should move to B")
PY

echo
echo "Recommendations are recomputed on the next read. Open $API"
