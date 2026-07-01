# flutter_cef — developer convenience targets.
#
# publish-cef-host: build the SANDBOXED (CEF_HOST_ADHOC=OFF), Developer-ID cef_host
# and publish it to GCS keyed by a content hash of the build inputs. Run this when
# native/cef_host/ or the CEF version changes so consumers can fetch a matching host
# (fetch_cef_host.sh) instead of building from source. Idempotent — re-running with
# an unchanged host is a no-op. Needs a Developer ID Application identity in your
# keychain and gsutil write on gs://flutterflow-downloads (auto-resolves the
# identity; override CODESIGN_ID / GCS_PREFIX to customize).
#
#   make publish-cef-host
#   GCS_PREFIX=campus_prebuilt_cef_host-staging make publish-cef-host   # dry-run to staging

CODESIGN_ID ?= $(shell security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $$2}')

.PHONY: publish-cef-host
publish-cef-host:
	@test -n "$(CODESIGN_ID)" || { echo "error: no 'Developer ID Application' identity in the keychain"; exit 1; }
	@command -v gsutil >/dev/null 2>&1 || { echo "error: gsutil not found (install the Google Cloud SDK)"; exit 1; }
	CODESIGN_ID="$(CODESIGN_ID)" bash packages/flutter_cef_macos/tool/publish-cef-host.sh
