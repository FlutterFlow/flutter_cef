## 0.1.3

* Initial release of the federated macOS implementation of `flutter_cef` (the
  Swift host plugin + the `cef_host` subprocess). Split out of the `flutter_cef`
  package; no API change for app-facing consumers. Carries the navigation scheme
  allowlist, the host-trusted-load exemption, and the `CEF_HOST_ADHOC` build
  flag (signed-release sandbox + real Keychain + release entitlements).
