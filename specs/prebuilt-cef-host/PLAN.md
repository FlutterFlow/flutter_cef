# Prebuilt, auto-bundled cef_host — make flutter_cef "just a Flutter package"

## Status — content-hash + GCS + Codemagic (supersedes the manifest/GitHub-release model)

The prebuilt is now **keyed by a content hash of the build inputs** (`native/cef_host/` +
`build_cef_host.sh`) and served from **public GCS** — not by a committed manifest + ad-hoc
GitHub release. Why: the artifact decouples from how flutter_cef versions itself (any
SHA/branch/tag pin that checks out the same native sources resolves to the same object), a
Dart-only change rebuilds nothing, and the signing material never touches this public repo.
The published variant is the **sandboxed, Developer-ID** host (`CEF_HOST_ADHOC=OFF`) — the
ad-hoc variant fails to render `agent_ui` in a consumer, which is why the earlier
manifest/ad-hoc approach was not adopted downstream.

- `tool/cef_host_hash.sh` — the deterministic hash, sourced by both sides so they can't drift.
- `tool/fetch_cef_host.sh` — consumer fetch: hash → `https://storage.googleapis.com/flutterflow-downloads/campus_prebuilt_cef_host/<hash>/cef_host-macos-arm64.tar.gz`, sha256-verify, extract. Fail-open on network, fail-closed on mismatch.
- `tool/publish-cef-host.sh` — build sandboxed+signed → hash → idempotent GCS upload. CI-agnostic.
- `make publish-cef-host` — the current publisher: run it locally when `cef_host` changes
  (auto-resolves the Developer-ID identity; needs `gsutil` write). Since the host changes
  rarely, this is enough; `publish-cef-host.sh` is CI-ready if automation is wanted later
  (e.g. a step in a repo you control that already holds signing + GCS creds).

The design detail below (embedding, signing, incremental rollout) still stands; only the
publish/fetch transport changed from "committed manifest + `gh release`" to "content-hash + GCS".

## Problem
The Dart/Swift half of flutter_cef is already a normal pod. The native `cef_host.app`
(a nested SIGNED app: ~200MB Chromium + 5 helper apps) is NOT — every consumer must
**build it from source** (cmake/ninja + a CEF SDK fetch) and **manually copy + sign** it
into `Contents/Frameworks` via make/scripts. A plain `flutter build macos` produces a
broken app (no cef_host → crashes ~30s in). This is the recurring "bundle the right cef"
pain, and it created a silent pin-drift class.

## Goal
A consumer gets a working app from `flutter pub get` + a normal `flutter build macos`:
- **debug/local**: zero extra steps, no `make cef-host`, no `FLUTTER_CEF_HOST`.
- **release**: one inside-out Developer-ID re-sign (consumer identity — irreducible).
- no pin-drift: one plugin version ⇒ exactly one cef_host.

## Mechanism (the two load-bearing decisions)
1. **EMBED** — a podspec `script_phase` with `execution_position: :after_compile` that
   `ditto`s the prebuilt into `${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/cef_host.app`.
   This runs DURING `flutter build macos`, AFTER `[CP] Embed Pods Frameworks` creates
   `Contents/Frameworks`, BEFORE Xcode's codesign. (`resource_bundles` nests it inside the
   pod framework — wrong place + breaks the framework seal; `vendored_frameworks` only
   embeds `.framework`, not a nested `.app`. So `:after_compile` script_phase it is.)
   The runtime resolver already probes `Contents/Frameworks` (FlutterCefPlugin.swift:691).
2. **FETCH** — a podspec `prepare_command` (runs at `pod install`) downloads + SHA256-verifies
   a version-matched prebuilt from a GitHub release asset, driven by a committed manifest
   `cef_host_prebuilt.json` (tag, urls, the four sha256s, source_sha, cef_version).

## Signing
- **dev**: embed the ad-hoc / get-task-allow variant; non-hardened debug runtime tolerates the
  unsealed nested app. Do NOT re-sign the main app (strips the Firebase Auth keychain entitlement).
- **release**: consumer re-signs the embedded tree in place with its own Developer-ID, inside-out
  (helpers → CEF framework Versions/A dylibs + Versions/A → root). Exactly today's
  release-macos-firebase.sh:888-901, just no longer preceded by a build. The prebuilt's own
  signature is throwaway (overwritten).

## Co-dev escape hatch (retained, additive — prebuilt is default)
`FLUTTER_CEF_HOST` env still wins over the bundled prebuilt (probed first). `build_cef_host.sh`,
`bundle_cef_host.sh`, and the consumer `make cef-host` loop all keep working for native hackers.

## Increments (each independently shippable + verifiable)
- **INC 0** — de-risk the embedding. Hand-build a cef_host.app → `native/cef_host/prebuilt/`,
  add ONLY the `:after_compile` script_phase, `flutter build macos` the example, assert cef_host.app
  lands at `Contents/Frameworks` (and exactly one, nowhere nested). Validate the actual phase order
  in the generated Runner.xcodeproj; fall back to a consumer Run Script if CocoaPods won't guarantee
  `:after_compile` after embed-frameworks. **This proves the whole approach.**
- **INC 1** — dev turnkey: add a dev (get-task-allow) variant; build work_canvas with a path-override,
  no `make cef-host`, no `FLUTTER_CEF_HOST` → app survives past 30s, tiles render.
- **INC 2** — release: rewire release-macos-firebase.sh to delete the build+ditto block, keep only the
  inside-out re-sign pointed at the embedded host; produce a notarized DMG + Gatekeeper-verify.
- **INC 3** — fetch automation: `tool/fetch_cef_host.sh` + `cef_host_prebuilt.json` + podspec
  `prepare_command`; hand-upload tarballs to a `v0.2.x` GitHub release; verify turnkey from a clean
  machine (no cmake/ninja). Escape hatches still win.
- **INC 4** — publishing CI: `.github/workflows/release-cef-host.yml` on `v*` — arm64 (+x86_64)
  matrix, build both variants, inside-out sign + standalone-notarize the release variant, stamp
  provenance, tar+sha256, `gh release upload` + GCS mirror, commit the manifest back.
- **INC 5** — consumer cleanup: delete the Makefile `cef-host` target/vars, the open-firebase manual
  bundle, the release-script build block, the cmake/ninja preflight; retire cef-doctor ASSERT 2 and
  repoint ASSERT 1's host-match to the fetched `cef_host_source_sha.txt`.

## Open risks (validate as we go)
- **CocoaPods phase ordering** (the linchpin): `:after_compile` must run after embed-frameworks +
  before codesign. Validate in INC 0; fall back to a one-time consumer Run Script if not guaranteed.
- **resourceURL vs Frameworks**: resolver probes the pod resourceURL before Contents/Frameworks —
  ensure no cef_host fragment leaks into the pod resource bundle.
- **git-dep prepare_command**: confirm it runs for a git-sourced flutter_cef and the fetched prebuilt
  survives Flutter's `.symlinks/plugins` copy into the build.
- **x86_64 cross-build/sign/notarize** unproven — may ship arm64-only first, keep from-source for x64.
- **notarization** of the consumer-resigned host (prebuilt's stapled ticket is invalidated by the
  re-sign — verify the whole-app notarize still passes in INC 2).
- **manifest source_sha staleness**: a consumer pinned to an untagged commit fetches the last tag's
  prebuilt; cef-doctor's repointed assert must allow `tag <= resolved && IPC-compatible`, not strict sha.
- **artifact size**: ~293MB × 4 per tag — cache `~/.cache/flutter_cef/prebuilt/<tag>`; consider
  arm64-only default.
