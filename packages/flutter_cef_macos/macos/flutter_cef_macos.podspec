#
# flutter_cef — macOS plugin. Compiles only the Swift host (FlutterCefPlugin +
# CefWebSession). CEF itself is NOT linked here: it lives inside cef_host.app, a
# separate subprocess this plugin spawns and talks to over a Unix socket. Build
# that with native/build_cef_host.sh; see the README for bundling/signing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_cef_macos'
  s.version          = '0.2.0'
  s.summary          = 'Live Chromium (CEF) browser as a Flutter Texture (macOS).'
  s.description      = <<-DESC
Embed a live Chromium browser via CEF off-screen rendering, shown as a Flutter
Texture so it composites, transforms, and clips like any widget and keeps
rendering when off-screen. macOS only.
                       DESC
  s.homepage         = 'https://github.com/FlutterFlow/flutter_cef'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'flutter_cef contributors' => '' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  # The Swift bridge itself is 10.15-clean; live rendering needs macOS 12+ at
  # runtime (CEF 144), gated by cef_host.app's own LSMinimumSystemVersion.
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
  s.resource_bundles = {'flutter_cef_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  # Fetch the prebuilt cef_host.app keyed by the content hash of native/cef_host at `pod install`
  # (a GitHub Release on the plugin repo; SHA-256 + Developer-ID-verified) into
  # native/cef_host/prebuilt/. Fail-open + cached for development; FLUTTER_CEF_FROM_SOURCE=1 skips
  # it for co-dev, and FLUTTER_CEF_REQUIRE_PREBUILT=1 (release builds) makes every miss an error.
  # The :after_compile phase below embeds it, so `flutter pub get` + `flutter build macos` is
  # turnkey with no make/host steps.
  s.prepare_command = 'bash ../tool/fetch_cef_host.sh'

  # Auto-embed cef_host.app into the consuming app's Contents/Frameworks. cef_host.app is a
  # nested SIGNED app (Chromium + 5 helper apps) — CocoaPods can't auto-embed a nested .app the
  # way it does a .framework (resource_bundles would nest it inside this pod's framework and break
  # its seal; vendored_frameworks only embeds .framework). So we copy it ourselves in an
  # :after_compile script phase, which runs DURING `flutter build macos` AFTER the app bundle +
  # `[CP] Embed Pods Frameworks` exist and BEFORE Xcode's codesign — the moment the destination
  # Contents/Frameworks is real (the old "a pod script-phase runs before the app bundle exists"
  # was only true for :before_compile). ditto (never cp -R) preserves the prebuilt's inside-out
  # signatures. The prebuilt is fetched at `pod install` by prepare_command (see fetch_cef_host.sh)
  # into native/cef_host/prebuilt/. Only a prebuilt built from THESE sources (its stamped input hash
  # matches) is embedded: a stale one would speak an older wire protocol. When absent (co-dev
  # from-source, or FLUTTER_CEF_HOST set) this is a clean no-op — the runtime resolver falls back to
  # FLUTTER_CEF_HOST / a make-built host — unless FLUTTER_CEF_REQUIRE_PREBUILT is set, which fails
  # the build rather than ship an app with no (or a mismatched) cef_host.
  s.script_phase = {
    :name => 'Embed cef_host.app',
    :execution_position => :after_compile,
    :shell_path => '/bin/bash',
    :script => <<-SCRIPT
set -e
NATIVE="${PODS_TARGET_SRCROOT}/../native"
PREBUILT="${NATIVE}/cef_host/prebuilt/cef_host.app"
DEST_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
echo "[flutter_cef] embed: PODS_TARGET_SRCROOT=${PODS_TARGET_SRCROOT}"
echo "[flutter_cef] embed: prebuilt=${PREBUILT}"
echo "[flutter_cef] embed: dest=${DEST_DIR}/cef_host.app"
refuse() {
  if [ -n "${FLUTTER_CEF_REQUIRE_PREBUILT:-}" ]; then
    echo "error: [flutter_cef] $1 — FLUTTER_CEF_REQUIRE_PREBUILT is set, refusing to build an app without a matching cef_host. Publish it (make publish-cef-host in flutter_cef) and re-run pod install."
    exit 1
  fi
  echo "[flutter_cef] $1; skipping (co-dev from-source / FLUTTER_CEF_HOST path)"
  rm -rf "${DEST_DIR}/cef_host.app"
  exit 0
}
[ -d "${PREBUILT}" ] || refuse "no prebuilt cef_host.app"
. "${PODS_TARGET_SRCROOT}/../tool/cef_host_hash.sh"
WANT="$(cef_host_input_hash "${NATIVE}")"
HAVE="$(cat "${NATIVE}/cef_host/prebuilt/cef_host_input_hash.txt" 2>/dev/null || true)"
[ "${HAVE}" = "${WANT}" ] || refuse "prebuilt cef_host.app is for input hash '${HAVE}', these sources are '${WANT}'"
mkdir -p "${DEST_DIR}"
rm -rf "${DEST_DIR}/cef_host.app"
ditto "${PREBUILT}" "${DEST_DIR}/cef_host.app"
echo "[flutter_cef] embedded cef_host.app (${WANT}) into Contents/Frameworks"
SCRIPT
  }
end
