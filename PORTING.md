# Porting flutter_cef to a new platform

`flutter_cef` is a **federated** Flutter plugin. macOS ships today
(`flutter_cef_macos`); Windows and Linux can be added as sibling
implementation packages without touching the app-facing API or the macOS
implementation. CEF itself is cross-platform — the work is re-implementing the
thin platform glue around it.

```
flutter_cef/                         # app-facing package (re-exports the API)
  packages/
    flutter_cef_platform_interface/  # the shared Dart contract (no platform code)
    flutter_cef_macos/               # the macOS implementation (reference)
    flutter_cef_windows/  _linux/    # <- you add these
```

## 1. The Dart / package side (small)

The Dart `lib/` is already platform-neutral and the cross-platform contract is
the **method-channel protocol** (channel name + method names + event names),
so a new platform needs almost no Dart.

1. Create `packages/flutter_cef_<os>/` with a `pubspec.yaml`:
   ```yaml
   name: flutter_cef_<os>
   dependencies:
     flutter_cef_platform_interface: { path: ../flutter_cef_platform_interface }
   flutter:
     plugin:
       implements: flutter_cef
       platforms:
         <os>:
           pluginClass: FlutterCefPlugin     # your native host plugin
           dartPluginClass: FlutterCef<Os>   # endorses the channel instance
   ```
2. `lib/flutter_cef_<os>.dart` — endorse the default method-channel instance
   (mirror `flutter_cef_macos`'s `FlutterCefMacos.registerWith`):
   ```dart
   class FlutterCef<Os> {
     static void registerWith() =>
         FlutterCefPlatform.instance = MethodChannelFlutterCef();
   }
   ```
3. Endorse it from the app-facing package: in `flutter_cef/pubspec.yaml` add
   `platforms: <os>: default_package: flutter_cef_<os>` and a path dependency on
   it (mirror the `macos:` entry).

That's the entire Dart side. Everything else is native.

## 2. The host plugin (your `FlutterCefPlugin` equivalent)

Reference: `packages/flutter_cef_macos/macos/Classes/` (Swift). The host plugin
lives in the Flutter app's process and:

- Registers a **platform texture** (a `FlutterTexture` on macOS) backed by a
  shared GPU surface, and hands its id to the page.
- Spawns **one `cef_host` subprocess per profile** (`--ipc --cdp-port
  --profile-dir --allowed-schemes --ephemeral` as argv), then creates **N
  browsers in that process** via `opCreateBrowser` frames carrying `url, width,
  height, dpr` + a `browserId`. **The create carries no surface id** — the
  surface model is *producer-allocates*: `cef_host` mints (and on resize
  re-mints) the shared surface itself and announces it to the host via
  `opPresent` frames carrying `{surface-id, srcW, srcH}` (the host promotes a
  frame only when its dims match the expected size — see
  `docs/OSR_SCALE_MISMATCH.md`). `--profile-dir` is always passed; a
  persistent (named) profile points it at a stable cache dir, while an ephemeral
  profile points it at a unique throwaway temp dir and adds `--ephemeral` (so the
  host's CDP / mock-keychain guards fire only for a real persistent profile —
  `--profile-dir` alone can't distinguish the two). `--profile-dir` is per-process
  — the shared cache is what makes one login (cookies, storage) shared across the
  browsers in the profile.
- Relays method-channel calls → IPC opcodes to `cef_host`, and IPC events from
  `cef_host` → `invokeMethod` back to Dart.

The method/event protocol it must implement is the same on every platform — see
the `case` labels in `FlutterCefPlugin.handle` (host→native verbs: `create`,
`navigate`, `loadTrusted`, `resize`, `dispose`, `pointer`, `key`, `reload`,
`executeJavaScript`, cookies, IME, …) and the `emit(...)` calls (native→Dart
events: `cursor`, `loadingState`, `title`, `url`, `consoleMessage`, `jsDialog`,
`cookies`, `imeCompositionBounds`, …).

## 3. The `cef_host` subprocess — the platform seams

Reference: `packages/flutter_cef_macos/native/cef_host/` (`main.mm` is the
browser process, `process_helper.mm` the CEF child processes). The CEF client /
app / handler logic, the browser-control functions, the navigation scheme
allowlist, and the **IPC opcode protocol** are platform-agnostic C++ and can be
reused verbatim. Only these seams are macOS-specific (file:line are into
`main.mm` at the time of writing):

| Seam | macOS reference | What your platform provides |
| --- | --- | --- |
| **Shared surface** — receive painted frames and present them to the host texture. CEF delivers either software `OnPaint` (CPU buffer) or `OnAcceleratedPaint` (a shared GPU texture handle). | `OnPaint` / `OnAcceleratedPaint` + the `IOSurface*` ops (~lines 346–450); `g_surface` (~133). macOS uses an IOSurface-backed `CVPixelBuffer`. | **Windows**: a shared D3D11 texture. Note (verified against CEF 144 `cef_types_win.h` + Flutter engine `external_texture_d3d.cc`): CEF's `OnAcceleratedPaint` delivers an **NT** handle (no keyed mutex, non-owning, pool-released when the callback returns — open it synchronously via `ID3D11Device1::OpenSharedResource1`), while Flutter's ANGLE compositor requires a **legacy** `D3D11_RESOURCE_MISC_SHARED` handle (`EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE`); the two are mutually exclusive on one texture, so exactly one `CopyResource` NT→legacy is structurally mandatory (macOS also blits — `CompositeMetalLocked`). **Linux**: shared memory or a DMA-buf, presented via the platform texture. Either way the model is **producer-allocates**: `cef_host` mints the shared surface and announces it via `opPresent` — the host does NOT pass a surface id in the create (the macOS field name differs too: `shared_texture_io_surface` vs Windows `shared_texture_handle`, so the accelerated-paint glue takes a per-OS `#if`, not a typedef). |
| **IPC transport** — a framed bidirectional byte stream to the host. Wire format: 4-byte big-endian length prefix, then `[u32 browserId][opcode][payload]` (`browserId 0` = process-level: `opReady`, process logs, `opShutdown`). | `WriteAll`/`ReadAll` (207–235), `SendFrame` (~237–249), `ConnectUnixSocket` (1341+), the read loop (~1140). Unix domain socket. | **Windows**: a named pipe. **Linux**: a Unix domain socket (reuse as-is). Keep the same length-prefixed framing and the `browserId` dimension. |
| **App / run loop** — give CEF a host application + message loop, and a per-profile cache dir. | `CefHostApplication : NSApplication<CefAppProtocol>` (304–330); `@autoreleasepool` + `sharedApplication` (1420+); `--profile-dir` → `settings.root_cache_path` cache; `_NSGetExecutablePath` (1335). | **Windows/Linux**: the platform's CEF message-loop integration (`CefRunMessageLoop` or OS loop) and the caller-supplied `--profile-dir` (per-profile, persistent) as the cache path. |
| **Agent-control CDP pipe (optional)** — for `agentControl`, the host launches `cef_host` so Chromium's `--remote-debugging-pipe` (NUL-framed CDP JSON) rides **inherited file descriptors 3=read / 4=write** instead of a TCP port. | `CefProfileHost.launchViaPosixSpawn` (Swift): two `pipe()` pairs `dup2`'d onto fds 3/4 via `posix_spawn_file_actions`, parent ends marked `FD_CLOEXEC`; `cef_host` appends `remote-debugging-pipe` in `OnBeforeCommandLineProcessing`. The relay (`CdpRelay.swift`) + per-tile Target filter are platform-agnostic; only the fd placement is OS-specific. | **Linux**: reuse the `posix_spawn_file_actions` fd-3/4 recipe verbatim. **Windows**: a different model — `CreatePipe` + `SetHandleInformation(HANDLE_FLAG_INHERIT)` + `STARTUPINFOEX` `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, and Chromium takes the two inherited pipe **HANDLE values** via the separate switch `--remote-debugging-io-pipes=<read>,<write>` (uint32-serialized HANDLEs, passed **in addition to** the bare `--remote-debugging-pipe` — verified against `content_switches.cc` at chromium 144.0.7559.254; `--remote-debugging-pipe` itself takes no arguments on any platform). The default (non-agent) launch also needs a native `exec`/`CreateProcess` (Foundation.Process is macOS-only). |
| **Sandbox** — bring the child processes into the Chromium sandbox in a signed/release build. | `process_helper.mm`: `CefScopedSandboxContext` (release only); `settings.no_sandbox` toggled by `CEF_HOST_ADHOC` (1426/1433). | **Windows**: CEF 144 ships **no `cef_sandbox.lib`** — the current model (`cef_sandbox_win.h`, CEF issue #3824) is: build your app as a **DLL** exporting `RunWinMain`/`RunConsoleMain` and launch it through the prebuilt `bootstrap.exe`/`bootstrapc.exe` from the CEF distribution, which establishes the sandbox before entering your code. **Linux**: the SUID / user-namespace sandbox helper. |
| **Framework / resource path** — point CEF at the CEF binary distribution. | `CefScopedLibraryLoader::LoadInMain`/`LoadInHelper`; `framework_dir_path` / `main_bundle_path` (1453/1466). | The equivalent paths for your bundle layout. |
| **Build + bundle + sign** | `native/build_cef_host.sh` (CMake, `CEF_MULTI_PROCESS` / `CEF_HOST_ADHOC` flags), `tool/bundle_cef_host.sh`. | A platform build that produces `cef_host` + the CEF runtime, and a bundling step into the host app. |

The fetched CEF distribution already ships per-platform binaries and a CMake
config (`cef_binary_*_{macosarm64,windows64,linux64}`), so most of
`build_cef_host.sh` and `CMakeLists.txt` is reusable — adjust the
platform-specific link libs and the surface/transport sources.

## 4. Recommended: extract a `core/` + `platform/` split *with* your port

The macOS `main.mm` currently keeps the portable CEF logic and the macOS glue in
one translation unit. The seams above are the natural cut line:

```
native/cef_host/
  core/        # protocol (opcodes + framing), CEF client/app, browser control,
               #   navigation allowlist, dispatch loop — depends only on platform.h
  platform/
    mac/       # IOSurface/Metal, Cocoa app, Unix socket, sandbox, paths
    <os>/      # your implementations of the same platform.h interface
```

This split is deliberately **not** done up front: a platform abstraction
designed without a second consumer tends to guess the seam wrong. Do it as the
first step of your port, using the table above as the contract — extract the
portable pieces into `core/` behind a small `platform.h`, implement `platform.h`
for macOS (moving the existing code) and for your OS, and you have a shared core
validated by two real platforms.

## Checklist

- [ ] `flutter_cef_<os>` package: pubspec (`implements`, `pluginClass`,
      `dartPluginClass`) + `registerWith`.
- [ ] Endorse via `default_package` in the app-facing `flutter_cef/pubspec.yaml`.
- [ ] Host plugin: texture registration, subprocess spawn, channel ↔ IPC relay.
- [ ] `cef_host`: implement the five seams (surface, transport, app loop,
      sandbox, paths); reuse the CEF logic + opcode protocol.
- [ ] Build + bundle + (release) signing for the platform.
- [ ] `example/` runs on the platform; pointer / keyboard / IME / navigation work.
