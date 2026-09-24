# flutter_cef — Windows port

Goal: `CefWebView` renders, composites, and behaves on Windows as it does on
macOS — same app-facing API, same method-channel contract, same wire protocol
(with one lockstep bump), same test gates — via a new endorsed
`flutter_cef_windows` package and a Windows build of `cef_host`. This is a
second platform, not a porting chore.

## 1. Bottom line

**Feasible. No fundamental blocker.** Every load-bearing unknown is either
CONFIRMED against primary sources (§2) or has a named Phase-0 spike with a
documented fallback (§3).

- **Cost: ~30 engineer-weeks to full parity** (honest range 26–34; the three
  competing plans priced 23.5/26/31.5 and the low ones underpriced their
  riskiest phases). One senior C++/Win32/D3D11 engineer ≈ 6–8 months calendar;
  a second engineer parallelizes only after first pixel (~4.5–5.5 months for
  two).
- **First demonstrable value at ~week 5**: a live, interactive web page inside
  a Flutter `Texture` widget on Windows, software-rendered, macOS untouched by
  construction. That milestone is the go/no-go checkpoint; abandoning there
  costs ~6 weeks and leaves macOS byte-identical.
- **Reuse ledger** (wc -l, verified): Dart carries over ~wholesale — 2,287
  lines with ~250 lines of platform-conditional edits. Native host: ~2,100 of
  main.mm's 2,924 lines are already plain C++ and move into a shared core;
  ~800–900 lines get a Windows twin. The 4,226 lines of Swift plugin/relay
  (CefProfileHost 1,710 + CdpRelay 919 + FlutterCefPlugin 780 + CefWebSession
  727 + policies 90) do **not** carry — Windows plugins are C++; expect
  ~5,500–6,500 C++ lines out (EncodableMap extraction is 3–6 lines where Swift
  needs 1). All ~1,050 lines of build/bundle/sign tooling (podspec, codesign,
  fetch/publish scripts) are macOS-shaped and get Windows rewrites.
- **One genuinely novel problem with zero prior art anywhere**: the shared GPU
  texture crosses *three* processes (CEF GPU proc → cef_host → Flutter/ANGLE).
  Every existing Windows CEF-in-Flutter project (webview_cef,
  flutter-webview-windows, CefSharp, JCEF) runs the browser in-process. macOS
  gets the extra hop free via `IOSurfaceIsGlobal` (main.mm:773); Windows has no
  equivalent primitive that is both cross-process and acceptable to ANGLE.
  Spiked in week 1 with an **animated** pass criterion and a pre-designed
  fallback (§3 S1).

Before committing, answer the buy-vs-build question in §10 honestly: if
Windows users only need "a webview", WebView2 delivers 80% of the value for
~5% of this cost. This port is justified only by what WebView2 cannot do:
multi-tile OSR compositing into Flutter's scene, per-tile CDP token isolation,
out-of-process crash isolation, shared profile hosts.

## 2. Verified vs. assumed

Every claim below was checked against primary sources (CEF branch 7559 =
CEF 144, Chromium tag 144.0.7559.254, the CEF builds CDN, ANGLE extension
specs, local Flutter engine source). Anything UNVERIFIED maps to a §3 spike.

| # | Claim | Status | Evidence |
|---|---|---|---|
| 1 | The pinned CEF build (`144.0.27+g3fae261+chromium-144.0.7559.254`, build_cef_host.sh:17) ships windows64/windowsarm64/windows32 minimal+standard tarballs, channel stable | **CONFIRMED** | cef-builds.spotifycdn.com index.json; windows64_minimal built 2026-06-03 |
| 2 | Windows `OnAcceleratedPaint` delivers an **NT** `HANDLE`, created **without a keyed mutex**, non-owning, pool-released when the callback returns; must be opened via `ID3D11Device1::OpenSharedResource1` synchronously inside the callback | **CONFIRMED** | include/internal/cef_types_win.h + include/cef_render_handler.h (branch 7559), verbatim; CEF #4027 |
| 3 | macOS struct field is *named differently* (`shared_texture_io_surface` vs `shared_texture_handle`) — a `#if` on the field is mandatory, a typedef is not enough | **CONFIRMED** | cef_types_mac.h vs cef_types_win.h |
| 4 | CEF-143 null-shared-handle regression (#4057) is absent from our 144.0.27 pin | **CONFIRMED** | issue closed 2025-12-19 via PR #4059; pinned build dated 2026-06-03 |
| 5 | Flutter's DXGI path binds via `EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE`, which requires a **legacy** `D3D11_RESOURCE_MISC_SHARED` handle; NT and legacy are mutually exclusive on one texture ⇒ **exactly one `CopyResource` is structurally mandatory** (note: macOS is not zero-copy either — CompositeMetalLocked blits, main.mm:850-985) | **CONFIRMED** | engine external_texture_d3d.cc:98-106 (local source); ANGLE EGL_ANGLE_d3d_share_handle_client_buffer spec |
| 6 | `kFlutterDesktopGpuSurfaceTypeD3d11Texture2D` is unusable from a plugin (ANGLE rejects textures not created on its own, unexposed, device) | **CONFIRMED** | ANGLE EGL_ANGLE_d3d_texture_client_buffer spec; Renderer11::getD3DTextureInfo |
| 7 | `TextureRegistrar::UnregisterTexture` is **asynchronous** on Windows; the engine may invoke the surface callback after it returns | **CONFIRMED** | flutter_texture_registrar.h:165 + flutter_windows_texture_registrar.cc:79-101 |
| 8 | `release_callback` fires **every frame**; EGL surface is re-imported only when `handle` changes; omitted `struct_size` ⇒ SAFE_ACCESS reads `handle` as null ⇒ silent black texture | **CONFIRMED** | external_texture_d3d.cc:83-115 |
| 9 | If ANGLE fails to init, `RegisterTexture` still returns a valid id and the callback is never invoked (blank, no log) | **CONFIRMED (substance)** | flutter_windows_texture_registrar.cc:26-30 guards only `!gl_` |
| 10 | CEF 144 ships **no `cef_sandbox.lib`** for Windows; the model is a client DLL exporting `RunWinMain`/`RunConsoleMain` + prebuilt `bootstrap.exe`/`bootstrapc.exe`; PORTING.md:92 and specs/cross-platform/PLAN.md:53 are **stale** | **CONFIRMED (header) / corroborated (tarball)** | cef_sandbox_win.h declares the bootstrap entry points; CEF #3824. Tarball enumeration = spike S2 |
| 11 | `--remote-debugging-pipe` takes **no** handle arguments; the handle-passing switch is the separate `--remote-debugging-io-pipes=<r>,<w>` (uint32-serialized inheritable HANDLEs), used in addition. **PORTING.md:91 is REFUTED** | **CONFIRMED** | content_switches.cc at tag 144.0.7559.254 |
| 12 | Windows OSCrypt = DPAPI-wrapped AES-256-GCM key in Local State (CEF: `LocalPrefs.json` in the cache dir); always available, signing-independent, decryptable by **any same-user process**. The macOS ad-hoc→mock-keychain→ephemeral-downgrade rail (main.mm:1598-1599, :2761-2768) has nothing to trigger on Windows | **CONFIRMED (substance)** | components/os_crypt behavior; `--use-mock-keychain` is Apple-only, `--password-store` Linux-only |
| 13 | `kOpPresent` is already 12 bytes `{u32 sid}{u32 srcW}{u32 srcH}` — the OSR_SCALE_MISMATCH size-gate (Fix-1) is **landed**; and `kOpCreateBrowser` carries **no** surface id (producer-allocates). PORTING.md's seam table says the opposite and would lead a porter into a deadlocking consumer-allocates model | **CONFIRMED** | main.mm:654-665, main.mm:137 |
| 14 | No `.gitattributes` exists; `tool/cef_host_hash.sh` hashes raw bytes ⇒ an `autocrlf=true` Windows checkout computes a different prebuilt digest than the macOS publisher forever | **CONFIRMED** | repo inspection |
| 15 | A legacy `MISC_SHARED` handle minted in cef_host opens via ANGLE in the **separate** Flutter process, tear-acceptably, at 12 tiles/60fps | **UNVERIFIED — no prior art exists** | → spike **S1** |
| 16 | `OnBeforeCommandLineProcessing` lands before Chromium reads `--remote-debugging-io-pipes`; a bootstrap-launched process inherits pipe handles + forwards argv into `RunConsoleMain` | **UNVERIFIED (inferred from the working macOS `--cdp-pipe` pattern)** | → spike **S3** |
| 17 | CEF's shared handle value stability across frames/resizes; whether mutating descriptor `handle` reproduces flutter/flutter#154716's engine GPU leak; whether size-bucketing suppresses it | **UNVERIFIED** | → spike **S4** |
| 18 | WebAuthn/passkeys complete in a windowless browser on Windows (webauthn.dll's Windows Hello modal takes an HWND; OSR `GetWindowHandle()` is NULL; main.mm:1059-1067 deliberately exempts WebAuthn from the permission gate) | **RESOLVED (SPIKES.md S5): the native passkey modal appears even with `SetAsWindowless(nullptr)` — Windows brokers WebAuthn UI out-of-process via CredentialUIBroker.exe. v1 supports passkeys; plumb the runner HWND into `SetAsWindowless` for dialog placement** | spike **S5** — PASS |
| 19 | `PluginRegistrarWindows::GetGraphicsAdapter` exists at plugin-registrar level | **VERSION-DEPENDENT** — 3.38.8+ only; on 3.32.8 it is `FlutterView::GetGraphicsAdapter`. CI pins 3.38.8 (ci.yaml:20); local box is 3.32.8 | → all spikes standardize on 3.38.8 |
| 20 | CEF headers compile under Flutter's `apply_standard_settings` (`_HAS_EXCEPTIONS=0` + `/W4 /WX`); plugin symlinks + out-of-tree native sources resolve under `generated_plugins.cmake` | **UNVERIFIED (webview_cef's workaround taken on faith)** | → spike **S6** |
| 21 | A Windows build of the consumer's custom Flutter engine (run_conformance_oracle.sh:25 → `work_canvas/scripts/campus-flutter-engine.sh`; the ci.yaml 3.38.8 pin rationale) exists, and whether its patches touch ExternalTextureD3d/ANGLE | **UNVERIFIED — gates the entire oracle strategy** | → §10 decision D5, resolved before P8 |

## 3. Phase 0 — spikes (throwaway code, outside the package tree)

All spikes on Flutter **3.38.8** + VS2022. Output is a written PASS/FAIL
report per spike with the fallback promoted into the architecture on FAIL.
Repo changes in P0 are limited to: `.gitattributes` (`packages/**/native/**
text eol=lf`), and the PORTING.md corrections (seam-table producer-allocates
inversion; line drift; the :91 CDP claim).

- **S1 — Cross-process legacy handle → ANGLE, ANIMATED.** Process A creates
  an `ID3D11Texture2D` (B8G8R8A8, `MISC_SHARED`) on the LUID adapter reported
  by the Flutter engine, renders a **rolling frame counter + moving pattern at
  60fps across 12 tiles**, ships `IDXGIResource::GetSharedHandle()` values
  over a pipe. Process B is a minimal Flutter app feeding the raw u64 into
  `FlutterDesktopGpuSurfaceDescriptor.handle`. Also: feed a real CEF 144
  `OnAcceleratedPaint` NT handle → `OpenSharedResource1` → `CopyResource` →
  legacy handle, measuring copy cost. **PASS = per-frame content assertion
  holds, a measured tearing/partial-frame rate is reported (not just "it lit
  up"), and a destroy-while-bound probe demonstrates what the consumer
  observes when the producer frees the texture** (this drives the lifetime
  protocol, §4.4). *Fallback A*: plugin-side bridge — cef_host
  `DuplicateHandle`s the NT handle into the plugin (plugin passes its process
  HANDLE at spawn); plugin opens + copies (one extra hop, a D3D device in the
  plugin). *Fallback B*: permanent software path only (works — shipped in P3
  anyway — more CPU, no 12-tile/60fps bar).
- **S2 — Sandbox/bootstrap model + tarball enumeration.** Download the actual
  windows64 minimal tarball for the pin; enumerate it (confirm no
  cef_sandbox.lib, confirm bootstrap.exe/bootstrapc.exe, read
  cef_sandbox_win.h as shipped). Build the smallest sandboxed OSR frame as
  cef_host.dll + `RunConsoleMain` + bootstrapc.exe; verify inherited HANDLEs
  and argv survive the bootstrap entry; verify the `icacls … *S-1-15-2-2`
  LPAC grant requirement. *Fallback*: `no_sandbox=true` v1 with the posture
  bit surfaced (§7) and a hard pre-GA deadline.
- **S3 — CDP io-pipes.** `CreatePipe` ×2 + `SetHandleInformation` +
  `STARTUPINFOEX` `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` + `CreateProcessW`;
  child injects `--remote-debugging-pipe` **and**
  `--remote-debugging-io-pipes=<r>,<w>` in `OnBeforeCommandLineProcessing`;
  drive one NUL-framed `Target.getTargets` round trip, including through the
  bootstrap entry from S2. *Fallback*: CRT lpReserved2 fd-3/4 block (last
  resort — Chromium issue 40259890 documents file corruption when fds 3/4 are
  not real pipes); second fallback: loopback `--remote-debugging-port` behind
  the relay, accepting the unauthenticated-port window.
- **S4 — Handle identity + resize.** Log CEF's `shared_texture_handle` across
  5,000 frames and across resizes at 12 tiles (stable / recycled / aliased?).
  Determine whether mutating the descriptor `handle` reproduces
  flutter/flutter#154716's GPU leak and whether a 64-px size lattice (crop via
  `visible_width/height`) suppresses it. *Fallback*: media_kit's
  unregister/re-register-new-texture-id strategy — which needs a new
  `textureChanged` event, since Dart ignores `resize`'s return today
  (cef_web_controller.dart:873-879).
- **S5 — WebAuthn/passkeys.** Load a WebAuthn test page in a windowless CEF
  144 browser with (a) a hidden `WS_CHILD` parent HWND, (b) a visible owner.
  Does the Windows Hello modal appear, and parented to what? *Fallback*:
  document passkeys as unsupported on Windows v1 (they are already
  entitlement-gated and out of scope on macOS per
  specs/persistent-profiles/PLAN.md:7-9), or require a visible owner HWND
  plumbed from the runner.
- **S6 — Toolchain probes** (half-day each): compile one CEF header under
  `apply_standard_settings` (`_HAS_EXCEPTIONS=0` `/W4 /WX`; **RESULT
  (SPIKES.md S6a): headers compile CLEAN under stock flags — the entire fix
  is `NOMINMAX` per target + wrapper rebuilt per-config with
  `-DCEF_RUNTIME_LIBRARY_FLAG=/MD` (/MDd for Debug); no `cxx_std_20`, no
  warning relaxations**); `add_subdirectory` through
  `flutter/ephemeral/.plugin_symlinks` into out-of-tree native sources
  (Developer-Mode symlink requirement?); confirm native tar.exe (bsdtar)
  decompresses the .tar.bz2 on the CI image; `Get-Command cmake` on a stock
  VS2022 box (it is NOT on PATH — the dev-setup doc must say so).

**P0 gate:** spike report committed to `specs/windows-port/SPIKES.md` with a
verdict per spike and, for every FAIL, the fallback promoted into §4;
`.gitattributes` landed; PORTING.md corrected; empty diff elsewhere.

## 4. Architecture

### 4.1 Dart (`packages/flutter_cef_windows` + shared-Dart edits)

New package mirrors flutter_cef_macos exactly: `implements: flutter_cef`,
`platforms: windows: {pluginClass: FlutterCefPlugin, dartPluginClass:
FlutterCefWindows}`, a 19-line `registerWith()` setting
`FlutterCefPlatform.instance = MethodChannelFlutterCef()`. Root pubspec gains
`windows: default_package: flutter_cef_windows` + path dep (today only
`macos:` is declared — a Windows app gets `MissingPluginException` on every
call). `FlutterCefPlatform` stays channel-only; no new interface members.

Shared-Dart changes (app-facing API frozen; all additive/conditional):

- **`CefKeyProfile`** (`enum {mac, win}` in platform_interface, derived from
  `defaultTargetPlatform`, `@visibleForTesting` override so both suites run on
  one host). Drives:
  - Accelerator: `isMetaOnly` (cef_web_view.dart:499-555) → `isAcceleratorOnly`
    keyed on the profile — Ctrl on Windows for copy/cut/paste/selectAll/undo,
    Ctrl+Y **and** Ctrl+Shift+Z for redo, Ctrl+`=`/`-`/`0` zoom, Ctrl+F. The
    ⌃⌘Space branch (:487-491) and `_seedCaretRect` become mac-only. Do **not**
    set `kCefEventFlagCommandDown` from `isMetaPressed` on Windows (:358-366)
    — the Win key must not present as `metaKey`.
  - Key codes: new `cefWinNativeKeyCode(PhysicalKeyboardKey, {repeat})`
    returning a WM_KEYDOWN-shaped lParam (scan code bits 16-23, extended bit
    24) — the only value from which Blink derives DOM `event.code`
    (`ui::KeycodeConverter::NativeKeycodeToDomCode`); `character = 0` for
    editing/navigation keys (no NSEvent 0xF700 codepoints). Extend
    `cefWindowsKeyCode` (cef_input.dart:180-188) for F1-F12, `VK_OEM_*`,
    Insert, numpad — those return 0 today on **both** platforms.
- **`loadFile` bug** (cef_web_controller.dart:812): `file://C:\path` →
  `Uri.file(absolutePath, windows: …)` = `file:///C:/dev/page.html`.
- **Create-failure state**: `_ensureSession` awaits `create()` inside an
  un-awaited post-frame callback (cef_web_view.dart:259-267, :305-306); wrap
  it so `MissingPluginException`/native errors render a failure widget rather
  than a permanent placeholder.
- **`CefSurfaceInfo.surfaceId`**: no shape change (Dart int is 64-bit).
  Re-document (cef_events.dart:82-100 + cef_web_controller.dart:139-146) as
  "an opaque platform surface token — global IOSurface id on macOS, DXGI
  legacy share handle on Windows".
- Multi-click thresholds: `GetDoubleClickTime`/`SM_CXDOUBLECLK` via a one-shot
  `getInputMetrics` channel call on Windows; macOS keeps its constants.
- `showEmojiPicker` → `PlatformException(MethodNotImplemented)` on Windows
  (Win+`.` is shell-owned; `SendInput` synthesis is fragile and steals
  focus). `performSelector` documented mac-only. The example app's emoji
  button (example/lib/main.dart:189-193) is hidden per-profile.
- **IME**: keep `enableDeltaModel: true`; the Win32 embedder never emits
  deltas, so Windows lands on the `updateEditingValue` fallback (:802-823) —
  currently untested against the deliberately-empty scratch buffer. P7
  rebuilds it as a diff-against-last-known-value strategy selected by
  `CefKeyProfile`, retaining `setComposingRect`/`setEditableSizeAndTransform`
  (they drive `ImmSetCandidateWindow`); the caret-seed and re-click `show()`
  AppKit hacks become mac-only.

### 4.2 Windows host plugin (C++, `packages/flutter_cef_windows/windows/`)

`flutter::Plugin` + `PluginRegistrarWindows` + `MethodChannel<EncodableValue>`
/ `StandardMethodCodec`. Infrastructure that must exist before anything else
compiles (Windows plugins get **no** task runner; `InvokeMethod` and
`MarkTextureFrameAvailable` are platform-thread-only):

- `platform_dispatcher` (~120 LOC): message-only HWND (`HWND_MESSAGE`) +
  `PostMessage` draining a mutex-guarded deque — replaces ~40
  `DispatchQueue.main.async` sites.
- `delayed_scheduler` (~150 LOC): thread + `priority_queue` +
  `condition_variable::wait_until` — replaces the 10
  `DispatchQueue.global().asyncAfter` timers in CefProfileHost.swift.
- `named_pipe_transport` (~300 LOC): `\\.\pipe\fcef-<128 random bits>`,
  `PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE`
  (defeats squatting), `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE |
  PIPE_REJECT_REMOTE_CLIENTS`, explicit current-user-SID DACL (**never** a
  NULL SD; never JCEF's `D:(A;;FA;;;WD)`); client opens with
  `SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS`. Reader restructured around
  OVERLAPPED + `CancelIoEx` + `WaitForMultipleObjects` (there is no
  `shutdown()`-wakes-the-reader on named pipes); the macOS "never close a
  handle on join timeout — deliberately leak" rule
  (CefProfileHost.swift:999-1002) carries over verbatim.
- `job_guard` (~60 LOC): `CreateJobObject` + `JOB_OBJECT_LIMIT_KILL_ON_JOB_
  CLOSE` + `AssignProcessToJobObject` — kernel-guaranteed no orphaned
  cef_host even under `TerminateProcess` of the app (strictly stronger than
  macOS's `willTerminateNotification`), plus a `RegisterTopLevelWindowProc
  Delegate` on `WM_ENDSESSION`. Retires the kqueue `WatchParentDeath` on this
  side.

Discipline for the CefProfileHost/CefWebSession rewrite — the highest-variance
work in the port (all three adversarial reviews independently named it, not
graphics):

- `shared_ptr` + `enable_shared_from_this` **mandatory**, private
  constructors so raw-pointer storage cannot compile; the ~30 `[weak self]`
  captures become `weak_ptr::lock()`.
- The documented lock order (`writeLock → bufferLock`; `browsersLock` /
  `presentLock` never nested), never-block-the-reader-on-a-write, and
  callbacks-outside-locks (CefProfileHost.swift:975-980, :1270-1275,
  :1454-1457, :1569, :1582) are encoded as a debug lock-order verifier, not
  comments. `assert(GetCurrentThreadId() == platform_thread_id_)` at every
  site macOS asserts `dispatchPrecondition(.onQueue(.main))`.
- Built under **Application Verifier + ASan from the first commit**; the P6
  gate is a soak (cascade probe ×50 + TerminateProcess-mid-resize fault
  injection), not one green run.
- **Fix, don't port**: `pendingCreates` is declared writeLock-guarded
  (CefProfileHost.swift:129) but cleared under browsersLock at :968/:1262 —
  masked by Swift CoW, a real race in `std::vector`. Unify on writeLock (per
  the declaration) at all five sites, on macOS too.
- `UnregisterTexture` is async (§2 #7): the session is kept alive by a
  `shared_ptr` captured in the completion callback — a correctness rewrite of
  CefWebSession.swift:479-492's synchronous assumption, not a translation.
- Process lifecycle simplifies: `CreateProcessW` (with CommandLineToArgvW-
  correct quoting, ~40 LOC) + held `hProcess`; the entire H5 pid-ownership
  dance (:1250-1256, :1301-1326) deletes — a HANDLE is not a recyclable
  global name. No SIGTERM: graceful = `opShutdown` + bounded wait, escalation
  = `TerminateProcess`. Profile lock = `CreateFileW` with `dwShareMode=0`,
  preserving the cross-layer contract **exit code 2 + literal log
  `profile-locked`** (main.mm:2786-2806; keyed on at FlutterCefPlugin.swift:521).
- Profile dirs: `SHGetKnownFolderPath(FOLDERID_LocalAppData)`; 0700 becomes a
  **protected** DACL (`D:P(A;OICI;FA;;;<userSID>)`) passed to
  `CreateDirectoryW` at creation (no inherited-ACL window) +
  `SetNamedSecurityInfoW(…, PROTECTED_DACL_SECURITY_INFORMATION)` for an
  existing leaf. The sanitizer (FlutterCefPlugin.swift:711-718) ports verbatim
  **plus** Windows-only rules: CON/PRN/AUX/NUL/COM1-9/LPT1-9, trailing
  dots/spaces, `:` (ADS), MAX_PATH.

### 4.3 cef_host native — two-stage host, converged early

**Stage 1 (P2–P4): a small greenfield `win/host_main.cc`, additive opcodes,
macOS untouched.** The Windows host starts as ~700 lines hand-copying only
what it needs, with the duplication tracked in `PORTING_DEBT.md` and a hard
rule that the window **closes at P5 — immediately after the interactive
milestone, NOT after verb parity** (converging two full 3,000-line hosts
never happens in practice). It presents via a **new opcode** `kOpPresentV2 =
0x1e` (verified unused in the table at main.mm:111-164), so `main.mm` is not
edited, `kCefHostProtocolVersion` stays 3, and macOS regression is impossible
by construction. The wire framing (`[u32 bodyLen][u32 browserId][u8 op]`,
≥5/≤64 MiB guard), BE codecs, and opcode payloads are copied verbatim.

Non-negotiables carried from day one: **external begin frames OFF on Windows**
— S4 (SPIKES.md) refuted the CefSharp-#2675-era assumption: on CEF 144,
`windowless_frame_rate=60` alone delivers 60.3 fps × 12 concurrent browsers,
while `external_begin_frame_enabled=1` + a 16 ms `SendExternalBeginFrame` pump
makes **only the first browser in the process ever paint** (fatal for the
one-host-N-browsers model). The macOS `PumpBeginFrame` pacer (main.mm:295-316)
must NOT be carried to Windows as-is; host-driven cadence, if ever wanted,
gets its own per-browser re-spike first;
`SetAsWindowless` on one hidden `WS_CHILD` HWND per host process (a null
parent degrades dialogs/menus/DPI/IMM and
browser_platform_delegate_native_win.cc bails on `!msg.hwnd`);
`CefRunMessageLoop` on the main thread + a reader `std::thread` (same model
as macOS, ports as-is); a `CefExecuteProcess` early-return replaces the
5-helper-app fan-out (Windows relaunches the same exe with `--type=`;
process_helper.mm's 85 lines collapse). The **must-port checklist** of
security-relevant lines a greenfield host would silently drop: the
CDP-on-persistent-profile refusal (main.mm:2757-2760), the deny-default
`HostPermissionHandler` (:1068-1089), `disable-blink-features=
AutomationControlled` + the `--cdp-pipe` injection pattern (:1651-1662), the
profile flock semantics (:2786-2806), and the exit-code-2 contract.

Software present path (P3, permanent): CEF software `OnPaint` → BGRA→RGBA
swizzle **producer-side** → shared-memory section → `flutter::
PixelBufferTexture` (engine does packed-RGBA `glTexImage2D`; no format/stride
fields). Hardened against the flaws found in review:

- **Name**: `Local\fcef-<128-bit CSPRNG hex>` communicated over the
  authenticated pipe — never a predictable pid/bid/gen name (squattable).
- **ACL**: explicit current-user-SID SD on `CreateFileMappingW`;
  `GetLastError() == ERROR_ALREADY_EXISTS` → abort (squat detection).
- **Sync**: a ring of **2–3 sections** with the presented index carried in
  `kOpPresentV2` — a plugin-local `std::mutex` excludes nothing across
  processes (the camera_windows `unique_lock::release()` idiom is
  in-process-only and covers only the engine↔plugin edge, where it is still
  used).
- **Validation**: consumer `VirtualQuery`s the mapped extent and rejects any
  present whose `srcH*stride` exceeds it — the section is not self-describing
  the way an IOSurface is.
- New section per size (never mutate a live one — JCEF's name-encodes-size
  trick), old sections retired only after the consumer acks adoption.

This path ships forever as the `IsGpuCompositingDisabled()` / ANGLE-init-
failed fallback and as the permanent "is it CEF or is it Flutter" bisector,
with a runtime kill-switch `FLUTTER_CEF_FORCE_SOFTWARE=1` (extending the
repo's env-knob culture).

**Stage 2 (P5): `core/platform.h`, seam-by-seam, oracle after every seam.**
This is the split specs/cross-platform/PLAN.md P3 deferred "until two
consumers exist" — at P5 the second consumer exists and its seam is
empirically known. Extraction order = decreasing certainty, macOS conformance
oracle run after **every** seam, not once at phase end:

1. `PlatformStream` — `Read/Write/Shutdown` (5 POSIX calls total on macOS;
   framing/codecs/opcode switch already pure C++).
2. `PlatformPaths` — exe/resource/cache dirs (~40 LOC; Windows: flat layout,
   `GetModuleFileNameW`, no `CefScopedLibraryLoader`, no framework paths).
3. `PlatformProcessGuard` — parent-death watch, profile lock, rlimit
   (deleted on Windows).
4. `PlatformApp` — run loop + sandbox init (the 16-line NSApplication
   subclass deletes on Windows).
5. `PlatformSurface` — **last**, when best understood: `Ensure(w,h)→Token`,
   `Lock/Unlock` (+base/stride), `BlitFromShared(const
   CefAcceleratedPaintInfo&)` (takes the CEF struct so the mac/win
   field-name divergence stays inside the platform layer; must complete
   before returning — same pool contract as CompositeMetalLocked's
   `waitUntilCompleted`), `Token()`, `Release()`. `Slot`'s two macOS members
   (`IOSurfaceRef surface`, `id<MTLTexture> dst_mtl` — referenced from five
   external sites at main.mm:781/927/1522/1802/1850) collapse to an opaque
   handle.

Then the win host is rebased onto `core/`, deleting the Stage-1 duplicates,
and the wire converges at **protocol v4** on both platforms in lockstep
(main.mm:108 ↔ CefProfileHost.swift:42 — the skew check is the point; never
fork the wire per-OS). The v4 present payload is **tagged and
variable-length** so a Linux port does not force v5 (its
`plane_count/modifier/planes[]` dma-buf provably does not fit a u64):

```
kOpPresent v4: {u8 kind}{u32 srcW}{u32 srcH}{payload}
  kind 0 = u32 IOSurface global id            (macOS)
  kind 1 = u64 DXGI legacy share handle       (Windows GPU)
  kind 2 = u8 len + utf8 shm name, u32 stride, u8 ringIndex (Windows software)
  kind 3 = reserved (multi-plane dma-buf, Linux)
```

Landing tree: repo-root `native/{cef_host/{core,platform/mac,platform/win},
cef_core/{policy,cdp_relay,test}}`, with build_cef_host.sh, the podspec
`prepare_command`/`:after_compile`, and `cef_host_hash.sh`'s find-root
re-pointed (one deliberate prebuilt-cache miss). CocoaPods can't glob across
package boundaries; use one-line `#include` shim TUs under `Classes/shim/`.
Also in stage 2: DevTools needs `window_info.SetAsPopup(NULL, "DevTools")`
(a default CefWindowInfo is not a top-level window on Windows, unlike
main.mm:2144-2145's comment); `GetScreenPoint` returns **device px** on
Windows vs DIP on macOS; `RealScreenDip` → `MonitorFromWindow` +
`GetMonitorInfoW` (top-left already, no Cocoa flip) with a per-platform
`kChromeH` (87 is "~ real Chrome on macOS" and leaks a wrong `outerHeight`
fingerprint otherwise); `DoKey`'s always-set `character` workaround
(main.mm:2297-2303, a macOS-Blink dedupe) goes behind the platform seam and
is settled empirically in P7 (risk: doubled Backspace/arrows).

### 4.4 GPU surface path (P8) — producer-allocates, with a real lifetime protocol

Retained from macOS: cef_host mints the bridge texture and publishes a token;
the size-tagged present + promote-only-on-size-match semantics (already
landed, §2 #13) carry over unchanged. The chain:

1. Plugin reads the engine adapter LUID
   (`PluginRegistrarWindows::GetGraphicsAdapter`, 3.38.8+) and passes
   `--adapter-luid=<high>,<low>` on cef_host argv; cef_host creates its
   `ID3D11Device` on that adapter (`D3D_DRIVER_TYPE_UNKNOWN`). Without this,
   hybrid-GPU laptops fail the open intermittently.
2. `OnAcceleratedPaint`: `OpenSharedResource1(info.shared_texture_handle)` →
   `CopyResource` into the slot's bridge texture (B8G8R8A8, `RENDER_TARGET |
   SHADER_RESOURCE`, **legacy `MISC_SHARED`**) → `Flush` — synchronously
   inside the callback (§2 #2). Bridge textures are allocated on a 64-px
   lattice with `visible_width/height` cropping so the published handle
   rarely changes (S4 validates this against flutter/flutter#154716).
3. `kOpPresent(kind=1)` publishes `IDXGIResource::GetSharedHandle()`.
4. **Lifetime protocol — the fix for the fatal flaw in the winning design.**
   A legacy share handle is a bare u64 the consumer cannot refcount by
   itself; without a protocol, cef_host destroying a bridge texture on
   resize while ANGLE binds asynchronously on the raster thread is a
   use-after-free (best case black tile; worst case the driver recycles the
   value onto a *different* live texture — cross-tile content leak). Two
   belts, both mandatory:
   - The plugin owns a small D3D11 device (same LUID) and, on each **new**
     token, `OpenSharedResource`s it itself, holding the ComPtr — a
     cross-process kernel reference that keeps the resource alive
     independent of the producer, and a validity probe (a failed open =
     reject the present, keep the current texture, log).
   - A new opcode `kOpSurfaceAck {u64 token}` (plugin → host): cef_host
     keeps every superseded bridge texture alive until the plugin acks
     adoption of its successor (first successful engine populate with the
     new handle). Mirrors the macOS retain semantics of
     `adoptSurfaceLocked`'s CVPixelBuffer.
5. Consumer: `flutter::GpuSurfaceTexture(kFlutterDesktopGpuSurfaceType
   DxgiSharedHandle, cb)` in a `map<int64_t, unique_ptr<TextureVariant>>`
   (registrar stores a raw pointer — the variant outlives registration);
   descriptor with `struct_size` set, `visible_*` from the present,
   `format = kFlutterDesktopPixelFormatNone`; a heap `DescriptorHolder`
   holding the ComPtr, released in `release_callback` (fires every frame).
   Startup probe: null `GetGraphicsAdapter()` ⇒ software path + loud log;
   plus webview_cef's 5-second "no accelerated frame arrived" warning task.

**Tearing is accepted as a structural v1 limitation, stated, not
discovered**: ANGLE's legacy-handle path excludes keyed mutex
(`MISC_SHARED_KEYEDMUTEX` is mutually exclusive; the engine never queries
`EGL_ANGLE_keyed_mutex`), so GPU mutual exclusion is unreachable through
Flutter's texture API. This is *parity*: README's Roadmap already documents
"the IOSurface is single-buffered, so very fast-updating pages can tear
slightly" on macOS. A 2-slot bridge ring is evaluated only against S1's
measured tearing rate — it pays `eglCreatePbufferFromClientBuffer` +
`eglBindTexImage` every frame and may hit #154716; adopt on measurement, not
principle.

### 4.5 CDP relay — one audited boundary, Windows-first validation

Shared C++ `native/cef_core/cdp_relay`: the pure policy
(`filterClientToPipe`, `filterPipeToClient`, `demuxPipeToClient`,
`rewriteOutgoingId`, `tokenAcceptable` — already factored `internal` so a
socket-free test can drive them), inverted from side-effecting to
value-returning (`struct FilterResult {optional<string> to_pipe;
vector<string> to_client; optional<string> self_command;}` — ~1 day, makes
the core strictly more testable than the Swift), plus HTTP head parse,
RFC-6455 framing, SHA-1/CSPRNG behind a BCrypt/CommonCrypto shim, NUL pipe
framing, behind an ~8-function socket backend (`posix.cc` / `winsock.cc`).
JSON via CEF's `cef_parser.h` (already linked; no new supply chain). All 60+
CdpRelayFilterTests assertions (incl. the 18 token edge cases and the
`pipeId = (relayId<<21)|seq` bit-layout cases) transcribe into a ctest target
that links neither CEF nor D3D, wired into **both** CI jobs — a CDP
regression once shipped precisely because CI wasn't running the filter suite
(ci.yaml:33-36).

Winsock redesigns (not translations): `SO_EXCLUSIVEADDRUSE` replaces
`SO_REUSEADDR` (CdpRelay.swift:161 — on Windows the latter is a port-hijack
primitive); `SO_RCVTIMEO`/`SO_SNDTIMEO` take a `DWORD` of **milliseconds**,
not a `timeval` (a verbatim port silently disables the slowloris and
stuck-client timeouts the write-isolation design depends on); `shutdown()`
does not wake a listening `accept()` (`WSAENOTCONN`) — teardown becomes
`WSAEventSelect(FD_ACCEPT)` + a manual-reset stop event +
`WSAWaitForMultipleEvents`; the per-relay writer queue is **bounded** (the
Swift DispatchQueue is unbounded).

Spawn: the S3 recipe (`CreatePipe` ×2, un-inherit parent ends,
`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, both `--remote-debugging-pipe` and
`--remote-debugging-io-pipes`); the fd-collision relocation guard
(CefProfileHost.swift:386-411) **deletes** — handle values are opaque.

Sequencing is the point: Windows validates the C++ core end-to-end
(multiview_probe + a real Playwright `connectOverCDP` drive) in P9; macOS is
cut over to it in a **separate, later, independently gated phase** (P10) so
the shipping security boundary is never touched by unproven code — and then
CdpRelay.swift is deleted so the deny-by-default filter exists exactly once.

### 4.6 Build, bundle, sign, distribute

- Plugin CMake: `add_library(flutter_cef_windows_plugin SHARED …)`,
  `apply_standard_settings`, link `flutter flutter_wrapper_plugin d3d11 dxgi
  dxguid ws2_32 shlwapi imm32`; S6's `_HAS_EXCEPTIONS`/`/MD` fixes applied.
  Bundling: `set(flutter_cef_windows_bundled_libraries … PARENT_SCOPE)` →
  `install(FILES)` next to the runner exe; `locales/` via explicit
  `install(DIRECTORY … DESTINATION ${INSTALL_BUNDLE_DATA_DIR})`; the ~250
  flat CEF files (libcef.dll, chrome_elf.dll, ANGLE/Vulkan DLLs, icudtl.dat,
  v8_context_snapshot.bin, *.pak). **Stamp-guarded install** so the ~500 MB
  copy does not re-run on every `flutter build windows`
  (`CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD` is 1 in the app template).
  **License files ship**: CEF/Chromium LICENSE + third-party manifest +
  the Microsoft-redistributable terms for d3dcompiler_47.dll — a legal
  ship-blocker, owner assigned in §10.
- Prebuilt fetch: no `pod install` hook exists — `fetch_cef_host.ps1` runs at
  CMake configure via `execute_process`, cached under
  `%LOCALAPPDATA%\flutter_cef`, hash-stamp short-circuit **load-bearing**
  (configure runs every build). Failure policy matches macOS: **fail-open**
  to build-from-source when the sidecar is unreachable, **fail-closed** on
  digest/signature mismatch (delete the cached archive). The §2 #14
  `.gitattributes` fix is the precondition for the shared content-hash key.
- Sandbox (P11, per S2): cef_host becomes `cef_host.dll` exporting
  `RunConsoleMain` + CEF's prebuilt `bootstrapc.exe`, `icacls <dir> /grant
  *S-1-15-2-2:(OI)(CI)(RX)` LPAC grant in the install step. Sandbox ON
  unconditionally once landed — it is signing-independent on Windows (the
  inverse of macOS).
- Signing/verification: Authenticode has no `--deep` tree seal and no
  requirement DSL, so 913f0f0's fail-closed property is rebuilt as:
  `WinVerifyTrust(WINTRUST_ACTION_GENERIC_VERIFY_V2)` (exactly-0 = success) +
  hand-rolled **leaf-thumbprint pinning** on **every PE**, + a signed
  catalog (or Authenticode-signed SHA-256 manifest) covering the non-PE
  assets, + rejection of **unexpected** files in the staging dir (per-PE
  verification says nothing about files an attacker *added*).
  `CreateProcessW` never consults SmartScreen/MotW — exactly as
  `posix_spawn` bypasses Gatekeeper — so this gate is the only root of
  trust. Publisher runs in CI with an HSM/Key-Vault identity (CA/B rules
  since 2023-06 rule out a local P12; no `security find-identity`
  equivalent). DLL hardening in cef_host/bootstrap entry:
  `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32)` first statement,
  absolute-path `LoadLibraryExW`, `SetProcessMitigationPolicy
  (ProcessImageLoadPolicy)` — the fetch dir is user-writable, making
  search-order hijack of libcef.dll live in dev/CI.
- CI: a `windows-latest` job pinned to Flutter 3.38.8 — analyze ×5 packages,
  `flutter test`, the cef_core ctest suite, a cached cef_host build. Note
  GitHub-hosted Windows runners have **no GPU**: the conformance oracle runs
  on a self-hosted/dev-box runner or as a documented pre-release ritual; CI
  proper gates on the GPU-free suites. AV/Defender note in the dev docs:
  unsigned exe + child spawning + RWX JIT + named-pipe IPC is the textbook
  EDR silhouette; document Defender exclusions for dev and expect
  enterprise-EDR reports as a support class.

## 5. Phases

Each phase ends at an explicit green gate; macOS gates are re-run at every
phase that touches shared code (verify, don't assume).

- **P0 — Spikes + repo prep** (§3). ~3 wks.
  *Gate:* SPIKES.md verdicts committed; fallbacks promoted; `.gitattributes`
  + PORTING.md corrections landed; empty diff elsewhere.
- **P1 — Package skeleton + Dart conditionals + CI.** New
  `flutter_cef_windows` (stub plugin answering `create` with a visible
  error), root endorsement, `flutter create --platforms=windows example/`
  (runner committed: main.cpp, flutter_window.cpp, Runner.rc, manifest —
  decide per-monitor-V2 DPI opt-in here), the §4.1 Dart changes, Windows
  twins of the ⌘-shortcut/key-table test groups, `/tmp` hardcodes in probes →
  `Directory.systemTemp`, windows-latest CI job. ~1.5 wks.
  *Gate:* analyze clean ×5 packages on both OSes; full Dart suite green on
  both (incl. new twins); `flutter build windows` of example launches and
  fails loudly, not silently; macOS example renders (oracle green).
- **P2 — cef_host.exe renders a page, zero Flutter.** Standalone CMake
  project; fetch the pinned windows64 minimal dist; `no_sandbox=true`
  (posture bit set, §7); windowless + hidden WS_CHILD HWND + external
  begin-frame pump; software `OnPaint` writes a swizzled PPM of a hardcoded
  URL at frame 30. ~1.5 wks.
  *Gate:* `cef_host.exe https://flutter.dev` writes a correct PPM at the
  requested size. All CEF-on-Windows build archaeology (S6 fixes, /MD,
  bsdtar) retired before any Flutter integration exists.
- **P3 — THE SLICE: software pixels in a Flutter Texture.** Named-pipe IPC
  (verbatim framing), six opcodes (`kOpCreateBrowser/Shutdown/Resize` in;
  `kOpReady/Log/PresentV2` out), the hardened shm ring (§4.3), dispatcher +
  Job Object + one reader thread + one `PixelBufferTexture`; single
  hardcoded session. ~2 wks.
  *Gate:* `flutter run -d windows` shows a live, correctly-scaled,
  correctly-colored page in a `Texture` widget, **with an animated-content
  check across a resize drag** (the ring, not just dimensions). macOS
  re-verified: main.mm unedited, protocol still 3.
- **P4 — Interactive.** Pointer/key/navigate/reload/stop/back/forward/
  setVisible/invalidate opcodes; wire encodings verbatim from
  cef_web_controller.dart:885-927; the resize supersede/coalesce machine
  (resizeGen + 80 ms invalidate re-kick) + size gate on `srcW/srcH`
  (promote only on match ±1px); title/url/loadState/pageStart/pageFinish/
  progress/loadErr/console/cursor events; wheel magnitude tuned against
  `WHEEL_DELTA` + `SPI_GETWHEELSCROLLLINES` (the sign negation at
  cef_web_view.dart:434-436 holds; the magnitude does not). ~1.5 wks.
  *Gate:* a human browses: links, typing, scroll, window resize across a DPI
  boundary, Ctrl+C/V, Ctrl+±/0; zoom_soak shows no stuck-scale frames.
  **This is the go/no-go milestone (~week 7).**
- **P5 — Converge: core/platform.h + shared policies + protocol v4** (§4.3
  stage 2). Seam-by-seam with the macOS oracle after every seam; win host
  rebased onto core (PORTING_DEBT.md emptied); tagged v4 present, versions
  bumped in lockstep both sides; the three resize/liveness policies + their
  ~30 test vectors → `native/cef_core/policy` ctest (skip the dead
  `shouldForcePromote`); macOS cut over to the policy lib only after ctest +
  full macOS gates green (Swift copies + swiftc runners then deleted). ~2.5
  wks.
  *Gate:* macOS conformance oracle + leak soak + all four policy suites
  green from the refactored tree; Windows P4 gate re-passes on core;
  `git diff` shows moves + seam indirection, no logic change (except the
  pendingCreates lock fix, called out).
- **P6 — Multi-browser lifecycle.** One host per profile key multiplexing N
  browsers; real sessionId routing; dispose/created/createFailed; the create
  pacer (window=3, 8 s backstop, 6-stable-frames/0.4 s dual release),
  first-paint watchdog, liveness sweep, and targetId resolve/epoch/retry
  implemented **in shared `core/`** (they reason about facts cef_host
  observes directly — OnAfterCreated, presents, the DevTools observer;
  consumer-side placement is why they need IPC backstops). Windows uses the
  core-side machinery from day one (greenfield validation); macOS keeps its
  Swift pacer untouched behind the existing wire until the P10 flag-flip.
  `processGone` reasons; `paintStalled`; the failHost-must-dispose-session
  ordering (fix macOS C-2 here: FlutterCefPlugin.swift:496-499 leaks the
  texture per host crash). ASan/AppVerifier soak. ~2.5 wks.
  *Gate:* Windows cascade probe: 12/12 tiles `paints>0` on one shared host,
  run ×50; TerminateProcess-mid-resize fault injection: every session gets
  `processGone`, zero texture/handle leak, zero crash; second app on a named
  profile → `processGone('locked')`. macOS unchanged.
- **P7 — Verb parity + input truth + IME.** Cookies, JS channels (per-session
  OnQuery routing), evalReturning, JS dialogs, find, zoom, editCommand,
  loadTrusted, downloads; the three string-packings byte-for-byte
  (`"id:json"`, `"name:message"`, cookies JSON). `CefDialogHandler::
  OnFileDialog` + new opcode (windowless = NULL owner HWND; `<input
  type=file>`/downloads otherwise fail silently — new on both platforms).
  DevTools `SetAsPopup`. Empirically settle: (a) DoKey's always-set
  `character` on Windows (doubled edits?); (b) whether Blink applies editor
  commands from raw key events on Windows OSR or the explicit editCommand
  path stays required; (c) the early-character fallback
  (cef_web_view.dart:598-600) vs WM_CHAR ordering. IME non-delta strategy
  (§4.1); verify the Win32 TextInputPlugin honors a non-implicit `viewId`.
  Native OAuth popup: `CreateWindowExW(WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU)`
  + WndProc mirroring `windowShouldClose:`, `SetAsChild(HWND, CefRect)`,
  `SetWindowTextW`, deferred destroy via `CefPostTask(TID_UI)`; forward
  runner messages per docs.flutter.dev/platform-integration/windows/extern_win;
  note `SetForegroundWindow` refusal means the popup may open un-foregrounded
  — mitigate with `AllowSetForegroundWindow` from the plugin before spawn and
  flash fallback. ~3 wks.
  *Gate:* channel_probe + channel_probe_shared write `pass:true` on Windows;
  cef_web_controller_test's 73 contract tests pass against the real host;
  manual matrix: each editing key applies exactly once, MS-IME + a CJK IME
  compose with the candidate window at the caret, `event.code` correct,
  file-picker and a download complete, Google `signInWithPopup` completes.
- **P8 — GPU path + Windows gates.** §4.4 wholesale, per S1/S4 verdicts:
  bridge textures, `--adapter-luid`, the two-belt lifetime protocol
  (plugin-side open+ref, `kOpSurfaceAck` deferred-destroy), lattice sizing,
  software fallback + `FLUTTER_CEF_FORCE_SOFTWARE`. Conformance oracle
  rebuilt as a **Dart driver** (one runner both OSes) over the unchanged
  conformance_harness.dart; Windows host emits the identical `diagpx
  wire=<id> painted=WxH want=WxH content=<n>` + FIRSTPAINT/ADOPT/blitmismatch
  grammar (hard requirement — the oracle is a parser over it; note the
  Windows sampler is a staging-texture `D3D11_MAP` readback, so keep
  `FLUTTER_CEF_DIAGPX_EVERY` debug-gated). Leak soak: `WorkingSet64` ceiling
  + `HandleCount` + a host-emitted live-shared-texture counter replacing
  `ioreg -c IOSurface`. ~3 wks.
  *Gate:* Windows oracle exits 0 on all five hard rules (NO-RENDER /
  NO-ADOPT / BLIT-CROP / BLANK / NO-DIAG) at HARNESS_N=12 HARNESS_HARD=1
  through all six storms; leak soak green; a forced
  `--disable-gpu-compositing` run still renders via software; measured CPU/
  frame drop vs P3. macOS oracle still green.
- **P9 — CDP relay on Windows** (§4.5). Shared core + winsock backend + S3
  spawn recipe + `--cdp-io-pipes` flag; ctest filter suite in both CI jobs.
  macOS stays on CdpRelay.swift. ~3 wks.
  *Gate:* multiview_probe `pass:true` on Windows (two grants, distinct
  ports+tokens, cross-token rejected, per-tile getTargets scoped, disable
  kills one, re-enable mints fresh); real Playwright `connectOverCDP` drives
  one tile without seeing a sibling.
- **P10 — macOS cutover: relay + pacer flag.** Retire CdpRelay.swift behind
  a thin ObjC++ shim onto the shared core; flip macOS to the core-side pacer/
  watchdogs (P6) behind its flag; delete the Swift copies + runners. ~1.5
  wks.
  *Gate:* macOS multiview_probe + run_channel_integration + cascade probe +
  oracle + leak soak green; 16 s-idle run proves no false wedge flag; net
  LOC deleted — one security boundary, one pacer. Tagged revert point.
- **P11 — Sandbox, signing, distribution, docs.** §4.6: bootstrapc.exe
  restructure per S2, LPAC ACLs, DLL hardening, posture bit1→0, Authenticode
  gate + signed manifest, fetch/publish scripts, license bundling, README
  security rewrite (§7), CHANGELOG + pubspec graph/publish-ordering update
  (root note at pubspec.yaml:22-33 gains the fourth package), Windows
  dev-setup doc (cmake/ninja PATH, Defender exclusions,
  FLUTTER_CEF_HOST probe order on Windows: env var → next to runner exe →
  `data/`). ~3 wks.
  *Gate:* `flutter build windows --release` on a clean machine yields a
  running, signed, **sandboxed** app (restricted-token renderers verified in
  Process Explorer); a tampered PE *and* a tampered .pak are rejected
  fail-closed with the cached archive deleted; identical prebuilt hash from
  a Windows and a macOS checkout of the same commit.
- **P12 — Windows-only hardening + folded probes.** TDR/`DXGI_ERROR_DEVICE_
  REMOVED` fault injection with a recreate-device/bridge/texture recovery
  path + a new `processGone` reason `deviceLost` (and `hostLaunchFailed` for
  missing VC++ runtime / AV-quarantined libcef — today indistinguishable
  from `crashed`); per-monitor-V2 DPI drag between differently-scaled
  monitors (the C-1f "dpr change while culled" case made routine); sleep/
  wake; software-fallback under hide/resize; single-renderer death in a
  shared host; slot/wire-id reuse across respawn under load. Fold the manual
  visual probes (cull_wedge, zoom_soak, crispness, interaction_soak,
  realsite_soak, sharedhost_html) into conformance_harness as **asserted**
  storm phases on both OSes; re-derive the Windows per-host browser ceiling
  via the PROBE_N bracket. ~3 wks.
  *Gate:* forced TDR recovers every tile to a painting texture within 5 s;
  a cross-DPI monitor drag leaves no wedged/wrong-scale tile; all folded
  storm phases assert green on both platforms; full parity matrix (§8)
  green.

Total ≈ 30 engineer-weeks. Pixels at ~week 5 (P3); go/no-go at ~week 7 (P4).

## 6. Deliberately NOT ported in v1

- **`showEmojiPicker`** → `MethodNotImplemented` (no supported Win32 API;
  example button hidden). **`performSelector`** documented mac-only.
- **The ad-hoc→mock-keychain→ephemeral downgrade rail** — inert on Windows
  (§2 #12); replaced by the posture-bit scheme in §7, not silently dropped.
- **Trackpad pan-zoom path + `_kTrackpadScrollGain=3.0`** — the Win32
  embedder delivers precision-touchpad scroll as PointerScrollEvent; the
  handler stays inert and the gain constant is never reused.
- **`CEF_MULTI_PROCESS=OFF`** — documented macOS-only (`--single-process` is
  Chromium-debug-only on Windows and forfeits OnAcceleratedPaint).
- **5-helper-app fan-out, `CefScopedLibraryLoader`, NSApplication subclass,
  rlimit bump, SIGPIPE guards, Mach-port peer-validation bypass, kqueue
  parent watch** — deleted on Windows (Job Object + `--type=` relaunch model).
- **A C++ rewrite of the macOS Swift plumbing** (CefProfileHost/
  CefWebSession transport + lifecycle). Deliberate: six mutexes with a
  documented lock order, ~30 ARC weak captures, and the wake/join/leak-on-
  timeout teardown are the highest-variance code in the repo; the decisions
  are shared (policies, pacer in core, relay), the OS-shaped plumbing is
  written twice on purpose.
- **HTML5 drag-and-drop, printing, context menus, accessibility** — missing
  on macOS too (no CefDragHandler/PrintHandler/ContextMenuHandler/
  AccessibilityHandler anywhere); parity means matching macOS, not fixing it.
  If added later, they belong in `core/`.
- **Tear-free GPU sync** — structurally unreachable through Flutter's
  Windows texture API (§4.4); parity with macOS's documented single-buffer
  tearing. Buffer-ring only on S1 measurement.
- **Windows-on-ARM** — deferred pending §10 D4 (the windowsarm64 CEF dist
  exists; the cost is fetch-arch plumbing, a second prebuilt, and CI runner
  availability).
- **WebAuthn/passkeys** — per S5's verdict; already out of scope on macOS
  (specs/persistent-profiles/PLAN.md:7-9).

## 7. Security contract deltas on Windows (stated, so nothing weakens silently)

1. **At-rest encryption.** macOS: OSCrypt key in the login Keychain,
   ACL-bound to the signing identity, real crypto only in signed builds.
   Windows: DPAPI-wrapped AES-256-GCM, **always on, signing-independent**,
   key inside the profile dir (`LocalPrefs.json`) — but decryptable by **any
   same-user process** with no prompt (the classic cookie-stealer path;
   Chrome's App-Bound Encryption needs a SYSTEM elevation COM service CEF
   does not ship). Net: better than macOS-ad-hoc, weaker same-user isolation
   than macOS-signed. README's Secrets-at-rest section gets a platform
   split, not a find-and-replace. Profile-dir ACL + BitLocker are the
   backstops.
2. **Posture bits — extended, never redefined.** The `opReady` handshake
   grows (under the v4 bump, where skew is caught loudly): **bit0 keeps its
   existing meaning** (secrets-at-rest unavailable / ad-hoc; Windows
   truthfully reports 0 — DPAPI is real crypto, so the named-profile
   downgrade rail correctly never fires). **New bit1 = "sandbox
   unavailable"**, set by the Windows host until P11 lands and thereafter
   whenever sandbox init fails, surfaced to Dart as a machine-readable
   `sandboxed` posture (create-result field + doc) so a consumer can refuse
   untrusted content on an unhardened host. No silent hardcoding: an
   unsandboxed build must not report a clean posture.
3. **Sandbox.** macOS: coupled to Developer-ID signing; off in ad-hoc.
   Windows: signing-independent — **on unconditionally** once P11 lands
   (dev and CI included), via the bootstrapc.exe model + LPAC ACL. Until
   P11, renderers run with the user's full token — worse than macOS's worst
   posture (no TCC/Gatekeeper second line) — which is why bit1 exists and
   why P11 must not slip past GA.
4. **README.md:321 is retracted for Windows.** "Even a same-UID process
   can't connect [to the relay]" rests on macOS denying `task_for_pid`.
   Windows grants the owning user `PROCESS_VM_READ` (token readable from the
   relay heap) and `PROCESS_DUP_HANDLE` (CDP pipe handles duplicable,
   bypassing token *and* filter) by default; PPL needs a Microsoft cert. The
   Windows claim is: defeats network/port-scanning and cross-user access —
   **same-user is not a boundary on Windows.** Documentation, because no
   engineering fixes it.
5. **Relay transport.** Token auth, constant-time compare, deny-by-default
   filter, discovery-without-token all port unchanged. New Windows rules:
   `SO_EXCLUSIVEADDRUSE` (never `SO_REUSEADDR`); DWORD-ms timeouts;
   loopback-TCP retained for the relay (Playwright can't speak pipes);
   AppContainer/MSIX packaging would break loopback without an exemption
   (noted for packagers).
6. **IPC + shm surfaces.** Named pipe: random 128-bit name,
   `FILE_FLAG_FIRST_PIPE_INSTANCE`, explicit user-SID DACL,
   `PIPE_REJECT_REMOTE_CLIENTS`, client `SECURITY_SQOS_PRESENT |
   SECURITY_ANONYMOUS` (a squatting server must not impersonate us).
   Software-path sections: CSPRNG names over the authenticated pipe,
   explicit user-SID DACL, `ERROR_ALREADY_EXISTS` → abort, extent-validated
   before trusting wire dims. (Note `Local\` objects are per-session while
   the profile lock is per-`%LOCALAPPDATA%`: RDP/fast-user-switching makes
   the `locked` path routine where macOS rarely sees it — the exit-2
   contract covers it.)
7. **Binary trust.** No Gatekeeper/notarization/entitlements. Replacement:
   per-PE WinVerifyTrust + pinned leaf thumbprint + signed manifest/catalog
   for non-PE assets + unexpected-file rejection + DLL search-order
   hardening (§4.6). `CreateProcessW` bypasses SmartScreen exactly as
   posix_spawn bypasses Gatekeeper — the explicit gate is the only root of
   trust, and it stays fail-closed.
8. **Command lines are logged on Windows** (4688/Sysmon/EDR persist argv to
   disk). Nothing profile-identifying or secret ever goes on argv; pipe
   handle values are not secrets (useless without PROCESS_DUP_HANDLE) but
   the rule is stated.
9. **CDP-on-persistent-profile refusal** (main.mm:2757-2760) and the
   deny-default permission handler are on the must-port checklist (§4.3) —
   they live in `core/` after P5 so no greenfield host can drop them again.

## 8. Parity test plan

The oracle strategy: one log grammar, one harness, two platforms. The
Windows host **must** emit the identical `diagpx wire=<id> painted=WxH
want=WxH content=<n>` / FIRSTPAINT / `ADOPT psid` / blitmismatch lines under
`FLUTTER_CEF_DEBUG=1` — every gate below is a parser over that grammar.

- **Tier 0 (P1, CI both OSes):** `flutter test` — the 73 controller-contract
  tests, ~150 input/widget tests + Windows twins of the ⌘/NSEvent groups;
  example integration smoke.
- **Tier 1 (P5/P9, CI both OSes, no GPU needed):** `native/cef_core` ctest —
  the 3 resize/liveness policies (~30 vectors) + the CDP
  filter/token/demux suite (60+ vectors incl. token edge cases and pipeId
  bit layout), transcribed verbatim from the Swift tests.
- **Tier 2 (P8, self-hosted/dev-box — GitHub Windows runners have no GPU):**
  the conformance oracle as a cross-platform Dart driver over the unchanged
  conformance_harness.dart — five hard rules (NO-RENDER / NO-ADOPT /
  BLIT-CROP / BLANK / NO-DIAG), convergence WARN-only, HARNESS_N=12,
  HARNESS_HARD=1, all six storms.
- **Tier 3 (P6-P9):** leak soak (recreates_total>0; WorkingSet64 ≤1.5×
  baseline; HandleCount + host-emitted live-shared-texture counter flat —
  the direct analogue of the IOSurface ledger); cascade probe (12/12 wires
  `paints>0`, ×50); channel gates rebuilt as a Dart runner (one runner both
  OSes) asserting each probe's `pass:true` JSON — channel_probe,
  channel_probe_shared, multiview_probe — with the Windows analogue of the
  `FLUTTER_CEF_ALLOW_INSECURE_PROFILE` masking trap handled explicitly (an
  unsandboxed host must not silently downgrade named profiles or the
  shared-host probes pass vacuously).
- **Tier 4 (P12, Windows-first):** TDR/device-removed fault injection with
  recovery assertion; cross-DPI monitor drag; sleep/wake; software fallback
  under hide/resize; renderer-death-in-shared-host; respawn-under-load
  wire-id reuse; the folded (now asserted) visual probes; PROBE_N ceiling
  bracket.
- **Manual acceptance:** the example app feature matrix (PORTING.md
  checklist) on Windows — pointer/keyboard/IME/navigation/allowlist/
  profiles/dialogs/downloads/OAuth popup.

## 9. Invariants

- **macOS builds, renders, and passes its full gate set at every phase**
  (verify, don't assume — the oracle runs after every P5 seam, not per
  phase).
- **App-facing API frozen**: `CefWebView` / `CefWebController` / exported
  types unchanged; `package:flutter_cef/flutter_cef.dart` imports keep
  working; `profile:` semantics identical.
- **Wire changes are additive until P5, then lockstep**: no edit to
  `main.mm` or the v3 protocol before the P5 convergence; from P5 the
  protocol version bumps on *both* sides in one change or not at all — never
  a per-OS fork, never a silent byte-reinterpretation (posture bits are
  *added*, not redefined).
- **No shared component reaches shipping macOS before Windows has validated
  it** (policies: ctest + full macOS gates; pacer: P6 Windows → P10 flag;
  relay: P9 Windows → P10 cutover, separately gated, tagged revert point).
- **The duplication window is bounded and ledgered**: PORTING_DEBT.md tracks
  every line copied into the Stage-1 win host; the ledger must be empty at
  the P5 gate.
- **Security posture is never silently weakened**: every delta in §7 is
  either surfaced machine-readably (posture bits) or documented in the
  platform-split README before GA; the fetch stays fail-closed on mismatch;
  the CDP filter exists exactly once after P10.
- **Cancellation is cheap by construction**: through P4 the macOS tree is
  byte-identical (additive opcode, no protocol bump); killing the port at
  the week-7 go/no-go costs ~6 weeks and zero macOS risk.
- **The diagpx/FIRSTPAINT/ADOPT log grammar is byte-identical across
  platforms** — it is the contract every automated gate parses.
- **cef_host pin moves in lockstep**: one CEF version string
  (build_cef_host.sh:17) for both platforms; a bump lands with both
  prebuilts republished and both oracle runs green.

## 10. Open decisions for the maintainer

- **D1 — Buy vs build (answer first).** If Windows users need "a webview",
  WebView2 via an existing plugin is 2–4 weeks and OS-maintained — but has
  no OSR multi-tile compositing, no per-tile CDP isolation, no shared
  profile hosts. This port is only justified by the agent-browser/multi-tile
  product on Windows. Who is the Windows user, and which do they need?
- **D2 — Agent control in Windows v1?** Cutting P9+P10 saves ~4.5 weeks;
  `enableAgentControl` already surfaces a clean `PlatformException`
  (cef_web_controller.dart:594-604). If cut, the shared-relay work still
  eventually happens — decide whether v1 ships without it.
- **D3 — Sandbox timing.** Block GA on P11 (recommended; unsandboxed
  Windows is worse than macOS's worst posture), or ship a bounded
  internal-preview window with bit1 surfaced and a hard deadline?
  Unsandboxed-forever is not an option.
- **D4 — Windows-on-ARM in scope?** Affects fetch arch detection, GCS
  object naming, a second prebuilt + publisher, and CI (no GitHub-hosted
  ARM64 Windows runners).
- **D5 — The oracle's engine.** run_conformance_oracle.sh:25 prefers the
  consumer's custom engine (`work_canvas/scripts/campus-flutter-engine.sh`);
  ci.yaml pins 3.38.8 for the same reason. Does a **Windows** build of that
  engine exist, and do its patches touch ExternalTextureD3d/ANGLE? The
  Windows gate is authoritative against whichever engine ships — resolve in
  writing before P8.
- **D6 — Signing identity.** Does the org hold (or must it procure) an
  HSM/Key-Vault-backed Authenticode cert? Procurement lead time can exceed a
  phase; start at P0. OV suffices (EV no longer buys SmartScreen reputation).
- **D7 — Licensing owner.** Who reviews/ships the CEF+Chromium license set
  and the Windows-SDK redistribution terms for d3dcompiler_47.dll? Legal
  ship-blocker; not an engineering task to discover at P11.
- **D8 — Staffing.** This needs Win32 + D3D11 + C++-concurrency fluency; the
  failure modes (torn frames, black textures with no error path,
  teardown races) are undiagnosable without it. If unavailable, add 30–50%
  to every estimate.
- **D9 — Kill criteria (agree up front).** Abandon/descope if: S1 fails AND
  software rendering can't meet the product's tile/fps bar; or the P4
  interactive milestone slips past week 10; or D1's demand hasn't
  materialized by milestone time; or D8 can't be staffed. Each caps the loss
  at ~6 weeks with macOS untouched.
- **D10 — Ongoing cost sign-off.** Post-GA, every CEF bump lands twice (two
  prebuilts, two signing pipelines, two oracle runs); the macOS host is
  under active churn (the last four commits touched render/screen/popup code
  — each would have needed a Windows twin). Budget ~30–50% ongoing overhead
  on this subsystem, or the platforms drift.
