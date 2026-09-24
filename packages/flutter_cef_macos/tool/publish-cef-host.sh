#!/usr/bin/env bash
# Build the SANDBOXED (CEF_HOST_ADHOC=OFF, Developer-ID) cef_host, key it by a
# content hash of the build inputs, and idempotently publish it as a GitHub
# Release on the plugin's own (public) repo: tag `cef-host-<hash>`, pointed at
# the publishing commit for provenance, assets = the tarball + its .sha256.
# Consumers fetch it anonymously at `pod install` (fetch_cef_host.sh).
#
# The SANDBOXED variant is deliberate: the ad-hoc variant (get-task-allow + mock
# keychain + Mach-port bypass) fails to render agent_ui in a consuming app. The
# Developer-ID signature is inside-out; release consumers re-sign it with their
# own identity, so only the (rare) direct-run case depends on it.
#
# Requires: `gh` authenticated with push on $FLUTTER_CEF_RELEASE_REPO, and a
# Developer-ID Application identity in the keychain named by $CODESIGN_ID.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"          # .../tool
PKG="$(cd "$HERE/.." && pwd)"                   # .../flutter_cef_macos
NATIVE="$PKG/native"
REPO="$(cd "$PKG/../.." && pwd)"                # repo root (git provenance)

: "${CODESIGN_ID:?CODESIGN_ID (Developer ID Application identity) must be set}"
GH_REPO="${FLUTTER_CEF_RELEASE_REPO:-FlutterFlow/flutter_cef}"
command -v gh >/dev/null 2>&1 || { echo "::error:: gh (GitHub CLI) not found" >&2; exit 1; }
arch=arm64
FILE="cef_host-macos-${arch}.tar.gz"

if [ -n "${FLUTTER_CEF_STOCK_FRAMEWORK:-}" ]; then
  echo "::error:: FLUTTER_CEF_STOCK_FRAMEWORK is set; a published host must carry the pinned framework variant" >&2
  exit 1
fi

# The hash covers every file under native/cef_host, and the release is tagged at
# HEAD, so an untracked, ignored or modified input would publish bytes no commit
# holds under a hash consumers can't reproduce. Only the build outputs may differ.
dirty="$(git -C "$REPO" status --porcelain --ignored --untracked-files=all -- \
  "$NATIVE/build_cef_host.sh" "$NATIVE/build-cef-from-source.sh" "$NATIVE/patches" \
  "$NATIVE/cef_host" ":(exclude)$NATIVE/cef_host/build" ":(exclude)$NATIVE/cef_host/prebuilt")"
if [ -n "$dirty" ]; then
  echo "::error:: cef_host inputs differ from HEAD; commit or remove them first:" >&2
  printf '%s\n' "$dirty" >&2
  exit 1
fi

# shellcheck source=cef_host_hash.sh
. "$HERE/cef_host_hash.sh"
HASH="$(cef_host_input_hash "$NATIVE")"
echo "[publish] cef_host input hash: $HASH"

TAG="cef-host-$HASH"
DST="$GH_REPO release $TAG"
release_exists() { gh release view "$TAG" -R "$GH_REPO" >/dev/null 2>&1; }

# Idempotency: this exact tree was already built + uploaded -> nothing to do — but VERIFY the
# remote asset first. The keys are content hashes of PUBLIC sources, so anyone with repo write
# could pre-plant a malicious release for a future commit and this skip would then permanently
# suppress the legitimate upload. Verifying the remote's Developer-ID signature (same gate the
# fetch applies) makes a planted asset loud instead of load-bearing.
if release_exists; then
  echo "[publish] $DST already exists — verifying the remote artifact's signature…"
  CHECK="$(mktemp -d)"
  gh release download "$TAG" -R "$GH_REPO" -p "$FILE" -D "$CHECK"
  tar -xzf "$CHECK/$FILE" -C "$CHECK"
  TEAM="${FLUTTER_CEF_TEAM_ID:-KLAJ5X6PJP}"
  if codesign --verify --deep --strict \
      -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" \
      "$CHECK/cef_host.app" 2>/dev/null; then
    echo "[publish] remote artifact signature ok (team $TEAM) — nothing to do."
    rm -rf "$CHECK"
    exit 0
  fi
  echo "::error:: remote $DST FAILED signature verification (team $TEAM) — possible planted/corrupt object." >&2
  echo "::error:: refusing to skip; investigate + delete the release, then re-run to publish a clean build." >&2
  rm -rf "$CHECK"
  exit 1
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

# Every Mach-O must carry a secure timestamp, or notarizing an app that embeds
# this host as-is fails.
untimed=""
while IFS= read -r -d '' f; do
  kind="$(file -b "$f")"
  case "$kind" in *Mach-O*) : ;; *) continue ;; esac
  info="$(codesign -dvv "$f" 2>&1 || true)"
  case "$info" in *"Timestamp="*) : ;; *) untimed+="  $f"$'\n' ;; esac
done < <(find "$APP" -type f -print0)
if [ -n "$untimed" ]; then
  echo "::error:: Mach-O files without a secure timestamp:" >&2
  printf '%s' "$untimed" >&2
  exit 1
fi

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

# --- Upload (re-check to close a publish race; a hash's release is never edited) ---
if release_exists; then
  echo "[publish] $DST appeared during build — skipping upload."
  exit 0
fi
NOTES="$(printf 'Prebuilt, Developer-ID-signed cef_host.app (macOS %s) for native/cef_host input hash `%s`.\n\nSource: %s\nCEF: %s\n\nFetched at `pod install` by fetch_cef_host.sh — not a plugin release.' \
  "$arch" "$HASH" "$SRC_SHA" "$CEF_VER")"
gh release create "$TAG" -R "$GH_REPO" --target "$SRC_SHA" \
  --title "cef_host prebuilt $HASH" --notes "$NOTES" \
  "$TARBALL" "$TARBALL.sha256"
echo "[publish] uploaded $DST (tarball sha256 $TAR_SHA)"
