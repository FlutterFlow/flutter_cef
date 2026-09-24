# CEF zoom scale-mismatch + frozen-but-interactable: root cause, fix, recommendation

All three traces converge on the same mechanism and I verified every load-bearing anchor in the actual source. The bug is **one defect with two faces**: a synchronous host-surface swap raced against an asynchronous renderer re-raster, mediated by a present protocol that carries only a surface id and therefore cannot tell a *provisional old-scale* frame from a *correct new-scale* frame.

---

## 1. Root cause (ranked)

### R1 — "too big / too small within bounds": scale-blind blit + size-blind promotion of a pre-re-raster frame (PRIMARY)

The blit is the only place src and dst scale couple, and it does **min()-from-top-left with no scale check and no margin clear**:

- `CompositeMetalLocked` (`flutter_cef_fix/.../cef_host/main.mm:731`): `cw=min(sw,dw), ch=min(sh,dh)`, copy origin(0,0)→origin(0,0), no scaling (`main.mm:734-742`). Software path `CompositeSoftwareLocked` and `BlitBGRA` (`main.mm:508-523`, `OnPaint` at `585`) are identical; `BlitBGRA`'s own comment already admits "CEF may deliver a frame at the pre-resize size while a resize is in flight."
- On a settled-zoom dpr change, `DoResize` (`main.mm:1410-1462`) swaps `slot->surface`/`width`/`height`/`dpr` **synchronously** under `surface_mutex` (`1430-1437`), drops the `dst_mtl` cache (`1438-1440`), then for a visible slot calls `NotifyScreenInfoChanged()` + `WasResized()` + one `SendExternalBeginFrame()` (`1445-1450`). Those only *post* a relayout; Blink re-rasters at the new `device_scale` **async**. `GetScreenInfo` already reports the new `slot->dpr` (`main.mm:547`) and `GetViewRect` the unchanged logical w/h (`main.mm:540`).
- So the immediate begin-frame (and the 16ms `PumpBeginFrame` ticks) pull a frame the renderer still rastered at the **old** device-scale → `src = logical*dpr_old`, `dst = logical*dpr_new`:
  - **dpr ↑ (zoom in):** small src lands top-left of the bigger zero-filled dst; Flutter samples the whole dst into the logical box → **content too small + stale/black margins** (nothing clears the uncovered region).
  - **dpr ↓ (zoom out):** bigger src clipped to dst's top-left `dw×dh`, stretched to fill the box → **content too big / cropped**.
- The wrong frame is **structurally the one promoted**: `SendPresentLocked` (`main.mm:558-565`) tags the present with only the new 4-byte surface id; Swift `handleFrame(opPresent)` (`CefWebSession.swift:620-631`) promotes `pendingBuffer→pixelBuffer` and clears `resizeInFlight` on the **first** present whose tag matches `pendingSurfaceId`, with **no size check**. The first post-resize present is the pre-re-raster old-scale frame.

This is ordering, not a dropped notify — `NotifyScreenInfoChanged`/`WasResized` do fire (`main.mm:1445-1446`); they just don't raster synchronously. The F-1..F-6 cull fixes removed the hidden-path wedge but never touched the blit/promotion seam, which is why the symptom went transient-but-persistent rather than away.

### R2 — "blank / freeze but interactable": wrong frame promoted with no guaranteed correct follow-up; watchdog force-promotes stale/zero pixels

Input keeps working because event routing is independent of paint; only the texture is wedged. It persists when no correct frame lands after the promotion:

- **Static page** (flutter.dev, idle agent_ui): one `_quantizedZoom` flip → exactly one `resize` → ~one paint. If that paint is old-scale and the compositor returns `DidNotProduceFrame` to subsequent pump ticks, the mis-scaled frame is the **last one ever produced** — frozen at wrong scale.
- **`resizeWatchdog` force-promote** (`CefWebSession.swift:303-347`, promote `319-330`): after 300ms it promotes whatever sits in `slot->surface` with **no scale check**. If the renderer hasn't re-rastered, that's old-scale content, or a **zero-filled** surface → blank-but-interactable; then `resizeInFlight=false`, `maybeSendNextResize` sends nothing.
- **Chained zoom**: `maybeSendNextResize` (`349-358`) swaps to step N+1's surface as soon as step N's lagging present promotes, so step N's correct frame arrives mis-tagged and is dropped → every promoted frame is one device-scale step behind until zoom stops.
- **Establishment race**: `DoResize` skips the screen-info re-assert when `slot->browser==null` (`main.mm:1442` guard → `needs_screen_info_on_show`), and `OnAfterCreated` re-asserts only close/visible, not geometry — a dpr resize during async create leaves the renderer at create-time dpr vs a new-dpr surface with nothing forcing a re-raster.
- Dart can't self-heal: `_ensureSession` writes `_lastDpr` **before** issuing the resize (`work_canvas_agentui_test/.../cef_web_view.dart:255-262`), so a coalesced/superseded resize is never re-issued; recovery depends entirely on native watchdog / F-6.

### R3 — F-6 is blind to "frozen-but-presenting" (lets R2 persist; YES, confirmed)

Every blit ends in an unconditional `SendPresentLocked` (`main.mm:758`/`599`/software), **including mis-scaled and blank-painted frames**. The present reader bumps `lastPresentNs` and clears `livenessNudgedAt` on *every* present (`CefProfileHost.swift:1147-1153`). The F-6 sweep (`785-825`) only escalates on **total** staleness (10s). So:
- A wrong-frame tile that then **idles** eventually trips F-6 → `opInvalidate` → re-raster at the now-correct scale (can recover).
- A wrong-frame tile that **keeps presenting** (animating agent_ui rAF, or the watchdog/nudge re-presenting) refreshes `lastPresentNs` forever → F-6 **never fires** → permanent wrong scale. F-6 detects "no pixels," never "wrong pixels."

### Key unused oracle
`OnAcceleratedPaint` (`main.mm:779-812`) reads only `info.shared_texture_io_surface` and **ignores `info.extra`** (`cef_accelerated_paint_info_common_t`: `coded_size`/`visible_rect`/`content_rect`/`source_size`). The pooled `view_src` IOSurface can even be larger than the actually-painted content, so `IOSurfaceGetWidth(view_src)` is not the true rastered size — `visible_rect`/`content_rect` is. `info.extra` is exactly the "did the renderer raster at the new device-scale yet" signal the guard needs.

---

## 2. The complete robust fix

Four coordinated edits; **(1)+(2) are the core** and eliminate both too-big/too-small and the frozen-wrong-scale promotion. (3) is the freeze/animated backstop, (4) the safety/margin.

### Fix 1 — Size-gated promotion (kills wrong-scale promotion at the source) — **native + Swift**
- **native** `SendPresentLocked` (`main.mm:558-565`): extend the `kOpPresent` payload from 4→12 bytes: `sid` + the **actually-composited src physical `w,h`** (from `info.extra.visible_rect`, falling back to `content_rect`/`coded_size`, then `IOSurfaceGetWidth/Height(view_src)`). Plumb those dims from `OnAcceleratedPaint`/`OnPaint` into the composite fns.
- **Swift** `handleFrame(opPresent)` (`CefWebSession.swift:620-631`): promote `pendingBuffer` **only** when `psid==pendingSurfaceId` **AND** `srcW≈round(width*dpr) && srcH≈round(height*dpr)` (±1px). A mis-scaled present advances nothing and leaves `resizeInFlight=true`. This turns "promote on first present of the new sid" into "promote on first **correctly-sized** present," so Flutter keeps sampling the old, geometrically-correct (slightly soft) buffer until the real frame lands — coherent with the existing resize-flash design (`CefWebSession.swift:265-273` already serves the old surface until the pending one paints).

### Fix 2 — Guarantee a correct final frame (kills static-page freeze + establishment race) — **native**
- `DoResize` on `dpr_changed` (`main.mm:1434-1461`): set a per-slot `awaiting_scale = {round(w*dpr), round(h*dpr)}`. `OnAcceleratedPaint` clears it and presents **only** when the `info.extra` dims equal the awaited dst; while it's set, keep driving `Invalidate(PET_VIEW)` + `SendExternalBeginFrame` (a short bounded pump burst, mirroring the F-1 un-hide forced repaint) so a static page that emits one frame is deterministically re-driven to the settled scale. Don't rely on the single synchronous `SendExternalBeginFrame` at `1450` racing the async relayout.
- `OnAfterCreated` (~`main.mm:1038-1060`): if slot dims/dpr differ from create-time (a resize arrived during async create), call `NotifyScreenInfoChanged()` + `WasResized()` + `SendExternalBeginFrame()` there to fix the establishment race (today only `needs_screen_info_on_show` covers the hidden case).

### Fix 3 — Blit guard + margin clear (no blank/garbage under the watchdog) — **native + Swift**
- **native** `CompositeMetalLocked`/`CompositeSoftwareLocked`/`OnPaint PET_VIEW` (`main.mm:646`, `693`, `584`): when `src != dst` dims, still blit the `min` rect (so the surface isn't blank for the watchdog backstop) **but clear the uncovered dst region** outside `[0,cw)×[0,ch)` (Metal clear / memset), and **do not** call `SendPresentLocked` for that provisional frame (pairs with Fix 1's gate). `dst_mtl` cache needs no change — `DoResize` already invalidates it unconditionally (`main.mm:1438-1440`), so it is **not** a contributor.
- **Swift** `resizeWatchdog` force-promote (`CefWebSession.swift:319-330`): gate force-promotion on "the pending surface has received an exact-dims frame"; otherwise keep waiting/nudging. Never force-promote stale-scale or zero-filled content.

### Fix 4 — Liveness detects frozen-but-presenting — **Swift**
With Fix 1, mis-scaled presents no longer reach the heartbeat, so `lastPresentNs` advances only on correct frames and F-6's existing staleness path (`CefProfileHost.swift:785-825`) fires naturally → `opInvalidate` → forced correct re-raster. Belt-and-suspenders: track a separate `lastCorrectScalePresentNs` (set only on a size-matched present in the reader at `1147-1153`) and feed **that** to `LivenessProbePolicy.evaluate`; treat a nudge whose repaint returns still-mismatched as *escalate*, not *reset*.

### Campus side
**No change required.** `cefRenderScale = round(dpr*clamp(zoom,1,3)*4)/4` (`platform_view_live_mode.dart:162-165`) and the `renderScale` pass-through (`cef_webview_tile.dart:821`, `agent_ui_tile.dart:2038`) are correct — they produce the right *value*; the realloc that value drives is the race trigger, not a value bug. One optional hardening: in `cef_web_view.dart:255-262`, write `_lastDpr`/`_lastSize` **after** the resize is acknowledged (or re-issue on a superseded resize) so Dart can re-drive a coalesced resize instead of relying solely on the native watchdog.

---

## 3. Recommendation: KEEP per-zoom device-scale resize (hardened) — do not switch

This is the second fragility round on the same mechanism, so the design question is fair. Verdict: **ship the hardened resize now (Fixes 1-4); treat fixed-density as a scoped, optional follow-up; reject page-zoom outright.**

| Option | What it does | Verdict |
|---|---|---|
| **(a) Per-zoom resize + size-gated promotion + blit guard + forced final frame** | Keeps `device_scale = dpr*clamp(zoom,1,3)`; makes promotion size-correct and guarantees a settled frame | **SHIP THIS.** Smallest surgical change; preserves crispness and the **bounded** (clamp 3×) IOSurface that the cull/memory budget depends on. Robust *because* Fix 1 makes promotion size-correct rather than racing it. |
| **(b) Fixed max-density surface** — allocate once at `logical*dpr*3`, never realloc on zoom; Flutter texture supersamples down | Deletes the resize race, the `resizeWatchdog`, and the hidden-promote special-casing for the zoom path entirely | **Strategic follow-up, scoped only to the engaged/foreground tile.** Cost is constant ~9× VRAM+raster per tile even at zoom 1 (≈54MB for a 720×520 tile), which directly fights the establishment/memory budget the cull fixes protect. A *global* fixed ceiling is too costly for many-tile boards; combined with the existing `WasHidden` off-screen gate it's acceptable for a handful of visible tiles. The durable target *if* (a) proves insufficient under heavy pages. |
| **(c) CEF `SetZoomLevel` / CSS page-zoom** (`DoSetZoom`, `main.mm:1500-1502`) | Changes content zoom → page **reflows** (layout/text/breakpoints) | **REJECT for crispness.** Canvas zoom must magnify rendered pixels while preserving layout; `device_scale_factor` is the correct knob. Keep `SetZoomLevel` only for user-facing Ctrl+/- content zoom. |

**Why not just lean on liveness:** F-6 is a *freeze* backstop by construction (it watches present cadence, not pixels) and structurally cannot see "presenting but visually wrong." The fix must live at the **blit/promotion seam** (Fixes 1-3); liveness (Fix 4) is only the secondary net once correct presents are the only thing that counts as a heartbeat.

**Net:** the renderScale-via-resize model is *sound for crispness* but *racy by construction* — every device-scale change re-runs sync-dst-swap vs async-src-raster mediated by a sid-only present. Fix the race with a size-tagged present + guaranteed final frame rather than abandoning the bounded-memory resize. Plan (b) for the single engaged tile as the race-eliminating simplification if heavy pages still slip through; never adopt (c).
