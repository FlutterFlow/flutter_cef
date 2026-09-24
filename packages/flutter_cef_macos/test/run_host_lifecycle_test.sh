#!/bin/bash
# cef_host's start and shutdown against a scripted plugin: it exits (and frees
# its profile lock) after its IPC closes, even when its UI thread is wedged, and
# reports start failures by exit status. Needs a locally built ad-hoc host (the
# wedge hook is compiled into ad-hoc builds only): FLUTTER_CEF_HOST, or the one
# native/build_cef_host.sh produced. Skips when there is none, as on the CI job
# that runs these suites without building the host.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${FLUTTER_CEF_HOST:-$DIR/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host}"
if [ ! -x "$HOST" ]; then
  echo "skipped: no cef_host at $HOST (build it with native/build_cef_host.sh)"
  exit 0
fi
python3 "$DIR/test/host_lifecycle_test.py" "$HOST"
