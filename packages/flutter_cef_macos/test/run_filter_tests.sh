#!/bin/bash
# Compile + run the standalone CdpRelay filter unit tests (CEF-2b security boundary).
# CdpRelay.swift uses only system frameworks, so no Xcode/pod harness is needed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/cdpfilter"
swiftc "$DIR/macos/Classes/CdpRelay.swift" "$DIR/test/CdpRelayFilterTests.swift" -o "$OUT"
"$OUT"
