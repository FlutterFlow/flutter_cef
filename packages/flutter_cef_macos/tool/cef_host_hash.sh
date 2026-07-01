#!/usr/bin/env bash
# Deterministic content hash of the cef_host build inputs.
#
# Sourced by BOTH fetch_cef_host.sh (consumer, at pod install) and
# publish-cef-host.sh (CI) so they ALWAYS compute the same digest from the same
# source tree — that digest is the GCS object key, so any drift here is a silent
# cache miss. Prints a 64-hex digest to stdout.
#
# Inputs = native/build_cef_host.sh (carries CEF_VERSION + the CEF dist sha pin +
# the signing/adhoc defaults) + every source file under native/cef_host/
# (excluding the prebuilt/ and build/ OUTPUT dirs). The huge CEF binary dist is
# NOT hashed — it is pinned transitively by build_cef_host.sh's CEF_VERSION.
#
# Usage:  . cef_host_hash.sh ; cef_host_input_hash <native_dir>
#   <native_dir> = .../packages/flutter_cef_macos/native
set -euo pipefail

# sha256 of the given file(s), or of stdin when no args. Portable across bash/zsh
# (no reliance on word-splitting a command string) and macOS/Linux.
_cefhost_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi
}

cef_host_input_hash() {
  local native_dir="$1"
  # Sorted, path-relative list of build-input files. LC_ALL=C makes the sort
  # byte-stable across machines. We emit "<relpath>\n<filesha>\n" per file so
  # BOTH content changes and path/renames move the final digest.
  (
    cd "$native_dir"
    export LC_ALL=C
    {
      printf '%s\n' "build_cef_host.sh"
      find cef_host -type f \
        -not -path 'cef_host/prebuilt/*' \
        -not -path 'cef_host/build/*'
    } | LC_ALL=C sort -u | while IFS= read -r f; do
        printf '%s\n' "$f"
        _cefhost_sha256 "$f" | awk '{print $1}'
      done
  ) | _cefhost_sha256 | awk '{print $1}'
}
