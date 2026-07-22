#!/usr/bin/env bash
# Build a PATCHED CEF binary distribution from source (macOS arm64), carrying the
# Campus WebAuthn keychain-access-group patch so cef_host can use the on-device
# platform authenticator (Touch ID / Secure Enclave) for passkeys.
#
# WHY: OSR/Alloy-style windowless browsers can't host WebAuthn UI, so the sign-in
# ceremony runs in a windowed Chrome-runtime browser. On-device Touch ID there is
# gated by the keychain-access-group Chromium names
# "<team>.org.chromium.Chromium.webauthn" -- but UNBRANDED CEF leaves the team
# prefix EMPTY (".org.chromium.Chromium.webauthn"), which no valid entitlement can
# match. The prebuilt CEF exposes no API/switch for it, so the only fix is a
# from-source rebuild with native/patches/campus_webauthn_keychain.patch.
# Full write-up: work_canvas specs/cef-passkey/PLAN.md.
#
# This is Tier-2 (build libcef from source), NOT a Chromium fork -- fold it into
# the same from-source build you stand up for proprietary codecs.
#
# Usage:  DOWNLOAD_DIR=/Volumes/CEFBuild/cef_src/chromium_git ./build-cef-from-source.sh
# Output: $DOWNLOAD_DIR/chromium/src/cef/binary_distrib/cef_binary_<ver>_macosarm64_minimal
#         -> point build_cef_host.sh at it via FLUTTER_CEF_CACHE (see bottom).
#
# Requirements (learned the hard way):
#  - FULL Xcode (not just CLT). Xcode 26 split out the Metal toolchain: run
#      xcodebuild -downloadComponent MetalToolchain
#    once, or ANGLE shader compilation fails ("missing Metal Toolchain").
#  - ~150 GB free on a CASE-SENSITIVE volume (Chromium checkout can hit case
#    collisions on case-insensitive APFS). 32 GB+ RAM.
#  - Network access to chromium.googlesource.com (first checkout ~70 GB).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Pinned to match the prebuilt cef_host wrapper's CEF API (keep in lockstep with
# native/build_cef_host.sh CEF_VERSION).
CEF_VERSION="144.0.27+g3fae261+chromium-144.0.7559.254"
CEF_COMMIT="3fae261"          # exact CEF commit (= g3fae261 in the version)
CEF_BRANCH="7559"             # Chromium branch base position (= 144.0.7559.x)
CEF_NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"

DOWNLOAD_DIR="${DOWNLOAD_DIR:?set DOWNLOAD_DIR to a case-sensitive path with ~150GB free}"
SRC="$DOWNLOAD_DIR/chromium/src"
AUTOMATE="$DOWNLOAD_DIR/../automate/automate-git.py"
PATCH="$HERE/patches/campus_webauthn_keychain.patch"

[ -f "$PATCH" ] || { echo "missing patch: $PATCH" >&2; exit 1; }

# 0. Bootstrap automate-git.py if absent.
if [ ! -f "$AUTOMATE" ]; then
  echo "[cef-src] fetching automate-git.py"
  mkdir -p "$(dirname "$AUTOMATE")"
  curl -fsSL \
    "https://raw.githubusercontent.com/chromiumembedded/cef/master/tools/automate/automate-git.py" \
    -o "$AUTOMATE"
fi

# 1. Checkout Chromium + CEF at the exact pinned revs, apply CEF's stock patches,
#    but DO NOT build yet (so we can inject our patch first).
echo "[cef-src] checkout (Chromium ${CEF_VERSION}) -- first run downloads ~70GB"
python3 "$AUTOMATE" \
  --download-dir="$DOWNLOAD_DIR" \
  --branch="$CEF_BRANCH" --checkout="$CEF_COMMIT" \
  --arm64-build --no-build --no-distrib

# 2. Apply the Campus keychain patch to the Chromium tree (idempotent).
#    (Also registered condition-gated in cef/patch/patch.cfg for CEF-native
#    full-patch-cycle builds; here we apply directly for reliability.)
if git -C "$SRC" apply --check --reverse "$PATCH" 2>/dev/null; then
  echo "[cef-src] keychain patch already applied"
else
  echo "[cef-src] applying keychain patch"
  git -C "$SRC" apply "$PATCH"
fi

# 3. Build RELEASE arm64 with is_official_build=true. This flag is load-bearing
#    THREE ways, do NOT downgrade it to a bare dcheck_always_on=false build:
#    (a) it matches exactly how the stock Spotify prebuilt framework is built;
#    (b) it strips DCHECKs -- a plain from-source build enables them and CRASHES
#        on startup at chrome_paths_mac.mm (Chrome's framework-layout DCHECK is
#        incompatible with CEF's Versions/A layout);
#    (c) it FIXES Google-account caBLE/QR passkey sign-in. A non-official build
#        breaks it ("Something went wrong" after the email step, post-passkey);
#        the official build completes the flow (reaches Google's passkey
#        enrollment page). NB: the -67030 process_requirement log line is a
#        BENIGN red herring -- present in the working build too; don't chase it.
#    proprietary_codecs + ffmpeg_branding="Chrome" add H.264/AAC. These are
#    ROYALTY-BEARING (MPEG-LA / Via-LA) -- gate *distribution* (prod release-tag)
#    on legal sign-off. See work_canvas specs/cef-passkey/PLAN.md.
echo "[cef-src] build (Release arm64, official + H.264/AAC) -- multi-hour first compile"
GN_DEFINES='is_official_build=true proprietary_codecs=true ffmpeg_branding="Chrome"' \
  python3 "$AUTOMATE" \
  --download-dir="$DOWNLOAD_DIR" \
  --branch="$CEF_BRANCH" --checkout="$CEF_COMMIT" \
  --arm64-build --no-debug-build \
  --no-update --force-build --no-distrib

# 4. Package the minimal distrib. --no-symbols is REQUIRED: --no-debug-build means
#    no .dSYM, and the default make_distrib dies packaging symbols. --no-format
#    avoids a clang-format dependency.
echo "[cef-src] make_distrib (minimal, no symbols)"
python3 "$SRC/cef/tools/make_distrib.py" \
  --output-dir="$SRC/cef/binary_distrib" \
  --ninja-build --arm64-build --minimal --no-symbols --no-format --no-docs

DIST="$SRC/cef/binary_distrib/$CEF_NAME"
echo "[cef-src] DONE -> $DIST"
echo
echo "Verify the patch made it into the framework:"
echo "  strings -a '$DIST/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework' | grep KLAJ5X6PJP.org.chromium.Chromium.webauthn"
echo
echo "Build cef_host against it (drop-in for the Spotify prebuilt):"
echo "  mkdir -p /tmp/cef_cache && ln -sfn '$DIST' /tmp/cef_cache/$CEF_NAME"
echo "  FLUTTER_CEF_CACHE=/tmp/cef_cache CEF_HOST_ADHOC=OFF \\"
echo "    CODESIGN_ID='Developer ID Application: FlutterFlow, Inc. (KLAJ5X6PJP)' \\"
echo "    '$HERE/build_cef_host.sh'"
echo
echo "cef_host then needs (see specs/cef-passkey/PLAN.md): the keychain-access-group"
echo "entitlement on the BROWSER process only + an embedded Developer-ID"
echo "provisioning profile authorizing that group. Release Campus.app is already"
echo "signed+notarized, so the validation-category condition is satisfied there."
