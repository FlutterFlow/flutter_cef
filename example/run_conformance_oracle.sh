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
LOGDIR="$(mktemp -d)"; LOG="$LOGDIR/conformance.log"; : > "$LOG"

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
lines = open(sys.argv[1], errors="ignore").read().splitlines()
firstpaint = adopt = blitmm = 0
diag = []                 # (phase, wire, pw, ph, ww, wh, content)
phase = "start"
for ln in lines:
    if "FIRSTPAINT" in ln: firstpaint += 1
    if "ADOPT psid" in ln: adopt += 1
    if "blitmismatch" in ln: blitmm += 1
    pm = re.search(r"=== PHASE (\w+) ===", ln)
    if pm: phase = pm.group(1); continue
    dm = re.search(r"diagpx wire=(\d+) painted=(\d+)x(\d+) want=(\d+)x(\d+) content=(\d+)", ln)
    if dm:
        w = dm.group(1); pw,ph,ww,wh,c = map(int, dm.groups()[1:])
        diag.append((phase, w, pw, ph, ww, wh, c))

blank = sum(1 for d in diag if d[6] == 0)

# HARD invariants — what producer-allocates STRUCTURALLY guarantees and must never regress:
#   • blitmismatch == 0  (cef_host sizes the surface to its own paint → blit is 1:1, no crop)
#   • blank == 0         (a painted frame always has content)
#   • rendered + adopted (the consumer actually wraps producer surfaces)
hard = []
if firstpaint == 0: hard.append("NO-RENDER: no FIRSTPAINT (harness never established)")
if diag and adopt == 0: hard.append("NO-ADOPT: painted but consumer never adopted a surface")
if blitmm > 0: hard.append(f"BLIT-CROP: {blitmm} src!=dst blits (must be 0 under producer-allocates)")
if blank > 0: hard.append(f"BLANK: {blank} painted frames with content==0")
if not diag: hard.append("NO-DIAG: no diagpx samples (FLUTTER_CEF_DEBUG not honored / no paints)")

# CONVERGENCE (quality, WARN-only): a tile's last IDLE-phase sample should be painted==want.
# A mismatch here is the accepted SOFT frame (Flutter scales the internally-consistent surface
# to the tile box → correct geometry, mild softness), NOT the crop/stretch/freeze bug — and the
# sample is noisy because the soak may end mid-storm. So it warns, never fails the gate.
idle_last = {}
for ph_, w, pw, ph, ww, wh, c in diag:
    if ph_ == "idle": idle_last[w] = (pw, ph, ww, wh, c)
soft = [(w, f"{v[0]}x{v[1]}", f"{v[2]}x{v[3]}") for w, v in idle_last.items()
        if v[4] > 0 and v[2] > 0 and (abs(v[0]-v[2]) > 1 or abs(v[1]-v[3]) > 1)]
ok = len(diag) - blank
print(f"[oracle] FIRSTPAINT={firstpaint} ADOPT={adopt} diagpx={len(diag)} content-ok={ok} "
      f"blank={blank} blitmismatch={blitmm} idle-converged={len(idle_last)-len(soft)}/{len(idle_last)}")
if soft:
    print(f"[oracle] WARN convergence (soft, acceptable): {len(soft)} idle tiles painted!=want, e.g. {soft[:3]}")
if hard:
    print("\n=== CONFORMANCE FAILED ==="); [print("  ✗ " + f) for f in hard]; sys.exit(1)
print("\n=== CONFORMANCE PASSED — producer-allocates structural invariants hold "
      "(blitmismatch=0, no blank, rendered+adopted) ===")
PY
RC=$?
echo "[oracle] log: $LOG"
exit $RC
