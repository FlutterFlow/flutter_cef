#!/usr/bin/env bash
# Bundle cef_host.app into a built host .app and code-sign it, so the app can
# spawn the renderer when not running from a dev checkout (where $FLUTTER_CEF_HOST
# points at it). Run this AFTER `flutter build macos`, or wire it into your
# Runner target as a Run Script build phase:
#
#   "$SRCROOT/path/to/flutter_cef/tool/bundle_cef_host.sh" \
#       "${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/.." \
#       "" "${EXPANDED_CODE_SIGN_IDENTITY:-}"
#
# Usage: bundle_cef_host.sh <YourApp.app> [cef_host.app] [signing-identity]
#   <YourApp.app>      the built app bundle (or its Contents/ parent)
#   [cef_host.app]     default: $FLUTTER_CEF_HOST_APP, then the plugin's
#                      native/cef_host/build/cef_host.app
#   [signing-identity] default: "-" (ad-hoc). Pass your Developer ID / Apple
#                      Development identity for a distributable build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

APP="${1:?usage: bundle_cef_host.sh <YourApp.app> [cef_host.app] [identity]}"
HOST_APP="${2:-${FLUTTER_CEF_HOST_APP:-$HERE/../native/cef_host/build/cef_host.app}}"
IDENTITY="${3:-${EXPANDED_CODE_SIGN_IDENTITY:-}}"
[ -z "$IDENTITY" ] && IDENTITY="-"
ENT="$HERE/../native/cef_host/entitlements.plist"

[ -d "$APP" ] || { echo "no such app bundle: $APP" >&2; exit 1; }
[ -d "$HOST_APP" ] || {
  echo "cef_host.app not found at $HOST_APP — run native/build_cef_host.sh first" >&2
  exit 1
}

DEST="$APP/Contents/Frameworks/cef_host.app"
echo "[flutter_cef] bundling $HOST_APP -> $DEST (identity: $IDENTITY)"
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$DEST"
cp -R "$HOST_APP" "$DEST"

# Sign inside-out with one identity so library validation passes (no need for
# the disable-library-validation entitlement when everything shares an identity).
codesign --force --sign "$IDENTITY" \
  "$DEST/Contents/Frameworks/Chromium Embedded Framework.framework"
if [ -f "$ENT" ]; then
  codesign --force --sign "$IDENTITY" --entitlements "$ENT" "$DEST"
else
  codesign --force --sign "$IDENTITY" "$DEST"
fi
echo "[flutter_cef] done. Remember the host app must NOT be sandboxed; see the README."
