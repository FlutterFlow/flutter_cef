## Unreleased

* Document-start scripts and create-time JS channels, sent in the browser's
  `extra_info` and installed by the renderer in `OnContextCreated`.
* `hostGroup`: ephemeral sessions in one group share a `cef_host`.
* Protocol v8 (`opSetDocumentStart` 0x41).
* `FLUTTER_CEF_REQUIRE_PREBUILT=1` makes the prebuilt fetch and embed fail
  closed. A prebuilt whose hash doesn't match the sources is removed, not
  embedded.
* `cef_host.app` bundles only the `CEF_HOST_LOCALES` (default `en`) locale paks.
* Fix: a `cef_host` that exits before connecting is reported. Its sessions got
  no `processGone` and stayed blank, and disposing them waited 2 s on a reader
  thread stuck in `accept()`.
* A host that dies before `opReady` is reported as `createFailed`, not
  `crashed` (exit code 2 is still `locked`).
* Fix: a view hidden right after `create()` kept painting. `cef_host` drops an
  `opSetVisible` sent before the browser's slot exists, and on a cold host the
  hide always went out first (control frames flush at connect, creates at
  `opReady`). The session now re-sends the hide on `opCreated`, and resyncs its
  hidden state there, so a thawed browser that should show is no longer treated
  as hidden.
* Fix: `setVisible` never replied, so awaiting
  `CefWebController.setVisible` hung forever.

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
