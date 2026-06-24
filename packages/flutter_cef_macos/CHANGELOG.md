## 0.2.0

* Persistent + shared named profiles (`profile:`): one `cef_host` process with one
  cookie jar per profile; ephemeral remains the default.
* Multi-view shared host: many sessions multiplex over one `cef_host` via a
  per-browser wire id; channel registration buffers until the browser attaches, so
  a page→host JS channel works on a shared host regardless of call/attach order.
* Agent control (`enableAgentControl`): a token-gated, loopback-only, per-tile-scoped
  CDP relay with a deny-by-default / fail-closed Target-domain filter.
* Reliability: EINTR-resilient pipe IO, CDP relay + pending-waiter cleanup on host
  death, and off-reader-thread CDP writes so one stuck client can't starve siblings.
* Ad-hoc dev builds (`CEF_HOST_ADHOC=ON`) downgrade a named profile to ephemeral
  unless `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1`.

## 0.1.3

* Initial release of the federated macOS implementation of `flutter_cef` (the
  Swift host plugin + the `cef_host` subprocess). Split out of the `flutter_cef`
  package; no API change for app-facing consumers. Carries the navigation scheme
  allowlist, the host-trusted-load exemption, and the `CEF_HOST_ADHOC` build
  flag (signed-release sandbox + real Keychain + release entitlements).
