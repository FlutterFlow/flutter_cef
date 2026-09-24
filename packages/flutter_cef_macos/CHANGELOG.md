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
* Protocol v10: `opBrowserGone` (0x42, upstream, utf8 reason) ends one
  browser's session; the plugin sends `processGone(reason)` and disposes it.
  The prebuilt must be republished.
* A renderer crash loop ends only its browser (`opBrowserGone "crashed"`);
  `cef_host` shuts down only when two browsers crash-loop within 10 s.
* The liveness ping (eval id `UInt32.max`) is a renderer process message
  (`renderer_messages.h`) answered by the renderer, not page JS. An unanswered
  ping ends that browser, not the host. A replaced GPU process is detected by
  pid, not by start time against the wall clock.
* Eval replies are `eval:<id>:<nonce>:<json>`; an id not in flight or a wrong
  nonce is refused.
* `SendFrame` drops a frame over the plugin's 64 MiB limit instead of sending
  it. Channel messages and eval results over 16 MiB are refused; console,
  dialog and context-menu strings are cut at 1 MiB.
* Shutdown closes every browser (tiles, popups, auth windows) and quits the
  loop after the last `OnBeforeClose` or a 2 s grace. A watchdog thread
  `_exit`s 6 s after shutdown starts, 30 s once `CefShutdown` runs.
* Popups are tracked by the tile that opened them and closed with it.
  `PopupClient::DoClose` takes the view out of its window, so a popup closed
  by `window.close()` finishes closing. `FLUTTER_CEF_SPIKE_AUTH_URL` is gone;
  `opOpenAuthWindow` windows are held to the scheme allowlist and a gesture.
* Startup: no `--ipc` or a failed connect exits 1; failing to open the
  profile lock logs `profile-lock-failed` and exits 3.
* IPC values are checked: view sides 1–16384, finite dpr and zoom, enum
  ranges. A navigate for a browser still being created is applied in
  `OnAfterCreated`, not at first paint.
* The plugin refuses to join a running host whose scheme allowlist is wider,
  or that has TCP CDP the view didn't ask for (`host_config_mismatch`), and
  reserves `~`-prefixed profile names. Host callbacks are installed once,
  before spawn.
* Agent control: `enableAgentControl` re-checks the session after its async
  setup, so a dispose in between no longer leaks a relay. CDP pipe ids come
  from one per-host allocator that stays within int32, and a relay forgets its
  id mappings when a new client connects.
* Tests: `test/run_host_config_tests.sh`, and `test/run_host_lifecycle_test.sh`
  (needs a built host; skips without one).

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
