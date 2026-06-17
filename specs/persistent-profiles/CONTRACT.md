# IMPLEMENTATION CONTRACT — flutter_cef persistent + shared profiles

**Status: FROZEN.** Single source of truth for the implementation workflow. Every layer can be coded from this section alone. All file:line anchors verified against the live tree on 2026-06-16. Where the four input plans disagreed, the **RECONCILED DECISION** is called out inline and is binding.

---

## A. FROZEN WIRE PROTOCOL

### A.1 Frame layout (both directions)

```
OLD:  [u32 bodyLen BE][u8 op][payload...]                    bodyLen = 1 + payloadLen
NEW:  [u32 bodyLen BE][u32 browserId BE][u8 op][payload...]  bodyLen = 4 + 1 + payloadLen
```

- `bodyLen` is big-endian, counts every byte after the 4-byte length prefix: `4 (browserId) + 1 (op) + payloadLen`.
- `browserId` is big-endian `u32`, immediately after the length prefix, before the opcode.
- **`browserId == 0` = process/profile-level.** Used by `kOpReady`, `kOpLog` (process-level logs), and inbound `kOpShutdown`. All other ops carry the originating (outbound) or target (inbound) browserId.
- `browserId` is the **Swift-assigned wire id** (allocated by `CefProfileHost`, starts at 1, monotonic per host). It is NOT CEF's `browser->GetIdentifier()` — that value never appears on the wire (see E).
- No back-compat: `cef_host` ships with `flutter_cef`; both ends change together.
- Minimum valid inbound `bodyLen` is now `5` (4 browserId + 1 op + 0 payload). The read-loop guard changes from `body_len == 0` to `body_len < 5`.

### A.2 RECONCILED OPCODE DECISION (binding)

**CONFLICT:** Native plan + BUILD/DOCS plan assigned `opCreateBrowser=0x13`, `opDisposeBrowser=0x15`. Swift plan assigned `0x36`, `0x37`.

**DECISION: `kOpCreateBrowser = 0x13`, `kOpDisposeBrowser = 0x15`.** Rationale: 3-of-4 plans agree; `0x13`/`0x15` are verified-free gaps inside the existing host→cef_host control band (between `0x12 kOpKey` and `0x14 kOpShutdown` / `0x16 kOpEvalResult`), keeping the table dense and adjacent to `kOpShutdown`. The Swift plan's `0x36`/`0x37` are discarded. **Both `CefWebSession.swift`/`CefProfileHost.swift` and `main.mm` MUST use `0x13`/`0x15`.**

### A.3 Complete opcode table (canonical)

All existing ops are byte-identical to today; the only change is the new `browserId` frame field plus the two new control ops. Direction: `H←C` = cef_host→host (plugin), `H→C` = host→cef_host.

| Byte | Name | Dir | browserId | Payload |
|---|---|---|---|---|
| 0x01 | opPresent | H←C | browser | (empty) — poke `textureFrameAvailable` |
| 0x02 | **opReady** | H←C | **0** | `{u8 readyFlags}` — **CHANGED: now carries 1 byte** (bit0 = ad-hoc/mock-keychain build). See F.5. |
| 0x03 | opCursor | H←C | browser | `{u32 cursorType}` |
| 0x04 | opLog | H←C | browser **or 0** | `{utf8 msg}` (0 = process log) |
| 0x05 | opLoadState | H←C | browser | `{u8 loading}{u8 back}{u8 forward}` |
| 0x06 | opTitle | H←C | browser | `{utf8}` |
| 0x07 | opUrl | H←C | browser | `{utf8}` main-frame address |
| 0x08 | opLoadErr | H←C | browser | `{u32 code}{utf8 "url\ntext"}` |
| 0x09 | opConsole | H←C | browser | `{u32 level}{utf8 "source:line\tmsg"}` |
| 0x0a | opPageStart | H←C | browser | `{utf8 url}` |
| 0x0b | opPageFinish | H←C | browser | `{utf8 url}` |
| 0x0c | opProgress | H←C | browser | `{u32 percent}` |
| 0x0d | opNewWindow | H←C | browser | `{utf8 url}` |
| 0x0e | opFindResult | H←C | browser | `{u32 count}{u32 activeOrdinal}{u8 final}` |
| 0x0f | opJsDialog | H←C | browser | `{u32 id}{u32 type}{u32 msgLen}{msg}{default}` |
| 0x10 | opPointer | H→C | browser | (unchanged) |
| 0x11 | opResize | H→C | browser | `{u32 w}{u32 h}{u32 iosurfaceId}` |
| 0x12 | opKey | H→C | browser | (unchanged) |
| **0x13** | **opCreateBrowser** | **H→C** | **new browser** | `{u32 w}{u32 h}{f64 dpr BE}{u32 iosurfaceId}{utf8 url}` — see A.4 |
| 0x14 | **opShutdown** | H→C | **0** | (empty) — tear down WHOLE process (all browsers) |
| **0x15** | **opDisposeBrowser** | **H→C** | **target browser** | (empty) — close ONE browser, keep process if others remain |
| 0x16 | opEvalResult | H←C | browser | `{utf8 "id:json"}` |
| 0x17 | opChannelMsg | H←C | browser | `{utf8 "name:message"}` |
| 0x18 | opDownload | H←C | browser | `{utf8 suggestedName}` |
| 0x19 | opImeBounds | H←C | browser | `{u32 x}{u32 y}{u32 w}{u32 h}` |
| 0x1a | opCookies | H←C | browser | `{u32 id}{utf8 json-array}` |
| 0x20 | opNavigate | H→C | browser | `{utf8 url}` |
| 0x21 | opReload | H→C | browser | (empty) |
| 0x22 | opStop | H→C | browser | (empty) |
| 0x23 | opBack | H→C | browser | (empty) |
| 0x24 | opForward | H→C | browser | (empty) |
| 0x25 | opExecuteJs | H→C | browser | `{utf8 code}` |
| 0x26 | opSetZoom | H→C | browser | `{f64 level}` |
| 0x27 | opFind | H→C | browser | `{u8 fwd}{u8 matchCase}{u8 findNext}{utf8}` |
| 0x28 | opStopFind | H→C | browser | `{u8 clearSelection}` |
| 0x29 | opJsDialogResp | H→C | browser | `{u32 id}{u8 ok}{utf8 text}` |
| 0x2a | opEvalReturning | H→C | browser | `{u32 id}{utf8 code}` |
| 0x2b | opAddChannel | H→C | browser | `{utf8 name}` |
| 0x2c | opSetCookie | H→C | browser | `{utf8 url\0name\0value\0domain\0path}` — acts on shared jar |
| 0x2d | opClearCookies | H→C | browser | (empty) — clears the **shared** jar (all browsers) |
| 0x2e | opVisitCookies | H→C | browser | `{u32 id}{utf8 url}` — reply `opCookies` stamps this browserId |
| 0x2f | opDeleteCookie | H→C | browser | `{utf8 url\0name}` — shared jar |
| 0x30 | opImeSetComp | H→C | browser | `{utf8 text}` |
| 0x31 | opImeCommit | H→C | browser | `{utf8 text}` |
| 0x32 | opImeCancel | H→C | browser | (empty) |
| 0x33 | opShowDevTools | H→C | browser | (empty) |
| 0x34 | opLoadTrusted | H→C | browser | `{utf8 url}` |
| 0x35 | opSetVisible | H→C | browser | `{u8 visible}` |

**Free bytes remaining after this change:** `0x1b–0x1f`, `0x36+`.

### A.4 opCreateBrowser payload — RECONCILED (binding)

**CONFLICT:** PLAN prose (line 66) and Swift plan put `allowedSchemes` in the `opCreateBrowser` payload. Native plan keeps `allowedSchemes` a process CLI arg (`--allowed-schemes`) because `g_allowed_schemes` is frozen process-global.

**DECISION: `allowedSchemes` stays a PROCESS CLI arg (`--allowed-schemes`); it is NOT in the opCreateBrowser payload.** Rationale: the FROZEN decision explicitly lists `g_allowed_schemes` as "keep process-global." All browsers in a profile share one allowlist (out of scope to make it per-browser). This overrides the PLAN's prose at line 66 and the Swift plan's payload layout.

**Canonical `opCreateBrowser` payload (exactly, in order):**
```
{u32 width BE}{u32 height BE}{f64 dpr BE}{u32 iosurfaceId BE}{utf8 url}
```
- `width`/`height`: logical (DIP) pixels.
- `dpr`: IEEE-754 double, big-endian (matches `appendF64` / `ReadF64BE` already in both codebases).
- `iosurfaceId`: the global IOSurface id this browser's `CefWebSession` allocated.
- `url`: remaining bytes; empty → `"about:blank"`.
- **No allowedSchemes, no trailing `\0`-separated field.** (The Swift plan's "`\0`{utf8 allowedSchemes}" suffix is DROPPED.)
- Minimum payload length: `4 + 4 + 8 + 4 = 20` bytes (url may be empty).

### A.5 Control-op semantics

- **opCreateBrowser (0x13):** frame `browserId` = the NEW id Swift assigned. cef_host creates a windowless browser bound to that id + the given IOSurface/geometry/url. The initial browser is NO LONGER created at startup from `--url`.
- **opDisposeBrowser (0x15):** frame `browserId` = target. Closes that one browser; process survives if other browsers remain.
- **opShutdown (0x14):** frame `browserId` = 0. Tears down the whole process (all browsers). Sent when the last browser is disposed, or as the host-shutdown signal.

---

## B. CLI ARG CONTRACT (cef_host, after the change)

| Arg | Scope | Status | Maps to |
|---|---|---|---|
| `--ipc=<path>` | process | **STAYS** | IPC Unix socket |
| `--cdp-port=<port>` | process | **STAYS** | `settings.remote_debugging_port` (ephemeral-only; rejected with named profile in Swift) |
| `--allowed-schemes=<csv>` | process | **STAYS** | `g_allowed_schemes` (shared by all browsers in the process) |
| `--profile-dir=<abs path>` | process | **NEW** | `settings.root_cache_path` (empty/omitted → ephemeral temp; see below) |
| `--url=<url>` | per-view | **REMOVED** → moves into opCreateBrowser |
| `--width=<px>` | per-view | **REMOVED** → opCreateBrowser |
| `--height=<px>` | per-view | **REMOVED** → opCreateBrowser |
| `--dpr=<scale>` | per-view | **REMOVED** → opCreateBrowser |
| `--iosurface-id=<id>` | per-view | **REMOVED** → opCreateBrowser |

**`--profile-dir` rules (binding):**
- Per-PROCESS / per-profile. One `root_cache_path` shared by all browsers in the process. A per-browser cache would defeat shared login.
- Swift ALWAYS passes `--profile-dir=<abs path>` — both for named profiles (persistent App-Support dir) and ephemeral (a unique throwaway temp dir Swift creates). **ONE code path; cef_host has no ephemeral special-case.**
- cef_host sets `root_cache_path = profile_dir` if non-empty; only as a fallback (defensive, should not happen since Swift always passes it) does cef_host synthesize a per-pid temp dir. The legacy unconditional per-pid temp block (`main.mm:1481–1487`) is replaced by "use `--profile-dir`."
- cef_host unconditionally sets `settings.persist_session_cookies = true` (harmless for ephemeral; required for "stay signed in").

**Defense-in-depth (advisory, non-authoritative — Swift is the gate):**
- If both `--cdp-port` and `--profile-dir` (non-empty) arrive, cef_host ignores `--cdp-port` and `SendLog(0, ...)`. (Swift already rejects this combination; this is belt-and-suspenders.)
- In a `CEF_HOST_ADHOC` build, if `--profile-dir` is set and `FLUTTER_CEF_ALLOW_INSECURE_PROFILE` is absent in env, `SendLog(0, "warning: persistent profile under mock keychain")`. Advisory only.

---

## C. METHOD-CHANNEL CONTRACT (Dart ↔ native)

**Exactly ONE change to the boundary: a new optional `'profile'` key in the `'create'` args map. Nothing else changes.**

`'create'` args map (canonical, in the order assembled by `_createSession`):
```
{
  'sessionId': String,
  'url': String,
  'width': int,
  'height': int,
  'dpr': double,
  if (allowedSchemes != null && allowedSchemes.isNotEmpty) 'allowedSchemes': String,  // csv, lowercased
  if (enableCdp) 'enableCdp': true,
  if (profile != null && profile!.isNotEmpty) 'profile': String,   // NEW — omitted ⇒ ephemeral
}
```
- **Backward-compat is structural:** when `profile` is null/empty the `'profile'` key is ABSENT, so the map is byte-identical to today. Native treats "no `profile`" exactly as "no `--profile-dir`" = ephemeral = today's behavior.
- `'create'` RESULT shape is UNCHANGED: `{textureId, width, height, cdpPort}`. (`cdpPort` now comes from the host, non-zero only for ephemeral hosts since named+CDP is rejected.)
- All other verbs (`navigate`, `resize`, `dispose`, `pointer`, `key`, `reload`, `executeJavaScript`, cookies, IME, find, …) and all events (`cursor`, `loadingState`, `title`, `url`, `consoleMessage`, `jsDialog`, `cookies`, `imeCompositionBounds`, …) are UNCHANGED. The `browserId` dimension lives entirely below the method channel (plugin ↔ cef_host).
- **No change** to `flutter_cef_platform_interface` (`flutter_cef_platform.dart`, `method_channel_flutter_cef.dart`): the `create` arg map is `Map<String,dynamic>` assembled in `_createSession`; adding a key needs no interface change (same as `allowedSchemes`/`enableCdp`).

---

## D. DART API (exact new signatures)

### `CefWebController` (`lib/src/cef_web_controller.dart`)

```dart
class CefWebController {
  CefWebController({String? sessionId, this.profile})
      : sessionId = sessionId ?? 'cef-${_counter++}' {
    _bySession[this.sessionId] = this;
    _installHandler();
  }

  final String sessionId;

  /// The persistent, shared profile this view's login lives in, or null for an
  /// ephemeral (in-memory, throwaway) session. Views constructed with the same
  /// non-null [profile] share one host process → one cookie jar → one login,
  /// and that login survives cef_host/host-app relaunch. Null (the default) is
  /// today's behaviour.
  final String? profile;
  // ... rest unchanged
}
```

- **`profile` is a controller FIELD, NOT a `create()` parameter.** `create()`'s signature is UNCHANGED; it reads `this.profile`. (Decision: per-controller identity, keeps create() idempotent/adopt-in-flight clean, and is the single source of truth for an adopted controller.)
- `_createSession` adds the conditional map entry (C above).
- Add a debug `assert` at the top of `create()`'s body (first statement):
  ```dart
  assert(!(enableCdp && profile != null && profile!.isNotEmpty),
    'enableCdp cannot be combined with a named profile (CDP is an '
    'unauthenticated localhost port that could read the shared cookie jar).');
  ```

### `CefWebView` (`lib/src/cef_web_view.dart`)

```dart
const CefWebView({
  super.key,
  required this.url,
  this.controller,
  this.focusNode,
  this.placeholder,
  this.allowedSchemes,
  this.enableCdp = false,
  this.profile,
}) : assert(!(enableCdp && profile != null),
        'enableCdp cannot be combined with a named profile: CDP exposes an '
        'unauthenticated localhost port that could read the profile\'s shared '
        'cookie jar. Use one or the other.');

/// The persistent, shared browser profile this view's login lives in. Views with
/// the same non-null [profile] share one signed-in profile that survives relaunch.
/// Null (default) is ephemeral. Ignored when an external [controller] is supplied
/// (that controller carries its own profile). Mutually exclusive with [enableCdp].
final String? profile;
```

- Forward to the internally-owned controller at field-init (`cef_web_view.dart:93–94`):
  ```dart
  late final CefWebController _controller =
      widget.controller ?? CefWebController(profile: widget.profile);
  ```
- The `create()` call site (`cef_web_view.dart:180–186`) is **UNCHANGED** — `profile` rides on the controller, not the call. Do NOT add `profile:` there.

---

## E. NATIVE EDIT LIST (`main.mm`) — ordered, concrete

`process_helper.mm`: **NO CHANGES** (its renderer-side message router is per-renderer-process and browser-agnostic).

**Step 1 — Opcodes (near line 105).** Add:
```cpp
constexpr uint8_t kOpCreateBrowser  = 0x13;  // {u32 w}{u32 h}{f64 dpr}{u32 iosurfaceId}{utf8 url}; frame browserId = NEW id
constexpr uint8_t kOpDisposeBrowser = 0x15;  // {} close ONE browser
```
Annotate `kOpShutdown = 0x14`: now "tear down whole PROCESS, frame browserId 0."

**Step 2 — Slot struct + maps; delete per-view globals.** Define a `Slot` struct holding the migrated per-browser state:
```cpp
struct Slot {
  uint32_t browser_id = 0;                 // Swift wire id
  CefRefPtr<CefBrowser> browser;
  std::mutex surface_mutex;
  IOSurfaceRef surface = nullptr;
  int width = 800, height = 600;
  double dpr = 1.0;
  bool popup_visible = false;
  CefRect popup_rect; std::vector<uint8_t> popup_buf; int popup_w = 0, popup_h = 0;
  std::multiset<std::string> trusted_pending;
  std::map<uint32_t, CefRefPtr<CefJSDialogCallback>> dialogs;
  uint32_t dialog_next = 1;
};
```
Add routing maps (process-global):
```cpp
std::mutex g_slots_mutex;
std::map<int /*cef GetIdentifier()*/, std::shared_ptr<Slot>> g_slots_by_cef_id;  // paint/display lookup
std::map<uint32_t /*wire id*/, std::shared_ptr<Slot>>       g_slots_by_wire_id;   // inbound IPC routing
```
**DELETE** these globals: `g_surface_mutex` (133), `g_surface` (134), `g_width/g_height/g_dpr` (135–137), `g_browser` (139), `g_trusted_pending` (161), `g_dialogs`/`g_dialog_next` (165–166), `g_popup_*` (204–208), `g_initial_url` (declared ~774). **KEEP process-global:** `g_ipc_fd`+`g_ipc_write_mutex` (130–131), `g_allowed_schemes` (148), `g_channels` (171), `g_cdp_port`, `CefInitialize` settings.

Map discipline: **mutated only on the CEF UI thread** (insert in `DoCreateBrowser`, erase in `OnBeforeClose`). Readers (reader thread, paint threads) take `g_slots_mutex`, copy the `shared_ptr`, release the lock, then operate. Add helper `std::shared_ptr<Slot> SlotForBrowser(CefBrowser* b)` (locks, looks up by `b->GetIdentifier()`).

**Step 3 — IPC primitives gain `browser_id` (lines 240–281, 1028–1056).** `SendFrame` signature → `SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload, uint32_t payload_len)`. New `body_len = 4 + 1 + payload_len`; frame layout `[4..7]=BE(browser_id)`, `[8]=opcode`, payload at `frame.data()+9`, buffer `4 + body_len`. Thread `browser_id` through ALL wrappers (`SendLog`, `SendUtf8`, `SendLoadState`, `SendCodePlusUtf8`, every inline `SendFrame`). **DECISION: explicit threading (option A), no thread-local current-browser.** Callbacks that have a `CefBrowser*` use `slot->browser_id`; `kOpReady`/process logs use `0`. `HostCookieVisitor` (1028–1044) stores the originating `browser_id` (add a field) so its `kOpCookies` reply routes correctly.

**Step 4 — `HostRenderHandler` (351–518) holds `shared_ptr<Slot>`.** Ctor takes the slot. Every callback derefs `slot_` instead of globals, under `slot_->surface_mutex`:
- `GetViewRect` → `slot_->width/height`.
- `GetScreenInfo` → `slot_->dpr`.
- `OnPaint`/`OnAcceleratedPaint`/`OnPopupShow`/`OnPopupSize`/`CopyAccelToPopupBuf`/`CompositeSoftwareLocked` → `slot_->surface`, `slot_->popup_*`; present with `SendFrame(slot_->browser_id, kOpPresent, …)`. Ignore the passed `CefBrowser*` (each handler owns one slot — no map lookup on the hot path).
- `OnImeCompositionRangeChanged` → `SendFrame(slot_->browser_id, kOpImeBounds, …)`.

**Step 5 — `HostClient` (520–772) holds `shared_ptr<Slot>`.** Ctor `HostClient(std::shared_ptr<Slot> slot)`; builds `rh_ = new HostRenderHandler(slot_)`. All dialog/trusted/display/load callbacks use `slot_` and stamp `slot_->browser_id`. JS dialogs use `slot_->dialogs`/`slot_->dialog_next`; `OnResetDialogState` clears only `slot_->dialogs`. `OnBeforeBrowse` consults `slot_->trusted_pending`. `OnLoadStart` channel-shim reinstall loop is UNCHANGED (`g_channels` stays global).

**Step 6 — `OnContextInitialized` (835–862): strip browser creation.** DELETE lines 839–858 (window_info/settings/`CreateBrowserSync`/`g_browser`). Body becomes:
```cpp
void OnContextInitialized() override {
  CEF_REQUIRE_UI_THREAD();
  if (std::getenv("FLUTTER_CEF_DEBUG")) fprintf(stderr, "[cef_host] OnContextInitialized\n");
  uint8_t ready_flags = 0;
#ifdef CEF_HOST_ADHOC
  ready_flags |= 0x01;  // bit0 = ad-hoc / mock-keychain build
#endif
  SendFrame(/*browser_id=*/0, kOpReady, &ready_flags, 1);
}
```

**Step 7 — New `DoCreateBrowser` (UI thread).** Signature `DoCreateBrowser(uint32_t wire_id, int w, int h, double dpr, uint32_t sid, std::string url)`. Make a `Slot`, set `browser_id=wire_id`, `width/height` (≥1), `dpr`, `surface = sid ? IOSurfaceLookup(sid) : nullptr` (log on failure). Insert into `g_slots_by_wire_id` under lock. `CefWindowInfo wi; wi.SetAsWindowless(0);` + `#ifdef CEF_HOST_MULTIPROCESS wi.shared_texture_enabled = true; #endif`; `CefBrowserSettings bs; bs.windowless_frame_rate = 60;`. `client = new HostClient(slot)`; `br = CreateBrowserSync(wi, client, url, bs, nullptr, nullptr)`; `slot->browser = br`; insert `g_slots_by_cef_id[br->GetIdentifier()] = slot` under lock.

**Step 8 — New `DoDisposeBrowser(uint32_t wire_id)` (UI thread).** Look up slot in `g_slots_by_wire_id`; if found, `slot->browser->GetHost()->CloseBrowser(true)`. Actual map-erase + surface release happen in `OnBeforeClose`.

**Step 9 — `OnBeforeClose` (729–731) centralizes cleanup.** After `router_->OnBeforeClose(browser)`: erase both map entries for this slot under `g_slots_mutex`; under `slot->surface_mutex` set `slot->surface = nullptr` THEN `CFRelease` the old surface; null `slot->browser` (break the HostClient→Slot→CefBrowser→HostClient cycle). The last `shared_ptr<Slot>` drops once in-flight paint refs drain.

**Step 10 — `DoShutdown` (1155–1161) closes ALL slots.** Copy all slots under lock, `CloseBrowser(true)` each, then `CefQuitMessageLoop()`. The existing reader-join + fd-close (1524–1536) + `CefShutdown` (1537) sequence is UNCHANGED.

**Step 11 — `IpcReadLoop` (1164–1331) header decode + routing.** New decode:
```cpp
if (!ReadAll(g_ipc_fd, hdr, 4)) break;
uint32_t body_len = ReadU32BE(hdr);
if (body_len < 5 || body_len > (64u<<20)) break;   // was ==0
std::vector<uint8_t> body(body_len);
if (!ReadAll(...)) break;
uint32_t wire_id = ReadU32BE(body.data());
uint8_t opcode   = body[4];
const uint8_t* p = body.data() + 5;
uint32_t plen    = body_len - 5;
auto slot = LookupWireId(wire_id);   // null for 0/unknown
```
Per-op:
- `kOpCreateBrowser`: parse `{w,h,dpr,sid,url}` (`plen >= 20`; guard `dpr<=0||dpr>8 → 1`; empty url → `"about:blank"`); `CefPostTask(TID_UI, BindOnce(&DoCreateBrowser, wire_id, w,h,dpr,sid,url))`. Ignore the slot lookup.
- `kOpDisposeBrowser`: `if(slot) CefPostTask(TID_UI, BindOnce(&DoDisposeBrowser, wire_id))`.
- `kOpShutdown`: `CefPostTask(&DoShutdown); return;` (arrives with `wire_id==0`).
- **Every per-browser op:** `if(!slot) break;` then `BindOnce(&DoXxx, slot, …)` (slot is the new leading bound arg; the `shared_ptr` copy keeps the slot alive until the UI task runs — closes the dispose/in-flight race). Re-base nothing else; payload offsets are unchanged relative to `p`.
- EOF path (1330): `CefPostTask(&DoShutdown)` UNCHANGED — socket loss kills the whole process.

All `Do*` helpers (`DoResize`, `DoNavigate`, `DoNavigateTrusted`, `DoReload`, …) gain a leading `const std::shared_ptr<Slot>&` and operate on it. Cookie ops (`DoSetCookie`/`DoClearCookies`/`DoVisitCookies`/`DoDeleteCookie`) still hit `CefCookieManager::GetGlobalManager` (= shared profile jar) and take `slot` only to stamp the reply browserId; comment that clear/delete affect the whole shared jar by design.

**Step 12 — `main` arg parsing (1405–1437) + settings (1481–1487).**
- DELETE the per-view `ArgValue` reads for `url/width/height/dpr/iosurface-id` and the `g_width/g_height/g_dpr/g_surface/g_initial_url` assignments (1405–1437). KEEP `--ipc`, `--cdp-port`, `--allowed-schemes` parsing.
- ADD `std::string profile_dir = ArgValue(argc, argv, "profile-dir");`.
- REPLACE the per-pid cache block (1481–1487) with:
  ```cpp
  std::string cef_cache = !profile_dir.empty()
      ? profile_dir
      : std::string([NSTemporaryDirectory() UTF8String]) + "flutter_cef_cache_" +
        std::to_string([[NSProcessInfo processInfo] processIdentifier]);
  CefString(&settings.root_cache_path) = cef_cache;
  settings.persist_session_cookies = true;
  ```
- Update the `clean_argv` comment (1446–1448) to drop the removed switches.
- ADHOC `#ifdef` blocks (787–794 mock-keychain, 805–818 Mach-port, 1454–1465 no_sandbox) are UNCHANGED.
- Update header doc (29–34): new process-arg list + new wire-frame description.

---

## F. SWIFT EDIT LIST

### F.1 New file `macos/Classes/CefProfileHost.swift`

Owns `{Process, listen/conn sockets, write lock, pendingFrames, reader thread}`, keyed by profileId. Absorbs the process layer from today's `CefWebSession` (spawn/socket/reader: CWS `106–115, 303–320, 364–460, 462–581`).

**Wire constants live here** (`static let opCreateBrowser: UInt8 = 0x13`, `opDisposeBrowser: UInt8 = 0x15`, `opShutdown: UInt8 = 0x14`, `opReady: UInt8 = 0x02`, `opLog: UInt8 = 0x04`, `opResize: UInt8 = 0x11`).

Fields: `profileId`, `profileDir`, `isEphemeral`, `cdpPort`; `process`, `listenFd`, `connFd`, `socketPath`, `writeLock`, `pendingFrames`, `running`, `readerStarted`, `readerDone`; plus `browsersLock`, `browsers: [UInt32: CefWebSession]`, `nextBrowserId: UInt32 = 1`, `ready`, `pendingCreates: [() -> Void]`, `adhocHost`, `createEnqueued: Set<UInt32>` (guarded by `writeLock`), and `onInsecureProfileRefused: (() -> Void)?` callback.

Public surface:
```swift
init(profileId: String, profileDir: String, isEphemeral: Bool)
func spawn(cefHostPath: String, enableCdp: Bool) -> Bool         // --ipc --cdp-port --profile-dir
func createBrowser(_ session: CefWebSession, url: String, allowedSchemes: String) -> UInt32
func send(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8])  // frames [bodyLen][browserId][op][payload]
func removeBrowser(_ browserId: UInt32) -> Int                   // opDisposeBrowser; returns remaining count
func shutdown()                                                  // opShutdown(0), join reader, free, terminate
```

- `spawn`: builds argv with `--ipc`, `--profile-dir=<profileDir>` always, and `--cdp-port=<port>` only when `enableCdp` (port picked here; CDP only reachable for ephemeral hosts since named+CDP is rejected upstream). `--allowed-schemes` is passed per-CREATE? No — **RECONCILED: `--allowed-schemes` is a process arg.** Since allowedSchemes is per-process and a host may serve N browsers, the host is spawned with the allowedSchemes of the FIRST browser that triggers the spawn; document that all browsers in a profile share that allowlist. (Pass it on the `spawn` call: `spawn(cefHostPath:, enableCdp:, allowedSchemes:)`.)
- `send`: frame `[u32 bodyLen=4+1+payload.count][u32 browserId][op][payload]`. If `connFd < 0`, queue into `pendingFrames` EXCEPT drop an `opResize` whose browserId is not yet in `createEnqueued` (its create carries current geometry).
- `createBrowser`: under `browsersLock`, `id = nextBrowserId++`, `browsers[id]=session`, `session.attach(host:self, browserId:id)`. Build `opCreateBrowser` payload from `session.surfaceId`, `session.width/height/dpr`, `url`. If `ready`, `send(id, opCreateBrowser, payload)` (and insert id into `createEnqueued`); else append a closure to `pendingCreates`.
- Reader loop (`acceptAndRead` ported): read `[u32 bodyLen]`, guard `bodyLen <= 4` (must hold browserId+op), read body, `bid = beU32(body,0)`, `op = body[4]`, `payload = Array(body[5...])`. If `bid==0` → `handleProcessFrame(op, payload)`; else look up `browsers[bid]` under `browsersLock` and call `session.handleFrame(op, payload)`.
- `handleProcessFrame`: `opReady` → parse `readyFlags` byte (`adhocHost = (flags & 0x01) != 0`); apply the safety-rail decision (F.5) BEFORE flushing; set `ready=true`; run+clear `pendingCreates`. `opLog` → `NSLog("[cef_host:\(profileId)] …")`. Else log-and-drop.
- `shutdown`: the deterministic dispose discipline hoisted from CWS `278–320`: `send(0, opShutdown, [])`; flag `running=false`; `shutdown(connFd/listenFd, SHUT_RDWR)` to unblock the reader; `readerDone.wait(timeout: .now()+2)` to JOIN; close fds; `unlink(socketPath)`; if `isEphemeral`, `removeItem(atPath: profileDir)`; `terminateProcess()`. `deinit` keeps a minimal net (terminate, close fds, unlink) for partial-spawn failure.

### F.2 Slimmed `CefWebSession.swift`

**KEEPS:** `FlutterTexture` + `copyPixelBuffer`; IOSurface/CVPixelBuffer/`bufferLock`; `allocateBuffers`; geometry `width/height/dpr`; `resize` (reallocs surface locally, then `host.send(browserId, opResize, payload)`); `textureId`+`registry` (registration stays in `init`); all event callbacks; `sessionId`; the per-op payload builders (`appendU32/appendF64/readU32` stay); the per-view opcode constants it needs to NAME ops.

**DROPS:** `process`, `listenFd`, `connFd`, `socketPath`, `writeLock`, `pendingFrames`, `running`, `readerStarted`, `readerDone`, `cefHostPath`, `enableCdp`, `allowedSchemes`; `pickFreeTcpPort`, `setupSocketAndSpawn`, `acceptAndRead`, `terminateProcess`, `frameBytes`, the old `sendFrame`, `readAll`/`writeAll`. The `deinit` safety net (313–320) is DELETED (no fds/process to clean).

**ADDS:**
```swift
private weak var host: CefProfileHost?
private(set) var browserId: UInt32 = 0
var surfaceId: UInt32 { bufferLock.lock(); defer { bufferLock.unlock() }
                        return ioSurface.map { IOSurfaceGetID($0) } ?? 0 }
var w: Int { width }; var h: Int { height }; var scale: CGFloat { dpr }  // expose for opCreateBrowser
func attach(host: CefProfileHost, browserId: UInt32) { self.host = host; self.browserId = browserId }
private func sendFrame(_ op: UInt8, _ payload: [UInt8] = []) { host?.send(browserId, op, payload) }
func handleFrame(_ op: UInt8, _ payload: [UInt8]) { /* the switch from CWS:499-579, offsets re-based to 0 */ }
```
- Every existing verb body (`navigate`, `reload`, `sendPointer`, `setCookie`, …) is UNCHANGED — they call `sendFrame(op, payload)`, now routed through the host.
- `handleFrame` contains the inbound `switch` extracted from CWS `499–579`, re-based so offsets start at 0 in `payload` (host already stripped browserId+op): e.g. old `readU32(body,1)` → `readU32(payload,0)`. `opPresent` keeps the main-thread `textureFrameAvailable(textureId)` hop.
- `init` no longer spawns: allocate buffers + register texture, return. `dispose()` becomes thin: `if textureId != 0 { registry?.unregisterTexture(textureId); textureId = 0 }; bufferLock.lock(); pixelBuffer = nil; ioSurface = nil; bufferLock.unlock()`.

### F.3 `FlutterCefPlugin.swift` — two-level registry + create/dispose

Replace `sessions` (14) with:
```swift
private var profiles: [String: CefProfileHost] = [:]   // key: profile name OR "~ephemeral~"+sessionId
private var sessions: [String: CefWebSession] = [:]     // sessionId -> session (verb routing; UNCHANGED usage)
private var sessionHost: [String: CefProfileHost] = [:] // sessionId -> its host
private var sessionKey:  [String: String] = [:]         // sessionId -> profiles[] key, for teardown
```
- `withSession` (126–128) and ALL verb `case`s (27–124) are UNCHANGED.
- `create()` flow: parse `sessionId/registry/cefHost` (unchanged); `let profile = a["profile"] as? String` (nil/empty → ephemeral); `enableCdp`. Dispose any prior session with this id (route through host). Resolve `(profileDir, isEphemeral)` via F.4. Safety rails:
  - **(a) CDP×named profile:** if `enableCdp && namedProfile` → `FlutterError("cdp_with_profile", …)`; return.
  - **(c) P1 single-view guard:** if `namedProfile && profiles[name]` already has a live browser → `FlutterError("profile_in_use", …)`. (Lifted in P2.)
  - The ad-hoc-build refusal (b) is async, handled at opReady (F.5).
- Resolve-or-spawn host: `key = namedProfile ? name : "~ephemeral~"+sessionId`; `host = profiles[key] ?? spawn-new`; `profiles[key] = host`.
- Construct the slimmed session (no spawn). Wire ALL event callbacks exactly as 161–226 (UNCHANGED — they close over `sessionId`).
- `let bid = host.createBrowser(session, url:url, allowedSchemes:allowedSchemes)`; store `sessions/sessionHost/sessionKey`. Result `{textureId, width, height, cdpPort: host.cdpPort}`.
- `destroy` (259–265): look up session + host + key; remove from all three maps; `let remaining = host.removeBrowser(s.browserId)` (sends opDisposeBrowser, unregisters under `browsersLock`). **ORDERING (binding):** if `remaining == 0`, call `host.shutdown()` (joins reader — no more inbound) FIRST, then `s.dispose()`, then `profiles[key] = nil`. If `remaining > 0`, `removeBrowser` already unregistered the browser under lock, so `s.dispose()` runs safely while the shared reader keeps serving siblings.

### F.4 Profile-dir computation (FCP helper or `ProfilePaths` enum)

```swift
func resolveProfileDir(_ profile: String?) -> (dir: String, ephemeral: Bool)
```
- Ephemeral (null/empty): `dir = NSTemporaryDirectory() + "flutter_cef_ephem_" + UUID().uuidString`, created `0700`, `ephemeral = true`.
- Named: sanitize to `[A-Za-z0-9._-]` (others → `_`); `dir = <AppSupport>/<Bundle.main.bundleIdentifier ?? "flutter_cef">/flutter_cef/profiles/<safe>`, created `withIntermediateDirectories: true, [.posixPermissions: 0o700]`, then re-`chmod 0700` the leaf; `ephemeral = false`.
- ONE code path downstream: both yield `(dir, ephemeral)`; the host always receives `--profile-dir=<dir>`. Ephemeral dirs are removed on `shutdown()`.

### F.5 Dev safety-rail — CHOSEN DETECTION MECHANISM (binding)

**DECISION: the host reports its ADHOC compile flag in the `opReady` payload (browserId 0), one byte, bit0 = ad-hoc.** Rejected alternatives: a Swift compile flag mirroring `CEF_HOST_ADHOC` (Swift and the host are built independently and the host can be swapped via `FLUTTER_CEF_HOST` — can disagree, unsound); an Info.plist value (fragile, lies under host-swap); `strings`/signature inspection (brittle). The opReady byte is authoritative (the running binary speaks), survives host swaps, and reuses the existing opReady signal.

**Flow (the no-creds-leak safety window):**
1. `spawn()` always starts with the resolved `--profile-dir`.
2. The host's `OnContextInitialized` creates NO browser — nothing loads, nothing is written to the cache until the first `opCreateBrowser`. That's the safety window.
3. `createBrowser` queues into `pendingCreates` if not ready. On `opReady{flags}`, `handleProcessFrame` sets `adhocHost`. BEFORE flushing `pendingCreates`: if `adhocHost && !isEphemeral && !allowInsecure` (`allowInsecure = env["FLUTTER_CEF_ALLOW_INSECURE_PROFILE"] == "1"`), do NOT send the creates — invoke `onInsecureProfileRefused`, which makes FCP: tear this host down, `NSLog` the warning, recreate an EPHEMERAL host for the same session (recompute dir/key via F.4), and re-issue `createBrowser`. Because nothing was written to the persistent dir, the refusal leaks no creds. Otherwise flush the creates.

### F.6 CDP rejection

Enforced in FCP `create()` (rail (a) above) — `enableCdp && namedProfile` → `FlutterError("cdp_with_profile", …)` before spawn, so `--cdp-port` and `--profile-dir` never co-arrive. Mirrored by Dart asserts (D) and an advisory native guard (B).

---

## G. BUILD / DOCS / TESTS EDIT LIST

**`main.mm` doc/header:**
- Lines 29–34: replace per-view-args + wire-format doc with the process-args list (`--ipc --cdp-port --profile-dir --allowed-schemes`) and the new frame `[u32 bodyLen][u32 browserId][u8 op][payload]`. Note opReady waits for opCreateBrowser.
- Annotate `kOpShutdown` (105) as process-level.

**`PORTING.md`:**
- Spawn bullet (~57–58): "one `cef_host` subprocess per **profile** (`--ipc --cdp-port --profile-dir`), then N browsers via `opCreateBrowser` carrying `url,width,height,dpr,iosurface-id` + browserId. Null/empty `--profile-dir` = ephemeral throwaway. `--profile-dir` is per-process; the shared cache is what makes login shared."
- IPC transport seam row: wire format → `[u32 browserId][opcode][payload]` (`browserId 0 = process-level`). Keep length-prefixed framing.
- App/run-loop seam row: note the cache path is now the caller-supplied `--profile-dir` (per-profile, persistent) rather than a per-pid temp dir.

**`README.md`:**
- Add a `## Profiles` H2 between `## Security` and `## Roadmap`: ephemeral-by-default; `profile:` opt-in; persistence path `<AppSupport>/<bundleId>/flutter_cef/profiles/<name>` (0700, `persist_session_cookies` on); shared = one process/cookie jar (`clearCookies` clears for all); secrets-at-rest need a signed `CEF_HOST_ADHOC=OFF` build (ad-hoc downgrades a named profile to ephemeral, override `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1`); "Chromium Safe Storage" Keychain item / ACL isolation; FileVault is the at-rest backstop; `localStorage`/IndexedDB plaintext; CDP incompatible with a profile.
- API snippet (7–17): add a `profile:` example.
- Security cache bullet (~141–142): append "— a named `profile:` uses a stable 0700 dir under Application Support (see Profiles)."

**`CHANGELOG.md`:** new `## 0.2.0` section above `## 0.1.3`: persistent shared profiles (`CefWebView/CefWebController(profile:)`), secrets-at-rest safety rail, CDP×profile rejection, internal browserId IPC dimension + opCreateBrowser/opDisposeBrowser; "omitting `profile:` is byte-for-byte today's behavior."

**`build_cef_host.sh` / `bundle_cef_host.sh`:** **NO functional change.** Optional one-line doc comment in `build_cef_host.sh` `CEF_HOST_ADHOC` block noting OFF is required for at-rest OSCrypt / persistent profiles. No new entitlements.

**Example app:** `example/lib/main.dart` — add a profile-name field/toggle threaded into `CefWebView(profile:)` (the one REQUIRED example change). `DebugProfile.entitlements`/`Release.entitlements` — comment-only (no new entitlement; host is unsandboxed, App Support writable, login Keychain by ACL). No committed `profiles/` dir.

**Tests:**
- Dart (mock MethodChannel): (1) `create()` forwards `profile` when set, omits when null (mirror the `allowedSchemes` present/absent pair); (2) `CefWebView(profile:)`/`CefWebController(profile:)` thread the name into create args; (3) `enableCdp + profile` triggers the assert (debug). Existing `cef_web_controller_test.dart`/`cef_web_view_test.dart` arg-map tests keep passing (additive); add profile assertions rather than rewrite.
- Swift unit (host-logic only, no CEF): (4) profile-path computation (`<AppSupport>/<bundleId>/flutter_cef/profiles/<id>`, 0700, ephemeral unique path); (5) safety-rail predicate table (named+adhoc+env-unset→ephemeral+warn; named+adhoc+env=1→persistent; named+signed→persistent; null→ephemeral); (6) frame browserId round-trip (`bodyLen == 4+1+payloadLen`, browserId survives, 0 routes process-level).
- Deferred to signed-host smoke gate (PLAN §125): real OSCrypt, Keychain prompt, cross-relaunch persistence.

---

## H. CROSS-LAYER CONSISTENCY CHECKS

### H.1 Opcode bytes — VERIFIED IDENTICAL across layers
- `opCreateBrowser = 0x13`, `opDisposeBrowser = 0x15` in BOTH `main.mm` (constants) AND Swift (`CefProfileHost` statics). **The Swift plan's 0x36/0x37 are overridden** (A.2).
- `opShutdown = 0x14` unchanged (both); now frame browserId 0.
- `opReady = 0x02` unchanged byte; **payload grows by 1 byte** (readyFlags) in both `main.mm` (Step 6) and Swift (`handleProcessFrame`). Both ends must agree the byte is present.
- All other opcodes byte-identical to the verified live table (A.3); the two opcode tables (`CefWebSession.swift:19–65` / `main.mm:82–127`) must stay in lockstep — the new control ops live on `CefProfileHost`, not the slimmed session.

### H.2 opCreateBrowser field order — VERIFIED IDENTICAL
`{u32 w}{u32 h}{f64 dpr BE}{u32 iosurfaceId}{utf8 url}` — Swift `createBrowser` builds it in exactly this order; `main.mm` `IpcReadLoop`/`DoCreateBrowser` parses it in exactly this order (`w` at p+0, `h` at p+4, `dpr` at p+8, `sid` at p+16, `url` at p+20). **No `allowedSchemes` field** (A.4) — `--allowed-schemes` is a process arg in both layers.

### H.3 Method-channel arg names — VERIFIED IDENTICAL
Dart sends `'profile'` (string) only when non-null/non-empty; Swift reads `a["profile"] as? String`. `'create'` result keys `{textureId, width, height, cdpPort}` unchanged. No platform-interface change.

### H.4 CLI arg names — VERIFIED IDENTICAL
Swift `spawn` passes `--ipc`, `--profile-dir`, `--cdp-port` (conditional), `--allowed-schemes`; `main.mm` reads exactly those via `ArgValue(..., "ipc"/"profile-dir"/"cdp-port"/"allowed-schemes")`. Per-view args (`url/width/height/dpr/iosurface-id`) removed from BOTH the Swift spawn argv AND `main.mm` parsing.

### H.5 RESOLVED CONFLICTS (recorded)
1. **Opcode bytes** (native/build vs swift): RESOLVED to `0x13`/`0x15`.
2. **allowedSchemes location** (PLAN-prose/swift payload vs native CLI): RESOLVED to process CLI arg `--allowed-schemes`; not in opCreateBrowser payload.
3. **opReady payload** (1-byte adhoc flag): adopted from the Swift safety-rail design; `main.mm` must send it (Step 6).
4. **Dart `profile` placement** (field vs create() param): RESOLVED to controller field; `create()` signature unchanged.

### H.6 RESIDUAL DECISIONS FOR THE HUMAN

- **Dev safety-rail detection — DECIDED (opReady byte).** No open question; recorded here per request. The async refuse-and-respawn (F.5) is the chosen path; the synchronous "block first createBrowser on a short ready-wait" is an acceptable P1 simplification IF the team prefers it, but the contract specifies the async path. **Human confirm:** accept async refuse-and-respawn, or downgrade P1 to the blocking-wait simplification.

- **Ephemeral-as-throwaway-host — DECIDED (one code path).** Ephemeral = a `CefProfileHost` with a unique non-persistent temp `--profile-dir`, keyed `"~ephemeral~"+sessionId`. cef_host has no ephemeral branch. **Human confirm:** OK to drop the legacy direct-spawn path entirely (the contract assumes yes).

- **Dialog-id scoping across browsers — DECIDED (per-slot).** `dialogs`/`dialog_next` move into `Slot`; `opJsDialog` stamps `slot->browser_id` outbound, `opJsDialogResp` routes to that slot, `OnResetDialogState` clears only that slot. This fixes a real multiplex bug (global ids would collide and `Continue` the wrong callback). Same for `trusted_pending` (per-slot, fixes a cross-browser allowlist-exemption bypass) and `popup_*` (per-slot, fixes simultaneous `<select>` dropdown clobber). **No human decision needed — flagged as a correctness requirement, not an option.**

- **Shared-texture / GPU multi-browser peer-validation — NO NEW RISK (verified), but FLAG for the smoke gate.** The Mach-port rendezvous env var + `--disable-features=MachPortRendezvous*PeerRequirements` are set ONCE per process and inherited by the single shared GPU/Viz process. N browsers in one cef_host share one GPU process, so peer validation is unaffected by multiplexing; `shared_texture_enabled` is set per-browser-create but resolves to the same GPU process. `CefInitialize` stays exactly once per process. **Human action:** the P2 gate (two webviews on `profile:'x'`) must explicitly verify GPU-accelerated `OnAcceleratedPaint` still delivers for the SECOND browser created in a live process (the first browser created the GPU process; confirm the second attaches cleanly and paints) — this is the one multiplex behavior not provable from static analysis and must be confirmed at runtime under a signed `CEF_HOST_ADHOC=OFF` build.

- **Per-browser IOSurface lifetime under accelerated paint (UAF) — DECIDED (shared_ptr + per-slot mutex).** `HostRenderHandler` holds `shared_ptr<Slot>`; surface `CFRelease` happens under `slot->surface_mutex` AFTER nulling `slot->surface`; `OnPaint` re-checks `if(!slot_->surface) return` post-lock. A GPU-thread paint racing UI-thread teardown either runs before release (valid) or sees null (no-op). Per-slot mutex (not the old global `g_surface_mutex`) is REQUIRED for multi-browser paint throughput. **No human decision — flagged as the binding mitigation for the one genuine UAF hazard.**
