#!/bin/bash
# Compile + run the Windows policy unit tests (policy_test.cc). The headers
# under test are pure C++17 (no Win32, CEF or Flutter), so any C++ compiler
# runs them; CI runs this on macOS.
set -euo pipefail
PKG="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)/policy_test"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror \
  -I"$PKG/native/cef_host" -I"$PKG/windows" \
  "$PKG/test/native/policy_test.cc" -o "$OUT"
"$OUT"
