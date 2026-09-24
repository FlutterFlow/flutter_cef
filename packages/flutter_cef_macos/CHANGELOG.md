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
* Fix: a view whose GPU process was replaced, or whose renderer hung, stayed
  frozen with no event. The liveness sweep now ends that host (processGone
  `crashed`): when the host's GPU process started after its first frame, or
  when a visible browser that stopped painting leaves a JS ping (eval id
  `UInt32.max`, consumed by the plugin) unanswered for 15 s.
* The hang ping skips a browser with a JS dialog open, one whose DevTools were
  opened, and every browser of a host started with CDP or agent control: each
  can be paused without being hung.
* Fix: reopening a named profile right after closing its last view reported
  `locked`, because the old host still held the profile lock. A host that exits
  `locked` within 10 s of this plugin shutting down that profile's previous host
  now waits for that host to exit (3 s max) and is started again.
* Fix: the startup sweep deleted other running apps' ephemeral profile dirs.
  Dirs are now named `flutter_cef_ephem_<pid>_<uuid>` and swept only once that
  pid has exited; older unnamed dirs are swept after a day untouched.
* An ephemeral profile dir is removed after its host has exited, not while the
  host may still be writing to it.
* Security: tile IOSurfaces are no longer `IOSurfaceIsGlobal`. `cef_host`
  sends each new surface as a Mach port right to the plugin's `SurfacePort`
  (bootstrap name in `--surface-port`) before the present that names it; the
  plugin accepts messages only from the spawned host's pid (audit trailer).
  Protocol v9.
* Fix: answering a JS dialog crashed `cef_host` (`DoJsDialogResp` erased
  through an iterator `Continue()` had invalidated via `OnResetDialogState`).
* Security: the CDP relay allowlists `Target.*` on the agent's page session
  (a page session answers `Target.getTargets`/`attachToTarget` for the whole
  browser, which let an agent drive sibling tiles).
* Security: JS channels are registered per browser (`Slot::channels`), not per
  host, and `OnQuery` refuses a `ch:` message for a channel the browser didn't
  register.
* Security: a sized popup needs a user gesture, a URL `SchemeAllowed`, and fewer
  than 4 native popups open; popup windows gate their own navigations too.
* Security: a navigate parked for a not-yet-created browser no longer arms the
  `data:`/`file:` trusted-load exemption.

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
