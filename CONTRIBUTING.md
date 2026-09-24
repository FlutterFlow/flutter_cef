# Contributing to flutter_cef

`flutter_cef` embeds a live Chromium browser (via the
[Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef/)) as a
Flutter `Texture` on **macOS 12+** (Apple silicon) and **Windows 10+** (x64). This guide covers the repo layout, building
the native renderer, and running the same checks CI does before you open a PR.

## Package layout (federated plugin)

The repo is a federated plugin — four packages, consumed from source (path /
git), not yet from pub.dev:

| Package | Path | What it is |
| --- | --- | --- |
| `flutter_cef` | repo root (`lib/`, `pubspec.yaml`) | The app-facing API: `CefWebView`, `CefWebController`. Re-exports the platform interface. |
| `flutter_cef_platform_interface` | `packages/flutter_cef_platform_interface` | The shared Dart types + the method-channel contract every platform implementation speaks. No native code. Breaking changes here require a major bump + a coordinated update of all implementations. |
| `flutter_cef_macos` | `packages/flutter_cef_macos` | The endorsed macOS implementation: the Swift host plugin (`FlutterCefPlugin`), the `cef_host` subprocess sources + build, the CDP relay, and the bundling tooling. |
| `flutter_cef_windows` | `packages/flutter_cef_windows` | The endorsed Windows implementation: the C++ plugin, the Windows `cef_host` (built by CMake during `flutter build windows`), the CDP relay, and `PROTOCOL.md`. |

The root `flutter_cef` package depends on both siblings via `path:` and endorses
`flutter_cef_macos` and `flutter_cef_windows` as the `default_package` for
their platforms, so a plain dependency on `flutter_cef` pulls in both. `example/` is a full browser
chrome (URL bar, back/forward/reload, loading bar, live title) plus the
real-host probes (`example/lib/*_probe.dart`).

A new platform is a sibling `flutter_cef_<os>` package — see
[`PORTING.md`](PORTING.md) for the contract and seam map.

### Dependency / publish model

Federation members are wired as `path:` deps because the repo is consumed from
source. `pub publish` rejects path deps, so **if/when we publish, publish
bottom-up**:

1. `flutter_cef_platform_interface`
2. `flutter_cef_macos` and `flutter_cef_windows`
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
FLUTTER_CEF_STOCK_FRAMEWORK=1 native/build_cef_host.sh   # fetches CEF + builds cef_host.app -> native/cef_host/build
export FLUTTER_CEF_HOST="$PWD/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host"
cd ../../example && flutter run -d macos
```

`native/cef_host/CEF_FRAMEWORK_VARIANT` pins a patched CEF framework (the
published prebuilt carries a WebAuthn keychain patch and H.264/AAC), which
takes a from-source Chromium build (`native/build-cef-from-source.sh`).
`FLUTTER_CEF_STOCK_FRAMEWORK=1` builds against the stock framework instead; the
host works, minus those patches, and can't be published.

The plugin resolves `cef_host` in this order: `$FLUTTER_CEF_HOST` → pod
resources → the host app's `Contents/Frameworks` → `Contents/Helpers`. For dev
work, exporting `$FLUTTER_CEF_HOST` is the easy path.

### Build flags

The script reads a few env vars (defaults in parentheses):

| Var | Default | Effect |
| --- | --- | --- |
| `CEF_HOST_ADHOC` | `ON` | **Dev/CI.** Ad-hoc signature, mock keychain, Mach-port peer-validation bypass — runs without Developer-ID signing, unsandboxed. `OFF` = **signed release**: real Keychain/OSCrypt, enforced validation, sandbox — requires correct inside-out Developer-ID signing, and signs with a secure timestamp (needed for notarization). Also required for at-rest cookie encryption on a persistent profile. |
| `CODESIGN_ID` | `-` (ad-hoc) | Pass a Developer ID / Apple Development identity for standalone use. When bundled into a host app, the app's own signing re-signs the tree instead. |
| `CEF_MULTI_PROCESS` | `ON` | Multi-process GPU-accelerated OSR (crash-isolated, heavy SPAs render). `OFF` = simpler single-process software-blit fallback. |
| `FLUTTER_CEF_STOCK_FRAMEWORK` | unset | `1` = build against the stock CEF framework even though `CEF_FRAMEWORK_VARIANT` pins a patched one. For contributors and CI; `publish-cef-host.sh` refuses it. |
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

## The wire protocol

The plugin and `cef_host` talk over a byte stream of opcode frames. Every
opcode and each platform's protocol version is defined once, in
`tool/protocol/spec.dart`. To add or change one, edit the spec and run

```sh
dart run tool/protocol/generate.dart
```

which rewrites `cef_host_opcodes.h` (macOS and Windows), `CefHostOpcodes.swift`
and the opcode table in the Windows `PROTOCOL.md`. Bump the platform's version
in the spec for any change the other side can't ignore.
`test/protocol_parity_test.dart` fails on a stale copy or an opcode defined by
hand.

## Running checks locally (exactly as CI does)

CI (`.github/workflows/ci.yaml`, `macos-14`, Flutter **3.38.8 / stable**) runs
the steps below in order. Reproduce them all before pushing.

> CI pins Flutter to **3.38.8** — the version the primary consumer
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

### 3. Swift tests

The plugin's pure-logic pieces (the CDP isolation filter, the liveness and
resize policies) use only system frameworks, so each suite compiles and runs
with `swiftc` directly, with no Xcode or CocoaPods harness. CI runs every
`run_*.sh` in the test folder:

```sh
for t in packages/flutter_cef_macos/test/run_*.sh; do "$t" || break; done
```

The CDP filter suite (`run_filter_tests.sh`) guards the boundary that confines
an agent-controlled tile to its own target; a regression there once shipped
because CI didn't run it.

### 4. Real-host probes (not in CI; run before bumping a consumer pin)

The Dart tests mock the method channel, so they can't catch a regression in the
plugin, `cef_host` or the wire between them. The probes in `example/lib` are app
entry points that drive a real `cef_host` and report PASS or FAIL:

```sh
tool/run_probes.sh                 # every automatic probe (about 20 minutes)
tool/run_probes.sh page_boundary   # just one (prefix match)
tool/run_probes.sh --list          # what each probe checks, including manual ones
```

It tests the host at `$FLUTTER_CEF_HOST`, or the one `build_cef_host.sh` built.
Probes that open a named profile run with `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1`,
so an ad-hoc host keeps the profile instead of downgrading it. Run the probes
that cover the code you touched, and the whole set for any native change. A new
probe prints `CEF_PROBE_RESULT PASS|FAIL` on stdout, then exits, and gets a row
in the script's table.

Longer gates for the rendering pipeline, run by hand after changing surface or
pacing code: `test/run_cascade_probe.sh` (many tiles created at once all
paint), `example/run_conformance_oracle.sh` (no wrong-size or blank frames
under resize, zoom and cull storms) and `example/run_leak_soak.sh` (surfaces
and memory stay bounded under recreate churn).

## Coding conventions

- **Match the surrounding style.** This codebase favors narrow, well-commented
  changes over broad refactors. The Dart, Swift, and CMake all carry dense
  explanatory comments at the non-obvious seams — keep that up; a tricky fix
  should explain *why*, not just *what*.
- **Say the reason in words.** Comments carry no audit or port-plan tags and
  no `file.ext:<line>` citations; CI runs `tool/check_comment_tags.sh`, which
  fails on them.
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

- Run the check stages above: analyze, `flutter test`, the Swift suites, and,
  for anything touching native code or the relay, `tool/run_probes.sh`.
- Add a `CHANGELOG.md` entry.
- If you change the wire protocol, change `tool/protocol/spec.dart`, regenerate,
  and update every platform that speaks the changed opcodes in the same PR. A
  macOS protocol change also needs a new prebuilt (`make publish-cef-host`)
  before consumers can repin.
