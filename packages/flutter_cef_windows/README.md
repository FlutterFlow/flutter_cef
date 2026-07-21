# flutter_cef_windows

The endorsed Windows implementation of [`flutter_cef`](../../README.md): a
live Chromium (CEF) browser rendered off-screen in a `cef_host` subprocess
and composited into the Flutter scene as a `Texture` (DXGI shared-texture
path).

**Status: Phase-1 skeleton of the Windows-port vertical slice.** The plugin
registers the `flutter_cef` channel and answers every verb (stubbed), the
`cef_host` skeleton connects the IPC pipe and announces `kOpReady`, and the
example app builds/runs with a blank tile. The authoritative plan is
`specs/windows-port/PLAN.md` + `SPIKES.md`; the wire/channel contract the
implementation follows is [`native/cef_host/PROTOCOL.md`](native/cef_host/PROTOCOL.md).

## Layout

- `lib/flutter_cef_windows.dart` — `registerWith()` endorsing the shared
  method-channel platform implementation.
- `windows/` — the C++ plugin: channel dispatch (`flutter_cef_plugin.*`),
  `texture_bridge.*` (Flutter texture side), `host_process.*` (cef_host
  spawn/lifecycle), `ipc_pipe.*` (named-pipe framing).
- `native/cef_host/` — the standalone CEF OSR host: `cef_host_win.cc`
  builds as `cef_host.dll` (exports `RunConsoleMain`), shipped beside CEF's
  `bootstrapc.exe` renamed to `cef_host.exe`. `build_cef_host.bat` builds it
  (driven from the plugin CMake during `flutter build windows`);
  `fetch_cef.ps1` resolves the pinned CEF distribution.

## Build prerequisites (dev box)

- VS2022 (MSVC + the bundled CMake/Ninja; they are NOT on PATH — the build
  scripts use absolute paths), Flutter 3.38.8, Developer Mode ON (plugin
  symlinks are true symlinks).
- The pinned CEF distribution
  `cef_binary_144.0.27+g3fae261+chromium-144.0.7559.254_windows64_minimal`,
  resolved via the `CEF_ROOT` env var (see `native/cef_host/fetch_cef.ps1`).
