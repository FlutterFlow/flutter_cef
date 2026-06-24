#!/usr/bin/env bash
#
# flutter_cef integration probes — REAL cef_host, headless, asserting.
#
# WHY THIS EXISTS: the Dart integration_test (example/integration_test/) MOCKS
# the host method channel, so it can NOT catch native channel-delivery or
# CDP-relay regressions — which is exactly how the shared-host page->host channel
# bug shipped. These probes run the example app against a REAL cef_host and assert
# the /tmp JSON result each writes. Run this before bumping a consumer's pin.
#
# Probes (example/lib/):
#   channel_probe         single ephemeral host: page->host JS channel delivers
#   channel_probe_shared  TWO sessions on ONE shared host: channel delivers +
#                         routes per-session (the B->A Campus regression)
#   multiview_probe       agent-control / CDP relay isolation on a shared host
#
# Usage:
#   ./test/run_channel_integration.sh                       # all probes
#   ./test/run_channel_integration.sh channel_probe_shared  # just one
#
# Env:
#   FLUTTER           flutter binary (default: `flutter` on PATH)
#   FLUTTER_CEF_HOST  cef_host binary (default: build/cef_host, built if absent)
#
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FLUTTER="${FLUTTER:-flutter}"
APP="$ROOT/example/build/macos/Build/Products/Debug/flutter_cef_example.app/Contents/MacOS/flutter_cef_example"

# --- resolve cef_host (build an ad-hoc one if not supplied / not present) ------
HOST="${FLUTTER_CEF_HOST:-}"
if [ -z "$HOST" ]; then
  HOST="$ROOT/build/cef_host/cef_host.app/Contents/MacOS/cef_host"
  if [ ! -x "$HOST" ]; then
    echo ">> building ad-hoc cef_host (needs cmake + ninja)…"
    ( cd packages/flutter_cef_macos && CEF_HOST_ADHOC=ON ./native/build_cef_host.sh "$ROOT/build/cef_host" ) || {
      echo "!! cef_host build failed — set FLUTTER_CEF_HOST to a prebuilt binary"; exit 2; }
  fi
fi
echo ">> cef_host: $HOST"

# An ad-hoc cef_host refuses named (shared) profiles and downgrades them to
# ephemeral — which would silently turn the shared-host probes into two separate
# hosts and mask the very regression they guard. This opt-in keeps the real
# shared host for the test. (A signed release build does not need it.)
export FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1

# probe : result-json : timeout-secs
PROBES=(
  "channel_probe:/tmp/cef_channel_probe.json:30"
  "channel_probe_shared:/tmp/cef_channel_probe_shared.json:40"
  "multiview_probe:/tmp/cef_multiview_probe.json:75"
)

want="${1:-}"
fails=0
for entry in "${PROBES[@]}"; do
  IFS=':' read -r name json timeout <<< "$entry"
  [ -n "$want" ] && [ "$want" != "$name" ] && continue
  echo ""
  echo "=== probe: $name ==="
  ( cd example && "$FLUTTER" build macos --debug -t "lib/$name.dart" ) >/tmp/cef_int_build.log 2>&1 || {
    echo "!! build failed for $name (see /tmp/cef_int_build.log)"; fails=$((fails+1)); continue; }
  pkill -9 -f flutter_cef_example 2>/dev/null; pkill -9 -f cef_host 2>/dev/null; rm -f "$json"
  FLUTTER_CEF_HOST="$HOST" nohup "$APP" >"/tmp/cef_int_${name}.log" 2>&1 &
  for _ in $(seq 1 "$timeout"); do [ -f "$json" ] && break; sleep 1; done
  pkill -9 -f flutter_cef_example 2>/dev/null; pkill -9 -f cef_host 2>/dev/null
  if [ ! -f "$json" ]; then echo "FAIL  $name — no result (timeout); see /tmp/cef_int_${name}.log"; fails=$((fails+1)); continue; fi
  if python3 -c "import json,sys; sys.exit(0 if json.load(open('$json')).get('pass') is True else 1)" 2>/dev/null; then
    echo "PASS  $name"
  else
    echo "FAIL  $name — $(cat "$json")"; fails=$((fails+1))
  fi
done

echo ""
if [ "$fails" -ne 0 ]; then echo "INTEGRATION FAILED ($fails probe(s))"; exit 1; fi
echo "ALL INTEGRATION PROBES PASSED"
