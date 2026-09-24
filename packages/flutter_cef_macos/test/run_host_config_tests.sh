#!/bin/bash
# Compile + run the standalone HostConfigPolicy unit tests (who may join a running
# shared cef_host). Foundation only, so no Xcode/pod harness is needed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/hostconfig"
swiftc "$DIR/macos/Classes/HostConfigPolicy.swift" "$DIR/test/HostConfigPolicyTests.swift" -o "$OUT"
"$OUT"
