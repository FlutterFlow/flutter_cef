#!/usr/bin/env bash
# Fetch a prebuilt, Developer-ID-signed cef_host.app keyed by a CONTENT HASH of
# the build inputs, from public GCS. Runs at `pod install` via the podspec's
# prepare_command; the :after_compile phase then embeds native/cef_host/prebuilt/
# cef_host.app into the app's Contents/Frameworks. Self-locating (CWD-independent).
#
# The hash (see cef_host_hash.sh) is derived from the checked-out native/cef_host
# sources + build_cef_host.sh, so it is identical to what the publisher computed —
# no committed manifest, no per-commit bookkeeping, release-model-agnostic (any
# SHA/branch/tag pin that checks out the same native sources resolves to the same
# object). Fail-OPEN on network/missing (co-dev + offline builds fall back to
# build-from-source / FLUTTER_CEF_HOST); fail-CLOSED on checksum mismatch.
set -euo pipefail

# Escape hatch: co-dev / build-from-source (native/build_cef_host.sh + a make host).
if [ -n "${FLUTTER_CEF_FROM_SOURCE:-}" ]; then
  echo "[flutter_cef] FLUTTER_CEF_FROM_SOURCE set — skipping prebuilt fetch (build from source)."
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"          # .../tool
PKG="$(cd "$HERE/.." && pwd)"                   # .../flutter_cef_macos
NATIVE="$PKG/native"
DEST="$NATIVE/cef_host/prebuilt"

# Only macos-arm64 is published today; x86_64 builds from source.
case "$(uname -m)" in
  arm64) arch=arm64 ;;
  *) echo "[flutter_cef] arch $(uname -m) has no prebuilt cef_host — build from source."; exit 0 ;;
esac

# shellcheck source=cef_host_hash.sh
. "$HERE/cef_host_hash.sh"
HASH="$(cef_host_input_hash "$NATIVE")"

BASE="${FLUTTER_CEF_GCS_BASE:-https://storage.googleapis.com/flutterflow-downloads/campus_prebuilt_cef_host}"
FILE="cef_host-macos-${arch}.tar.gz"
URL="$BASE/$HASH/$FILE"
SHA_URL="$URL.sha256"

# Already current? the extracted prebuilt carries the input hash it was built from.
STAMP="$DEST/cef_host_input_hash.txt"
if [ -d "$DEST/cef_host.app" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$HASH" ]; then
  echo "[flutter_cef] prebuilt cef_host.app already current ($HASH) — skipping fetch."
  exit 0
fi

CACHE="${FLUTTER_CEF_CACHE:-$HOME/.cache/flutter_cef}/prebuilt/$HASH/$arch"
mkdir -p "$CACHE"
tarball="$CACHE/$FILE"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# The expected tarball sha256 (transport integrity) lives beside the object.
# Fail-OPEN if unreachable: no published host for this hash yet (a fresh native
# change before CI publishes, or offline) -> build from source.
expected=""
if ! expected="$(curl -fsSL --retry 3 --retry-delay 1 "$SHA_URL" 2>/dev/null | awk '{print $1}')"; then
  echo "[flutter_cef] no published cef_host for hash $HASH ($SHA_URL unreachable)."
  echo "[flutter_cef] building from source (dev), or CI will publish it shortly."
  exit 0
fi

# (Re)download on cache miss or a stale/corrupt cached tarball.
if [ ! -f "$tarball" ] || [ "$(sha256_file "$tarball")" != "$expected" ]; then
  echo "[flutter_cef] downloading prebuilt cef_host: $URL"
  if ! curl -fL --retry 3 --retry-delay 1 -o "$tarball.part" "$URL"; then
    echo "[flutter_cef] download failed — building from source." >&2
    rm -f "$tarball.part"
    exit 0
  fi
  actual="$(sha256_file "$tarball.part")"
  if [ "$actual" != "$expected" ]; then
    echo "[flutter_cef] SHA256 mismatch for $FILE (expected $expected, got $actual) — refusing." >&2
    rm -f "$tarball.part"
    exit 1                       # fail-CLOSED: never embed an unverified host
  fi
  mv "$tarball.part" "$tarball"
fi

echo "[flutter_cef] extracting prebuilt cef_host -> $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/cef_host.app"
# tar preserves the inside-out Developer-ID signature; the .app + provenance
# stamps (source_sha / version / input_hash) land in prebuilt/.
tar -xzf "$tarball" -C "$DEST"
printf '%s\n' "$HASH" > "$STAMP"    # stamp even if the tarball predates the field
echo "[flutter_cef] prebuilt cef_host ready ($HASH)."
