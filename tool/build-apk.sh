#!/usr/bin/env bash
# Build release APKs the way they actually have to be built.
#
# Two things went wrong often enough by hand to be worth a script:
#
#   * An APK built without AVERTIS_API_KEY cannot write to the backend.
#     Reads are open, so health checks pass and the phone looks healthy
#     while every sync comes back 401.
#
#   * --split-per-abi fixes the versionCode per ABI, so every build came
#     out as the same version. Android will not treat that as an upgrade,
#     the sideload is refused, and the usual response is to uninstall —
#     which loses the permissions and the node id. The build number is
#     bumped here so each APK is genuinely newer than the last.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
API=${AVERTIS_API_BASE:-https://avertis-687930058257.asia-south1.run.app}

# A non-interactive shell does not get the login PATH, so find the SDK
# rather than assuming it is there. $FLUTTER overrides.
FLUTTER=${FLUTTER:-$(command -v flutter || true)}
for candidate in "$HOME/development/flutter/bin/flutter" \
                 "$HOME/flutter/bin/flutter" \
                 /opt/homebrew/bin/flutter; do
  [ -n "$FLUTTER" ] && break
  [ -x "$candidate" ] && FLUTTER=$candidate
done
if [ -z "$FLUTTER" ]; then
  echo "cannot find the flutter SDK; set FLUTTER=/path/to/bin/flutter" >&2
  exit 1
fi

KEY=$("$ROOT/tool/write-key.sh")
if [ -z "$KEY" ]; then
  echo "could not read the write key; an APK without it cannot sync" >&2
  exit 1
fi

# Bump the build number: 0.1.0+7 -> 0.1.0+8
PUBSPEC="$ROOT/mobile/pubspec.yaml"
CURRENT=$(grep -E '^version:' "$PUBSPEC" | sed -E 's/.*\+([0-9]+)$/\1/')
NEXT=$((CURRENT + 1))
sed -i '' -E "s/^(version: [0-9.]+)\+[0-9]+$/\1+$NEXT/" "$PUBSPEC"
echo "build number $CURRENT -> $NEXT"

cd "$ROOT/mobile"
"$FLUTTER" build apk --release --split-per-abi \
  --dart-define=AVERTIS_API_BASE="$API" \
  --dart-define=AVERTIS_API_KEY="$KEY"

mkdir -p "$ROOT/dist"
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
   "$ROOT/dist/avertis-arm64.apk"
cp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk \
   "$ROOT/dist/avertis-arm32.apk"

echo
echo "dist/avertis-arm64.apk  (most phones)"
echo "dist/avertis-arm32.apk  (older phones)"
echo "pointed at $API"
