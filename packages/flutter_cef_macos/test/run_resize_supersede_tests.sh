#!/bin/bash
# Compile + run the standalone ResizeSupersedePolicy unit tests (the wedged-resize self-heal).
# Pure Swift stdlib — no Xcode/pod harness needed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/rsp"
swiftc "$DIR/macos/Classes/ResizeSupersedePolicy.swift" "$DIR/test/ResizeSupersedePolicyTests.swift" -o "$OUT"
"$OUT"
