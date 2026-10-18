#!/usr/bin/env bash
# Wipe the command centre back to empty, for recording from scratch.
#
# Close the Avertis app on every phone first. A running app syncs every
# 20 seconds, so it will repopulate the board while this is deleting —
# which looks like the wipe failing. Force-stopping is not enough on
# Android: the foreground service is START_STICKY and comes back. Swipe
# the app away, or turn off its Wi-Fi.
#
#   ./tool/reset-demo.sh
set -euo pipefail

PROJECT="${AVERTIS_PROJECT:-gen-lang-client-0373165899}"
BUCKET="${AVERTIS_BUCKET:-avertis-media-0373165899}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "Clearing Firestore…"
"$HERE/backend/.venv/bin/python" - "$PROJECT" <<'PY'
import sys
from google.cloud import firestore

client = firestore.Client(project=sys.argv[1])
deleted = 0
for collection in ("incidents", "activity", "nodes", "links", "responders",
                   "report_index", "media", "recommendations",
                   "_healthcheck"):
    while True:
        docs = list(client.collection(collection).limit(400).stream())
        if not docs:
            break
        batch = client.batch()
        for doc in docs:
            batch.delete(doc.reference)
            deleted += 1
        batch.commit()
print(f"  {deleted} document(s) deleted")
PY

echo "Clearing stored media…"
gcloud storage rm -r "gs://$BUCKET/media/**" 2>/dev/null || echo "  already empty"

# Recommendations and the incident counter are rebuilt from the store on
# startup, but a running container may still hold cached state — the
# summary in particular. A new revision starts clean.
echo "Restarting the service…"
gcloud run services update avertis --region asia-south1 --project "$PROJECT" \
  --update-env-vars "RESET=$(date +%s)" --quiet >/dev/null
sleep 8

echo "Board now:"
curl -s --max-time 90 https://avertis.web.app/api/v1/world | \
  "$HERE/backend/.venv/bin/python" -c "
import json, sys
w = json.load(sys.stdin)
print('  incidents     ', len(w['physical']['incidents']))
print('  nodes         ', w['network']['nodes_total'])
print('  recommendations', len(w['recommendations']))
print()
print('  If these are not zero, an app is still running somewhere.')
"
