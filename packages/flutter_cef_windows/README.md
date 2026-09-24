# flutter_cef_windows

The endorsed Windows implementation of [`flutter_cef`](../../README.md): a
live Chromium (CEF) browser rendered off-screen in a `cef_host` subprocess
and composited into the Flutter scene as a `Texture` (DXGI shared-texture
path).

The wire/channel contract the implementation follows is
[`native/cef_host/PROTOCOL.md`](native/cef_host/PROTOCOL.md); the original
port plan and spikes are in
[`docs/history/windows-port/`](../../docs/history/windows-port/).

## What works, and what doesn't

Windows serves the same channel verbs as macOS, with these exceptions:

- `chooseContextMenu`, `respondMediaRequest`, `setMediaSetting`,
  `openAuthWindow` and `showEmojiPicker` reply with a `PlatformException`
  whose code is `unsupported`. The host never raises the events that lead to
  them (no page context menu, no camera/microphone prompt), and a sized
  `window.open` popup (OAuth sign-in) loads in the tile itself, so the
  opener/postMessage handshake can't complete.
- A verb the plugin doesn't know replies `MissingPluginException`.
- `freezeSession`/`thawSession`, `sessionStats`, `setAudioMuted` and
  `setFrameInterval` are implemented. `setFrameInterval` sets the tile's
  windowless frame rate (the interval is clamped to 8-250 ms).
- The IME candidate window doesn't follow the caret (the host sends no
  composition bounds).
- Only the `en-US` locale pak ships.

Liveness matches macOS except for one check: the plugin reports
`paintStalled` for a tile that never paints, and ends a host whose renderer
leaves a JS ping unanswered for 15 s (`FLUTTER_CEF_HANG_MS`), but it does not
detect a replaced GPU process.

## Sandbox

`cef_host` runs Chromium's sandbox: CEF's bootstrap (`cef_host.exe`) hands the
host its sandbox info, and the renderer and GPU processes start sandboxed. To
rule the sandbox in or out while diagnosing a child process that won't start,
set `FLUTTER_CEF_NO_SANDBOX=1` in the app's environment; the host then logs that
it is running unsandboxed. Don't ship with it set.

## Downloads

A download opens the system Save As dialog, prefilled with the page's
suggested name in the user's Downloads folder (made safe for Windows, and
given a ` (2)`-style suffix when that name is taken). Nothing is written
unless the user confirms. The app also gets a `download` event with the
suggested name.

## Rendering

Frames normally arrive from Chromium's GPU compositor as shared D3D11
textures. When GPU compositing is unavailable (a blocklisted GPU, Remote
Desktop, a VM), Chromium paints in software and the host uploads those frames
into the same shared texture, so tiles still render. The host creates its
D3D11 device on the hardware adapter and falls back to WARP (the software
rasterizer) when there is none. `<select>` dropdowns are drawn over the view.

`FLUTTER_CEF_SOFTWARE_COMPOSITING=1` turns the GPU off for every host, so
Chromium paints in software. It is how CI covers the software path, and it
helps tell a GPU-driver problem from a page problem.

## Layout

- `lib/flutter_cef_windows.dart` — `registerWith()` endorsing the shared
  method-channel platform implementation.
- `windows/` — the C++ plugin: channel dispatch (`flutter_cef_plugin.*`),
  `texture_bridge.*` (Flutter texture side), `host_process.*` (cef_host
  spawn/lifecycle), `ipc_pipe.*` (named-pipe framing), `cdp_relay.*` (the
  agent-control CDP relay), `liveness_policy.h` (the liveness sweep's
  decisions).
- `native/cef_host/` — the standalone CEF OSR host: `cef_host_win.cc`
  builds as `cef_host.dll` (exports `RunConsoleMain`), shipped beside CEF's
  `bootstrapc.exe` renamed to `cef_host.exe`. `build_cef_host.bat` builds it
  (driven from the plugin CMake during `flutter build windows`);
  `fetch_cef.ps1` resolves the pinned CEF distribution. `cef_host_policy.h`
  holds the pure decisions the host and plugin share.
- `test/native/` — unit tests for the pure policy headers
  (`run_policy_tests.sh`; any C++17 compiler).

## Build prerequisites (dev box)

- VS2022 (MSVC + the bundled CMake/Ninja; they are NOT on PATH — the build
  scripts use absolute paths), Flutter 3.38.8, Developer Mode ON (plugin
  symlinks are true symlinks).
- The CEF distribution pinned in `native/cef_host/cef_pin.txt` (version and
  SHA-256). The build resolves it from the `CEF_ROOT` env var, else
  `%LOCALAPPDATA%\flutter_cef\<dist>`, else downloads and verifies it
  (`native/cef_host/fetch_cef.ps1`). Configure fails if the resolved tree's
  `include/cef_version.h` isn't the pinned version.
