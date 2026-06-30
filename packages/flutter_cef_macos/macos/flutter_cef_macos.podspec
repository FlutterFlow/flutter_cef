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

  # Auto-embed cef_host.app into the consuming app's Contents/Frameworks. cef_host.app is a
  # nested SIGNED app (Chromium + 5 helper apps) — CocoaPods can't auto-embed a nested .app the
  # way it does a .framework (resource_bundles would nest it inside this pod's framework and break
  # its seal; vendored_frameworks only embeds .framework). So we copy it ourselves in an
  # :after_compile script phase, which runs DURING `flutter build macos` AFTER the app bundle +
  # `[CP] Embed Pods Frameworks` exist and BEFORE Xcode's codesign — the moment the destination
  # Contents/Frameworks is real (the old "a pod script-phase runs before the app bundle exists"
  # was only true for :before_compile). ditto (never cp -R) preserves the prebuilt's inside-out
  # signatures. The prebuilt is fetched at `pod install` by prepare_command (see fetch_cef_host.sh)
  # into native/cef_host/prebuilt/. When absent (co-dev from-source, or FLUTTER_CEF_HOST set) this
  # is a clean no-op — the runtime resolver falls back to FLUTTER_CEF_HOST / a make-built host.
  s.script_phase = {
    :name => 'Embed cef_host.app',
    :execution_position => :after_compile,
    :script => <<-SCRIPT
set -e
PREBUILT="${PODS_TARGET_SRCROOT}/../native/cef_host/prebuilt/cef_host.app"
DEST_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
echo "[flutter_cef] embed: PODS_TARGET_SRCROOT=${PODS_TARGET_SRCROOT}"
echo "[flutter_cef] embed: prebuilt=${PREBUILT}"
echo "[flutter_cef] embed: dest=${DEST_DIR}/cef_host.app"
if [ -d "${PREBUILT}" ]; then
  mkdir -p "${DEST_DIR}"
  rm -rf "${DEST_DIR}/cef_host.app"
  ditto "${PREBUILT}" "${DEST_DIR}/cef_host.app"
  echo "[flutter_cef] embedded cef_host.app into Contents/Frameworks"
else
  echo "[flutter_cef] no prebuilt cef_host.app; skipping (co-dev from-source / FLUTTER_CEF_HOST path)"
fi
SCRIPT
  }
end
