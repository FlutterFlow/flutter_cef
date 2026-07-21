# Windows port — Phase 0 spike report

Executed 2026-07-20 on the reference box (Win11, VS2022 17.14 / MSVC 19.44,
Win10 SDK 10.0.26100, Intel Arc iGPU, Flutter 3.38.8 + system 3.32.8, CEF
`144.0.27+g3fae261+chromium-144.0.7559.254` windows64_minimal). Spike code is
throwaway, lives outside the repo at `C:\dev\flutter_cef_spikes\{s1..s6b}`
(producers, consumers, logs, screenshots preserved there). Verdicts are
against the pass criteria in [PLAN.md §3](PLAN.md).

**Result: 7/7 PASS. No fallback promoted. The GPU path, the bootstrap sandbox
model, the CDP pipe transport, and the plugin/toolchain assumptions all
survived. Three PLAN.md claims are corrected below (one refuted outright).**

| Spike | Verdict | One-line result |
| --- | --- | --- |
| S1 GPU handle → ANGLE | **PASS** | Cross-process legacy `MISC_SHARED` handle → Flutter `GpuSurfaceTexture` works, animated, 12 tiles; tearing 1.81%; NT→legacy copy mean 0.48–0.59 ms @720p |
| S2 sandbox/bootstrap | **PASS** | Sandboxed render via `bootstrapc.exe` + client DLL `RunConsoleMain`; renderer at UNTRUSTED IL; argv + inherited HANDLEs survive; LPAC icacls grant NOT needed for default config |
| S3 CDP io-pipes | **PASS** | `Target.getTargets` → `attachToTarget` → `Runtime.evaluate` over inherited pipe handles, 3/3 runs, ~2–3 s; also through `bootstrapc.exe` |
| S4 handle identity | **PASS** | Handle **value** is fresh-per-callback and aliases across sizes/browsers — never key on it; true pool = 2–3 kernel objects/browser, never reused across sizes; #154716 leak probe **clean** on 3.38.8 |
| S5 WebAuthn OSR | **PASS** | Native passkey modal (CredentialUIBroker) appears **even with `SetAsWindowless(nullptr)`** — support passkeys in v1 |
| S6a CEF headers/flags | **PASS** | CEF 144 headers compile **clean** under stock `apply_standard_settings`; entire fix = `NOMINMAX` + per-config `/MD` wrapper builds |
| S6b symlinks/OOT | **PASS** | Out-of-tree `../native/` sources build + incremental-rebuild through `.plugin_symlinks`; `bundled_libraries` lands extra DLLs beside the exe. Requires Developer Mode (true SYMLINKD, not junction, on 3.38.8) |

## S1 — cross-process shared texture (the novel risk): retired

- **Producer** 12× `ID3D11Texture2D` B8G8R8A8 `D3D11_RESOURCE_MISC_SHARED`,
  rolling frame counter in 8×8 corner blocks, 59.5–60.0 fps over 15,300
  frames.
- **Raw ANGLE consumer** (separate process): all 12 handles open via
  `eglCreatePbufferFromClientBuffer` + `EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE`,
  0 failures; counters advance 350 consecutive reads/tile; 1,178 reads/s.
  **Tearing 1.81%** (76/4200 reads, diagonal-corner counter disagreement) —
  the number that prices the future 2-slot ring; acceptable for v1.
- **Real Flutter consumer** (3.38.8 release): 12 `flutter::GpuSurfaceTexture`
  (`kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`) live-animate in a 4×3
  grid; 5 s vs 15 s screenshots differ 64.4–65.8% of sampled pixels on every
  tile.
- **Destroy-while-bound**: consumer's held reference keeps the kernel object
  alive after producer `Release()` — counter freezes at last value, glError 0,
  no device-removed. **Belt-1 (plugin holds a ref) is the safety requirement;
  belt-2 (`kOpSurfaceAck` deferred destroy) is a visual-quality optimization**
  and may ship after P8 if schedule demands (PLAN §4.4 refined).
- **CEF leg**: `OnAcceleratedPaint` NT handle (`MiscFlags=0x802`) →
  `OpenSharedResource1` → `CopyResource` → legacy bridge: mean **0.594 ms**
  (p95 1.56) on example.com, **0.483 ms** (p95 1.51) on a CSS-animation page
  @1280×720 — 3–10% of a 60 fps frame budget. The structurally-mandatory copy
  is not a perf concern.
- Caveats: single-GPU box — hybrid-GPU/cross-adapter (`--adapter-luid`)
  remains an assumption; handle-value-recycled-onto-different-texture worst
  case not exercised (covered instead by S4's identity findings + belt-1).
- Note: Flutter ships **no standalone** `libEGL.dll`/`libGLESv2.dll` in 3.38.8
  engine artifacts (ANGLE is statically linked into `flutter_windows.dll`);
  the raw-ANGLE leg used CEF's shipped ANGLE. Both providers accept the same
  cross-process legacy handle.

## S2 — bootstrap sandbox: the shipping contract

- Invocation (empirical; not in CEF's README): client DLL must sit **in the
  bootstrap exe's own directory**; select with `--module=<basename>`
  (positional is a FATAL "Missing module name"), or **rename the bootstrap
  exe to `<module>.exe`** — the rename route is what we should ship (clean
  Task Manager names). Neither `bootstrapc.exe` nor `libcef.dll` is
  Authenticode-signed, so unsigned dev DLLs load fine.
- `RunConsoleMain(argc, argv, sandbox_info, version_info)`: forward
  `sandbox_info` to both `CefExecuteProcess` and `CefInitialize`. With
  `no_sandbox=0`: 6-process tree, renderers at **UNTRUSTED** integrity, GPU at
  LOW, page renders correctly (PPM inspected), clean exit.
- argv (`--marker=xyz123`) and an inherited pipe HANDLE (via
  `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`) both pass through the bootstrap entry
  unchanged.
- **LPAC `icacls` S-1-15-2-2 grant is NOT required** for CEF 144's default
  sandbox (no AppContainer children; network I/O works ungrated). Only the
  opt-in `NetworkServiceSandbox` feature needs it (and more than the exe-dir
  grant — not fully chased). Document as future hardening, not setup.
- Build detail: client DLL must link `delayimp.lib` (CEF's `/DELAYLOAD` list).

## S3 — CDP over inherited pipe handles: ports directly

- `CreatePipe` ×2 + `HANDLE_FLAG_INHERIT` + `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`;
  child translates a private `--cdp-io-pipes=<r>,<w>` into
  `--remote-debugging-pipe` **plus** `--remote-debugging-io-pipes=<r>,<w>` in
  `OnBeforeCommandLineProcessing` (browser process only) — the exact macOS
  `--cdp-pipe` pattern (main.mm:~1640) with handle values instead of fds 3/4.
- Full sequence green 3/3: `Target.getTargets` (answers **before** any
  browser exists — the Windows relay can open its transport at spawn, don't
  wait for create) → `attachToTarget(flatten:true)` → sessioned
  `Runtime.evaluate` = 2. NUL-framed UTF-8 JSON, same as macOS.
- Same sequence green through `bootstrapc.exe` (composition with S2 proven).
  Not yet exercised: io-pipes with the sandbox *enabled* (S3 ran
  `no_sandbox=1`; S2 proved handle inheritance under the sandbox separately —
  compose in P2).

## S4 — handle identity: the law of the pool

- The `shared_texture_handle` **value** is a fresh NT handle every callback,
  closed by CEF on return. Values recycle and **alias**: 185 values seen at
  >1 coded-size, 441 values seen from >1 browser. **Never key identity or
  change-detection on the handle value.** Consumption must be
  open+copy-inside-the-callback (confirms PLAN §4.4 step 2 as mandatory and
  sufficient).
- True identity (`CompareObjectHandles` over retained dups): **2–3 kernel
  objects per browser** in strict A/B alternation (+1 burst buffer);
  per-browser pools; **zero** cross-browser sharing; **zero** null handles in
  11,842 paints.
- Resize: every `WasResized` (even ±1 px) discards the whole pool; kernel
  objects are never reused across coded sizes. 1–3 late callbacks per step
  still deliver the **old** size after `WasResized` — and
  `info.extra.coded_size` correctly describes each delivered frame, so the
  OSR_SCALE_MISMATCH size-gate oracle works on Windows as designed.
- flutter/flutter#154716 leak probe: **flat** GPU memory over ~6,700
  handle-changing imports on 3.38.8 → the 64-px size lattice is a churn
  optimization, not a leak requirement; media_kit-style re-register +
  `textureChanged` event **not needed**. (Skia/ANGLE backend; re-run if the
  engine flips to Impeller-default.)
- **REFUTES PLAN §4.3's "non-negotiable"** external-begin-frame rule — see
  Plan corrections below.

## S5 — WebAuthn: supported in v1 (decision flipped)

- The native passkey modal (`Credential Dialog Xaml Host`, owner
  `CredentialUIBroker.exe`) appears in **all three** configs, including
  `SetAsWindowless(nullptr)` — Windows brokers WebAuthn UI out-of-process and
  does not need our HWND. With a visible owner HWND the dialog tracks the
  window's position; with nullptr it centers on the desktop.
- `isUserVerifyingPlatformAuthenticatorAvailable()` → true in every config.
  Live-confirmed end-to-end to the phone leg: the caBLE QR flow reached a
  real phone during the run (maintainer observation).
- v1 action: plumb the runner's top-level HWND into `SetAsWindowless` for
  dialog placement (small refinement, not a blocker). Re-confirm the
  biometric sub-UI on a Hello-enrolled box (this box has no NGC container).
- **Caveat closed 2026-07-20**: during live P4-slice testing the maintainer
  completed a real passkey **login** end-to-end in the example app on this
  machine (OSR browser → webauthn.dll → CredentialUIBroker → authenticator →
  assertion accepted by the page). WebAuthn on Windows OSR is confirmed at
  the full-ceremony level, not just dialog-appearance.

## S6 — toolchain: smaller delta than budgeted

- `apply_standard_settings` verbatim (3.32.8 template; 3.38.8 byte-identical):
  `cxx_std_17`, `/W4 /WX /wd4100`, **`/EHsc` already present** (folklore
  wrong), `_HAS_EXCEPTIONS=0`. CEF 144 headers + wrapper subclasses +
  `CefMessageRouterBrowserSide` compile **clean** under stock flags. The
  entire real-world fix:
  - `NOMINMAX` per target (`cef_types_win.h` pulls `windows.h`; else
    `std::min` → C2589), and
  - wrapper built per-config with `-DCEF_RUNTIME_LIBRARY_FLAG=/MD` (Debug
    auto-appends `d`; mixing configs → LNK2038 RuntimeLibrary /
    `_ITERATOR_DEBUG_LEVEL` mismatch). Prebuilt tooling must ship /MD **and**
    /MDd wrapper libs.
  No `cxx_std_20`, no `/wd` additions, no exception-model change, no
  `USING_CEF_SHARED` macro.
- `.plugin_symlinks` on 3.38.8 is a **true SYMLINKD** (reparse tag
  0xa000000c), not a junction → **Developer Mode (or elevation) is a
  dev/CI-image requirement**; document in setup. Out-of-tree
  `../native/shared/*.cc` sources compile, incremental rebuild propagates
  through the symlink (edit → 7.9 s rebuild, change present),
  `<plugin>_bundled_libraries PARENT_SCOPE` lands an out-of-tree DLL beside
  `app.exe` — the shared-core layout of PLAN §4.3 is buildable exactly as
  drawn.

## Plan corrections applied

1. **PLAN §4.3 external-begin-frame "non-negotiable" — REFUTED and
   inverted.** On CEF 144/Windows, `windowless_frame_rate=60` **without**
   external begin frames delivers 60.3 fps × 12 concurrent browsers. With
   `external_begin_frame_enabled=1` + a 16 ms `SendExternalBeginFrame` pump to
   all 12, **only the first browser ever paints** — fatal for the
   one-host-N-browsers model. Windows default: external begin frames OFF;
   host-driven cadence (the macOS pacer) must be re-spiked per-browser before
   any P6 use. (CefSharp #2675 evidently fixed/changed by 144.)
2. **PLAN §3 S6 expected-fix list** replaced by the two-line S6a recipe
   above.
3. **PLAN §2 claim #18 (WebAuthn)** resolved: UI appears; v1 supports
   passkeys; `SetAsWindowless(hwnd)` refinement noted.
4. (P0 scope, already landed with this report: `.gitattributes` LF-pins
   `packages/**/native/**` + `*.sh`; PORTING.md's producer-allocates
   inversion, `--remote-debugging-io-pipes`, and bootstrap-DLL sandbox model
   corrected.)

## P0 gate: **GREEN**

All six spike questions answered with measurements; no fallback needed
anywhere; PLAN.md §2/§3/§4 updated where evidence contradicted it. Next: P1
(package skeleton + Dart conditionals + example/windows runner + CI).
