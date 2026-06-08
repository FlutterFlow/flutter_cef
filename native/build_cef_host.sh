#!/usr/bin/env bash
# Fetch the CEF binary distribution and build cef_host.app — the off-screen
# renderer subprocess. Output: cef_host.app under the chosen build dir.
#
#   native/build_cef_host.sh [OUT_DIR]
#
# Env: FLUTTER_CEF_CACHE (default ~/.cache/flutter_cef), CODESIGN_ID (default
# ad-hoc; pass a Developer ID / Apple Development identity for standalone use —
# when bundled into an app, the app's own signing re-signs it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Pinned CEF (minimal dist). Keep in lockstep with any cef_host API use.
CEF_VERSION="144.0.27+g3fae261+chromium-144.0.7559.254"
# Pinned SHA-256 of the tarball, fail-closed. arm64 is pinned; for x64 leave
# empty and we verify against the CDN-published .sha1 instead.
CEF_SHA256_ARM64="8214fdef23def8d3c5a7acd69383dcd55ad2f197acdfeb2256100806a0fc898a"
CEF_SHA256_X64=""
case "$(uname -m)" in
  arm64) CEF_ARCH="macosarm64"; CEF_SHA256="$CEF_SHA256_ARM64" ;;
  x86_64) CEF_ARCH="macosx64"; CEF_SHA256="$CEF_SHA256_X64" ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
CEF_NAME="cef_binary_${CEF_VERSION}_${CEF_ARCH}_minimal"

CACHE="${FLUTTER_CEF_CACHE:-$HOME/.cache/flutter_cef}"
CEF_ROOT="$CACHE/$CEF_NAME"
OUT="${1:-$HERE/cef_host/build}"
CODESIGN_ID="${CODESIGN_ID:--}"

mkdir -p "$CACHE"
if [ ! -f "$CEF_ROOT/cmake/FindCEF.cmake" ]; then
  echo "[flutter_cef] fetching CEF $CEF_VERSION ($CEF_ARCH) ..."
  enc="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "${CEF_NAME}.tar.bz2")"
  tarball="$CACHE/${CEF_NAME}.tar.bz2"
  curl -fL "https://cef-builds.spotifycdn.com/${enc}" -o "$tarball"
  if [ -n "$CEF_SHA256" ]; then
    echo "[flutter_cef] verifying SHA-256 ..."
    echo "${CEF_SHA256}  ${tarball}" | shasum -a 256 -c - \
      || { echo "[flutter_cef] CEF checksum mismatch — aborting" >&2; rm -f "$tarball"; exit 1; }
  else
    echo "[flutter_cef] no pinned SHA-256 for $CEF_ARCH; verifying against CDN .sha1 ..."
    curl -fsL "https://cef-builds.spotifycdn.com/${enc}.sha1" -o "$tarball.sha1" \
      && echo "$(cat "$tarball.sha1")  ${tarball}" | shasum -a 1 -c - \
      || { echo "[flutter_cef] could not verify CEF download — aborting" >&2; rm -f "$tarball"; exit 1; }
  fi
  tar -xjf "$tarball" -C "$CACHE"
fi

echo "[flutter_cef] building cef_host.app ..."
MP_FLAG="-DCEF_MULTI_PROCESS=OFF"
if [ "${CEF_MULTI_PROCESS:-}" = "1" ] || [ "${CEF_MULTI_PROCESS:-}" = "ON" ]; then
  MP_FLAG="-DCEF_MULTI_PROCESS=ON"
  echo "[flutter_cef] multi-process build (needs Developer ID + notarization for a clean -67030)"
fi
cmake -G Ninja -S "$HERE/cef_host" -B "$OUT" \
  -DCEF_ROOT="$CEF_ROOT" -DCODESIGN_ID="$CODESIGN_ID" "$MP_FLAG" >/dev/null
ninja -C "$OUT" cef_host
echo "[flutter_cef] -> $OUT/cef_host.app"
echo "[flutter_cef] for dev, point the app at it:"
echo "  export FLUTTER_CEF_HOST=\"$OUT/cef_host.app/Contents/MacOS/cef_host\""
