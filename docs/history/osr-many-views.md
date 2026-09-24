# OSR with many animating views: why it caps and how to scale

> **★ SOLVED (2026-06-25). The fix is SOFTWARE-ONLY on ONE shared host — no multi-process,
> no cookie-sync, no engine patch.** The earlier analysis in this doc (§3–§7 below) concluded
> the limit was a steady-state per-GPU-process capture ceiling requiring more processes. That
> was a **measurement artifact**: the stress probe created all tiles *visible at once*. The
> real limit is **concurrent first-frame establishment**, and serializing it fixes everything.
> Sections below are kept as the investigation record; this banner is the current truth.

## 0. The actual mechanism (current, validated)

**Root cause.** Each OSR browser, on its *first show*, lazily creates a `viz::FrameSinkVideoCapturer`
and does a one-time **first-frame GPU shared-image allocation** (CEF source:
`RenderWidgetHostViewOSR::ShowWithVisibility` → `CefVideoConsumerOSR`). When N browsers do that
allocation **simultaneously**, the GPU-process allocator races and the losers hit
`FrameSinkVideoCapturerImpl::MaybeCaptureFrame`'s first-frame `Stop()` — **permanent, silent
(LOG(ERROR) only), no `createFailed`, no callback**. That stuck capturer can't be revived
(re-kick / WasHidden / resize / recreate-under-load all fail). **Steady state is fine** — once
established, one GPU process drives 20+ animating views; the bug is purely the concurrent
*establishment*.

**Fix — serialize establishment (host-side, in `cef_host`):**
1. **Create-pacer gated on first PAINT, not bind.** `CefProfileHost` sends one
   `CreateBrowser` at a time and doesn't send the next until the previous browser has produced
   its first frame (a few frames, or a short settle for static content), with a generous
   backstop so one slow page can't block the queue. This keeps concurrent first-frame
   allocations at ~1, so the race never happens.
2. **Begin-frame pump always runs** (`PumpBeginFrame`, per slot) = liveness. A blank tile is
   then almost always merely *slow* (heavy page / saturated GPU), and paints on its own once
   resources free — **patience, not destruction.**
3. **Patient watchdog → bounded recreate.** If a browser produces no frame within a generous
   grace (~10s), `cef_host` reports `paintStalled` (a *repeating* signal) and the consumer does
   a **bounded** recreate (last resort, capped → never churns). Recreate succeeds because it
   too goes through the serial pacer (low contention).

**Validated:**
- 12 concurrent *animated* tiles → **12/12 establish + animate** (was ~9/12 with permanent blanks).
- 20 *real* websites incl. WebGL/3D/video → **20/20 get content, 0 churn, ~8.5 GB / one shared host**.
- Bulk-open lights up in ~2 s (Chrome "tabs come alive" feel); steady-state is full 60 fps.
- **Patience-only (no recreate) also reached 20/20** — serialization alone prevents the silent
  death; the bounded recreate is kept only for the rare genuine `Stop()`.

**Why this is better than the old plan:** one shared `cef_host` = one profile = **shared
cookies/logins**, no pool, no cookie-sync, no Chromium patch. Per the user's spec it **never
permanently blanks**; under genuine resource pressure it **degrades gracefully** (tiles appear
over a few extra seconds) rather than blanking or churning.

---

## (Investigation record below — superseded by §0)

## 1. TL;DR (original — superseded)

- **Symptom:** When many off-screen-rendered (OSR) webview tiles *animate at once* on a single shared `cef_host` process, a few of them (~1–4 of 12 in our stress probe) never produce a first frame and stay **blank**. Intermittent.
- **Root cause (one line):** Each OSR browser copies its pixels out through its own `viz::FrameSinkVideoCapturer`, and — empirically — one Chromium GPU/Viz process can only *establish and sustain* a limited number of concurrently-capturing views before late capturers fail to complete their first capture. In our probe that ceiling landed around ~8–10. (This is an observed number, not a documented Chromium constant — see §3.)
- **Decisive tell:** **Static** content renders 12/12 every time; only **continuous animation during establishment** loses tiles. So the bottleneck is establishment-under-concurrent-capture-load, not GPU drawing, GPU memory, or frame area/pixels.
- **Why Chrome doesn't hit this (one line):** Chrome renders windows **on-screen** via a zero-copy CALayer/IOSurface handoff to the macOS WindowServer — there is no per-view video-capture copy-out step. OSR *must* copy each view out of Chromium, and that copy machinery is what caps.
- **The fix (SUPERSEDED — see §0; serialization on one host works):** Spread animating tiles across **more GPU processes** (more `cef_host` processes), sized so each carries **≤ ~6 animating tiles**, so every tile renders at full 60fps.
- **The no-blank guarantee:** A graceful **take-turns throttle** — only ~6 views actively capture at any instant, the rest show their last frame (a freeze, never blank), and tiles come up in waves so each gets a first frame to freeze on.

---

## 2. The simple explanation

Think of each webview tile as a TV that Chromium is drawing.

Chrome's normal mode is like **hanging real TVs on a wall**: the operating system's window server is built to juggle dozens of on-screen surfaces at once and composite them for free. Adding more TVs is cheap because the OS does the final assembly.

Our mode (OSR) can't hang TVs on the wall — every tile has to live *inside* the Flutter canvas (draggable, zoomable, clippable, shareable with peers). So instead we point a **screen recorder at each TV** and copy its picture out frame-by-frame, then paint that copy into the canvas.

One Chromium instance can only run a handful of these screen recorders smoothly at the same time. When too many TVs are all *playing video at once while their recorders are still warming up*, the last few recorders never finish starting — so those tiles stay blank.

Two important details that fall out of the analogy:

- A **still picture** is easy: every recorder captures one frame and stops. That's why static content always comes up 12/12.
- The fix isn't a faster recorder — it's **more rooms**: split the TVs across several Chromium processes so no single one is running more than ~6 recorders at once. And as a safety net, **take turns** — let only ~6 record live at a time and freeze the rest on their last frame so nothing ever goes blank.

---

## 3. The technical mechanism

### OSR delivers pixels via a per-browser `FrameSinkVideoCapturer`

CEF/Chromium windowless (off-screen) rendering delivers each browser's pixels to the embedder through Chromium's `viz::FrameSinkVideoCapturer`. The software `OnPaint` path performs a CPU readback ("OnPaint has always been sharing the OSR pictures using FrameSinkVideoCapturer, but via CPU"); the hardware `OnAcceleratedPaint` path (reintroduced ~M124/M125, requires `shared_texture_enabled`) hands over a shared GPU texture instead of doing a CPU copy. Both ride the same `FrameSinkVideoCapturer` machinery — the difference is CPU readback vs. GPU shared-texture handoff. Either way, OSR adds a **per-view copy-each-view-out step** that on-screen rendering does not have.

> Precision note: the literal "video-capture copy" describes the software `OnPaint` path. If flutter_cef is on (or moves to) the accelerated `OnAcceleratedPaint` shared-texture path, the per-view step is a shared-texture handoff rather than a CPU copy. It's still an extra per-view step versus on-screen delegated rendering, and it still rides the same per-browser capturer plumbing.

### The pipeline constants (per capturer)

From `components/viz/service/frame_sinks/video_capture/frame_sink_video_capturer_impl.h`:

- `kDesignLimitMaxFrames = 10` — "the maximum number of frames in-flight in the capture pipeline, reflecting the storage capacity dedicated for this purpose."
- `kTargetPipelineUtilization = 0.6f` — "A safe, sustainable maximum number of frames in-flight... exceeding 60% of the design limit is considered 'red line' operation."

So `10 × 0.6 = ~6` sustainable in-flight frames **per capturer**. The header also notes that in practice only **0–3** frames are typically in flight, depending on content-change rate and system performance.

**Important scope (read this before quoting any number):** these constants bound in-flight frames **per `FrameSinkVideoCapturer`** (each browser's own frame pool). They are a *per-capturer pipeline depth*, **not** a documented "8–10 capturers per GPU process" cap. No Chromium source states a fixed per-Viz-process capturer limit. The two numbers measure different things — per-capturer pipeline depth (≤ ~6 in-flight, documented) vs. how many capturers one Viz process can establish and sustain at once (~8–10, **empirical, ours**) — so do not present the `6` as proof of the `~8–10`.

### The ~8–10 concurrent-capture ceiling (empirical)

The observed ceiling — one GPU/Viz process sustains only ~8–10 *continuously-animating* capturers before late establishers fail — is an **empirical finding from our 12-animating-tiles stress probe**, not a named constant. It most likely emerges from the aggregate of per-capturer frame pools, `VideoCaptureOracle` feedback contention, and Viz scheduling, but we did not isolate which dominates. State it as observed behavior, not a hard documented limit, and treat the exact number as probe-specific (hardware, content, and Chromium version dependent).

The `media::VideoCaptureOracle` (`media/capture/content/video_capture_oracle.cc`) does auto-throttle, but this is a **separate mechanism** from the frame-pool/in-flight limit above — it scales **capture resolution**, not capturer concurrency. It throttles by **capable frame *area*** (pixels per frame), computed as `capture_size.GetArea() / feedback.resource_utilization` and evaluated over time windows (e.g. `kBufferUtilizationEvaluationInterval = 200ms`, `kConsumerCapabilityEvaluationInterval = 1s`). This is consumer-resource-feedback-driven **resolution scaling**. The oracle exposes only enable/disable (`kThrottlingDisabled` / `kThrottlingEnabled` / `kThrottlingActive`), with no public knob to tune the throttle math; it is self-adjusting by design (the code provides no configuration surface for the math, rather than an explicit "do not configure" assertion). (We earlier described the metric as "capable pixels per second" — the current code expresses it as a per-frame *area*, so prefer that wording.)

### The static-vs-animated tell

**Static content (paint-once-then-idle) renders 12/12 every time; only continuous animation during establishment loses tiles.** This pinpoints the bottleneck as **establishment under concurrent capture load**, and rules out:

- GPU drawing — Viz produced ~540 accelerated fps for the tiles that did come up.
- GPU memory — the static case allocated all 12 surfaces fine.
- Frame area / pixels — smaller tiles (140px, 80px) did not help (see §4).

### On-screen delegated rendering vs. OSR copy-out

There is exactly one Viz process for all of Chromium ("There is usually only one GPU and screen to draw to"); it aggregates compositing from every renderer plus the browser process into a single compositor frame.

For **on-screen** macOS windows, the GPU process renders web content into an IOSurface-backed texture exposed via a `CAContext`, and hands it to the browser process **by CAContext ID**; the browser wraps it in a `CALayer` "which will make the frame appear on the screen." The macOS Render Server (WindowServer) then composites all active CAContexts into the final image, owning positioning, ordering, and clipping. This is a **zero-copy layer handoff** with **no per-view capture step** — the OS natively juggles many windows.

For **OSR**, because tiles must live inside the Flutter canvas (not as OS windows), each view's pixels must instead be copied out via its `FrameSinkVideoCapturer` (`CefVideoConsumerOSR::OnFrameCaptured` receives the captured frame on the CEF side). The Chromium *drawing* is identical to Chrome's; the cap comes entirely from the **extra copy-each-view-out step** that on-screen delegated rendering doesn't have.

*(Sources cited inline above; full list in §8.)*

---

## 4. What we tried and ruled out

All levers were measured on the same 12-animating-tiles-on-one-host stress probe. Metric: how many tiles produce a first accelerated frame (per-slot diagnostic counters). **Don't re-run these — they're refuted.**

| Lever tried | Result | Takeaway |
| --- | --- | --- |
| Begin-frame rate throttle (slow everyone during startup) | **Worse** — slower → fewer establish | Slowing down hurts establishment |
| Coordinated single-vsync pump (all begin-frames in phase, one source) | No change (~10) | Phase alignment irrelevant |
| Bounded-concurrency round-robin (cap N producing per tick, rotate active window) | ~11, one straggler persists; N=6/5/4 all plateau ~10–11 | Lowering N doesn't break the ceiling |
| Establishment-priority (un-painted tiles get first claim on the budget) | Still ~11 | Priority doesn't help the last tile |
| Capture resolution / smaller tiles (140px, 80px vs full grid) | **No effect** | Refutes the frame-area / pixels theory |
| `--force-gpu-mem-available-mb` (1024 / 2048 / 4096) | No effect (Apple-Silicon unified memory) | Not a GPU-memory cap |
| `--disable-gpu-watchdog` | No effect | Not the watchdog |
| `WasHidden(true)` → `WasHidden(false)` re-establish recovery | Fired ~16×, no effect | Hide/show doesn't recover |
| Gradual create (1.5s spacing between tiles) | No effect (~10) | Not a create-burst race |
| Recreate-on-stall self-heal (watchdog → dispose + recreate stalled tile) | Does **not** converge — fresh browser hits the same wall (10/12) | The wall is per-host, not per-tile |

**Conclusion:** nothing reachable from `cef_host` or the consumer broke the ~8–10 ceiling in our probe. We attribute it to CEF/Chromium's OSR capture pipeline (per-capturer pools + oracle feedback + Viz scheduling) rather than to anything in our wiring — though we did not pinpoint the single internal cause.

---

## 5. The separate Flutter-pull bug (DIFFERENT issue, fixable)

This is a **distinct bug** from the capture ceiling and is almost certainly **masked in real Campus** — call it out separately so it isn't conflated.

**Symptom (in the bare flutter_cef example):** rendered tiles looked *static* even though `cef_host` was producing 60fps.

**Cause:** Flutter was not **pulling** the produced frames. `textureFrameAvailable` did not wake an idle Flutter, so `copyPixelBuffer` only fired on the probe's 2-second `setState` timer (~840 frames presented per tile vs. ~7 actually pulled). Forcing a Flutter repaint every frame made them animate.

**Why it's masked in Campus:** Campus's canvas is essentially always animating, so Flutter never sleeps and keeps pulling frames. The bug surfaces only in standalone/idle consumers.

**Fix (worth doing in the plugin):** drive a Flutter frame per present when `textureFrameAvailable` fires, so standalone flutter_cef consumers animate without an always-on canvas.

---

## 6. The cookie / shared-login tension

Scaling by "use more processes" collides with shared login:

- **Shared cookies require ONE Chromium instance.** The profile (user-data) directory is guarded by Chromium's `ProcessSingleton` — on POSIX a symlink-based advisory `SingletonLock` whose target is `<hostname>-<PID>` (`process_singleton_posix.cc`); a stale lock yields the familiar "profile appears to be in use by another process" error. CEF inherits this: each CEF instance needs its own `cache_path` / `root_cache_path` or it conflicts. So **one process per profile dir.**
- **The cookie store belongs to that one instance.** `CookieMonster` (`net/cookies`) is wrapped by `CookieManager` in `//services/network`, owned by the `NetworkContext` and reached via `StoragePartition::GetCookieManagerForBrowserProcess()`, backed by `SQLitePersistentCookieStore`. Cookies are isolated per `NetworkContext`; the docs describe no cross-instance sharing path. (Per the CookieMonster design doc, `CookieMonster` is *not* a singleton — one process can hold several instances: standard, incognito, extensions. So it's "one per `NetworkContext`," not literally "one per process" — but none are shared across separate Chromium processes.)
- **CEF gives one self-contained Chromium per `CefInitialize`** ("CEF can only be initialized once per process"), with its own network/cookie service, and exposes **no API to share** one network/cookie service across instances. Cross-instance cookie movement must be done by replication via `CefCookieManager` (`VisitAllCookies` + `SetCookie`).

**So the tension is:** ONE host = shared login but ~8–10 captures; MORE hosts (more GPU processes) = more captures but **separate cookie jars**.

**DBSC note.** Device Bound Session Credentials (DBSC) binds session cookies to a hardware-held private key (TPM on Windows; Secure Enclave intended for macOS). It reached **general availability on Windows only** (Chrome 146, ~Apr–May 2026); **macOS support is "coming in an upcoming release" — not GA on macOS as of June 2026.** DBSC is a Chrome-browser/runtime feature, not a web-content capability. We have **no source confirming or denying** that CEF (or the Alloy-style browser path) implements DBSC; the reasonable inference — given DBSC is a Chrome-runtime feature that CEF's identity surface tends to lag — is that CEF currently yields **plain, syncable cookies** for replication, but treat that as an inference, not a sourced fact. Either way DBSC is **not a blocker** for the cookie-sync approach: if CEF doesn't implement it, cookies stay plain; if it eventually does, replication would need to carry the bound credential, but that path doesn't exist on macOS today. (Terminology: in current CEF "Alloy" refers to a window *style* within the one Chrome-bootstrap runtime, not a separate runtime — the Alloy bootstrap was deprecated M125 / removed M128.)

---

## 7. The fix

**Core idea:** more GPU processes = more `cef_host` processes, each sized so it carries **≤ ~6 animating tiles** (safely under the observed ~8–10 ceiling) → every tile renders at full 60fps. (The `6` here is the per-host *animating-tile budget* we chose as a safe margin under the empirical ceiling — not the per-capturer in-flight-frame constant from §3. They happen to share a number; they are not the same thing.)

### Shape A — Partition-by-profile (PREFERRED)

Each profile already gets its own `cef_host` = its own GPU/Viz process, so load spreads **for free**, and cookies stay shared **within** a profile. Needs no cookie-sync. Works **unless more than ~6 animating tiles must share ONE login at once.**

### Shape B — Pool + cookie-sync (GENERAL)

Bucket a single profile across N hosts and replicate cookies between them via `CefCookieManager` (`VisitAllCookies` + `SetCookie`). Handles >6 animating tiles of one login. More complex (cookie replication, consistency, race handling).

### The graceful no-blank throttle (the guarantee)

As a safety net for when a single host *does* exceed its safe count, add a **take-turns** throttle:

- Only ~6 webviews **actively capture** at any instant; the rest show their **last frame** — a freeze-frame, **never blank**, because the Flutter texture retains the last painted picture.
- **Rotate** which tiles are live.
- **Bring tiles up in waves of ~6**, so each one gets a first frame to freeze on.

**Steady-state guarantee:** every tile shows live-or-frozen, never blank. The only costs are a brief per-tile "loading" before its establishment wave, and reduced fps while more than ~6 animate at once. **Below ~6 animating per host the throttle is inactive** (full 60fps).

### Open decision question

**Do more than ~6 *animating* tiles ever need to share one login simultaneously?**

- If **no** → Partition-by-profile (Shape A) alone is sufficient; ship the throttle as a guarantee for edge cases.
- If **yes** → Pool + cookie-sync (Shape B) is required for that login bucket, plus the throttle.

---

## 8. Sources

- Chromium — `frame_sink_video_capturer_impl.h` (`kDesignLimitMaxFrames = 10`, `kTargetPipelineUtilization = 0.6f`): https://chromium.googlesource.com/chromium/src/+/7292bb3e6a1e6cd89d41aa5f52ecdbf030ba4191/components/viz/service/frame_sinks/video_capture/frame_sink_video_capturer_impl.h
- Chromium — `video_capture_oracle.cc` (capable frame area, throttling states/intervals): https://chromium.googlesource.com/chromium/src/media/+/refs/heads/main/capture/content/video_capture_oracle.cc
- Chromium — RenderingNG architecture (one Viz process): https://developer.chrome.com/docs/chromium/renderingng-architecture
- Chromium — Mac delegated rendering (CAContext / IOSurface / CALayer handoff): https://www.chromium.org/developers/design-documents/chromium-graphics/mac-delegated-rendering/
- Chromium — CookieMonster design doc (CookieMonster is not a singleton): https://www.chromium.org/developers/design-documents/network-stack/cookiemonster/
- Chromium — `net/cookies` README: https://chromium.googlesource.com/chromium/src/+/HEAD/net/cookies/README.md
- Chromium — `process_singleton.h`: https://chromium.googlesource.com/chromium/src/+/HEAD/chrome/browser/process_singleton.h
- Chromium — `process_singleton_posix.cc` (SingletonLock): https://chromium.googlesource.com/chromium/src/+/HEAD/chrome/browser/process_singleton_posix.cc
- CEF — `CefCookieManager` docs (VisitAllCookies / SetCookie): https://cef-builds.spotifycdn.com/docs/121.3/classCefCookieManager.html
- CEF — issue #3685 (per-instance cache directory): https://github.com/chromiumembedded/cef/issues/3685
- CEF — issues #3730 / #4057 and CEF forum t=19401 (OSR capturer / FrameSinkVideoCapturer discussion): https://github.com/chromiumembedded/cef/issues/3730 · https://github.com/chromiumembedded/cef/issues/4057 · https://magpcss.org/ceforum/viewtopic.php?f=10&t=19401
- Electron — PR #42953 / issue #41972 (OnAcceleratedPaint / shared-texture OSR): https://github.com/electron/electron/pull/42953 · https://github.com/electron/electron/issues/41972
- DBSC — Chrome docs: https://developer.chrome.com/docs/web-platform/device-bound-session-credentials · Windows GA announcement: https://workspaceupdates.googleblog.com/2026/05/prevent-account-takeovers-with-DBSC-now-generally-available-in-the-Chrome-browser-for-Windows.html · spec: https://github.com/w3c/webappsec-dbsc