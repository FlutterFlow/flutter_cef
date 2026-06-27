# CEF Off-Screen-Rendering Visibility / Resize / Cull / Lifecycle Audit

Repos:
- **flutter_cef** = `/Users/wenkaifan/.pub-cache/git/flutter_cef-c29b93f39b74be493f726130ae524e39c374ff66`
  - native = `packages/flutter_cef_macos/native/cef_host/main.mm`
  - swift = `packages/flutter_cef_macos/macos/Classes/{CefWebSession,CefProfileHost,FlutterCefPlugin}.swift`
  - dart = `lib/src/{cef_web_view,cef_web_controller}.dart`
- **Campus** = `/Users/wenkaifan/Dev/work_canvas_agentui_test` (HEAD `de0f9458`, pins flutter_cef `c29b93f`)

---

## Part 1 — Confirmed issues, deduped & ranked by severity

After dedup, the 18 confirmed entries collapse to **12 distinct defects**. The 6 "resize/visibility-while-hidden wedge" entries are genuinely distinct *members of one class* (distinct triggers, shared root + shared fix), so they are grouped as **C-1** with one row per member.

### HIGH

#### C-1. The resize/visibility-while-culled wedge class (the proven family)
Shared root: a CEF surface receives a resize **or** is shown/hidden while the per-slot begin-frame pump is gated off (`main.mm:283` `if (slot->visible)`), and **nothing forces a repaint on un-hide** (`DoSetVisible(true)` at `main.mm:1484-1487` only calls `WasHidden(false)` — no `Invalidate`/`WasResized`/`SendExternalBeginFrame`). The per-session `resizeWatchdog` then actively force-promotes a never-painted surface. No native or consumer self-heal for an already-painted tile, because the C1 first-present watchdog is retired forever on first paint (`CefProfileHost.swift:653-658`, re-arm gated on `firstPresentPending.contains` at `:702`).

| # | Member / trigger | Repo · file:line | Severity |
|---|---|---|---|
| C-1a | **W/H geometry resize while paint-culled** — `_ensureSession` resizes on any `_lastSize!=size` with no visibility guard; cull keeps the subtree mounted+laid-out (`CullByViewport` is a paint/hit-test-only `RenderProxyBox`). Fresh IOSurface never painted while hidden → `resizeWatchdog` force-promotes blank at +300ms. Permanent blank for static pages. | dart `cef_web_view.dart:255-263`; native `main.mm:283,1417-1438,1484-1487`; swift `CefWebSession.swift:291-323`; campus `viewport_cull.dart:860`, `cef_webview_tile.dart:612`, `content_layer.dart:806-808` | **high** |
| C-1b | **DoSetVisible(true) re-asserts no geometry/begin-frame** — a resize that landed while hidden is never re-applied on un-cull; Dart already advanced `_lastSize/_lastDpr` so no corrective resize either. | native `main.mm:1484-1487`, `main.mm:1432-1437`; swift `CefWebSession.swift:291-318`; dart `cef_web_view.dart:255-262` | **high** |
| C-1c | **resizeWatchdog force-promotes a never-painted (zero-filled) surface for a hidden browser** — no visibility gate; comment's premise ("pump has been painting into it the whole time") is provably false while hidden. Active anti-heal. Live-proven by commit `de0f9458`. | swift `CefWebSession.swift:287-323`; native `main.mm:283,691-692,1480-1487` | **high** |
| C-1d | **Un-cull (setVisible(true)) issues no repaint on an *evicted* surface** — Chromium `FrameEvictionManager` reclaims off-screen compositor frames (>~5 browsers / memory pressure); `WasHidden(false)` returns blank/stale and resuming begin-frames does NOT repaint (documented empirically: `specs/osr-ecosystem-survey.md:114-116`, `osr-many-views.md:138`). Same-size scroll-back sends no resize (`same` guard `CefWebSession.swift:228-239`), so resizeWatchdog never arms either. Permanent silent blank. | native `main.mm:1484-1487`; swift `CefProfileHost.swift:702`, `CefWebSession.swift:228-239`; campus `cef_webview_tile.dart:612`, `agent_ui_tile.dart:1863` | **high** |
| C-1e | **Resizing a culled cefWebview tile wedges blank** (consumer-framed instance of C-1a) — campus-resize-off-screen / area-zone relayout. Maintainers' own comment documents it (`platform_view_live_mode.dart:149-160`). | dart `cef_web_view.dart:255-263`; campus `viewport_cull.dart:879-881`, `platform_view_live_mode.dart:149-161` | **high** |
| C-1f | **DPR change while culled wedges even with renderScale pinned to dpr** — the `cefRenderScale=>dpr` stabilizer (`platform_view_live_mode.dart:161`) removed only the *zoom* trigger; a mixed-DPI monitor drag / display-scaling change still flows dpr through `renderScaleOf` → resize-while-hidden. Not peer-specific (owners too). Heals on any later visible resize; permanent only on passive scroll-back. | campus `platform_view_live_mode.dart:161,203-210`, `agent_ui_tile.dart:2038`; native `main.mm:283,1484-1487`; swift `CefWebSession.swift:291-314` | **medium** |

> Note C-1f is rated medium (narrow concurrent trigger), the rest high. All six are closed by the same two native fixes (see Fix Plan F-1, F-2).

#### C-2. Texture + IOSurface + CVPixelBuffer leak on every cef_host crash
`onHostDied` nils `sessions[sid]`/`sessionHost[sid]` **without** calling `session.dispose()`, so `registry.unregisterTexture` (its only caller, `CefWebSession.swift:476` inside `dispose()`) never runs; the later Dart `controller.dispose()` early-returns in `disposeSession` (`guard let session = sessions[id] else { return }`). `FlutterTextureRegistry` pins the texture; no `deinit`. Per crashed browser: `CefWebSession` + textureId + `CVPixelBuffer` + IOSurface + any un-promoted `pendingBuffer` leak for engine lifetime. Asymmetric vs `onBrowserFailed`/respawn-failure which DO dispose.
- swift `FlutterCefPlugin.swift:489-495` (vs dispose sites 518/576/654/660/663); `cef_web_controller.dart:888`; `FlutterCefPlugin.swift:645`; `CefWebSession.swift:185,476`
- **Severity: HIGH** (unbounded resource leak under the exact condition — host crashes — where recovery happens most).

### MEDIUM

#### C-3. No post-establishment liveness watchdog (native) + no consumer-side stale detector
Merges the two detector-gap findings. C1 first-present watchdog retires permanently at first paint (`firstPresentArrived` removes id from both `firstPresentPending` and `watchdogArmed`, `CefProfileHost.swift:653-658`; `checkFirstPresent` bails on `guard stillBlank`, `:721-745`); `resizeWatchdog` only covers the in-flight-resize window (`CefWebSession.swift:293`). A single browser's renderer/GPU stall inside a *shared* host keeps the host pipe alive → no `processGone`. Consumer `recover()` is triggered *only* by `onPaintStalled`(first-paint-only)/`onProcessGone`/establishment-watchdog (`cef_session_controller.dart:120-123,136-143,158-160`). A browser that paints ≥1 frame then wedges has **no detector at either layer**.
- swift `CefProfileHost.swift:653-658,721-745,1068`; `CefWebSession.swift:291-323`; campus `cef_session_controller.dart:120-123,136-160`, `platform_view_live_mode.dart:180-187`, `cef_webview_tile.dart:231-238,340-342`
- **Severity: MEDIUM** (missing detector / defense-in-depth; impact contingent on a post-first-paint wedge — but C-1d is exactly such a wedge, so this gap is what lets C-1d stay silent).

#### C-4. Visibility op outruns create → tile establishes VISIBLE and paints off-screen
Merges the "PACED create" and "queued opCreateBrowser on busy shared host" findings (same root). `send()` never gates `opSetVisible` (only `opResize` gets the `!createEnqueued` guard, `CefProfileHost.swift:761`); on a connected shared host with the K=3 pacer full the create sits in `createSendQueue` while `opSetVisible(false)` reaches the wire first. cef_host drops it (`main.mm:1938-1942` `if(!slot) break;`); create payload carries no visibility (`{w}{h}{dpr}{sid}{url}`, `sendCreate:504-524`); slot defaults `visible=true` (`main.mm:238`) and pumps at 60fps. `hiddenBrowsers` desyncs (noteVisibility ran before the dropped write, suppressing the C1 watchdog). cefWebview is the exposed consumer (`cef_webview_tile.dart:612`, ungated); agent_ui is guarded (defers on `_sessionReady`, replays in onPageStarted `agent_ui_tile.dart:1799-1804`) but its eager-spawn-adopt path is still vulnerable.
- swift `CefProfileHost.swift:752-775,504-524,689,1051-1056`; native `main.mm:238,283,1293,1867,1938-1942`; campus `cef_webview_tile.dart:612`, `viewport_cull.dart:988-997`, `canvas_snapshot_restore.dart:87-107`
- **Severity: MEDIUM** (power/perf, not crash/data; self-heals on next visibility flip; agent_ui immune).

#### C-5. Single CEF UI thread couples every tile on a shared host
Per-present synchronous GPU blit (`[cb waitUntilCompleted]`) plus all resize/dispose/input/visibility tasks serialize on one TID_UI; each slot's `PumpBeginFrame` ticks independently at 16ms with no cross-slot fairness or aggregate cap. N visible tiles = N uncoordinated 60fps pumps through one thread.
- native `main.mm:280-291,673-677`
- **Severity: MEDIUM** (scalability/latency ceiling; low-medium in practice on Apple Silicon unified memory — blit "~neutral" per comment `:677`).

### LOW

#### C-6. Un-hide drives no immediate begin-frame (~100ms first-repaint latency)
`DoSetVisible` calls `WasHidden(false)` only; first post-show frame waits for the next hidden-cadence pump tick (`slot->visible ? 16 : 100`, `main.mm:291`). Stale (not blank) frame for already-painted tiles. Same root as C-1b; the immediate-kick idiom exists in `DoResize`(1437)/`DoInvalidate`(1818) but not `DoSetVisible`.
- native `main.mm:1484-1487,280-291`; **Severity: LOW**.

#### C-7. OnAfterCreated does not reconcile slot->visible
A `setVisible(false)` resolving a non-null-but-unbound slot runs `DoSetVisible` with `browser==null`, skipping `WasHidden` (guarded `if(slot->browser)`); `OnAfterCreated` binds the browser but never reconciles desired visibility (it DOES reconcile `close_requested` via the H3 pattern — asymmetric). Residue: missing blink page-hidden throttling on a tile created off-screen and never revealed; one wasted paint per resize-while-culled (`DoResize` `SendExternalBeginFrame` is unconditional, `main.mm:1437`).
- native `main.mm:238,1032-1048,1307-1310,1437,1485-1486`; **Severity: LOW**.

#### C-8. onPaintStalled is first-paint-only; no consumer-side post-establishment detector
Consumer-side framing of C-3 (kept distinct because the fix is a consumer un-hide freshness check). `onSurface`/`getFrameSurface` feed only the peer-stream mirror; `setVisible(true)` on un-hide verifies no fresh frame.
- swift `CefProfileHost.swift:1069,1080,653-658,624`; campus `cef_session_controller.dart:120-122`, `cef_webview_tile.dart:231-238,340-342`; **Severity: LOW**.

#### C-9. cefWebview recover() does not replay viewport-visibility to the swapped controller
Merges the two recover-visibility findings. `setViewportVisible(v) => controller.setVisible(v)` stores no state; `recover()` builds a fresh visible controller; `_onRecreate` only invalidates the peer-stream surface. `CullByViewport` sits above the generation-rebuilt subtree and is edge-triggered, so it never re-fires while the cull bool stays false. Recover-while-culled → fresh session paints off-screen until the next viewport-edge flip. agent_ui is immune (wraps body in `_TileViewportVisible` above the generation builder, replays in `didChangeDependencies`).
- campus `cef_webview_tile.dart:611-612,258-262,488-518`; `content_layer.dart:806-808`; `viewport_cull.dart:988-997`; `cef_session_controller.dart:176-200`; `agent_ui_tile.dart:686-688,1804,1857-1864`; **Severity: LOW**.

#### C-10. Eager-warmed and headless-CDP owner sessions run VISIBLE with no body to pause them
`_eagerWarmCefTiles` warms up to 4 tiles in snapshot order with no per-tile viewport-rect check; warm session created visible. The only `setVisible` producer (`content_layer.dart:806-808`) is nested inside `BuildNearViewport.builder`, which never runs for off-screen tiles, so `onVisibility` never fires. agent_ui's instance `setViewportVisible` only updates the notifier (`agent_ui_tile.dart:1203`) — with no mounted body nothing applies it. Headless-CDP path (`agent_ui_tile.dart:523-533`) is a genuine no-body case, bounded only by agent behavior.
- campus `canvas_snapshot_restore.dart:87-107`; `cef_session_controller.dart:131-169`; `viewport_cull.dart:327-377`; `agent_ui_tile.dart:1203`; dart `cef_web_controller.dart:785`; **Severity: LOW** (restore ≤4; medium-defensible for headless-CDP — never self-heals).

#### C-11. URL prop change during cold-start is silently dropped (raw CefWebView consumers)
`create()` captures the OLD url synchronously; `didUpdateWidget` gates `navigate()` on `_textureId != null`; post-create `_ensureSession` only resizes; no controller reconcile. Campus is masked (cefWebview navigates explicitly; agent_ui uses `loadHtmlString`). Latent raw-consumer API gap.
- dart `cef_web_view.dart:236-237,196-198,249,255-263`; `cef_web_controller.dart:467-524`; **Severity: LOW**.

#### C-12. agent_ui owner double-loads the document on warm-spawn
Instance `onCreated` load (`_syncInstanceCdpDocument:613`) + body `initState` load (`_loadCurrentHtml:1874`) both fire — two `data:` navigations on the same warm-spawned controller, no de-dup. No startup flash (both loads identical, designed idempotent supersede); narrow real edge = loses ephemeral agent-driven CDP DOM/scroll state from the headless window.
- campus `canvas_snapshot_restore.dart:87-107`, `agent_ui_tile.dart:474,494-511,613,717-727,1850-1853,1874,1799`; `cef_session_controller.dart:160`; **Severity: LOW**.

---

## Part 2 — Fix Plan (grouped by repo, keystone-first)

### flutter_cef — native (`cef_host/main.mm`) — KEYSTONE
These two close the entire C-1 class (a–f) and C-6, and are the fixes commit `de0f9458` explicitly defers to flutter_cef.

- **F-1 (keystone): Force a repaint + geometry re-assert on un-hide.** In `DoSetVisible(true)` (`main.mm:1484-1487`), on the hidden→visible edge, after `WasHidden(false)`: call `NotifyScreenInfoChanged()` (if dpr changed while hidden) + `WasResized()` + `SendExternalBeginFrame()` against current `slot->width/height/dpr` (mirror the existing immediate-kick in `DoResize:1437` / `DoInvalidate:1812-1818`). Ideally gate on a `resize_pending_on_show` flag set whenever `DoResize` runs while `!slot->visible`. This alone is sufficient for a static page and also fixes C-6's ~100ms latency. Closes **C-1b, C-1d, C-1e, C-1f, C-6**.
- **F-2 (keystone): Don't paint/promote while hidden — pair with F-1.** Make the `DoResize` begin-frame conditional on `slot->visible` (today unconditional at `:1437`); keep the surface/dims swap so geometry is current, defer the frame to F-1's un-hide kick. (The Swift half is F-4.)
- **F-3: Reconcile slot->visible in OnAfterCreated.** After binding `slot_->browser` and the `close_requested` check, before starting the pump (`main.mm:1032-1048`): `if (slot_->browser->GetHost() && !slot_->visible) slot_->browser->GetHost()->WasHidden(true);` — mirrors the H3 deferred-intent pattern. Closes **C-7**.
- **F-8 (C-4 preferred): Carry an initial-visible byte in the create payload.** Extend `{w}{h}{dpr}{sid}{url}` (`sendCreate:504-524` + `DoCreateBrowser` signature `:1293/1867`) and set `slot->visible` from it BEFORE `OnAfterCreated` starts `PumpBeginFrame`. Closes **C-4** at the engine (single source of truth).
- **F-9 (C-5): Host-level begin-frame fairness/cap.** Replace N independent 16ms pumps (`:280-291`) with a host pacer that round-robins/budgets `SendExternalBeginFrame` across slots and degrades per-tile cadence as visible-slot count grows; add a TID_UI-saturation detector. Do **not** drop `[cb waitUntilCompleted]` (CEF reclaims `view_src` on callback return — true zero-copy impossible). Mitigates **C-5**.

### flutter_cef — Swift
- **F-4 (keystone, pairs with F-2): Make resizeWatchdog visibility-aware.** Thread hidden state into `CefWebSession` (mirror `CefProfileHost.hiddenBrowsers` via the existing `setVisible` plumbing, `CefWebSession.swift:365-367`); in the `givenUp` branch (`:291-323`) **defer** force-promotion while hidden — keep serving the old `pixelBuffer` until a real present for `pendingSurfaceId` lands after un-hide. Closes the anti-heal in **C-1a, C-1c**.
- **F-5 (C-2): Dispose the session before niling the maps in onHostDied.** In `FlutterCefPlugin.swift:489-495`: capture `let session = self.sessions[sid]`, nil the four maps, then `session?.dispose()` (zeroes textureId under `bufferLock`, calls `unregisterTexture`). Optionally `host.shutdown()` first to match `disposeSession` ordering. Closes **C-2**.
- **F-6 (C-3): Steady-state per-browser liveness probe.** Track `lastPresentNs` per browser (set where `presentCount` bumps, `CefProfileHost.swift:1068`). Periodic sweep over live, visible (not in `hiddenBrowsers`), already-established browsers: if no present for a generous env-tunable window, send `opInvalidate` (the only discriminator between healthy-idle-static and wedged); if still none after a short grace, emit `onPaintStalled(id)` → routes into Campus's existing bounded `recover()`. Exempt hidden + `firstPresentPending` browsers. Closes **C-3** (and gives **C-8** a backstop).
- **F-8b (C-4 alt): Replay last opSetVisible on opCreated** (`CefProfileHost.swift:1051-1056`) — equivalent to F-8 if the payload approach is undesirable.

### flutter_cef — Dart (`cef_web_view.dart`)
- **F-7 (C-1 belt-and-suspenders): Visibility-aware resize defer.** Give `CefWebView` a `visible`/`paused` signal (Campus already tracks via `setViewportVisible`); in `_ensureSession` (`:255-263`) defer the `resize()` branch while hidden — record requested size, **do NOT advance `_lastSize/_lastDpr`** — then force-apply the coalesced latest size on un-hide. A pure-native fix leaves `_lastSize` advanced past an unpainted buffer, so this complements F-1/F-4.
- **F-10 (C-11): Navigate-on-drift after cold-start.** In `_ensureSession`, capture `final createdUrl = widget.url;` and after create resolves + `_textureId` set: `if (mounted && widget.url != createdUrl) _controller.navigate(widget.url);` (compare against captured create-url, not the racy `_controller.url.value`). Closes **C-11**.

### Campus (`work_canvas_agentui_test`)
- **F-11 (C-1 stopgap until F-1/F-4 land): Hold renderScale/size while hidden.** In `_CefSurfaceView`/`_ensureSession` callers, freeze the `renderScale` passed to `CefWebView` to its last-visible value while `_desiredVisible == false`; re-apply latest on un-cull so a single corrective resize-while-visible paints. Interim mask for **C-1f**.
- **F-12 (C-9): Replay viewport-visibility on recover for cefWebview.** Add `bool _viewportVisible` to `_CefWebviewTileInstance`, set it in `setViewportVisible`, re-apply in `_onRecreate` deferred to the new session's `onCreated` — or wrap the body in the same `_TileViewportVisible` notifier agent_ui uses (hoist it to a shared file). Closes **C-9**.
- **F-13 (C-10): Warm-spawn off-screen sessions hidden.** In both `warmSpawnCef` impls, push `controller.setVisible(false)` by default for tiles not currently near-viewport (and the headless/no-body case); un-hide on first cull-visible. Make agent_ui's instance apply `setVisible` to the owner controller directly (gated on `_session?.isCreated`) like cefWebview, rather than only setting the notifier. Closes **C-10**.
- **F-14 (C-12): De-dup the agent_ui owner double-load.** Add a shared "loaded current description revision" marker set in `_syncInstanceCdpDocument`; body checks it before `_loadCurrentHtml` in `initState` and skips when the live doc already matches. Closes **C-12**.
- **F-15 (C-4 belt-and-suspenders): Gate `cef_webview_tile.dart:612`** to defer `setViewportVisible` until the session is created and re-assert on create (mirror agent_ui's onPageStarted replay). Secondary to F-8.

### Re-enabling the dpr×clamp(zoom,1,3) crispness
The Campus stabilizer pinned `cefRenderScale(dpr,zoom)=>dpr` (`platform_view_live_mode.dart:161`) only to remove the *zoom*-density resize trigger. **Landing F-1 + F-4 (un-hide repaint + don't-resize/promote-while-hidden) is the gate** — those make every resize-while-hidden self-heal on un-cull, after which Campus can revert line 161 to the intended `dpr*clamp(zoom,1,3)` and un-pin `renderScaleOf`. F-7 (Dart defer) and F-11 (Campus freeze) are sufficient interim partial cover but do not by themselves make crispness safe to restore — the native un-hide repaint is required because Dart cannot force a frame into an evicted/hidden surface.

**Landing order:** F-1 → F-2/F-4 (keystone pair, closes C-1 class) → F-5 (C-2 leak, independent, high) → F-6 (C-3 liveness, gives C-1d/C-8 a backstop) → F-3, F-8 (create-time correctness) → F-7/F-10 (Dart) → F-11–F-15 (Campus) → F-9 (C-5, larger refactor) → **then** restore crispness.

---

## Part 3 — Completeness note: transition classes NOT covered (round-2 targets)

The audit was deep on **single-host hide/show, resize, dpr, cull, recover, crash-of-whole-host, and create-ordering**. The following transition classes named in the mission were **not** (or only glancingly) exercised and are open for a round-2 file:line-anchored pass:

1. **Secondary-window / multi-view promotion teardown.** The two multi-view findings (`isPrimaryFlutterView` non-reactive gate `agent_ui_tile.dart:698`; owner controller double-register during a primary-view flip) were **refuted**, but the refutations leaned on `WorkCanvasMultiWindowRoot.didChangeMetrics` (`work_canvas_multi_window_root.dart:55-92`) actually firing on macOS window close/minimize. That platform assumption was reasoned, not observed. Round-2: confirm the metrics event empirically, and audit the *dying* primary's `CullByViewport.detach` (it sends no final `setVisible(false)`) plus IOSurface/texture handoff when a tile's owning `View` migrates between windows.

2. **Slot/wire-id reuse across a host respawn under load.** The "verified clean" coverage note checked monotonic `nextBrowserId` + host-identity filter, but only statically. Round-2: a stress test that crashes a shared host mid-resize with many in-flight presents, checking for present-tag → wrong-session delivery during the respawn window (`FlutterCefPlugin.swift:477-503`, `:534-539`).

3. **Process-gone of a *single renderer* inside a shared host (not whole-host EOF).** C-3 establishes there is no detector; nobody traced what CEF does to the *other* slots' begin-frame pump / GPU channel when one renderer in a shared `cef_host` dies (GPU-process loss vs renderer-process loss). Round-2: does a renderer crash stall TID_UI or the Metal blit for sibling tiles?

4. **IOSurface lifetime across rapid resize churn + dispose interleave.** Findings covered force-promote of a single pending buffer; not covered: a dispose racing a chain of `maybeSendNextResize` (`CefWebSession.swift:331`) leaving an orphaned `pendingBuffer`/`ioSurface` retain, or an OS-recycled IOSurface global id colliding mid-resize.

5. **Begin-frame credit / pump leak on dispose.** `PumpBeginFrame` self-reposts and only dies on slot dispose (`main.mm:282`). Not audited: whether a dispose that races `OnAfterCreated` (slot inserted `:1307` but browser not yet bound) can leave a self-reposting pump targeting a half-torn-down slot, or double-start the pump.

6. **CDP / agent-browser driving a culled or mid-resize surface.** `campus webview`/CDP input delivery to a hidden or being-resized session (input→disposed/wrong session) was not exercised; the headless-CDP path (C-10) was only analyzed for visibility, not for input/eval routing during a recover swap.

7. **Software (non-accelerated) paint path.** All wedge analysis assumed the Metal/IOSurface accelerated path. `CompositeSoftwareLocked` (`main.mm:652-658`) and `BlitBGRA` were only touched in refuted crop findings; the software fallback's behavior under hide/resize was not separately verified.

8. **Display reconfiguration / GPU reset / sleep-wake.** Monitor hot-plug, GPU switch (discrete↔integrated), and system sleep/wake invalidate Metal devices and IOSurfaces wholesale — entirely outside this audit's scope and a likely source of post-establishment blank-with-no-detector wedges (overlaps C-3).
