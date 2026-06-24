# Contributing to flutter_cef

`flutter_cef` embeds a live Chromium browser (via the
[Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef/)) as a
Flutter `Texture` on **macOS 12+**. This guide covers the repo layout, building
the native renderer, and running the same checks CI does before you open a PR.

## Package layout (federated plugin)

The repo is a federated plugin — three packages, consumed from source (path /
git), not yet from pub.dev:

| Package | Path | What it is |
| --- | --- | --- |
| `flutter_cef` | repo root (`lib/`, `pubspec.yaml`) | The app-facing API: `CefWebView`, `CefWebController`. Re-exports the platform interface. |
| `flutter_cef_platform_interface` | `packages/flutter_cef_platform_interface` | The shared Dart types + the method-channel contract every platform implementation speaks. No native code. Breaking changes here require a major bump + a coordinated update of all implementations. |
| `flutter_cef_macos` | `packages/flutter_cef_macos` | The endorsed macOS implementation: the Swift host plugin (`FlutterCefPlugin`), the `cef_host` subprocess sources + build, the CDP relay, and the bundling tooling. |

The root `flutter_cef` package depends on both siblings via `path:` and endorses
`flutter_cef_macos` as the macOS `default_package`, so a plain dependency on
`flutter_cef` pulls in macOS support automatically. `example/` is a full browser
chrome (URL bar, back/forward/reload, loading bar, live title) plus the
integration probes (`example/lib/*.dart`).

A new platform is a sibling `flutter_cef_<os>` package — see
[`PORTING.md`](PORTING.md) for the contract and seam map.

### Dependency / publish model

Federation members are wired as `path:` deps because the repo is consumed from
source. `pub publish` rejects path deps, so **if/when we publish, publish
bottom-up**:

1. `flutter_cef_platform_interface`
2. `flutter_cef_macos`
3. `flutter_cef` (root)

At each step, swap the sibling `path:` deps for hosted caret constraints and keep
the `path:` entries under `dependency_overrides` for local dev. See the inline
note in the root `pubspec.yaml` (deps section) for the canonical wording.

## Building the `cef_host` subprocess

CEF (~200 MB) is **fetched, not vendored**. The off-screen renderer
(`cef_host.app`) is built once from
`packages/flutter_cef_macos/native/build_cef_host.sh`.

**Prerequisites:** `cmake` + `ninja` (the script drives a CMake/Ninja build),
Xcode command-line tools, and a network connection (first run downloads +
SHA-256-verifies the pinned CEF binary distribution into `~/.cache/flutter_cef`).

```sh
cd packages/flutter_cef_macos
native/build_cef_host.sh            # fetches CEF + builds cef_host.app -> native/cef_host/build
export FLUTTER_CEF_HOST="$PWD/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host"
cd ../../example && flutter run -d macos
```

The plugin resolves `cef_host` in this order: `$FLUTTER_CEF_HOST` → pod
resources → the host app's `Contents/Frameworks` → `Contents/Helpers`. For dev
work, exporting `$FLUTTER_CEF_HOST` is the easy path.

### Build flags

The script reads a few env vars (defaults in parentheses):

| Var | Default | Effect |
| --- | --- | --- |
| `CEF_HOST_ADHOC` | `ON` | **Dev/CI.** Ad-hoc signature, mock keychain, Mach-port peer-validation bypass — runs without Developer-ID signing, unsandboxed. `OFF` = **signed release**: real Keychain/OSCrypt, enforced validation, sandbox — requires correct inside-out Developer-ID signing. Also required for at-rest cookie encryption on a persistent profile. |
| `CODESIGN_ID` | `-` (ad-hoc) | Pass a Developer ID / Apple Development identity for standalone use. When bundled into a host app, the app's own signing re-signs the tree instead. |
| `CEF_MULTI_PROCESS` | `ON` | Multi-process GPU-accelerated OSR (crash-isolated, heavy SPAs render). `OFF` = simpler single-process software-blit fallback. |
| `FLUTTER_CEF_CACHE` | `~/.cache/flutter_cef` | Where the CEF dist is fetched/extracted. |

Signed-release build:

```sh
CEF_HOST_ADHOC=OFF CODESIGN_ID="<Developer ID>" native/build_cef_host.sh
```

### Bundling into a distributable app

For a shipped `.app` (no dev env var), `cef_host.app` must live in
`Contents/Frameworks` and be signed by your build. After `flutter build macos`,
run `packages/flutter_cef_macos/tool/bundle_cef_host.sh` (see the snippet at the
top of that script to wire it as a Run Script build phase on the Runner target,
so it runs before Xcode's code-sign phase). The script picks entitlements by
signing posture: ad-hoc (`-`) keeps `entitlements.plist` (with `get-task-allow`,
for debugging); a real identity uses `entitlements.release.plist` (no
`get-task-allow`). Your host app **must not be App-Sandboxed**.

## Running checks locally (exactly as CI does)

CI (`.github/workflows/ci.yaml`, `macos-14`, Flutter **3.38.8 / stable**) runs
the steps below in order. Reproduce them all before pushing.

> CI pins Flutter to **3.38.8** — the version the primary consumer (work_canvas)
> ships against — not floating `stable`. Floating stable breaks CI whenever the
> framework adds an interface method the pinned engine doesn't carry. Use the
> same version locally if you hit an analyzer/`TextInputClient` mismatch.

### 1. Analyze (package + all sub-packages + example)

`flutter analyze` does **not** recurse into sub-packages, so CI runs it in each
one explicitly:

```sh
flutter pub get
flutter analyze
(cd packages/flutter_cef_platform_interface && flutter pub get && flutter analyze)
(cd packages/flutter_cef_macos && flutter pub get && flutter analyze)
(cd example && flutter pub get && flutter analyze)
```

### 2. Dart unit/widget tests

```sh
flutter test
```

### 3. CDP isolation filter tests (security keystone)

The per-tile CDP Target-domain isolation filter is the security boundary that
confines an agent-controlled tile to its own target. `CdpRelay.swift` uses only
system frameworks, so the suite compiles + runs with `swiftc` directly — no
Xcode/CocoaPods harness:

```sh
./packages/flutter_cef_macos/test/run_filter_tests.sh
```

A regression here once shipped unnoticed precisely because CI wasn't running it —
**do not skip it** when touching `CdpRelay.swift` or the filter.

### 4. Real-host integration probes (not in CI — run before bumping a consumer pin)

The Dart `integration_test` mocks the host method channel, so it cannot catch
native channel-delivery or CDP-relay regressions (that's how the shared-host
page→host channel bug shipped). These probes drive the **real** `cef_host`
headless and assert a `/tmp` JSON result:

```sh
./test/run_channel_integration.sh                       # all probes
./test/run_channel_integration.sh channel_probe_shared  # just one
```

Probes (`example/lib/`):
- `channel_probe` — single ephemeral host: page→host JS channel delivers.
- `channel_probe_shared` — two sessions on one shared host: channel delivers +
  routes per-session (the B→A regression).
- `multiview_probe` — agent-control / CDP relay isolation on a shared host.

The runner builds an ad-hoc `cef_host` if `$FLUTTER_CEF_HOST` is unset, and sets
`FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1` so the shared-host probes get a real
shared host (an ad-hoc host otherwise downgrades named profiles to ephemeral,
masking the very regression they guard).

## Coding conventions

- **Match the surrounding style.** This codebase favors narrow, well-commented
  changes over broad refactors. The Dart, Swift, and CMake all carry dense
  explanatory comments at the non-obvious seams — keep that up; a tricky fix
  should explain *why*, not just *what*.
- **Document threading assumptions in the native layers.** The Swift/native code
  spans the Flutter platform thread, CEF's UI thread, the GPU/Viz process, and
  the socket relay. When you touch a method that must run on (or hand off to) a
  specific thread/queue, say so in a comment — wrong-thread CEF calls are a
  common, hard-to-debug failure mode.
- **Respect the security posture.** JS channel names are validated as JS
  identifiers before injection; `runJavaScriptReturningResult` expects a single
  trusted expression; the CDP filter is deny-by-default / fail-closed /
  flatten-only. Preserve these invariants and extend the corresponding tests
  (`run_filter_tests.sh`, the integration probes) when you change behavior.
- **Keep the platform-interface contract clean.** New cross-platform surface goes
  through `flutter_cef_platform_interface`; macOS-specific plumbing stays in
  `flutter_cef_macos`. Don't reach around the method-channel contract.

## Pull requests

- Run all four check stages above (analyze ×4, `flutter test`,
  `run_filter_tests.sh`, and — for anything touching native delivery or the
  relay — `run_channel_integration.sh`).
- Add a `CHANGELOG.md` entry.
- If you change the wire protocol, update both `flutter_cef_platform_interface`
  and `flutter_cef_macos` in the same PR, and note any pin-bump implications for
  consumers.
