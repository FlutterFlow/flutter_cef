# flutter_cef — federated cross-platform restructure

Goal: restructure the package so a Windows/Linux implementation can be added
later as an independent, endorsed federated package, without touching the
app-facing API or the macOS implementation. The Dart `lib/` is already
platform-neutral; the work is (1) splitting into federated packages and (2)
giving the native `cef_host` an internal portable-core / platform-glue seam so
the C++ is shareable across OS implementations down the line.

## Target layout

```
flutter_cef/                         # repo root = app-facing package (unchanged name/version)
  lib/
    flutter_cef.dart                 # re-exports public API + shared types
    src/cef_web_view.dart            # widget (app-facing)
    src/cef_web_controller.dart      # controller (app-facing) — talks the shared channel
  example/                           # unchanged location; deps resolve to the federated packages
  packages/
    flutter_cef_platform_interface/  # the cross-platform contract
      lib/flutter_cef_platform_interface.dart
      lib/src/flutter_cef_platform.dart   # FlutterCefPlatform (PlatformInterface) + channel name
      lib/src/method_channel_flutter_cef.dart
      lib/src/cef_events.dart        # shared DTOs (moved from root lib/src)
      lib/src/cef_input.dart         # shared input enums/helpers (moved)
    flutter_cef_macos/               # endorsed macOS implementation (self-contained)
      lib/flutter_cef_macos.dart     # registerWith → sets the default platform instance
      macos/                         # Swift plugin + podspec (moved from root macos/)
      native/cef_host/               # moved from root native/; restructured:
        core/                        #   PORTABLE C++: protocol + CEF client/app + browser control
        platform/mac/               #   macOS glue: IOSurface/Metal/Cocoa/Unix-socket/sandbox
      tool/bundle_cef_host.sh        # moved from root tool/
  PORTING.md                         # what a flutter_cef_windows / _linux must implement
```

`flutter_cef` depends on `flutter_cef_platform_interface` and endorses
`flutter_cef_macos` via `plugin: platforms: macos: default_package`.

## The cross-platform contract (what a new platform implements)

1. **Dart**: a `flutter_cef_<os>` package with `dartPluginClass` that sets
   `FlutterCefPlatform.instance`. In practice the contract is the method-channel
   protocol (channel name + method names + event names + the IPC opcode table),
   so a platform plugin mostly implements the native side.
2. **Native `cef_host`** — implement `core/platform.h` for the OS:
   - **Surface**: allocate/lookup a shared GPU surface by id + present painted
     frames. macOS = IOSurface-backed CVPixelBuffer + Metal; Windows = shared
     D3D11 texture / DXGI handle; Linux = shared memory / DMA-buf.
   - **IPC transport**: framed read/write. macOS/Linux = Unix domain socket;
     Windows = named pipe.
   - **App bootstrap / run loop**: macOS = NSApplication; Windows/Linux = their
     message loops.
   - **Sandbox**: macOS = `CefScopedSandboxContext`; Windows = `cef_sandbox`
     static lib + `CefScopedSandboxContext`; Linux = SUID/userns sandbox.
   - **Framework/resource path resolution** for the CEF binary distribution.
3. **Host plugin** (`macos/` equivalent): spawn the `cef_host` subprocess, own
   the texture registration, relay channel calls to the IPC opcodes.

## Phases (each ends at a green gate: analyze + test + macOS example build)

- **P1 — platform_interface package.** Create
  `packages/flutter_cef_platform_interface`; move `cef_events.dart` +
  `cef_input.dart`; add `FlutterCefPlatform` (PlatformInterface) holding the
  channel name + default `MethodChannelFlutterCef`. Root `flutter_cef` depends on
  it; controller uses the shared channel name. Gate: `flutter analyze` + `flutter test`.
- **P2 — flutter_cef_macos package.** Move `macos/`, `native/`, `tool/` into
  `packages/flutter_cef_macos`; rename podspec → `flutter_cef_macos.podspec`; fix
  every relative path (`build_cef_host.sh`, `bundle_cef_host.sh`, podspec,
  CMake, FLUTTER_CEF_HOST resolution in the Swift plugin); add
  `lib/flutter_cef_macos.dart` + `dartPluginClass`. Root pubspec endorses it via
  `default_package`. Gate: example macOS build + signed-host smoke.
- **P3 — native core/platform split.** Inside `flutter_cef_macos/native/cef_host`,
  extract `core/` (protocol.h + CEF client/app + browser control + dispatch
  loop, depending only on `core/platform.h`) and `platform/mac/` (the ~50
  macOS-specific sites). Gate: rebuild cef_host (ad-hoc + signed) clean.
- **P4 — docs.** `PORTING.md`, README structure, CHANGELOG. Gate: `git diff --check`.

## Invariants

- macOS must build + render at every phase gate (verify, don't assume).
- App-facing API (`CefWebView`, `CefWebController`, exported types) unchanged —
  consumers' imports of `package:flutter_cef/flutter_cef.dart` keep working.
- No behavior change; this is structure only.
- Dev path-deps during the restructure; switch to version deps only at publish.
