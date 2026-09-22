# flutter_cef — developer convenience targets.
#
# publish-cef-host: build the SANDBOXED (CEF_HOST_ADHOC=OFF), Developer-ID cef_host
# and publish it as a GitHub Release on FlutterFlow/flutter_cef (tag cef-host-<hash>,
# keyed by a content hash of the build inputs). Run this when native/cef_host/ or
# the CEF version changes so consumers can fetch a matching host (fetch_cef_host.sh)
# instead of building from source. Idempotent — re-running with an unchanged host
# is a no-op. Needs a Developer ID Application identity in your keychain and `gh`
# authenticated with push on the repo (auto-resolves the identity; override
# CODESIGN_ID / FLUTTER_CEF_RELEASE_REPO to customize).
#
#   make publish-cef-host
#   FLUTTER_CEF_RELEASE_REPO=you/flutter_cef make publish-cef-host   # dry-run to a fork

CODESIGN_ID ?= $(shell security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $$2}')

.PHONY: publish-cef-host
publish-cef-host:
	@test -n "$(CODESIGN_ID)" || { echo "error: no 'Developer ID Application' identity in the keychain"; exit 1; }
	@command -v gh >/dev/null 2>&1 || { echo "error: gh not found (brew install gh && gh auth login)"; exit 1; }
	CODESIGN_ID="$(CODESIGN_ID)" bash packages/flutter_cef_macos/tool/publish-cef-host.sh
