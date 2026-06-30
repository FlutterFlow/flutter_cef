#!/usr/bin/env bash
# Fetch the prebuilt, version-matched cef_host.app — run at `pod install` via the podspec's
# prepare_command. Downloads + SHA256-verifies the artifact named in cef_host_prebuilt.json,
# caches it, and extracts cef_host.app into native/cef_host/prebuilt/ where the :after_compile
# script phase embeds it. Self-locating (CWD-independent). Fail-OPEN: any problem leaves no
# prebuilt, and the build falls back to FLUTTER_CEF_HOST / build-from-source.
#
# Escape hatch: FLUTTER_CEF_FROM_SOURCE=1 skips the fetch entirely (co-dev builds cef_host from
# source via native/build_cef_host.sh and points the app at it with $FLUTTER_CEF_HOST).
set -uo pipefail

if [ -n "${FLUTTER_CEF_FROM_SOURCE:-}" ]; then
  echo "[flutter_cef] FLUTTER_CEF_FROM_SOURCE set — skipping prebuilt fetch (build-from-source)"
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"   # .../flutter_cef_macos/tool
PKG="$(cd "$HERE/.." && pwd)"           # .../flutter_cef_macos
MANIFEST="$PKG/cef_host_prebuilt.json"
DEST="$PKG/native/cef_host/prebuilt"

[ -f "$MANIFEST" ] || { echo "[flutter_cef] no $MANIFEST — skipping fetch"; exit 0; }

case "$(uname -m)" in
  arm64)  arch=arm64 ;;
  x86_64) arch=x86_64 ;;
  *)      echo "[flutter_cef] unsupported arch $(uname -m) — skipping fetch"; exit 0 ;;
esac
key="macos-${arch}-dev"

# Parse the manifest with python3 (present on every macOS dev box). Prints: base file sha src ver
read -r base file sha src ver <<EOF
$(python3 - "$MANIFEST" "$key" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); art = m.get("artifacts", {}).get(sys.argv[2])
if not art:
    print("NONE NONE NONE NONE NONE")
else:
    print(m["base_url"], art["file"], art["sha256"], m.get("source_sha", ""), m.get("cef_version", ""))
PY
)
EOF

if [ "$base" = "NONE" ] || [ -z "$base" ]; then
  echo "[flutter_cef] no prebuilt for $key in manifest — skipping (build from source)"
  exit 0
fi

# Already current? (the tarball carries cef_host_source_sha.txt next to cef_host.app)
if [ -d "$DEST/cef_host.app" ] && [ -f "$DEST/cef_host_source_sha.txt" ] \
   && [ "$(cat "$DEST/cef_host_source_sha.txt" 2>/dev/null)" = "$src" ]; then
  echo "[flutter_cef] prebuilt cef_host already current ($src) — skipping fetch"
  exit 0
fi

CACHE="${FLUTTER_CEF_CACHE:-$HOME/.cache/flutter_cef}/prebuilt/$src/$arch"
mkdir -p "$CACHE"
tarball="$CACHE/$file"

if [ ! -f "$tarball" ] || [ "$(shasum -a 256 "$tarball" 2>/dev/null | awk '{print $1}')" != "$sha" ]; then
  echo "[flutter_cef] downloading prebuilt cef_host ($key, cef $ver)…"
  if ! curl -fL --retry 3 "$base/$file" -o "$tarball.part"; then
    echo "[flutter_cef] download failed — leaving no prebuilt (FLUTTER_CEF_HOST / from-source will be used)" >&2
    rm -f "$tarball.part"; exit 0
  fi
  got="$(shasum -a 256 "$tarball.part" | awk '{print $1}')"
  if [ "$got" != "$sha" ]; then
    echo "[flutter_cef] SHA256 mismatch (got $got, want $sha) — refusing the artifact" >&2
    rm -f "$tarball.part"; exit 1
  fi
  mv "$tarball.part" "$tarball"
fi

echo "[flutter_cef] extracting prebuilt cef_host -> $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/cef_host.app"
tar -xzf "$tarball" -C "$DEST"
echo "[flutter_cef] prebuilt cef_host ready ($src)"
