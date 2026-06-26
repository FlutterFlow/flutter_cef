#!/bin/bash
# Compile + run the standalone ResizeWatchdogPolicy unit tests (the F-4 visibility-gating
# that prevents the resize/cull wedge). ResizeWatchdogPolicy uses only the Swift stdlib,
# so no Xcode/pod harness is needed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/rwd"
swiftc "$DIR/macos/Classes/ResizeWatchdogPolicy.swift" "$DIR/test/ResizeWatchdogPolicyTests.swift" -o "$OUT"
"$OUT"
