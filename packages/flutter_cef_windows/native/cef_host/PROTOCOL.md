# flutter_cef Windows wire + channel contract

The opcodes and protocol versions of both platforms are defined once, in
`tool/protocol/spec.dart`, and generated into each package (§2). The rest of
this document was transcribed from the macOS implementation:

- `packages/flutter_cef_macos/native/cef_host/` — framing (`ipc.mm`), read-loop
  payload decoding (`ipc_reader.mm`), and the per-browser handlers
  (`host_client.mm`, `browser_ops.mm`).
- `packages/flutter_cef_macos/macos/Classes/FlutterCefPlugin.swift` — channel
  verb dispatch (`handle`) and native->Dart events (`emit` sites).
- `lib/src/cef_web_controller.dart` — the exact channel-arg maps Dart sends.

The Windows host + plugin speak the macOS protocol with two payload
differences, `kOpPresent` and `kOpShowDevTools` (§2), and their own protocol
version.

---

## 1. IPC framing (byte stream over the named pipe)

Identical to macOS (`SendFrame` in `ipc.mm`, `IpcReadLoop` in
`ipc_reader.mm`):

```
[u32 bodyLen BE][u32 browserId BE][u8 opcode][payload...]
```

- `bodyLen` = 4 (browserId) + 1 (opcode) + payloadLen — counts every byte
  after the length prefix.
- Guard on read: `5 <= bodyLen <= 64 MiB`, else the stream is desynced —
  log + tear down the whole process.
- `browserId` is the PLUGIN-assigned wire id (>= 1). `browserId 0` =
  process/profile level (`kOpReady`, process-level `kOpLog`, inbound
  `kOpShutdown`).
- ALL multi-byte integers are BIG-ENDIAN, including `f64` (IEEE-754 double,
  BE byte order — `ReadF64BE`/`WriteF64BE`, as in macOS `ipc.h`).
- Writes are assembled into one contiguous frame and written atomically
  under a write mutex, so a partial write never desyncs the peer.
- Transport on Windows: named pipe `\\.\pipe\flutter_cef_<128-bit random
  hex>` (an unguessable name, so a same-user process can't squat it),
  `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE`, single instance; plugin is the
  server (`CreateNamedPipeW`), cef_host connects with `CreateFileW`
  (+ `SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS`). Same framing on top.
- **OVERLAPPED I/O is REQUIRED on any pipe end that reads and writes from
  different threads** (empirical, cef_host + pipe_probe 2026-07-20): Windows
  serializes I/O on a synchronous pipe file object, so a dedicated reader
  thread's pending blocking `ReadFile` makes every `WriteFile` on the same
  handle queue behind it. In cef_host that froze the CEF UI thread inside
  `SendFrame(kOpCreated)`, stalled `CefRunMessageLoop`, and every Chromium
  child process died with "Terminating current process after 15 seconds with
  no connection" (no renderer/GPU/network, browsers never created). Fix:
  open/create the handle with `FILE_FLAG_OVERLAPPED` and run all reads AND
  writes as event-based overlapped ops (`cef_host_win.cc` `OverlappedIo`).
  The plugin's server end (`CreateNamedPipeW` + reader thread + writes from
  the platform thread) has the identical shape and MUST also pass
  `FILE_FLAG_OVERLAPPED`. A Unix socket fd is full-duplex, so the macOS
  reference never encounters this.
- Unknown opcode at either end: log ONCE per opcode value and drop the
  frame — never kill the stream.
- Plugin writes run on the platform thread and wait at most 3 s for the host
  to take a frame. A write that fails or times out ends the host (every
  session gets `processGone("crashed")`): the host isn't reading, and part of
  a frame may already be on the wire.
- Page-sourced payloads (console messages, titles, URLs, channel messages,
  eval results, JS dialog text, cookie lists) are capped at 8 MiB by the host,
  far under the 64 MiB frame guard, so one page can't make the plugin drop the
  whole host. Text is truncated with a note; an eval result that is too large
  becomes an `{ok:false}` reply for the same id; an oversized channel message
  is refused.

## 2. Opcode table

Generated from `tool/protocol/spec.dart`, like `cef_host_opcodes.h`; edit the
spec and run `dart run tool/protocol/generate.dart`. Payloads match macOS except
kOpPresent (a D3D bridge handle instead of an IOSurface id) and kOpShowDevTools
(no inspect point). A short frame is dropped, not fatal.

<!-- BEGIN GENERATED OPCODES (tool/protocol/generate.dart) -->

Protocol version 6. Payload integers are big-endian.

### cef_host -> plugin

| Op | Name | Payload |
|---|---|---|
| 0x01 | kOpPresent | {u64 bridgeHandle}{u32 srcW}{u32 srcH}: bridgeHandle is the DXGI legacy shared handle of the host-minted bridge texture. |
| 0x02 | kOpReady | {u8 readyFlags}{u8 protocolVersion} on browserId 0, before any browser exists. readyFlags bit0 = ad-hoc (mock keychain) build; Windows sends 0. |
| 0x03 | kOpCursor | {u32 cef_cursor_type_t} |
| 0x04 | kOpLog | {utf8 message}; browserId 0 = process-level |
| 0x05 | kOpLoadState | {u8 loading}{u8 canGoBack}{u8 canGoForward} |
| 0x06 | kOpTitle | {utf8 title} |
| 0x07 | kOpUrl | {utf8 main-frame url} |
| 0x08 | kOpLoadErr | {u32 code}{utf8 "url\ntext"} |
| 0x09 | kOpConsole | {u32 level}{utf8 "source:line\tmsg"} |
| 0x0a | kOpPageStart | {utf8 url} main-frame load started |
| 0x0b | kOpPageFinish | {utf8 url} main-frame load finished |
| 0x0c | kOpProgress | {u32 percent 0-100} |
| 0x0d | kOpNewWindow | {utf8 url} popup / target=_blank |
| 0x0e | kOpFindResult | {u32 count}{u32 activeOrdinal}{u8 final} |
| 0x0f | kOpJsDialog | {u32 id}{u32 type}{u32 msgLen}{utf8 msg}{utf8 defaultText} |
| 0x16 | kOpEvalResult | {utf8 "id:json"} reply to kOpEvalReturning |
| 0x17 | kOpChannelMsg | {utf8 "name:message"} JS channel -> plugin |
| 0x18 | kOpDownload | {utf8 suggestedName} a download started |
| 0x19 | kOpImeBounds | {u32 x}{u32 y}{u32 w}{u32 h} caret rect (DIP) |
| 0x1a | kOpCookies | {u32 id}{utf8 json-array} reply to kOpVisitCookies |
| 0x1b | kOpTargetId | {utf8 targetId} this browser's CDP targetId, reply to kOpResolveTargetId |
| 0x1c | kOpCreated | {} OnAfterCreated: the browser is up; the plugin paces the next create on it |
| 0x1d | kOpCreateFailed | {} the async CreateBrowser dispatch failed; the plugin drops the session |
| 0x42 | kOpBrowserGone | {utf8 reason} this one browser can't continue (its renderer keeps crashing); the process survives and the plugin drops the session |

### plugin -> cef_host

| Op | Name | Payload |
|---|---|---|
| 0x10 | kOpPointer | {u8 type}{u8 button}{u8 clickCount}{u8 pad}{u32 modifiers}{f64 x}{f64 y}{f64 dx}{f64 dy}; type 0=move 1=down 2=up 3=wheel 4=leave, button 0=left 1=middle 2=right, x/y in DIP |
| 0x11 | kOpResize | {u32 w}{u32 h}[{f64 dpr}]: dpr absent or 0 = unchanged, must be in (0, 8] |
| 0x12 | kOpKey | {u8 type}{u8 pad x3}{u32 modifiers}{u32 windowsKeyCode}{u32 nativeKeyCode}{u32 character}; type 0=rawkeydown 2=keyup 3=char |
| 0x13 | kOpCreateBrowser | {u32 w}{u32 h}{f64 dpr}{utf8 url}; the frame's browserId is the NEW id; empty url = about:blank |
| 0x14 | kOpShutdown | {} on browserId 0: end the whole process |
| 0x15 | kOpDisposeBrowser | {} close one browser; the process survives |
| 0x20 | kOpNavigate | {utf8 url} |
| 0x21 | kOpReload | {} |
| 0x22 | kOpStop | {} |
| 0x23 | kOpBack | {} |
| 0x24 | kOpForward | {} |
| 0x25 | kOpExecuteJs | {utf8 code} |
| 0x26 | kOpSetZoom | {f64 level}; factor = 1.2^level |
| 0x27 | kOpFind | {u8 forward}{u8 matchCase}{u8 findNext}{utf8 text} |
| 0x28 | kOpStopFind | {u8 clearSelection}; absent = 1 |
| 0x29 | kOpJsDialogResp | {u32 id}{u8 ok}{utf8 text} |
| 0x2a | kOpEvalReturning | {u32 id}{utf8 expression}; replies kOpEvalResult |
| 0x2b | kOpAddChannel | {utf8 name} register a JS channel |
| 0x2c | kOpSetCookie | {utf8 url\0name\0value\0domain\0path[\0secure(0\|1)\0httpOnly(0\|1)\0sameSite(unspecified\|none\|lax\|strict)]} |
| 0x2d | kOpClearCookies | {} delete all cookies |
| 0x2e | kOpVisitCookies | {u32 id}{utf8 url}; empty url = all; replies kOpCookies |
| 0x2f | kOpDeleteCookie | {utf8 url\0name} |
| 0x30 | kOpImeSetComp | {utf8 text} IME composition update |
| 0x31 | kOpImeCommit | {utf8 text} commit composed text |
| 0x32 | kOpImeCancel | {} cancel composition |
| 0x33 | kOpShowDevTools | {} open DevTools in a window |
| 0x34 | kOpLoadTrusted | {utf8 url} a load by the embedder, exempt from the scheme allowlist |
| 0x35 | kOpSetVisible | {u8 visible}; absent = 1 |
| 0x36 | kOpResolveTargetId | {} replies kOpTargetId |
| 0x37 | kOpInvalidate | {} force a repaint, to re-kick a stalled first frame |
| 0x38 | kOpEditCommand | {u8 cmd} in the focused frame: 0=copy 1=cut 2=paste 3=selectAll 4=undo 5=redo |
| 0x3a | kOpSetAudioMuted | {u8 muted} |
| 0x3b | kOpSetPumpInterval | {u16 ms} visible begin-frame cadence, clamped to [8, 250] |
| 0x3f | kOpSetAuthoredHtml | {utf8 baseUrl}\0{utf8 html}: store-only; serve html as the main-frame response for exactly baseUrl (empty html clears it). The load is a following kOpCreateBrowser or kOpLoadTrusted for that URL |
| 0x41 | kOpSetDocumentStart | ({u8 kind}{u32 len}{utf8})*, kind 0 = JS channel name, 1 = script (document_start.h): store-only, for the browser created right behind it |

macOS only, never reuse on Windows: 0x1e kOpMediaRequest, 0x1f kOpMediaState, 0x40 kOpContextMenu, 0x39 kOpOpenAuthWindow, 0x3c kOpMediaResponse, 0x3d kOpSetMediaSetting, 0x3e kOpContextMenuCommand.

<!-- END GENERATED OPCODES -->

## 3. Method-channel verbs (Dart -> plugin), channel `flutter_cef`

Verb names + arg keys verbatim from FlutterCefPlugin.swift (`handle`) and
cef_web_controller.dart (invokeMethod sites). Every arg map carries
`sessionId` (String). `showDevTools` and the three `ime*` verbs are
implemented natively but not yet verified on Windows OSR. Verbs listed as
returning Error `unsupported` reply
`Error("unsupported", "<verb> is not supported on Windows")`.

| Verb | Args (beyond sessionId) | Returns | Maps to |
|---|---|---|---|
| create | url:String, width:int (clamped to 1..16384), height:int (clamped to 1..16384), dpr:double, allowedSchemes:String? (csv of URL schemes, omit-when-empty; anything else is `bad_args`), enableCdp:bool? (omit-when-false), agentControl:bool? (omit-when-false), profile:String? (omit-when-empty), hostGroup:String? (omit-when-empty), authoredHtml:String? (serve as `url`), documentStartScripts:List<String>?, channels:List<String>? (JS channels registered before create) | `{textureId:int, width:int, height:int, cdpPort:int}` | spawn host (if needed) + [kOpSetDocumentStart 0x41] + [kOpSetAuthoredHtml 0x3f] + kOpCreateBrowser 0x13 |
| navigate | url:String | null | 0x20 |
| loadTrusted | url:String | null | 0x34 |
| loadAuthored | url:String, html:String | null | 0x3f then 0x34 |
| resize | width:int, height:int, dpr:double | `{textureId:int}` (or null if unknown session) | 0x11 |
| getFrameSurface | — | `{surfaceId:int, width:int, height:int}` (physical px) of the frame the texture is showing, or null before the first | plugin-local |
| dispose | — | null | 0x15 (last browser: 0x14 + host teardown) |
| freezeSession | — | bool (false: unknown, already frozen, or host gone) | 0x15 (last browser: 0x14 + host teardown); the session and texture stay |
| thawSession | url:String? (default: the create url) | `{textureId:int}` or null when not frozen | host resolve/spawn + [0x41] + [0x3f] + 0x13 at the current size |
| sessionStats | — | `{presentCount:int, lastPresentAgoMs:int?, firstPresentSeen:bool, frozen:bool}` (promoted presents only) or null | plugin-local |
| setAudioMuted | muted:bool | null | 0x3a |
| setFrameInterval | ms:int | null | 0x3b `{u16 ms}`; host clamps to [8, 250] and sets the windowless frame rate |
| chooseContextMenu, respondMediaRequest, setMediaSetting, openAuthWindow | — | Error `unsupported` | — |
| pointer | type:int, button:int, clickCount:int, modifiers:int, x:double, y:double, dx:double, dy:double | null | 0x10 |
| key | type:int, modifiers:int, windowsKeyCode:int, nativeKeyCode:int, character:int | null | 0x12 |
| reload | — | null | 0x21 |
| stop | — | null | 0x22 |
| goBack | — | null | 0x23 |
| goForward | — | null | 0x24 |
| executeJavaScript | code:String | null | 0x25 |
| setZoomLevel | level:double | null | 0x26 |
| editCommand | command:int | null | 0x38 |
| setVisible | visible:bool | null | 0x35 |
| find | text:String, forward:bool, matchCase:bool, findNext:bool | null | 0x27 |
| stopFind | clearSelection:bool | null | 0x28 |
| respondJsDialog | id:int, ok:bool, text:String | null | 0x29 |
| evalReturning | id:int, code:String | null | 0x2a |
| addJavaScriptChannel | name:String | null | 0x2b |
| setCookie | url, name, value, domain, path, sameSite : String; secure, httpOnly : bool | null | 0x2c |
| clearCookies | — | null | 0x2d |
| visitCookies | id:int, url:String | null | 0x2e |
| deleteCookie | url:String, name:String | null | 0x2f |
| showDevTools | — | null | 0x33 |
| enableAgentControl | — | `{wsUrl:String, token:String, port:int}` or FlutterError (`no_agent_control` when the session wasn't created with `agentControl:true`; `agent_control_unavailable` when it was, but joined a profile whose host started without it) | CDP relay (§8) |
| disableAgentControl | — | null | CDP relay (§8) |
| showEmojiPicker | — | Error `unsupported` | macOS-only (Character Palette) |
| imeSetComposition | text:String | null | 0x30 |
| imeCommitText | text:String | null | 0x31 |
| imeCancelComposition | — | null | 0x32 |

Unknown verbs reply `NotImplemented` (a `MissingPluginException` in Dart), as
on macOS.

## 4. Events (plugin -> Dart), channel `flutter_cef`

Method names + payload keys verbatim from the Swift `emit` sites. Every
payload carries `sessionId:String`. `invokeMethod` MUST run on the platform
thread (marshal from the reader thread).

| Method | Payload (beyond sessionId) | From opcode |
|---|---|---|
| cursor | cursor:int (cef_cursor_type_t) | 0x03 |
| loadingState | isLoading:bool, canGoBack:bool, canGoForward:bool | 0x05 |
| title | title:String | 0x06 |
| url | url:String | 0x07 |
| loadError | code:int, url:String, text:String (split payload at first '\n') | 0x08 |
| consoleMessage | level:int, message:String | 0x09 |
| pageStarted | url:String | 0x0a |
| pageFinished | url:String | 0x0b |
| progress | progress:int | 0x0c |
| newWindow | url:String | 0x0d |
| findResult | count:int, activeMatchOrdinal:int, isFinal:bool | 0x0e |
| jsDialog | id:int, type:int, message:String, defaultText:String | 0x0f |
| evalResult | payload:String ("id:json") | 0x16 |
| channelMessage | payload:String ("name:message") | 0x17 |
| download | suggestedName:String | 0x18 |
| imeCompositionBounds | x:int, y:int, w:int, h:int | 0x19 |
| cookies | id:int, json:String | 0x1a |
| onSurface | surfaceId:int, width:int, height:int (physical px) — Windows: surfaceId = the bridge-handle token as int64 | 0x01 (on surface (re)alloc) |
| processGone | reason:String — "crashed" (host death, a failed/timed-out pipe write, a renderer the liveness sweep found hung, or 0x42 for one crash-looping browser) \| "locked" (the host logged "profile-locked") \| "createFailed" (0x1d, or the host died before kOpReady) \| "respawnFailed" \| "protocolMismatch(host=vN)" | host death / 0x1d / 0x42 / handshake |
| paintStalled | — | first-present watchdog: every grace (10 s, `FLUTTER_CEF_FIRSTPAINT_MS`) that ends with no promoted 0x01, with a 0x37 re-kick — the macOS cadence |

## 5. Handshake + lifecycle rules (carry-over)

- Plugin sends NOTHING until it receives `kOpReady`; it then checks
  `protocolVersion == kCefHostProtocolVersion` (§2) and refuses (teardown +
  `processGone protocolMismatch`) on skew (macOS: the `CefOp.ready` case in
  `CefProfileHost+Ipc.swift`).
  Frames queued before ready flush in order, and a queued `kOpCreateBrowser`
  is rewritten with its view's size as of the flush: the host takes seconds to
  start, and the view may have been laid out again meanwhile.
- The host registers a browser's slot when its create frame arrives. Per-browser
  ops that reach it before the (asynchronous) browser exists wait on the slot
  and run in order once it binds, instead of being dropped.
- `kOpLog "profile-locked"` (then exit code 2) = profile already open
  elsewhere -> `processGone reason:"locked"`. The plugin latches the log line:
  the pipe EOF usually arrives before the exit code exists.
- Present size-gate: every `WasResized` discards CEF's frame pool, and frames
  at the old size or scale still arrive after it. So the plugin promotes a
  presented bridge handle to the Flutter texture ONLY when `{srcW,srcH}`
  matches the expected `round(logical*dpr)` for the current size (±1 px);
  until then it keeps serving the previous texture (the rationale is on
  `SendPresentLocked` in the macOS `render_handler.mm`). Only a promoted
  present counts as painted (it ends the first-present watchdog and feeds
  `sessionStats`); a rejected one shows nothing.
- No create pacer on Windows: the plugin sends every create at once and does
  not wait on `kOpCreated`, which it uses only to re-assert a hide.
- Steady-state liveness: every 2 s the plugin checks each painted, visible
  tile. One with no frame for 10 s (`FLUTTER_CEF_LIVENESS_MS`) gets a 0x37
  repaint and a ping: `kOpEvalReturning` with id `0xFFFFFFFF` (Dart's ids never
  reach it; the reply is consumed, not forwarded). The host doesn't evaluate
  it in the page: it sends the renderer a process message, which the
  renderer's main thread answers, and replies `0xFFFFFFFF:{"ok":true,"v":1}`
  (a page's own `eval:` reply under that id is refused). A renderer that
  leaves the ping unanswered for 15 s (`FLUTTER_CEF_HANG_MS`) is hung: the
  plugin emits `processGone("crashed")` for that session alone and disposes
  it, and the host's other browsers carry on. Tiles blocked on a JS dialog,
  with DevTools opened, or on an agent-control host are not pinged. macOS
  also ends a host whose GPU process was replaced; on Windows the tiles keep
  painting after one is, so it isn't watched.
- Shutdown: `kOpShutdown`, the pipe closing and a crash-loop host exit all
  arm a watchdog in the host, which ends the process (exit code 0) if it is
  still running 6 s later, or 30 s after its message loop has quit, logging
  `[cef_host] still running after shutdown (<why>); exiting now` to stderr.
  A wedged UI thread never runs the shutdown, and a host left running keeps
  its profile locked. The timings are the macOS host's.
- Renderer crash loops are counted per browser, as on macOS. A crash reloads
  the page; 4 crashes of one browser within 10 s end only that browser
  (kOpBrowserGone "crashed", no more reloads): the plugin emits
  `processGone("crashed")` for its session and disposes it, and the host's
  other browsers carry on. When two different browsers burst within 10 s of
  each other the host's children can't start, so the host exits and every
  session gets `processGone("crashed")`.
- Bridge-handle identity: the host-minted legacy handle is the identity
  Flutter sees; never key anything on CEF's per-callback
  `shared_texture_handle` values, which are fresh every callback and alias
  across sizes and browsers.
- The plugin holds an opened `ID3D11Texture2D` ComPtr on the current bridge
  handle for as long as it feeds it to Flutter, so the texture stays alive
  even after the host releases the bridge.
- cef_host args: `--ipc=<pipe name>` `--profile-dir=<abs path>` `--ephemeral`
  `--allowed-schemes=<csv>` (§6) and — for agent control (§8) — `--cdp-io-pipes=
  <read>,<write>` (cf. the macOS args in the `main.mm` header; `--cdp-port` TCP
  CDP is not implemented on Windows — the Dart-side `enableCdp`+named-profile
  assert already blocks the unsafe combination, so `cdpPort` stays 0 on
  Windows).

## 6. Profile model

The plugin owns ONE `cef_host` process per **profile key** and multiplexes N
browsers over it (one wire browserId each) — the macOS
`CefProfileHost`/`FlutterCefPlugin` model transcribed to Windows. Key =
the sanitized `profile` name for a named profile, `"~group~"+hostGroup` for an
ephemeral session in a host group, or `"~ephemeral~"+sessionId` for the default
(throwaway) case, so an ungrouped ephemeral session gets its own host, a group's
sessions share one throwaway host (torn down with the last of them), and every
view with the same non-null `profile` shares one host → one cookie jar → one
login (macOS: `ephemeralKey` in FlutterCefPlugin.swift, and the
`CefProfileHost` class comment).

### 6.1 Profile-dir resolution (plugin side)

The `create` verb's `profile` arg (String, omit-when-empty — §3) selects the
mode. The plugin resolves an on-disk cache dir and always passes it as
`--profile-dir=<abs path>` (macOS `resolveProfileDir` in
FlutterCefPlugin.swift):

- **Ephemeral** (`profile` absent/empty): a unique throwaway dir
  `%TEMP%\flutter_cef_ephem_<pid>_<tick>_<counter>`, created + removed once the
  host's whole process tree is gone (a startup sweep reclaims dirs whose owning
  pid is dead), and the
  host is launched WITH `--ephemeral` (macOS uses `flutter_cef_ephem_<uuid>` +
  `--ephemeral=1`).
- **Named / persistent** (`profile` non-empty): a stable dir
  `%LOCALAPPDATA%\flutter_cef\profiles\<sanitized-name>`, launched WITHOUT
  `--ephemeral`. Sanitize the name to `[A-Za-z0-9._-]` (every other char → `_`),
  and neutralize an all-dots leaf (`.`/`..`/`...`) to `_` so it can't escape the
  `profiles\` container (macOS `resolveProfileDir` — mirror this exactly,
  including the all-dots guard).

  NOTE — Windows path root differs from macOS DELIBERATELY: macOS uses
  `<Application Support>/<bundleId>/flutter_cef/profiles/<name>`; Windows uses
  `%LOCALAPPDATA%\flutter_cef\profiles\<name>` (no per-app bundleId segment).
  **Multi-app shared-profiles-root caveat**: every flutter_cef app for a given
  Windows user therefore shares this one `profiles\` root, so a `profile: 'work'`
  in app A and app B resolve to the SAME dir (analogous to the macOS
  shared-"Chromium Safe Storage"-keychain caveat). Co-locate only
  mutually-trusting apps on a shared profile name.

- **DACL**: create the named-profile dir (and its `profiles\` ancestor) with a
  current-user-SID-protected DACL — the same pattern `ipc_pipe.cpp` uses for the
  pipe. This is the Windows analogue of macOS's `0700` owner-only chmod in
  `resolveProfileDir`. The ACE is inheritable
  (OICI) so the files Chromium creates inside inherit it. Unlike macOS, which
  re-chmods an existing leaf, Windows applies the DACL only when it creates the
  dir: a dir from a prior run keeps whatever DACL it has.

### 6.2 Host side (`--profile-dir` → `root_cache_path`)

`cef_host` maps `--profile-dir` to `CefSettings.root_cache_path` and sets
`settings.persist_session_cookies = true` (as macOS `main.mm` does). One
`root_cache_path` is shared by every browser in the process — that is what makes
the login shared. `persist_session_cookies` keeps session cookies across relaunch
(harmless for ephemeral, required for "stay signed in" on a named profile). The
`--ephemeral` flag (`is_ephemeral` in macOS `main.mm`) marks the throwaway case
so the host's guards (CDP-on-named-profile refusal, and on macOS the mock-keychain
downgrade) fire only for a REAL persistent profile — `--profile-dir` is set for
both.

### 6.3 At-rest encryption — Windows DPAPI (NO macOS-style downgrade)

**KEY Windows security fact:** OSCrypt on Windows encrypts the
cookie store with **DPAPI**, which is **always available and
signing-independent**. So the macOS rule "ad-hoc build → mock keychain → downgrade
a named profile to ephemeral (unless `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1`)"
has **NO Windows analogue** — there is no mock-keystore state and no downgrade.
A named profile on Windows simply persists, encrypted at rest, regardless of code
signing. Concretely: `kOpReady`'s `readyFlags` bit0 (ad-hoc/mock-keychain build)
is **macOS-only; the Windows host always sends 0** (§2), and
there is no `onInsecureProfileRefused` / re-home-to-ephemeral path on Windows.

**Caveat (state it, do not hide it):** DPAPI's user-tier protection is
**same-user-readable** — any process running as the same Windows user can call
`CryptUnprotectData` and decrypt the store. This is **weaker than the macOS
Keychain**, which can prompt / ACL-scope access. So on Windows the at-rest
guarantee is "protected against other users / offline disk theft, NOT against
other same-user processes." `localStorage`/IndexedDB are plaintext on both
platforms (FileVault/BitLocker is the backstop).

### 6.4 Cookies API (the four verbs + the result event)

Cookies act on the profile's ONE process-wide `CefCookieManager` (the shared
jar §6.1), so a write/clear is visible to every browser in the host. The four
command opcodes and the one result event are fully specified in §2 (byte layouts)
and reached from Dart via the verbs in §3/§4 — summarized here:

| Dart (controller) | Verb (§3) | Opcode (§2) |
|---|---|---|
| `setCookie(url,name,value,domain,path,secure,httpOnly,sameSite)` | `setCookie` | 0x2c `{utf8 url\0name\0value\0domain\0path\0secure\0httpOnly\0sameSite}` (pad to 8) |
| `clearCookies()` | `clearCookies` | 0x2d `{}` |
| `getCookies({url})` → `List<CefCookie>` | `visitCookies` | 0x2e `{u32 id}{utf8 url}` (empty = all) → **0x1a** `{u32 id}{utf8 json-array}` event |
| `deleteCookie(url,name)` | `deleteCookie` | 0x2f `{utf8 url\0name}` |

`getCookies` is the only round-trip: the plugin assigns `id`, sends `visitCookies`,
and resolves the Dart `Future` when the `cookies` event (from opcode 0x1a — §4)
arrives carrying the same `id` and a JSON array (`CefCookie.fromJson` per element,
in `_handleCookies`). The JSON array shape MUST match macOS byte-for-byte (the
`DoVisitCookies` serializer in macOS `browser_ops.mm`) so a page cannot detect a
Windows-vs-macOS divergence.

## 7. JS bridge, JS dialogs, find, zoom, downloads

All opcode numbers and byte layouts are in §2; this section documents the
**string packings** and the **per-session message-router routing** that these
verbs depend on, transcribed from the macOS host. The Dart side
(cef_web_controller.dart, cross-platform, unchanged for Windows) parses exactly
these shapes; the Windows host MUST reproduce them byte-for-byte so a page cannot
detect a Windows-vs-macOS divergence.

### 7.1 The message router (CefMessageRouter) — renderer + browser halves

The JS bridge (channels + `runJavaScriptReturningResult`) rides one
`CefMessageRouter` created with the **DEFAULT** `CefMessageRouterConfig`
(`window.cefQuery` / `window.cefQueryCancel`). Browser-side and renderer-side
MUST use the SAME config or queries never route.

- **macOS reference:** browser-side router lives in `HostClient`
  (`host_client.mm` — `router_->OnProcessMessageReceived` and `OnQuery`).
  The renderer half is a SEPARATE process
  (`process_helper.mm`): `CefMessageRouterRendererSide` with the default config,
  wired in `OnContextCreated` / `OnContextReleased` / `OnProcessMessageReceived`.
- **Windows:** there is no separate helper exe — the SAME `cef_host.exe` is
  re-executed as the render subprocess via `CefExecuteProcess`, so the
  renderer-side router lives in cef_host's `CefApp::GetRenderProcessHandler`
  (cef_host_win.cc), branched by process type. Both halves still use the DEFAULT
  config (contract, not Dart-visible).

### 7.2 JS channels — `addJavaScriptChannel` / `removeJavaScriptChannel`

Page → host. The shim is injected NATIVELY (there is no Dart-injected shim):

- `addJavaScriptChannel(name)` → verb `addJavaScriptChannel` → **0x2b
  kOpAddChannel** `{utf8 name}` (§2). The host validates `name` is a JS
  identifier (`IsValidChannelName`; ≤64 chars,
  `[A-Za-z_$][A-Za-z0-9_$]*`) and registers it process-globally in `g_channels`
  (`DoAddChannel`). Invalid names are dropped + logged, never
  fatal. Dart pre-validates with the same regex (`_channelNameRe`) and
  re-registers every channel on `create()` so add-before-mount works.
- **Shim injection** (`InjectChannelShim`) — injected into the
  **MAIN frame ONLY** on every `OnLoadStart` and into the
  current frame at registration time (`DoAddChannel`). The injected source is
  exactly:
  ```js
  window['<name>']={postMessage:function(m){window.cefQuery({request:'ch:<name>:'+String(m),
    persistent:false,onSuccess:function(){},onFailure:function(){}});}};
  ```
- **Page → host delivery.** `window.<name>.postMessage(m)` calls
  `window.cefQuery` with `request = "ch:<name>:<m>"`. `OnQuery`
  refuses subframe queries (privileged bridge; 403), strips
  the `"ch:"` prefix (3 bytes), and sends **0x17 kOpChannelMsg** `{utf8
  "name:message"}`. The plugin emits `channelMessage
  {payload:"name:message"}` (§4); Dart splits at the FIRST `:` and dispatches to
  the registered handler (`_handleChannelMessage`)
  — colons in the message body are preserved.
- **Per-session routing (mandatory — channel_probe_shared).** `OnQuery` stamps
  `slot_->browser_id` (the originating browser) on kOpChannelMsg,
  and the plugin fans the event to only that session's Dart
  channel handler. A message from tile A's page reaches A's handler, never B's,
  even on a shared host. This is an information-sharing boundary (the channel
  NAME is process-global), not a message-spoofing one.
- `removeJavaScriptChannel(name)` is **Dart-local**:
  it stops delivery to the handler but does NOT tear down the page-side shim
  (which is process-global on a shared profile), so the page may still post — those
  messages are dropped. No opcode.

### 7.3 `runJavaScriptReturningResult` — the eval round-trip

- `runJavaScriptReturningResult(code)` assigns an `id` and sends verb
  `evalReturning` → **0x2a kOpEvalReturning** `{u32 id}{utf8 code}` (§2).
  The host (`DoEvalReturning`) SPLICES `code` into a `window.cefQuery` call
  (not `eval()`, so it survives a strict page CSP) that JSON-stringifies
  `{ok:true,v:(<code>)}` on success or `{ok:false,v:String(e)}` on throw, with
  `request = "eval:<id>:<json>"`.
- `OnQuery` refuses subframe queries (403), strips the
  `"eval:"` prefix (5 bytes), and sends **0x16 kOpEvalResult** `{utf8
  "id:json"}`. The plugin emits `evalResult
  {payload:"id:json"}` (§4); Dart splits at the FIRST `:`, matches the pending
  completer by `id`, and JSON-decodes the tail: `ok:true` completes with `v`,
  `ok:false` completes with an `Exception('<v>')` (`_handleEvalResult`).
- In-flight evals are failed (never leaked) on `pageStarted`, `processGone`,
  and `dispose` (`_failPendingEvals`).
- `executeJavaScript(code)` is the fire-and-forget sibling → **0x25
  kOpExecuteJs** `{utf8 code}` (§2), no result event.

### 7.4 JS dialogs — alert / confirm / prompt

- Host → page request: `CefJSDialogHandler::OnJSDialog`
  assigns a per-slot `id`, stashes the `CefJSDialogCallback`, and sends **0x0f
  kOpJsDialog** `{u32 id}{u32 type}{u32 msgLen}{msg utf8}{defaultText utf8}`.
  `type`: 0=alert, 1=confirm, 2=prompt.
  The plugin emits `jsDialog {id,type,message,defaultText}` (§4).
- Dart (`_handleJsDialog`) routes by `type` to
  `onJavaScriptAlertDialog` / `onJavaScriptConfirmDialog` /
  `onJavaScriptTextInputDialog`, then replies verb `respondJsDialog
  {id, ok, text}` → **0x29 kOpJsDialogResp** `{u32 id}{u8 ok}{utf8 text}` (§2).
  Unset handlers fall closed to sensible defaults (alert dismissed, confirm→OK,
  prompt→defaultText). A throwing handler fails closed (`ok=false`) but is
  reported via `FlutterError.reportError` (not silently swallowed).
- Host applies the answer: `DoJsDialogResp` looks up the
  stashed callback by `id` and calls `Continue(ok, text)`, which returns the
  page's `alert`/`confirm`/`prompt`. `OnBeforeUnloadDialog` always allows
  navigation.

### 7.5 Find-in-page

- `find(text, forward, matchCase, findNext)` → verb `find` → **0x27 kOpFind**
  `{u8 fwd}{u8 matchCase}{u8 findNext}{utf8 text}` (§2; host → `DoFind`).
- `stopFind(clearSelection)` → verb `stopFind` → **0x28 kOpStopFind** `{u8
  clearSelection}` (absent = 1) (§2; host → `DoStopFind`).
- Result event: `CefFindHandler::OnFindResult` sends **0x0e
  kOpFindResult** `{u32 count}{u32 activeOrdinal}{u8 final}` = 9 bytes.
  The plugin emits `findResult
  {count, activeMatchOrdinal, isFinal}` (§4); Dart delivers a `CefFindResult`
  to `onFindResult`. ⌘F/Ctrl+F is surfaced to
  the host via `CefWebView.onFind` — the widget has
  no find bar of its own.

### 7.6 Content zoom

- `setZoomLevel(level)` → verb `setZoomLevel` → **0x26 kOpSetZoom** `{f64
  level}` (§2; host → `DoSetZoom`). `level` is a Chromium zoom LEVEL; the
  factor is `1.2^level` (0 = 100%). The view wires Ctrl/⌘ +/-/0 to step it.
  No result event.

### 7.7 Downloads

- `CefDownloadHandler::OnBeforeDownload` allows the download
  (CEF blocks downloads without a handler) and sends **0x18 kOpDownload** `{utf8
  suggestedName}`. The plugin emits `download {suggestedName}`
  (§4); Dart invokes `onDownload(suggestedName)`.
  Informational only (no reply verb).
- Windows continues with `show_dialog=true`, like macOS's Save panel, so
  nothing is written without the user's say. The dialog opens on
  `%USERPROFILE%\Downloads\<leaf>`, where the leaf is the page's suggested name
  made safe (last path component only; Windows-reserved characters, trailing
  dots/spaces and DOS device names neutralized) and given a ` (n)` suffix when
  that file exists.

## 8. Agent control — CDP-over-pipe + the token-gated loopback relay

An external CDP client (Playwright via `connectOverCDP`, agent-browser) drives a
live, logged-in tile **without** an open debug port: Chromium speaks CDP over an
inherited pipe (`--remote-debugging-pipe` + `--remote-debugging-io-pipes`,
NUL-framed JSON), and a small token-gated LOOPBACK HTTP+WebSocket relay bridges a
standard CDP client to that pipe. Transcribed from the macOS reference
`CdpRelay.swift` (the canonical relay) + `CefProfileHost.swift`
(launchViaPosixSpawn / readCdpLoop / enableAgentControl); the Windows spawn
hands Chromium two inherited anonymous pipes instead of fds. **SINGLE-TILE
scope:** one relay per host (raw browser-level passthrough — the pipe carries
exactly one page target); the per-tile Target-domain filter + N-relay CDP-id
multiplex (the `scopeTargetId` machinery in `CdpRelay.swift`) is a documented
follow-up (the `scope_target_id` seam in `windows/cdp_relay.h`).

### 8.1 Launch — the CDP pipe

The `create` arg `agentControl:true` (§3) switches the host launch mechanism.
`HostProcess::Spawn(agent_control=true)` (windows/host_process.cpp):

- `CreatePipe` × 2 (anonymous). `cmd_pipe`: parent writes CDP → child reads.
  `out_pipe`: child writes CDP → parent reads.
- `SetHandleInformation(HANDLE_FLAG_INHERIT)` on **only the two child-side ends**;
  a `STARTUPINFOEX` `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` naming exactly those two
  (so nothing else leaks). This **composes** with the existing spawn, which
  inherits nothing: the IPC pipe is connected by NAME (`CreateFileW`) and the Job
  Object is assigned post-spawn — neither is an inherited handle. `bInheritHandles
  = TRUE` + `EXTENDED_STARTUPINFO_PRESENT` are added only on this path; the
  non-agent spawn stays byte-identical (the renamed bootstrap exe passes the
  inherited handles through to the host DLL unchanged).
- The child gets `--cdp-io-pipes=<childRead>,<childWrite>` (decimal HANDLE
  values). cef_host's `OnBeforeCommandLineProcessing` (browser process only)
  translates it into Chromium's `--remote-debugging-pipe` +
  `--remote-debugging-io-pipes=<childRead>,<childWrite>`. Mirrors the macOS
  `main.mm` `--cdp-pipe` → `remote-debugging-pipe` injection (fds 3/4 there;
  explicit HANDLE values here).
- The plugin keeps the two PARENT-side ends (`CdpTransport::read`/`write`) and
  runs an always-on `CdpReadLoop` that splits the NUL-framed CDP stream and fans
  each message to the current relay (mirrors `CefProfileHost.readCdpLoop` +
  `deliverCdpToRelays`). `cdpPort` stays 0 — there is no listening socket.

### 8.2 The relay (`windows/cdp_relay.{h,cpp}`, winsock + bcrypt)

A loopback HTTP+WS server (`socket`/`bind` `127.0.0.1:0` → OS-assigned ephemeral
port, accept thread, detached per-connection handlers), a direct winsock port of
`CdpRelay.swift`:

- **Discovery (token-free):** `GET /json/version` · `/json` · `/json/list`
  advertise `webSocketDebuggerUrl = ws://127.0.0.1:<port>/devtools/browser` (the
  token is NOT in the discovery response).
- **Upgrade (token-REQUIRED):** RFC-6455 handshake; `Sec-WebSocket-Accept =
  base64(SHA-1(key + GUID))` via BCrypt. The upgrade is rejected **401** without a
  valid `Authorization: Bearer <token>` header (a `?token=` query is an accepted
  fallback); constant-time compared. A second concurrent client is **503**'d
  (single active client).
- **Bridge:** masked client text frames → `send_to_pipe` (NUL-framed CDP command
  onto `cmd_pipe`); pipe messages → `DeliverToClient` (unmasked text frame to the
  client). Frame/message cap 64 MiB; ping→pong; close handled.
- **Token:** 24 CSPRNG bytes (`BCryptGenRandom`) hex-encoded (48 chars).

Security posture (matches macOS): loopback only, ephemeral unadvertised port,
mandatory token, single client, and the relay exists **only while the grant is
active** (created by `enableAgentControl`, torn down by `disableAgentControl` /
dispose / host-death). Strictly better than raw Chrome's fixed, always-open,
multi-client `--remote-debugging-port`.

### 8.3 Verbs

- `enableAgentControl` → starts (idempotently) the relay for the session's host
  and returns `{wsUrl, token, port}` — the macOS return shape **exactly**:
  `wsUrl = ws://127.0.0.1:<port>/devtools/browser?token=<token>`
  (`CefProfileHost.endpoint`). Errors `no_agent_control` if the session was not
  created with `agentControl:true`.
- `disableAgentControl` → stops the relay (closes the listener + any client,
  invalidates the token); the tile keeps running. Idempotent. Also torn down on
  `dispose` / host death (the reaper stops the relay, joins the CDP reader, and
  closes the pipe ends).

### 8.4 Deferred (N-tile Target multiplex)

Not implemented on Windows (single-tile is passthrough): `Target.getTargetInfo`
targetId resolution (`kOpResolveTargetId 0x36` → `kOpTargetId 0x1b`, still a
logged drop host-side), the deny-by-default / fail-closed / flatten-only
Target-domain filter, and the per-relay CDP-id rewrite/demux that lets N relays
share one browser-wide pipe. See `CdpRelay.swift` + `CefProfileHost+Cdp.swift`
and the filter test vectors
`packages/flutter_cef_macos/test/CdpRelayFilterTests.swift`.
