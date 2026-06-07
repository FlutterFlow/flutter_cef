#
# flutter_cef — macOS plugin. Compiles only the Swift host (FlutterCefPlugin +
# CefWebSession). CEF itself is NOT linked here: it lives inside cef_host.app, a
# separate subprocess this plugin spawns and talks to over a Unix socket. Build
# that with native/build_cef_host.sh; see the README for bundling/signing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_cef'
  s.version          = '0.0.1'
  s.summary          = 'Live Chromium (CEF) browser as a Flutter Texture (macOS).'
  s.description      = <<-DESC
Embed a live Chromium browser via CEF off-screen rendering, shown as a Flutter
Texture so it composites, transforms, and clips like any widget and keeps
rendering when off-screen. macOS only.
                       DESC
  s.homepage         = 'https://github.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'flutter_cef contributors' => '' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '11.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
  s.resource_bundles = {'flutter_cef_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
