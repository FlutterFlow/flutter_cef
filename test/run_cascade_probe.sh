#!/usr/bin/env bash
#
# flutter_cef cascade / never-blank probe — REAL cef_host, asserting.
#
# WHY THIS EXISTS: the never-blank guarantee (serialized establishment via the
# paint-gated create-pacer + sliding window K + bounded recreate) and the cascade
# speed are GPU/host behaviors the mocked Dart tests can't exercise. This launches
# the stress probe against a REAL cef_host with N concurrently-created animating
# tiles and asserts EVERY tile reaches a first accelerated frame (paints>0) — i.e.
# none stays permanently blank — and reports the establishment cascade time.
# Run it before bumping a consumer's pin / merging pacer or establishment changes.
#
# Usage:
#   ./test/run_cascade_probe.sh            # N=12 tiles, window=3 (defaults)
#   CEF_N=20 CEF_WINDOW=3 ./test/run_cascade_probe.sh
#
# Env:
#   FLUTTER           flutter binary (default: `flutter` on PATH)
#   FLUTTER_CEF_HOST  cef_host binary (default: build/cef_host, built if absent)
#   CEF_N             tiles created at once (default 12)
#   CEF_WINDOW        FLUTTER_CEF_ESTAB_WINDOW establishment concurrency (default 3)
#   CEF_SECS          run seconds before asserting (default 30 — room to self-heal)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FLUTTER="${FLUTTER:-flutter}"
N="${CEF_N:-12}"
WINDOW="${CEF_WINDOW:-3}"
SECS="${CEF_SECS:-30}"
APP="$ROOT/example/build/macos/Build/Products/Debug/flutter_cef_example.app/Contents/MacOS/flutter_cef_example"

HOST="${FLUTTER_CEF_HOST:-}"
if [ -z "$HOST" ]; then
  HOST="$ROOT/build/cef_host/cef_host.app/Contents/MacOS/cef_host"
  if [ ! -x "$HOST" ]; then
    echo ">> building ad-hoc cef_host (needs cmake + ninja)…"
    ( cd packages/flutter_cef_macos && CEF_HOST_ADHOC=ON ./native/build_cef_host.sh "$ROOT/build/cef_host" ) || {
      echo "!! cef_host build failed — set FLUTTER_CEF_HOST to a prebuilt binary"; exit 2; }
  fi
fi
echo ">> cef_host: $HOST   N=$N window=$WINDOW"

echo ">> building stress probe…"
( cd example && "$FLUTTER" build macos --debug \
    --dart-define=CEF_POOL=1 --dart-define=CEF_INITIAL="$N" \
    --dart-define=CEF_RECREATE_ON_STALL=true \
    -t lib/stress_probe.dart ) || { echo "!! example build failed"; exit 2; }

LOG="/tmp/cef_cascade_$$.log"; : > "$LOG"
pkill -9 -f flutter_cef_example 2>/dev/null; pkill -9 -f "MacOS/cef_host" 2>/dev/null; sleep 1
# Ad-hoc host downgrades named profiles to ephemeral unless allowed — the probe
# uses a shared named profile (CEF_POOL=1), so keep it on the real shared host.
FLUTTER_CEF_DEBUG=1 FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 \
  FLUTTER_CEF_ESTAB_WINDOW="$WINDOW" FLUTTER_CEF_HOST="$HOST" \
  nohup "$APP" > "$LOG" 2>&1 &
APP_PID=$!
for _ in $(seq 1 "$SECS"); do sleep 1; done
pkill -9 -f flutter_cef_example 2>/dev/null; pkill -9 -f "MacOS/cef_host" 2>/dev/null

# Count distinct browsers that reached a first accelerated frame (paints>0).
EST=$(python3 - "$LOG" <<'PY'
import re, sys
seen = set()
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"wire=(\d+) pumpTicks=\d+ paints=(\d+)", line)
    if m and int(m.group(2)) > 0:
        seen.add(m.group(1))
print(len(seen))
PY
)
EST="${EST:-0}"
echo ">> established $EST / $N  (log: $LOG)"
if [ "$EST" -lt "$N" ]; then
  echo "!! FAIL: $((N-EST)) tile(s) never produced a first frame (permanent blank)"
  exit 1
fi
echo ">> PASS: every tile rendered"
