#!/bin/bash
# LEAK-SOAK GATE — guards the producer-allocates IOSurface LIFETIME invariant (the property the
# three sev-8 audit findings probed and which the render oracle does NOT cover): cef_host mints a
# surface per paint/recreate and CFReleases the old; the consumer's CVPixelBuffer holds the only
# remaining ref until it adopts the next id. If that ledger ever regresses (producer forgets to
# release, or the consumer never drops the old ref), surfaces accumulate — invisible to the render
# oracle (which checks correctness, not memory) until it OOMs. This drives a recreate-heavy soak
# (dispose+create churn) and asserts cef_host RSS + the live IOSurface count stay BOUNDED.
#
#   FLUTTER_CEF_HOST=/path/to/cef_host ./run_leak_soak.sh
#
# Honors SOAK_SECONDS (default 100, ~200 recreate cycles). Fails (non-zero) if, after warmup,
# cef_host RSS grows past RSS_CEILING_MULT x baseline, or IOSurface count grows monotonically.
set -uo pipefail

HOST="${FLUTTER_CEF_HOST:?set FLUTTER_CEF_HOST to a built cef_host binary}"
[ -x "$HOST" ] || { echo "FAIL: FLUTTER_CEF_HOST not executable: $HOST"; exit 2; }
DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$(cd "$DIR/../../.." && pwd)/work_canvas/scripts/campus-flutter-engine.sh"
[ -x "$ENGINE" ] || ENGINE="flutter"
SOAK="${SOAK_SECONDS:-100}"
RSS_CEILING_MULT="${RSS_CEILING_MULT:-1.5}"   # post-warmup RSS may not exceed baseline x this
LOGDIR="$(mktemp -d)"; LOG="$LOGDIR/leak.log"; : > "$LOG"

echo "[leak] cef_host: $HOST"
pkill -f "flutter_cef_example" 2>/dev/null; sleep 1
( cd "$DIR" && FLUTTER_CEF_HOST="$HOST" FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 FLUTTER_CEF_DEBUG=1 \
    "$ENGINE" run -d macos -t lib/recreate_soak_probe.dart >> "$LOG" 2>&1 ) &

# Wait for establishment (build can take minutes).
for _ in $(seq 1 90); do grep -q "FIRSTPAINT\|BUILD FAILED\|: error:" "$LOG" && break; sleep 4; done
if grep -qE "BUILD FAILED|: error:" "$LOG"; then
  echo "FAIL: probe build error"; grep -iE "error:" "$LOG" | head -5; pkill -f flutter_cef_example; exit 2
fi

cefpid() { pgrep -f "cef_host.app/Contents/MacOS/cef_host" | head -1; }
rss() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }   # KB
iosurf() { ioreg -c IOSurface 2>/dev/null | grep -c "IOSurface"; }

sleep 12  # warmup: let establishment + the first recreates settle before baseline
PID="$(cefpid)"
[ -n "$PID" ] || { echo "FAIL: no cef_host process"; pkill -f flutter_cef_example; exit 2; }
BASE_RSS="$(rss "$PID")"; BASE_SURF="$(iosurf)"
echo "[leak] baseline (post-warmup): cef_host RSS=${BASE_RSS}KB IOSurfaces=${BASE_SURF}"

# Sample the trend across the soak.
SAMPLES=$(( SOAK / 15 )); [ "$SAMPLES" -lt 3 ] && SAMPLES=3
MAX_RSS="$BASE_RSS"; LAST_SURF="$BASE_SURF"
for i in $(seq 1 "$SAMPLES"); do
  sleep 15
  P="$(cefpid)"; [ -n "$P" ] || { echo "FAIL: cef_host died mid-soak (crash?)"; pkill -f flutter_cef_example; exit 1; }
  R="$(rss "$P")"; S="$(iosurf)"
  [ "$R" -gt "$MAX_RSS" ] && MAX_RSS="$R"
  LAST_SURF="$S"
  echo "[leak] t+$((12 + i*15))s: RSS=${R}KB IOSurfaces=${S}"
done
RECREATES="$(grep -oE 'recreates_total=[0-9]+' "$LOG" | tail -1)"
pkill -f "flutter_cef_example" 2>/dev/null; sleep 1

python3 - "$BASE_RSS" "$MAX_RSS" "$BASE_SURF" "$LAST_SURF" "$RSS_CEILING_MULT" "$RECREATES" <<'PY'
import sys
base_rss, max_rss, base_surf, last_surf, mult = (int(sys.argv[1]), int(sys.argv[2]),
                                                 int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]))
recreates = sys.argv[6] or "recreates_total=?"
ceiling = int(base_rss * mult)
surf_grow = last_surf - base_surf
print(f"[leak] {recreates}  RSS base={base_rss}KB peak={max_rss}KB ceiling={ceiling}KB  "
      f"IOSurfaces base={base_surf} last={last_surf} (delta={surf_grow:+d})")
fail = []
if recreates.endswith("=?") or recreates.endswith("=0"):
    fail.append("NO-CHURN: no recreates observed — the soak didn't exercise the lifetime path")
if max_rss > ceiling:
    fail.append(f"RSS-LEAK: cef_host RSS peaked {max_rss}KB > {ceiling}KB ({mult}x baseline)")
# IOSurfaces are system-wide + noisy; flag only a LARGE monotonic climb (producer-allocates holds
# ~1-2 surfaces per live tile; a leak shows tens-to-hundreds of unreleased surfaces).
if surf_grow > 80:
    fail.append(f"SURFACE-LEAK: live IOSurface count grew {surf_grow} over the soak (unbounded)")
if fail:
    print("\n=== LEAK-SOAK FAILED ==="); [print("  ✗ " + f) for f in fail]; sys.exit(1)
print("\n=== LEAK-SOAK PASSED — RSS + IOSurface count bounded across the recreate churn ===")
PY
RC=$?
echo "[leak] log: $LOG"
exit $RC
