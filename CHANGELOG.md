## Unreleased

* **Windows catches up with macOS**: `sessionStats`, `setAudioMuted`,
  `setFrameInterval` and `freeze`/`thaw` work; verbs Windows can't serve
  (context menus, camera/microphone prompts, the auth window, the emoji picker)
  throw `PlatformException('unsupported')` instead of succeeding silently. The
  Chromium sandbox is on, downloads ask where to save, tiles render without a
  GPU, and early resizes, non-ASCII profile paths, locked profiles and hung
  hosts are handled. See `packages/flutter_cef_windows/CHANGELOG.md`.
* **Document-start scripts**: `CefWebController(documentStartScripts: [...])`
  runs each script in every main-frame document before the page's own scripts
  (also after a cross-site navigation). A script that throws is reported to the
  console, and the scripts after it still run.
* **Create-time JS channels**: channels added with `addJavaScriptChannel` before
  create are available to the page's first `<head>` script. Before this, they
  arrived on load start and raced the page.
* **Host groups**: `CefWebController(hostGroup: 'name')` puts ephemeral sessions
  on one shared `cef_host` process, which exits with the group's last session.
  Use it for several short-lived views of one app, such as editors.
* **`onCreateFailed`**: `CefWebView` stops retrying a failed create. The failure
  goes to `CefWebController.onCreateFailed`, which is also called on a
  `createFailed` or `protocolMismatch` `processGone`, so a consumer can fall back
  to another web view.
* **A `cef_host` that exits before it's ready is reported**: sessions get
  `onProcessGone('createFailed')` and `onCreateFailed`, so a consumer falls back
  instead of showing a blank view. On macOS, a host that exited before
  connecting used to go unreported.
* **A view hidden right after `create()` stays hidden**: a `setVisible(false)`
  that reached `cef_host` before the browser existed was dropped, so a view
  mounted out of sight kept painting (on a cold macOS host, always). The plugins
  now re-send the hide once the host reports the browser created.
* **`CefWebView(enableZoomShortcuts: false)`**: ⌘+/⌘−/⌘0 (Ctrl on Windows) then
  reach the page instead of zooming it, for a view whose CSS viewport is fixed on
  purpose, such as a device-frame preview.
* **macOS: a view that can never paint again is reported**: when the GPU
  process died (it does under memory pressure), Chromium relaunched it but the
  view stayed frozen for good with no event. A hung renderer was likewise taken
  for an idle page. The plugin now reports `onProcessGone('crashed')` and the
  consumer recreates the view the way it recovers from a crash: to every
  session on the host for a replaced GPU process, and for a hung renderer to
  that view's session alone on macOS (on Windows, to every session on its
  host). A GPU process other than the one that drew the host's first frame
  counts as a replacement; a renderer that leaves a ping unanswered for 15 s
  (`FLUTTER_CEF_HANG_MS`) while not painting counts as hung. On macOS the
  renderer answers the ping itself, so page script can't make it look hung.
  Idle static pages are left alone. Windows now has the hung renderer check,
  but not the GPU-process one.
* **The hang check leaves paused pages alone**: a page waiting on a JS dialog, or
  one that may be paused in a debugger (DevTools opened, CDP or agent control
  enabled), can't answer the ping but isn't hung, and is no longer ended as
  `crashed`.
* **macOS: one page can't take down the other views on its host**:
  * a renderer that keeps crashing ends its own view
    (`onProcessGone('crashed')`); `cef_host` exits only when several views
    crash-loop at once. One crash-looping page used to end every view on the
    host. Windows does the same.
  * page-sized data is capped: a JS-channel message or
    `runJavaScriptReturningResult` result over 16 MB is refused (the result
    fails with `result too large`), and console, dialog and context-menu text
    is cut at 1 MB. A page that logged a 64 MB string made the plugin drop the
    host.
  * a page can't answer a `runJavaScriptReturningResult` call it didn't run:
    each call's reply carries a nonce the page never sees.
* **macOS: sign-in popups close with their view**: a popup stayed open after
  the view that opened it was disposed, and one closed by its own page
  (`window.close()`) stayed on screen empty. Nested popups get their own
  window. The auth window is held to the scheme allowlist and a user gesture.
* **macOS: a `cef_host` stuck at shutdown exits**, 6 s after shutdown starts
  (30 s once CEF is tearing down), so its profile lock is released. It now
  closes every browser before shutting CEF down. A host started without
  `--ipc`, or that can't connect, exits 1; one that can't open its profile lock
  reports that and exits 3 instead of claiming the profile is `locked`.
* **macOS: a view that would join a host with weaker settings is refused**:
  `create()` and `thaw()` on a named profile or host group whose running host
  allows schemes the view didn't allow, or has a CDP port the view didn't ask
  for, fail with `host_config_mismatch` instead of running on the host's
  settings. Profile names starting with `~` are reserved (`bad_args`).
* **macOS agent control**: enabling it on a view that is disposed meanwhile no
  longer leaves a CDP listener behind; command ids stay unique on a host that
  has created many browsers; and an agent that reconnects no longer gets
  responses meant for the previous connection.
* **macOS**: `FLUTTER_CEF_DEBUG`'s Chromium log goes to a per-process file in
  the user's temp dir, not the shared `/tmp/cef_host_chromium.log`. Wire
  protocol v10.
* **macOS: a named profile reopened at once is no longer reported `locked`**:
  closing a profile's last view shuts its host down, and the next host of that
  profile could start before the old one let go of the profile's lock. The
  plugin now waits for its own previous host and starts the new one again.
* **macOS: the startup sweep keeps other apps' ephemeral profiles**: it removed
  every `flutter_cef_ephem_*` dir in `$TMPDIR`, including those of other running
  apps that use flutter_cef. Dirs now carry the owning pid and are removed only
  once that app has exited.
* **`processGone` ends the session**: `isCreated` turns false, a later
  `create()` starts a new session, and `isLoading`/`mediaState` reset. A
  throwing `onCreateFailed` no longer keeps `onProcessGone` from running, and an
  error thrown by any event callback is reported instead of breaking the channel.
* **macOS: tile surfaces are private to the app**: they were created global, so
  any local process could look a tile's IOSurface up by id and read the page
  (without Screen Recording permission). `cef_host` now hands each surface to
  the plugin by Mach port, accepted only from the host the plugin spawned.
  `CefSurfaceInfo.surfaceId` still resolves with `IOSurfaceLookup` inside the
  app's own process. Wire protocol v9: a v8 `cef_host` is refused at connect.
* **macOS: answering a JS dialog no longer crashes `cef_host`**: every
  `alert()`/`confirm()`/`prompt()` answer took down the host and every tile on
  it (`processGone('crashed')`), because `Continue()` re-entered
  `OnResetDialogState` and cleared the map being erased from. Windows already
  had this fix.
* **Agent control can't reach sibling tiles** (macOS): the relay forwarded
  every `Target.*` command sent on the agent's own page session, and a page
  session answers for the whole browser, so an agent could list the other tiles
  on its host (`Target.getTargets`), attach to one (`Target.attachToTarget`) and
  run script in it. On a page session only `setAutoAttach` (flatten),
  `detachFromTarget`, `getTargetInfo`, `activateTarget` and `closeTarget` for
  its own target now go through. Windows was not affected: it grants agent
  control only on a host with one tile.
* **JS channels are per tile**: a channel was injected into every tile's page on
  the host, and a page could post to any registered channel name through
  `window.cefQuery`. A page now gets, and can post to, only the channels its own
  controller registered.
* **macOS: sized popups are capped at 4 open at once**, and a popup is held to
  the tile's scheme allowlist, for the URL it opens and for its own
  navigations.
* **macOS: an early navigate is held to the scheme allowlist**: a `navigate()`
  that reached the host before its tile's create frame replaced the create URL
  and, for a `data:` or `file:` URL, was treated as host content and loaded
  despite the allowlist.
* **`runJavaScriptReturningResult` and `getCookies` fail at once** with a
  `StateError` when there is no session to answer (not created, disposed, gone
  or frozen), instead of never completing.
* **Windows**: `loadHtmlString(baseUrl:)` and create-with-html now serve the
  document at its http(s) origin, as macOS does. This means no `data:` URL and no
  2 MB cap. The Windows wire protocol is now v4.
* **Windows editing shortcuts go to the page first**: Ctrl+C/X/V/A/Z/Y and
  Ctrl+Shift+Z reach the page as keys, as ⌘-shortcuts already do on macOS.
  Before, `CefWebView` ran the browser's edit command in their place, so an
  editor with its own undo stack and selection (Monaco) never saw them: undo did
  nothing and select-all selected the wrong text. `cef_host` still runs the
  command when the page leaves the key unhandled.
* **macOS prebuilt**:
  * `FLUTTER_CEF_REQUIRE_PREBUILT=1` makes pod install / build fail when the
    matching prebuilt `cef_host.app` can't be fetched or embedded. Release
    pipelines should set it.
  * A stale prebuilt (one that doesn't match the sources' hash) is no longer
    embedded.
  * `cef_host.app` keeps only the English locale paks, since CEF runs en-US
    regardless of the system language. This saves about 49 MB installed and
    about 12 MB compressed. See `CEF_HOST_LOCALES`.
* **Release pipeline**:
  * The published `cef_host` is signed with a secure timestamp, so an app that
    embeds it as-is can be notarized. `publish-cef-host.sh` refuses a build
    with any Mach-O lacking one.
  * `publish-cef-host.sh` refuses to publish when a hashed input is modified,
    untracked or ignored, so a release always matches the commit it's tagged at.
  * `FLUTTER_CEF_STOCK_FRAMEWORK=1 native/build_cef_host.sh` builds against the
    stock CEF framework, for contributors without the patched from-source one.
  * CI compiles `cef_host` and the macOS plugin, and warns when no prebuilt is
    published for the sources.
* **One protocol definition**: the `cef_host` opcodes and protocol versions
  live in `tool/protocol/spec.dart`, and `tool/protocol/generate.dart` writes
  the macOS host header, the Swift constants and the Windows header from it.
  Before, four hand-kept copies had drifted: Windows still documented 0x1e as
  reserved, while macOS uses it. `test/protocol_parity_test.dart` checks the
  copies and that no opcode is defined anywhere else.
* **`CefWebController.state`**: a `ValueListenable<CefSessionState>` —
  `idle`, `creating`, `live`, `frozen`, `gone` (the host died or the browser
  never came up), `disposed` — replacing the separate disposed / frozen /
  texture flags the controller kept. `isCreated`, `isFrozen` and `textureId`
  are derived from it and read as before.
* **Fix**: a session that ended while `create()` was still waiting for its
  reply was adopted anyway, leaving the controller "created" on a texture with
  no browser, and every later `create()` returned that dead texture. `create()`
  now returns null and the controller stays `gone`.
* The controller talks to the platform through `FlutterCefPlatform`'s typed
  methods instead of ~45 raw method-channel strings; the wire calls are
  unchanged and pinned by `test/platform_wire_test.dart`.
* **`CefWebView` follows its controller**:
  * a new `controller` (or, for the view's own controller, a new `profile`) is
    adopted; it used to be ignored, and consumers re-keyed the view instead;
  * when the session ends (`onProcessGone`), the view shows its placeholder
    instead of a dead texture, and shows the new session once the host calls
    `create()` again;
  * a `url` changed while `create()` was still queued is navigated to once the
    session is up; it used to be lost;
  * a disposed controller no longer makes the view call `create()` every frame;
  * unbounded constraints (a view in a `Column`) fail with a clear message
    instead of an `UnsupportedError` every frame.
* **Input**: a cancelled press sends the page a mouse-up, so Chromium no longer
  keeps the button held (later hovers extended a selection). ⌘+ on the numpad
  zooms in. The key-up of a key taken as a zoom or find shortcut is kept from
  the page, which never saw its key-down. ⌘+/⌘− continue from a zoom set with
  `setZoomLevel`, now readable as `CefWebController.zoomLevel`.
* **Controller fixes**:
  * `thaw(html:)` serves the document at the `htmlBaseUrl` the session was
    created with (new optional `thaw(htmlBaseUrl:)`), so the page keeps its
    origin; it always became an opaque `data:` URL.
  * A controller disposed while its `create()` waits in the spawn throttle
    leaves the queue at once; each one used to take a turn and a spacing gap.
  * Disposing a controller whose `sessionId` a newer controller took over no
    longer tears down the newer one's session or drops its events.
  * `<base href>` in the `data:` fallback is no longer inserted inside a
    `<header>` element.
  * A throwing `onCreateFailed` and `onProcessGone` are each reported through
    `FlutterError.reportError`.
* **Unsupported platform calls**: a platform answers a method it doesn't
  implement with a `PlatformException` whose code is `kCefUnsupportedCode`
  (`'unsupported'`); `isCefUnsupported(error)` recognises it. `freeze()`
  returns false and `setAudioMuted` / `setFrameInterval` do nothing there;
  `sessionStats()` throws rather than answering null, which means "no such
  session".
* **A new view on a warm macOS host paints**: up to one view in five created
  while the host's first view was animating never painted, because of a race
  in Chromium's begin-frame handling. `cef_host` now avoids it (see
  `packages/flutter_cef_macos/CHANGELOG.md`).
* Docs: cookies live in the host's jar, shared per profile or host group (not
  a process-wide store), and `clearCookies` signs out every view on it.

## 0.2.0

* **Persistent, shared profiles**: `CefWebView(profile: 'name')` /
  `CefWebController(profile: 'name')` opt a view into a persistent, shared
  browser profile — cookies and storage live in a stable `0700` directory under
  Application Support (`<bundleId>/flutter_cef/profiles/<name>`,
  `persist_session_cookies` on), so a login survives `cef_host` / host-app
  relaunch. Every view with the same non-null `profile` is served by **one
  `cef_host` process and one cookie jar**, so they share one login (and
  `clearCookies` / `deleteCookie` clear it for all of them). Omitting `profile:`
  (the default) is **byte-for-byte today's behaviour** — an ephemeral, throwaway
  in-memory session. See the new "Profiles" section in the README.
* **Secrets-at-rest safety rail**: cookies only encrypt at rest under a signed
  release build (`CEF_HOST_ADHOC=OFF`, real Keychain / OSCrypt). An ad-hoc / dev
  build cannot, so a named profile is **automatically downgraded to ephemeral**
  (with a logged warning) rather than persisting a login to a plaintext store;
  set `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1` to override. The refusal happens
  before any browser is created, so it leaks no credentials.
* **CDP × profile rejection**: `enableCdp` cannot be combined with a named
  `profile` — CDP is an unauthenticated localhost port that could read the shared
  cookie jar — so the combination is rejected (a debug assert in
  `CefWebView` / `CefWebController`, and a native refusal of the create).
* **Internal: per-browser IPC dimension**. The host↔`cef_host` wire protocol
  gained a `browserId` frame field plus `opCreateBrowser` / `opDisposeBrowser`
  control ops, so one `cef_host` process can host several browsers (the shared
  profile). This is entirely below the method channel — the Dart API and the
  `create`/event arg maps are unchanged apart from the new optional `profile`
  key.
* **Agent control (drive a tile over CDP, no open port)**:
  `CefWebView(agentControl: true)` launches `cef_host` so it speaks CDP over an
  inherited pipe (Chromium `--remote-debugging-pipe`) instead of a TCP port — so
  there is **no listening debug port**, and (unlike `enableCdp`) it is permitted on
  a named `profile`. `CefWebController.enableAgentControl()` then brokers a
  token-gated **loopback** HTTP+WebSocket CDP endpoint (`{wsUrl, token, port}`) an
  external CDP client (e.g. `agent-browser`/Playwright via `--cdp <port>`) connects
  to; `disableAgentControl()` tears it down. Security model: per-tile opt-in; the
  relay exists **only while a grant is active**, binds **loopback only** on an
  **ephemeral port**, accepts a **single client**, and **requires** the token: the ws
  upgrade is rejected without a valid `Authorization: Bearer <token>` (Playwright
  forwards it via `connectOverCDP({ headers })`; a `?token=` query is a fallback),
  while discovery (`/json/*`) stays token-free so a port-scanner can't upgrade.
  Crucially the relay **confines the agent to
  that one tile**: a deny-by-default / fail-closed / flatten-only CDP Target-domain
  filter exposes only the tile's own target (sibling tiles in the same shared-profile
  process are hidden and unreachable), and browser-context-wide CDP (`Storage.*`,
  `Tracing.*`, `Browser.*` mutators, cookie methods) is refused — so an agent can
  drive the page but cannot read or clear the shared cookie jar. **Multi-view:**
  N tiles sharing one `cef_host` (one named profile) can each be agent-controlled
  concurrently — one token-gated relay per tile, each pinned to its own CDP target,
  all multiplexed over the single browser-wide `--remote-debugging-pipe`: inbound
  traffic is scoped by `sessionId`, and browser-level commands (which carry no
  `sessionId`) are disambiguated by a per-relay CDP-id rewrite, so a sibling tile's
  page can be neither observed nor driven through another tile's grant (distinct
  ephemeral port + token each). On host quit every `cef_host` is SIGTERM-reaped so
  none is left orphaned holding a profile's Chromium `SingletonLock`.

## 0.1.3

* **Federated package structure** (no API change): `flutter_cef` is now a
  federated plugin — the app-facing package plus
  `flutter_cef_platform_interface` (the shared Dart types + method-channel
  contract) and the endorsed `flutter_cef_macos` (Swift plugin + `cef_host`).
  Consumers keep depending on `flutter_cef` and importing
  `package:flutter_cef/flutter_cef.dart` exactly as before. A Windows or Linux
  implementation can now be added as a sibling `flutter_cef_<os>` package — see
  [`PORTING.md`](PORTING.md) for the contract and the platform-seam map.

## 0.1.2

* **Navigation scheme allowlist**: `CefWebView(allowedSchemes: {...})` restricts
  which URL schemes the page may navigate to — the initial load, programmatic
  `navigate()`, in-page link clicks, and redirects are all gated in the
  renderer's `OnBeforeBrowse`. `about:` is always permitted. Pass e.g.
  `{'http', 'https'}` to keep an untrusted page off `file:` / `data:` /
  `chrome:` schemes — important when a host can drive navigation
  programmatically. Default (`null`) preserves the previous allow-all behavior,
  so this is a non-breaking, opt-in addition. The host's explicit
  content-injection APIs — `loadHtmlString` (a `data:` URL) and `loadFile` (a
  `file:` URL) — are exempt from the allowlist, since the host (not the page)
  chose that content; only navigation (the page's, and `navigate()`) is gated.
* **Production hardening (build-time, `-DCEF_HOST_ADHOC=OFF`)**: a signed release
  build now enables the **Chromium renderer/GPU sandbox** (the helper calls
  `CefScopedSandboxContext` before loading the framework; `settings.no_sandbox`
  is false), drops the ad-hoc-only Mach-port peer-validation bypass + mock
  keychain (so cookies encrypt at rest via the real Keychain/OSCrypt), and signs
  with a stripped entitlements file that omits `get-task-allow`. All of this is
  off by default (`CEF_HOST_ADHOC=ON`) so dev/CI builds are byte-identical and
  run unsandboxed under ad-hoc signing; the release posture only *validates*
  under correct inside-out Developer-ID signing of the `cef_host` tree.

## 0.1.1

* **Multi-view host support**: the IME connection now carries
  `TextInputConfiguration.viewId` (as `EditableText` does). In a host that
  enables Flutter's multi-view mode the implicit view 0 does not exist, so a
  config without `viewId` bound the IME to a nil view and `show()` silently
  failed — pages received keydown/keyup but never characters. Typing, CJK
  composition, and the emoji picker now work in multi-view (multi-window) apps.
* Re-issue `TextInput.show()` on every click into an already-focused view
  (mirrors `EditableText.requestKeyboard`), so hosts that move macOS first
  responder around between clicks can't strand the IME view; also re-seeds the
  emoji/accent-picker caret anchor at the latest click.
* Trackpad scrolling inside hosts that opt into Flutter's trackpad gesture API
  (e.g. canvas apps): two-finger pans arrive as `PointerPanZoom*` events rather
  than `PointerScrollEvent`s — they are now forwarded to the page as scrolls,
  with a gain factor to approximate native browser scroll distance.

## 0.1.0

* Multi-process CEF by default — crash-isolated, so heavy SPAs (e.g. Google
  sign-in) render and survive. **GPU-accelerated OSR**: CEF's GPU process
  composites the page and hands it to `OnAcceleratedPaint` as a shared IOSurface,
  which moves compositing off the CPU (the bottleneck for video / animation).
  This runs multi-process without Developer-ID signing by disabling the
  MachPort peer-requirement validation that otherwise `-67030`s the GPU→browser
  handoff. The composited surface is still copied into the shared surface (cheap
  on unified-memory Macs); true zero-copy is on the roadmap.
* Fixed a multi-process blank-render bug (resize-race: geometry is re-synced
  when the renderer connects) and hardened the IPC (pre-connect frame queue).
* Page-lifecycle callbacks: `onPageStarted`, `onPageFinished`, `onProgress`,
  `onUrlChange`; new-window routing via `onCreateWindow`.
* JavaScript bridge over `CefMessageRouter`: `runJavaScriptReturningResult`
  (JSON round-trip — primitives, lists, maps) and `addJavaScriptChannel`
  (`window.<name>.postMessage` → Dart).
* JS dialogs: `onJavaScriptAlertDialog` / `onJavaScriptConfirmDialog` /
  `onJavaScriptTextInputDialog`.
* Content zoom (`setZoomLevel`), find-in-page (`find` / `stopFind` /
  `onFindResult`), `loadHtmlString` / `loadFile`.
* Cookies (`setCookie` / `clearCookies`, plus `getCookies` to read/enumerate —
  optionally scoped to a URL — and `deleteCookie`), scrolling (`scrollTo` /
  `scrollBy` / `getScrollPosition`), `getTitle` / `getUserAgent`,
  `clearLocalStorage`.
* Downloads (`onDownload` + the native Save panel).
* `openDevTools` — opens the Chrome DevTools inspector for the view in its own
  window (Elements / Console / Network / Sources, inspecting the live page).
* Automatic IME / text input: while focused, `CefWebView` holds a platform
  `TextInputConnection`, so dead keys, CJK composition, and emoji all reach the
  page. Committed text is sent as full UTF-8 (fixes the prior surrogate-pair
  truncation that mangled emoji / astral characters), composition is relayed and
  visibly underlined, and the OS candidate window is positioned under the caret
  (`OnImeCompositionRangeChanged` readback). The low-level
  `imeSetComposition` / `imeCommitText` / `imeCancelComposition` controller verbs
  remain for direct use.
* The macOS emoji & symbols picker (⌃⌘Space) now opens cold over the page —
  previously it only worked after the shortcut had been used in another (native)
  text field first. Two fixes: the key router no longer swallows ⌃⌘Space (it
  carries no `character`, so it was being treated as a consumed non-text key
  instead of falling through to the platform input context), and a caret rect is
  now always pushed while focused (seeded at the last click), so the picker —
  and the candidate / accent popups — anchor at the text instead of the screen
  corner. New `showEmojiPicker()` opens the same picker programmatically.
* Keyboard activation: typed characters now reach the page as real
  `keydown → keypress → keyup` events (a CHAR key event) like a browser, instead
  of an IME commit that fired no key events. So a focused control activates from
  the keyboard: **Enter** clicks a button / submits a form, **Space** toggles a
  checkbox / radio or clicks a button, and the page's own keypress handlers fire.
  (Composition results and multi-unit inserts — emoji, paste — still commit via
  the IME, which is correct: they have no keypress.) Space also now carries its
  `character` on keydown/keyup so Blink resolves the activation key.
* Input fidelity: editing / navigation keys (Backspace, arrows, …) no longer
  double-apply (one Backspace deleted two characters; one arrow moved two
  options in a `<select>`) — the host now sets the macOS `character` /
  `unmodified_character` on every key, which de-duplicates the edit command on
  CEF's OSR path (known CEF behavior). `<select>` dropdowns now position and
  click correctly on Retina — the popup composite offset is scaled by the device
  pixel ratio. Key routing also stops Flutter's own shortcuts from eating arrow
  keys while the view is focused.
* Verbose CEF logging is now gated behind the `FLUTTER_CEF_DEBUG` env var.
* Hardening (security/concurrency audit): validate JS channel names before
  injection; fail pending `runJavaScriptReturningResult` completers on
  navigation/dispose; deterministic session teardown that joins the reader
  thread (no use-after-free on dispose); per-user/per-process CEF cache +
  randomized IPC socket (off the world-readable `/tmp`); null main-frame and
  resize-dimension guards in the host.

## 0.0.1

* Initial macOS preview: `CefWebView` widget + `CefWebController`.
* Live Chromium (CEF) rendered off-screen into a Flutter `Texture` via a
  per-view `cef_host` subprocess and a shared IOSurface.
* Pointer, scroll, and keyboard input forwarding; page cursor drives a
  `MouseRegion`. Native `<select>` dropdowns composite over the view.
* Navigation + history: `navigate` / `reload` / `stop` / `goBack` /
  `goForward`, gated by `canGoBack` / `canGoForward`.
* Page state to Dart: `isLoading`, `title`, `url` (`ValueListenable`s) plus
  `onLoadError` and `onConsoleMessage` callbacks.
* `executeJavaScript(code)` (fire-and-forget).
* `native/build_cef_host.sh` fetches CEF and builds `cef_host.app`.
