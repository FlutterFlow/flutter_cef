#!/bin/bash
# Compile + run the standalone LivenessProbePolicy unit tests (F-6 steady-state liveness
# decision). Swift stdlib only — no Xcode/pod harness needed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/liveness"
swiftc "$DIR/macos/Classes/LivenessProbePolicy.swift" "$DIR/test/LivenessProbePolicyTests.swift" -o "$OUT"
"$OUT"
