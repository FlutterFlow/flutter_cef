#!/usr/bin/env bash
#
# Run the real-host probes in example/lib against a real cef_host (macOS).
#
# The Dart tests mock the method channel, so they can't catch a regression in
# the plugin, the host or the wire between them. Each probe here is an app
# entry point that drives a real cef_host and reports PASS or FAIL. Run the set
# before bumping a consumer's pin, and after any native change.
#
# Usage:
#   tool/run_probes.sh                  # every automatic probe
#   tool/run_probes.sh page_boundary    # just the named probes (prefix match)
#   tool/run_probes.sh --list           # the table, including manual probes
#
# Env:
#   FLUTTER           flutter command (default: fvm flutter if available, else flutter)
#   FLUTTER_CEF_HOST  the cef_host binary to test (default: the locally built
#                     packages/flutter_cef_macos/native/cef_host/build one)
#   PROBE_LOGS        where logs go (default: a fresh temp dir)
#
# A probe reports in one of two ways: a `CEF_PROBE_RESULT PASS|FAIL` line on
# stdout, or a JSON file with `"pass": true|false`. This script kills only the
# processes it started, never other cef_host processes on the machine.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

if [ -z "${FLUTTER:-}" ]; then
  if command -v fvm >/dev/null 2>&1; then FLUTTER="fvm flutter"; else FLUTTER=flutter; fi
fi
HOST="${FLUTTER_CEF_HOST:-$ROOT/packages/flutter_cef_macos/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host}"
LOGS="${PROBE_LOGS:-$(mktemp -d -t flutter_cef_probes)}"
APP="$ROOT/example/build/macos/Build/Products/Debug/flutter_cef_example.app/Contents/MacOS/flutter_cef_example"

# name | entry point | timeout s | result | host | needs | note
#   result: stdout, or json:<path>
#   host:   default (the host under test), false (/usr/bin/false), hang (never connects)
#   needs:  - , signed (named profiles; an ad-hoc host refuses them),
#           shared (runs with FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1), or
#           manual (interactive or a soak: listed, never run)
PROBES=(
  "authored_origin|authored_origin_probe|120|stdout|default|-|loadHtmlString(baseUrl:) serves the document at that origin"
  "document_start|document_start_probe|120|stdout|default|-|document-start scripts run before page scripts"
  "hidden_at_create|hidden_at_create_probe|120|stdout|default|-|a view created hidden paints once shown"
  "host_start_failure|host_start_failure_probe|60|stdout|false|-|a host that exits at once reports createFailed"
  "host_start_hang|host_start_failure_probe|60|stdout|hang|-|a host that never connects is disposed promptly"
  "keyboard_shortcut|keyboard_shortcut_probe|120|stdout|default|-|⌘-key combos reach the page before edit commands"
  "page_boundary|page_boundary_probe|180|stdout|default|-|popups, schemes and navigation stay inside the allowlist"
  "relay_isolation|relay_isolation_probe|180|stdout|default|-|an agent can't reach a sibling tile over CDP"
  "samesite|samesite_probe|120|stdout|default|-|setCookie stores Secure / HttpOnly / SameSite"
  "surface_handoff|surface_handoff_probe|120|stdout|default|-|frames arrive over a Mach port, not a global IOSurface"
  "wedge_recovery|wedge_recovery_probe|400|stdout|default|-|a wedged renderer is recovered without killing healthy tiles"
  "host_robustness|host_robustness_probe|480|stdout|default|-|one page can't take down the other tiles on its host"
  "alert|alert_probe|90|json:/tmp/cef_alert_probe.json|default|-|answering a JS alert unblocks the page"
  "channel|channel_probe|60|json:/tmp/cef_channel_probe.json|default|-|page-to-app JS channel delivers"
  "channel_shared|channel_probe_shared|60|json:/tmp/cef_channel_probe_shared.json|default|shared|two views on one host: each channel message reaches its own view"
  "multiview|multiview_probe|120|stdout|default|signed|agent control on several tiles of one shared host"
  "profile_reopen|profile_reopen_probe|180|stdout|default|signed|reopening a named profile never reports locked"
  "stress|stress_probe|300|json:/tmp/cef_stress.json|default|manual|many animating tiles on one host (tunable with dart-defines)"
  "recreate_soak|recreate_soak_probe|0|stdout|default|manual|create/dispose churn"
  "profile|profile_probe|0|stdout|default|manual|Windows: named profile and cookies end to end"
  "windows_smoke|windows_smoke_probe|0|stdout|default|manual|Windows: paint, eval, channel, resize, freeze/thaw (run by the windows-build CI job)"
  "agentcontrol|agentcontrol_probe|0|stdout|default|manual|Windows agent-control smoke"
  "jsbridge_smoke|jsbridge_smoke|0|stdout|default|manual|Windows JS bridge smoke"
  "conformance|conformance_harness|0|stdout|default|manual|rendering conformance against Chrome (example/run_conformance_oracle.sh)"
  "crispness|crispness_probe|0|stdout|default|manual|visual: HiDPI text crispness"
  "cull_wedge|cull_wedge_probe|0|stdout|default|manual|visual: cull and restore under load"
  "interaction_soak|interaction_soak_probe|0|stdout|default|manual|visual: input under load"
  "realsite_soak|realsite_soak_probe|0|stdout|default|manual|visual: real sites under load"
  "sharedhost_html|sharedhost_html_probe|0|stdout|default|manual|visual: authored HTML on a shared host"
  "zoom_soak|zoom_soak_probe|0|stdout|default|manual|visual: zoom churn"
)

if [ "${1:-}" = "--list" ]; then
  for e in "${PROBES[@]}"; do
    IFS='|' read -r name _ _ _ _ needs note <<< "$e"
    printf '%-18s %-7s %s\n' "$name" "${needs/-/auto}" "$note"
  done
  exit 0
fi

if [ ! -x "$HOST" ]; then
  echo "No cef_host at $HOST."
  echo "Build one (FLUTTER_CEF_STOCK_FRAMEWORK=1 packages/flutter_cef_macos/native/build_cef_host.sh) or set FLUTTER_CEF_HOST."
  exit 2
fi
signed=0
codesign -dvv "$HOST" 2>&1 | grep -q '^Authority=' && signed=1

HANG="$LOGS/hang_host"
printf '#!/bin/sh\nexec sleep 600\n' > "$HANG" && chmod +x "$HANG"
# profile_reopen_probe checks that the startup sweep keeps the ephemeral dir of a
# live process. pid 1 is always alive, so this dir must survive.
mkdir -p "${TMPDIR:-/tmp}/flutter_cef_ephem_1_probe"

pass=0; fail=0; skip=0; built=""
echo "host: $HOST ($([ $signed = 1 ] && echo signed || echo ad-hoc))"
echo "logs: $LOGS"
for e in "${PROBES[@]}"; do
  IFS='|' read -r name entry timeout result host needs note <<< "$e"
  if [ $# -gt 0 ]; then
    match=0; for want in "$@"; do [[ "$name" == "$want"* ]] && match=1; done
    [ $match = 1 ] || continue
  fi
  if [ "$needs" = manual ]; then
    [ $# -gt 0 ] && echo "SKIP  $name (manual: $note)"
    continue
  fi
  if [ "$needs" = signed ] && [ $signed = 0 ]; then
    echo "SKIP  $name (needs a signed host)"; skip=$((skip + 1)); continue
  fi

  defines=()
  [ "$name" = host_start_hang ] && defines=(--dart-define=CEF_PROBE_HOST_HANGS=true)
  key="$entry ${defines[*]:-}"
  if [ "$built" != "$key" ]; then
    if ! (cd example && $FLUTTER build macos --debug -t "lib/$entry.dart" ${defines[@]+"${defines[@]}"}) > "$LOGS/$name.build.log" 2>&1; then
      echo "FAIL  $name (build failed: $LOGS/$name.build.log)"; fail=$((fail + 1)); built=""; continue
    fi
    built="$key"
  fi

  case "$host" in
    false) h=/usr/bin/false ;;
    hang) h="$HANG" ;;
    *) h="$HOST" ;;
  esac
  json=""; [[ "$result" == json:* ]] && json="${result#json:}" && rm -f "$json"
  env_extra=()
  [ "$needs" = shared ] && env_extra=(FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1)

  log="$LOGS/$name.log"
  env FLUTTER_CEF_HOST="$h" ${env_extra[@]+"${env_extra[@]}"} "$APP" > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 "$timeout"); do
    kill -0 $pid 2>/dev/null || break
    grep -q 'CEF_PROBE_RESULT' "$log" && break
    [ -n "$json" ] && [ -s "$json" ] && break
    sleep 1
  done
  # Some probes stay open after reporting; give an exiting one a moment, then stop it.
  sleep 1
  kill $pid 2>/dev/null; wait $pid 2>/dev/null

  if [ -n "$json" ]; then
    if [ -s "$json" ] && python3 -c "import json,sys; sys.exit(0 if json.load(open('$json')).get('pass') is True else 1)" 2>/dev/null; then
      echo "PASS  $name"; pass=$((pass + 1))
    else
      echo "FAIL  $name ($( [ -s "$json" ] && cat "$json" || echo "no result within ${timeout}s"); log: $log)"; fail=$((fail + 1))
    fi
  elif grep -q 'CEF_PROBE_RESULT PASS' "$log"; then
    echo "PASS  $name"; pass=$((pass + 1))
  else
    echo "FAIL  $name ($(grep -m3 'CEF_PROBE_LOG .*FAIL' "$log" | sed 's/.*CEF_PROBE_LOG *//' | tr '\n' ';' ; grep -q CEF_PROBE_RESULT "$log" || echo "no result within ${timeout}s"); log: $log)"
    fail=$((fail + 1))
  fi
done

echo
echo "$pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ]
