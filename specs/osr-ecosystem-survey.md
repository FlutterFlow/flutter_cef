# CEF Off-Screen Rendering (OSR) in the Wild — Survey & Scaling Synthesis

**Question driving this survey:** when many OSR Chromium views animate at once on **one** shared `cef_host` process, ~1–4 of 12 never produce a first frame (blank). Proven mechanism: OSR pixels exit via a **per-browser `viz::FrameSinkVideoCapturer`**; one GPU/Viz process sustains only ~8–10 concurrently-capturing animating views before late ones starve. The candidate fix is **multiple `cef_host` processes (more GPU processes) + a take-turns throttle**.

This report consolidates four implementation clusters (bindings, game-engines, streaming/broadcast, electron-desktop), an internals/scaling cluster, and three gap deep-dives (cloud pixel-streaming fleets; CEF hidden→shown first-paint failures; external-begin-frame pacing/QCefView sync).

---

## 1. Comparison table of notable CEF-OSR implementations

| Project | Category | Pixel-out path | Accel / shared-texture | FPS control | Runs many OSR? | Scaling approach |
|---|---|---|---|---|---|---|
| **CefSharp** (.NET) | binding | OnPaint CPU readback (default) + OnAcceleratedPaint | Windows **D3D11 handle only**; surfaces handle, host must render it | `windowless_frame_rate` (30 default); `SendExternalBeginFrame` | No orchestration | none built-in; #2940 shows ~1–3 fps callback cadence even with empty body |
| **JCEF / java-cef** (incl. JetBrains JBR) | binding | **OnPaint CPU only** (no accel binding; #506 open) | None | `windowless_frame_rate` (30) | JetBrains runs several, all CPU | none; stays on CPU deliberately |
| **cefpython** | binding | **OnPaint CPU only** (accel removed) | None | `windowless_frame_rate` (caps ~30); recommends `--disable-gpu` | Single-browser examples | go **software** to dodge GPU ceiling (loses WebGL) |
| **CEF4Delphi** | binding | OnPaint + OnAcceleratedPaint | **Cross-platform**: Win D3D11 handle / **mac IOSurface** / Linux dmabuf-fds | `windowless_frame_rate` + external begin-frame | No pooling | never shipped a heavy-OSR demo |
| **CefGlue** (.NET/Avalonia) | binding | OnPaint CPU (default) | Optional Win-D3D11 in some forks | `windowless_frame_rate` | No | none documented |
| **cef-rs** (Rust) | binding | No documented OSR surface | — | — | No | n/a (pre-1.0, windowed-focused) |
| **cef-mixer** (daktronics/mediabuff) | demo | OnAcceleratedPaint | **Win D3D11 zero-copy** | **`SendExternalBeginFrame`** (windowless_frame_rate ignored) | **Yes** — `--grid=2x2`, N browsers composited | host-driven begin-frame; small grids only (never stressed to 12) |
| **cef-spout** | engine-asset | OnAcceleratedPaint (Win); OnPaint fallback elsewhere | Win D3D11 + Spout re-share | external begin-frame | Yes (grid) | per-instance process + unique `--cache-path` |
| **Vuplex 3D WebView** (Unity, commercial) | engine-asset | Win D3D11 OnAcceleratedPaint; **macOS = CPU OnPaint** | Win only; **no accel on Mac** | `SetTargetFrameRate` (60) | Yes, many in one process | **accepts ~10** ("usually 10 active webviews"); no multi-process |
| **ZFBrowser** (Unity) | engine-asset | CPU OnPaint → shared memory → re-upload | None (GPU→CPU→GPU) | internal cap | Yes (one helper proc) | shrink animating surfaces |
| **UnityWebBrowser (UWB)** | engine-asset | CPU buffer over IPC (TCP default) | None | internal cap | **one engine process per browser** | structural multi-process (for isolation, CPU path) |
| **Unreal WebUI / UCefView** | framework | OnPaint (stock) + OnAcceleratedPaint (Web UI/UCefView) | Win D3D11 shared texture into RHI | `windowless_frame_rate`-style | A few layered widgets | layering; one CEF/GPU proc; flicker if texture held |
| **OBS obs-browser** | app | OnPaint (default) + OnAcceleratedPaint | **Win NT handle / mac IOSurface / Linux dmabuf** | `windowless_frame_rate` (max 60); per-source FPS | **Yes — largest real consumer** | **cap to 3-4 sources + shutdown-when-hidden** |
| **Streamlabs Desktop** | app | (inherits obs-browser) | same | same | Yes | same cap-and-hide guidance |
| **vMix** | app | CEF OSR → D3D (Win only) | not user-exposed | global perf mode | Per-input Chromium | shrink resolution; avoid multi-GPU |
| **TouchDesigner Web Render TOP** | app | CEF3 OSR; shared-mem default | **Win D3D11 shared-texture opt-in** | `maxrenderrate` target | **Yes — process(es) per Web Render TOP** | **multi-process per view** (closest precedent to our plan) |
| **SpoutBrowser** | alternative | OSR shared texture → Spout | Win D3D11 | `--off-screen-frame-rate` (30/60) | Yes | separate process + unique `--cache-path` |
| **Electron OSR (default)** | framework | `paint` NativeImage = CPU readback | No | `setFrameRate` (≤240); damage-driven | Multiple offscreen windows | none; per-window capturer, one GPU proc |
| **Electron OSR (`useSharedTexture`)** | framework | OnAcceleratedPaint-equivalent via Viz GMB pool | **Win D3D11 / mac IOSurface / Linux dmabuf** | `setFrameRate`; 240-cap removed for shared-tex | Multiple, no pooling | none; documents `kFramePoolCapacity=10` + copy-then-release |
| **Neko / Kasm / BrowserBox** (cloud fleets) | alternative-arch | **whole-display capture** (Xvfb/X11) or CDP screencast — **NOT** per-browser OSR | n/a (HW video encode: VAAPI/NVENC) | encoder-paced; KasmVNC down-scales | **Yes, dozens–hundreds** | **one capture per display; scale = more containers/processes** |
| **Coherent Gameface / Ultralight** | alternative-engine | n/a (not CEF) — renders inline with host | n/a | host-frame | Yes, many views | abandon Chromium OSR model entirely |

*Uncertain/version-sensitive:* CefSharp's exact accelerated-path fps, vMix internals, XSplit's OSR path (docs too thin — omitted from the table beyond a note that it's CEF-class).

---

## 2. Who actually runs MANY simultaneous OSR browsers — and how they cope

**Real many-OSR-browser consumers are rare, and none raises the in-flight cap. They ration *active* capturers:**

- **OBS Studio (obs-browser)** — the largest, most-stressed CEF-OSR consumer. Its own guidance: **"Limit to 3-4 browser sources maximum"** because "the GPU cannot render all your sources quickly enough." Second lever: **"Shutdown source when not visible"** (kills the Chromium process when hidden) — the direct analog of an off-screen visibility gate. The **OBS 30.2→31 regression** (#470: "15+ videos in iframes" → "more than a couple at a time freezes all the videos," after the new CEF 127 shared-texture impl) and **#468** ("hang on a frame for 250ms, repeating") are the clearest public reproductions of our ceiling, confirmed on 3 machines.

- **Vuplex (Unity, commercial)** publishes a number: **"usually 10 active webviews on Windows, macOS, Android without performance issues."** This independently corroborates both our empirical ~8–10 ceiling and Chromium's `kFramePoolCapacity=10`. Their answer to scale is **not** multi-process — they accept ~10 and ship plain **CPU OnPaint on macOS**.

- **cef-mixer** composites a grid of independent browsers but only at small counts (2×2/3×3) — it demonstrates the pattern, never stresses the ceiling.

- **TouchDesigner** runs **multiple CEF process groups per Web Render TOP** and scales acceptably — the strongest existing precedent for our multi-process direction (caveat below).

**Who looks like a many-browser app but isn't OSR:** Spotify, Steam, Battle.net, Epic, GOG, Discord, Slack, VS Code — all **windowed** CEF/Electron (native HWND/NSView). They never touch `FrameSinkVideoCapturer` and offer **no** evidence that many-simultaneous-OSR scales. This is a meaningful negative result: the OSR-into-texture niche has **no large public app running 12 concurrently-animating OSR browsers.**

**The one industry that genuinely runs dozens–hundreds of live browsers** (Neko, Kasm/KasmVNC, BrowserBox) **categorically avoids per-browser OSR.** They render *windowed* Chromium into a virtual display and capture the **whole display once** at the X-server/compositor level, then HW-encode (VAAPI/NVENC). There is exactly **one capturer per display**, so the per-capturer pool ceiling never arises — and they scale "more browsers" as **more containers/processes**, never more capturers in one process.

---

## 3. State of the art for getting pixels out at scale

**Two paths, same source:**

1. **OnPaint (CPU readback)** — historical default; GPU→CPU copy per frame. Hosts the documented "every other frame dropped" 30fps behavior (`CropScaleReadbackAndCleanMailbox` can't keep up at 60Hz).
2. **OnAcceleratedPaint (GPU shared texture)** — Win D3D11 NT handle / **macOS IOSurfaceRef** / Linux dmabuf. Lowers **per-frame cost** but **does not change the per-browser capturer concurrency model**.

**Critical: both paths route through `viz::FrameSinkVideoCapturer` → `OnFrameCaptured`** (confirmed in CEF #3730). The accelerated path merely swaps a CPU `CopyOutputRequest` target for a `GpuMemoryBuffer`/`MappableSharedImage`. Confirmed constants in `frame_sink_video_capturer_impl.h`:

```
kDesignLimitMaxFrames = 10;
kFramePoolCapacity   = kDesignLimitMaxFrames + 1;   // 11
kTargetPipelineUtilization = 0.6f;                  // "red line" ≈ 6 in-flight
```

These are **per-capturer (per browser)**, independently confirmed from a second codebase — **Electron's OSR README states `kFramePoolCapacity=10` verbatim.**

**True zero-copy is impossible — independently re-derived by Electron and CEF.** The pool hands a **different** texture each frame and reclaims it on `release()`/callback return. Electron's PR #42953 author: it's "actually one [copy], there's a CopyRequest of frame texture." Mandatory pattern everywhere: **open the handle → copy to your own intermediate texture → release immediately.** This matches our existing "GPU-blit-the-copy" conclusion.

**macOS is the weak platform for accelerated OSR — and everyone knows it.** Upstream CEF historically did **not** call OnAcceleratedPaint on macOS; it required out-of-tree patches that **cannot rebase past Chromium ~103**, and the reference Metal POC is "slow and buggy." **Vuplex ships CPU OnPaint on Mac despite having D3D11 accel on Windows.** OBS ships **patched CEF (4183)** specifically to get macOS IOSurface OnAcceleratedPaint. Electron itself flags (#45428) that the macOS `useSharedTexture` path has "neither test nor documentation."

> **Actionable uncertainty (verify):** confirm flutter_cef's `cef_host` is actually on the **patched IOSurface OnAcceleratedPaint** path. If it has silently fallen back to **CPU OnPaint**, the per-capturer ceiling is *much* worse (every-other-frame readback drop), and fixing the paint path would be higher-leverage than multi-process.

**Multi-process at scale:** the cloud fleets and TouchDesigner/SpoutBrowser all scale by **more processes**, each owning **one** capture/encoder. SpoutBrowser surfaces a concrete gotcha: you need a **unique `--cache-path` per instance** or cefclient "reuses the main browser process."

---

## 4. Does anyone solve many-simultaneous-animating OSR?

**No one solves it *within the per-browser CEF OSR capturer model.* The genuine solutions all step outside it.**

- **Pooling across processes (the cloud-fleet answer):** Neko/Kasm/BrowserBox **eliminate** N capturers by capturing **one display** (or using CDP `Page.startScreencast` per tab with `everyNthFrame` + `screencastFrameAck` backpressure). This is the only architecture that runs hundreds of live browsers. **But it doesn't fit our requirement** of independently-positioned, separately-zoomable per-tile Flutter textures — you'd need a tiling/scene-graph step to carve one capture back into per-tile textures. The transferable *principle* is "amortize the capture pool across surfaces," not the literal architecture.

- **Take-turns / load-shed:** Chromium's own `VideoCaptureOracle` (drop resolution, not just fps; reduce ≤once/3s), KasmVNC "Video Mode" down-scaling, and CDP `everyNthFrame`+`Ack` are all **the same idea** — gate on completion/ack, shed load by lowering resolution/fps. Nobody enlarges the pipeline.

- **Accelerated path avoiding the capturer:** **does not exist for CEF.** OnAcceleratedPaint still flows through `FrameSinkVideoCapturer`. The only engines that avoid a per-view capturer are **non-CEF**: Coherent Gameface, Ultralight, **Servo + surfman** (one WebRender context, N surfaces usable as host textures — offscreen + multi-webview landed 2024), and **WPE/WPEBackend-fdo** (per-view dmabuf/EGLImage export, "synchronization implicit, avoiding additional capture infrastructure"). These prove a general web engine *can* render N live views→host textures with **no** per-view capturer — but **none has a first-class macOS IOSurface story**, so they're architecture validation, not drop-in replacements.

- **Multi-GPU-process pooling for OSR specifically:** **searches found ZERO projects** spawning multiple CEF/GPU processes to raise OSR concurrency. OBS, Electron, cef-mixer, QCefView all share **one** GPU/Viz process. **So our multi-`cef_host` direction is novel-in-this-corpus** — and the only surveyed approach that actually raises the *aggregate* readback ceiling.

---

## 5. Lessons for our problem; does our fix match prevailing practice?

**Our diagnosis is correct and triple-confirmed** (Chromium source, Electron README, Vuplex's ~10 number). The ceiling is **aggregate single-GPU-process readback bandwidth** across N per-browser capturers, not a single global constant.

### 5a. Our two-pronged fix is well-supported — with one important sharpening

- **Multi-`cef_host` (more GPU processes): VALIDATED but uncommon for OSR.** TouchDesigner (process-group per view) and the cloud fleets (one capture/encode per process/container) are the precedents. **Caveat (TouchDesigner/Malcolm):** extra GPU contexts add context-switch overhead "but not hugely so," and each extra `cef_host` on macOS is a **full GPU+Renderer+Plugin helper-app tree**. → **Use a small bounded pool with a strict per-host capturer budget (~6 sustained, hard-stop ~10); shard only when a host would exceed budget. Do NOT spawn one host per tile.**

- **Take-turns throttle: build it as round-robin EXTERNAL-BEGIN-FRAME pacing, NOT `windowless_frame_rate` tuning.** This is the survey's biggest correction. Under `SendExternalBeginFrame`, **CEF's internal timing is disabled and `windowless_frame_rate` is IGNORED** (cef-mixer + obs-browser docs). Worse, **CefSharp #2675/#2940 prove the accelerated path collapses to ~1 fps WITHOUT a host-driven begin-frame pump** (callback fired ~1–3×/sec even with an empty body). So a throttle that merely lowers `windowless_frame_rate` would be a **no-op** for our IOSurface/OnAcceleratedPaint path. The correct scheduler shape:
  - **ONE BeginFrameSource** (Flutter/host composition tick or CVDisplayLink), **fanned out round-robin** to N browsers.
  - **Completion-gated per browser:** issue a browser's next BeginFrame **only after its prior frame completed** (`OnAcceleratedPaint`/`OnFrameComplete`). Firing a second `SendExternalBeginFrame` before the prior completes triggers **`Check failed: !pending_frame_callback_. Got overlapping IssueExternalBeginFrame`** — a **GPU-process crash** that, on a shared host, **blanks every tile** (CEF #2800). cef-mixer's unconditional per-tick `SendExternalBeginFrame` is the *anti-pattern* to avoid.

### 5b. A second, possibly *primary*, cause of our exact symptom — and a hazard in the throttle itself

The gap deep-dive on **CEF #2483 / #3427 (FrameEvictionManager)** is the closest match to "1–4 of 12 never produce a first frame," and it **changes the recommendation**:

- OBS/CefSharp engineers hit our **exact** symptom — *"six OSR windows… only four behave normally, other two stop refresh," ">5 browsers," "blank buffer after `WasHidden(false)`"* — and root-caused it to **Chromium's `FrameEvictionManager` evicting compositor frames** for off-screen browsers (an LRU soft cap), **not** to capturer throughput. After eviction, `WasHidden(false)` returns a blank/stale buffer.
- **The documented fix is a forced resize with *changed* dims** (a same-size `WasResized()` is a no-op; CEF added a size guard). CefSharp's shipped recipe: resize −1px then restore. `Invalidate`/`NotifyScreenInfoChanged`/begin-frame ticks alone **do not** un-stick an evicted view.
- **Hazard:** a take-turns throttle that **hides off-screen/idle tiles via `WasHidden`** would *manufacture the many-hidden-then-shown pattern that arms eviction.* Per the cross-check against `flutter_cef`'s `cef_host/main.mm`, **`DoSetVisible`'s un-hide path lacks the force-resize kick** (it only sets `WasHidden(!visible)`), while the **resize path already does `WasResized()` + `SendExternalBeginFrame` correctly** — so the un-hide path should copy that pattern *with changed dims*.

> **Strong recommendation:** before committing to "more processes for more GPU," **instrument whether the blanks correlate with frame eviction** (check `LocalSurfaceId`/frame-id on the blank slots, per the #2483 reporters) **vs. capturer count**. If eviction is the cause, more GPU processes won't help; the cheap, well-precedented fix is **force-resize-on-unhide**. These are not mutually exclusive — land the resize-kick regardless, since it's low-risk and addresses a class our throttle would otherwise worsen.

### 5c. Operational guardrails the survey surfaced

- **Release/copy every frame inside the callback; never hold the IOSurface across frames** — no IOSurface primitive supports safe cross-frame holding; the pool reclaims at callback return. A holding/slow consumer **starves the pool and reproduces blanks independent of GPU saturation** (Electron added a GC-warning for exactly this).
- **macOS sync is by ordering, not exclusion.** There is **no keyed-mutex analog** on macOS (keyed-mutex is the QCefView/Windows-D3D11 proposal; Electron even *removes* the mutex on Windows). CEF hands us a **raw IOSurfaceRef with no fence and no mutex.** Safety rests on doing the copy + an explicit **GPU flush / Metal commit inside `OnAcceleratedPaint` before returning**, ordered ahead of CEF's pool recycle. → **Verify flutter_cef issues that flush/commit and doesn't return early; a hitch that delays the copy past recycle yields a torn/blank frame even at low view counts.** We can fence our *own* read but cannot make CEF wait for us — so a "fix the sync on one GPU process" path is **not** available to us on macOS the way it is on Windows.
- **Pin/validate CEF carefully:** the shared-texture path is where concurrency is most fragile across upgrades (OBS 30.2→31 regression; CEF #4057 null handle on 143 release builds; the 250ms animation-region detection bug, chromium 391118566). If our blanks correlate with **animation start**, part of it may be that casting/animation-detection bug — **fixable by a newer Chromium pin rather than adding processes.**

### 5d. Prevailing practice vs. our plan — verdict

| Lever | Prevailing practice | Our plan |
|---|---|---|
| Cap active capturers | OBS "3-4 sources max" + shutdown-when-hidden; Vuplex accepts ~10 | take-turns throttle (matches) |
| Multi-GPU-process for OSR | **nobody** (TouchDesigner/fleets do per-process-capture, not multi-GPU-for-one-scene) | multi-`cef_host` (**novel; sound; bound the pool**) |
| Throttle mechanism | external begin-frame (cef-mixer) / oracle / CDP ack | **must be external begin-frame, completion-gated — not `windowless_frame_rate`** |
| Avoid the capturer | leave CEF (Gameface/Ultralight/Servo/WPE) | n/a (committed to CEF) |
| Display-amortized capture | cloud fleets | **doesn't fit per-tile textures** |

**Better idea the survey surfaced:** the combination — **a small bounded pool of `cef_host` processes (each under a ~6-sustained capturer budget) + a single-source, round-robin, completion-gated external-begin-frame scheduler per host + a hardened force-resize-on-unhide path + prioritizing cold-start (first-frame) capturers over steady-state animators when shedding load.** Prioritizing first-frame establishment directly targets our actual failure (late views never get frame #1); the oracle's `kDebouncingPeriodForAnimatedContent=3s` / `kProvingPeriodForAnimatedContent=30s` explains *why* late-joining animators into a saturated GPU get starved, so **admitting views sequentially** (let each establish a steady frame before admitting the next) is a precise counter.

---

## 6. The honest frontier — what nobody appears to solve

- **No one solves many-simultaneous-animating OSR *inside* the per-browser capturer model.** Every real solution either rations active capturers (OBS/Vuplex), leaves CEF for a non-capturer engine (Gameface/Ultralight/Servo/WPE), or captures one display and HW-encodes (cloud fleets). The accelerated/zero-copy path **does not** escape the capturer.

- **No public "12 concurrently-animating OSR browsers" benchmark exists.** Our observed ~8–10 ceiling is **novel empirical data** that matches `kDesignLimitMaxFrames`/`kTargetPipelineUtilization` math almost exactly — treat it as the authoritative number to size the throttle and process fan-out.

- **No multi-GPU-process OSR precedent** — our direction is uncharted; sound, but unvalidated at scale by anyone else.

- **macOS accelerated OSR is upstream-unsupported and patch-fragile.** No keyed-mutex, no fence handed to the consumer, no upstream test/docs; the GPU-OSR patches can't rebase past Chromium ~103; the maintainer's long-term answer (Ozone, #3263) is Linux-only and **"not currently planned or staffed"** by Google. **We are on the least-trodden platform path.**

- **No begin-frame-completion signal is exposed to clients on the relevant boundaries** (CEF #4166 maintainer: "I'm not sure there is a reliable signal currently, as this involves multiple asynchronous pipelines in different processes"). First-frame establishment under contention has **no clean upstream primitive** — the field workaround is per-frame marker pixels in JS + resize-kicks.

- **`FrameEvictionManager` blanks on hide→show with >5–6 browsers (#3427) remain OPEN** with no clean upstream fix — only the resize-kick workaround. This is the failure class our own throttle could *arm*, and it is the single most under-appreciated risk in the planned design.

---

### Files referenced
- `/Users/wenkaifan/Dev/flutter_cef/packages/flutter_cef_macos/native/cef_host/main.mm` — the un-hide path (`DoSetVisible`, missing force-resize kick), the correct resize path (`WasResized()` + `SendExternalBeginFrame`), the begin-frame pump (`PumpBeginFrame`, no in-flight/OnFrameComplete gate), and the load-time self-heal (`OnLoadEnd`→`Invalidate`, `kOpInvalidate`/`DoInvalidate`) are the concrete code sites to harden before adding multi-process/take-turns.