#!/bin/bash
# CONFORMANCE ORACLE — the automated regression gate for the producer-allocates OSR pipeline.
#
# Drives the conformance_harness headless through all storms (resize / zoom / cull / recreate /
# combo) and parses cef_host's diagpx oracle to FAIL (non-zero exit) on any violation of the
# invariants the whole producer-allocates change exists to guarantee:
#   • WRONG-SIZE  : a painted surface whose dims != the requested logical×dpr (the 4x/crop class)
#   • BLANK       : a painted frame with no content (content == 0)
#   • BLIT-CROP   : any cef_host blit where src != dst (must be 0 — src==dst by construction)
#   • NO-RENDER   : the harness never established / never adopted a surface
#
# This turns the manual "read the logs" check into a repeatable gate. Run after any change to
# CefWebSession.swift / CefProfileHost.swift / cef_host/main.mm.
#
#   FLUTTER_CEF_HOST=/path/to/cef_host.app/Contents/MacOS/cef_host ./run_conformance_oracle.sh
#
# Requires a built cef_host (see `make cef-host`; rm build/cef_host/.flutter_cef_ref after a
# native edit so it actually rebuilds). Honors HARNESS_N (default 9) and SOAK_SECONDS (default 55,
# enough for the auto-cycle to traverse every storm phase at least once).
set -uo pipefail

HOST="${FLUTTER_CEF_HOST:?set FLUTTER_CEF_HOST to a built cef_host binary}"
[ -x "$HOST" ] || { echo "FAIL: FLUTTER_CEF_HOST not executable: $HOST"; exit 2; }
DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$(cd "$DIR/../../.." && pwd)/work_canvas/scripts/campus-flutter-engine.sh"
[ -x "$ENGINE" ] || ENGINE="flutter"  # fallback to PATH flutter
SOAK="${SOAK_SECONDS:-55}"
LOG="$(mktemp)/conformance.log"; mkdir -p "$(dirname "$LOG")"; : > "$LOG"

echo "[oracle] cef_host: $HOST ($(stat -f '%Sm' "$HOST" 2>/dev/null))"
echo "[oracle] driving conformance_harness HARD for ${SOAK}s…"
pkill -f "flutter_cef_example" 2>/dev/null; sleep 1
( cd "$DIR" && FLUTTER_CEF_HOST="$HOST" FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 \
    FLUTTER_CEF_DEBUG=1 FLUTTER_CEF_DIAGPX_EVERY=6 HARNESS_HARD=1 HARNESS_N="${HARNESS_N:-9}" \
    "$ENGINE" run -d macos -t lib/conformance_harness.dart >> "$LOG" 2>&1 ) &
RUNPID=$!

# Wait for first paint (build can take minutes), then soak through the storm cycle.
for _ in $(seq 1 90); do grep -q "FIRSTPAINT\|BUILD FAILED\|error:" "$LOG" && break; sleep 4; done
if grep -qE "BUILD FAILED|: error:" "$LOG"; then
  echo "FAIL: harness build error"; grep -iE "error:" "$LOG" | head -5; kill "$RUNPID" 2>/dev/null; exit 2
fi
sleep "$SOAK"
pkill -f "flutter_cef_example" 2>/dev/null; sleep 1

# ---- Parse the oracle ----
python3 - "$LOG" <<'PY'
import re, sys
log = open(sys.argv[1], errors="ignore").read()
firstpaint = len(re.findall(r"FIRSTPAINT", log))
adopt      = len(re.findall(r"ADOPT psid", log))
blitmm     = len(re.findall(r"blitmismatch", log))
diag = re.findall(r"diagpx wire=(\d+) painted=(\d+)x(\d+) want=(\d+)x(\d+) content=(\d+)", log)
wrong, blank, ok = [], 0, 0
for wire,pw,ph,ww,wh,c in diag:
    pw,ph,ww,wh,c = map(int,(pw,ph,ww,wh,c))
    if c == 0: blank += 1
    elif ww>0 and (abs(pw-ww) > 1 or abs(ph-wh) > 1): wrong.append((wire,f"{pw}x{ph}",f"{ww}x{wh}"))
    else: ok += 1
print(f"[oracle] FIRSTPAINT={firstpaint} ADOPT={adopt} diagpx={len(diag)} ok={ok} blank={blank} wrong-size={len(wrong)} blitmismatch={blitmm}")
fail = []
if firstpaint == 0: fail.append("NO-RENDER: no FIRSTPAINT (harness never established)")
if len(diag) > 0 and adopt == 0: fail.append("NO-ADOPT: painted but consumer never adopted a surface")
if blitmm > 0: fail.append(f"BLIT-CROP: {blitmm} src!=dst blits (must be 0 under producer-allocates)")
if blank > 0: fail.append(f"BLANK: {blank} painted frames with no content")
if wrong:     fail.append(f"WRONG-SIZE: {len(wrong)} frames painted!=want, e.g. {wrong[:3]}")
if len(diag) == 0: fail.append("NO-DIAG: no diagpx samples (FLUTTER_CEF_DEBUG not honored / no paints)")
if fail:
    print("\n=== CONFORMANCE FAILED ==="); [print("  ✗ "+f) for f in fail]; sys.exit(1)
print("\n=== CONFORMANCE PASSED — producer-allocates invariants hold ===")
PY
RC=$?
echo "[oracle] log: $LOG"
exit $RC
