#!/usr/bin/env bash
# Build the SANDBOXED (CEF_HOST_ADHOC=OFF, Developer-ID) cef_host, key it by a
# content hash of the build inputs, and idempotently publish it to public GCS.
# Run by the private flutter_cef Codemagic workflow (which holds the signing
# material + a GCS-writable service account) on push-to-main and cef-host-v* tags.
#
# The SANDBOXED variant is deliberate: the ad-hoc variant (get-task-allow + mock
# keychain + Mach-port bypass) fails to render agent_ui in a consuming app. The
# Developer-ID signature is inside-out; release consumers re-sign it with their
# own identity, so only the (rare) direct-run case depends on it.
#
# Requires: gsutil/gcloud authed with object-create on gs://$GCS_BUCKET, and a
# Developer-ID Application identity in the keychain named by $CODESIGN_ID.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"          # .../tool
PKG="$(cd "$HERE/.." && pwd)"                   # .../flutter_cef_macos
NATIVE="$PKG/native"
REPO="$(cd "$PKG/../.." && pwd)"                # repo root (git provenance)

: "${CODESIGN_ID:?CODESIGN_ID (Developer ID Application identity) must be set}"
GCS_BUCKET="${GCS_BUCKET:-flutterflow-downloads}"
GCS_PREFIX="${GCS_PREFIX:-campus_prebuilt_cef_host}"
arch=arm64
FILE="cef_host-macos-${arch}.tar.gz"

# shellcheck source=cef_host_hash.sh
. "$HERE/cef_host_hash.sh"
HASH="$(cef_host_input_hash "$NATIVE")"
echo "[publish] cef_host input hash: $HASH"

DST="gs://$GCS_BUCKET/$GCS_PREFIX/$HASH/$FILE"

# Idempotency: this exact tree was already built + uploaded -> nothing to do.
if gsutil -q stat "$DST" 2>/dev/null; then
  echo "[publish] $DST already exists — nothing to do."
  exit 0
fi

# --- Build the sandboxed, Developer-ID-signed variant ---
OUT="$(mktemp -d)/out"
mkdir -p "$OUT"
CEF_HOST_ADHOC=OFF CODESIGN_ID="$CODESIGN_ID" bash "$NATIVE/build_cef_host.sh" "$OUT"
APP="$OUT/cef_host.app"
[ -d "$APP" ] || { echo "::error:: cef_host.app not produced by build" >&2; exit 1; }

# Fail-fast: it must be Developer-ID signed and NOT ad-hoc. Capture the output
# (|| true) and string-match rather than piping into grep under `set -o pipefail`
# — codesign -dvv can exit non-zero on a perfectly valid signature, which would
# false-fail a `codesign … | grep` pipeline.
sig="$(codesign -dvv "$APP" 2>&1 || true)"
case "$sig" in
  *"Developer ID Application"*) : ;;
  *) echo "::error:: cef_host.app is not Developer-ID signed (ad-hoc?):" >&2
     printf '%s\n' "$sig" | head -3 >&2
     exit 1 ;;
esac

# --- Provenance stamps beside the app (informational; the URL is the hash) ---
SRC_SHA="$(git -C "$REPO" rev-parse HEAD)"
CEF_VER="$(grep '^CEF_VERSION=' "$NATIVE/build_cef_host.sh" | head -1 | cut -d'"' -f2)"
printf '%s\n' "$SRC_SHA" > "$OUT/cef_host_source_sha.txt"
printf '%s\n' "$CEF_VER" > "$OUT/cef_version.txt"
printf '%s\n' "$HASH"    > "$OUT/cef_host_input_hash.txt"

# --- Tar + sha256 (COPYFILE_DISABLE keeps ._* AppleDouble junk out of the tar) ---
STAGE="$(mktemp -d)"
TARBALL="$STAGE/$FILE"
COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$OUT" \
  cef_host.app cef_host_source_sha.txt cef_version.txt cef_host_input_hash.txt
if command -v shasum >/dev/null 2>&1; then
  TAR_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
else
  TAR_SHA="$(sha256sum "$TARBALL" | awk '{print $1}')"
fi
printf '%s  %s\n' "$TAR_SHA" "$FILE" > "$TARBALL.sha256"

# --- Upload (re-check to close a publish race; objects are immutable) ---
if gsutil -q stat "$DST" 2>/dev/null; then
  echo "[publish] $DST appeared during build — skipping upload."
  exit 0
fi
gsutil -h "Cache-Control:public,max-age=31536000,immutable" cp "$TARBALL"        "$DST"
gsutil -h "Cache-Control:public,max-age=31536000,immutable" cp "$TARBALL.sha256" "$DST.sha256"
echo "[publish] uploaded $DST (tarball sha256 $TAR_SHA)"
