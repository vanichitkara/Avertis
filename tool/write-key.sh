#!/usr/bin/env bash
# Print the Avertis write key, read from the deployed service.
#
# Cloud Run holds the authoritative copy — it was set there at deploy time
# and nothing else needs to store it. Reading it back beats keeping a second
# copy somewhere that can drift or leak.
#
#   ./tool/write-key.sh                    # print it
#   KEY=$(./tool/write-key.sh)             # use it in a command
#
# Needed for: writes to the API (gateway sync, media upload, dispatch),
# the simulator's --api-key, APK builds, and the dashboard's approve button
# via ?key=<key>. Reads — the dashboard itself — need nothing.
set -euo pipefail

REGION="${AVERTIS_REGION:-asia-south1}"
PROJECT="${AVERTIS_PROJECT:-gen-lang-client-0373165899}"
SERVICE="${AVERTIS_SERVICE:-avertis}"

gcloud run services describe "$SERVICE" \
  --region "$REGION" --project "$PROJECT" \
  --format="value(spec.template.spec.containers[0].env.filter(\"name:AVERTIS_API_KEY\").extract(\"value\"))" \
  2>/dev/null | tr -d "[]'\" "
