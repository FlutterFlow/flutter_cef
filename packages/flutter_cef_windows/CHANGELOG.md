## Unreleased

* A renderer that leaves the liveness ping unanswered ends only its own tile
  (`processGone("crashed")`); it used to end the whole host. The ping is
  answered by the renderer's main thread (a process message), not the page, so
  a page that breaks `window.cefQuery` or `JSON.stringify` isn't taken for
  hung, and a page can't answer in the ping's place. As on macOS.
* `cef_host` ends itself when it is still running 6 s after a shutdown
  request, or 30 s after its message loop quit (a stuck `CefShutdown`),
  logging `still running after shutdown (<why>); exiting now` to stderr. As on
  macOS. The watchdog's thread starts with the host, so a wedged thread
  holding the loader lock can't keep it from starting.
* A replaced GPU process doesn't end the host, unlike on macOS: Windows tiles
  keep painting after Chromium relaunches it.
* CI: `pipe_probe` serves its pages on 127.0.0.1 instead of example.com,
  prints each host's stdout and stderr, and checks that a host whose UI
  thread is suspended at `kOpShutdown` exits on its own about 6 s later. The
  smoke test hangs one tile's renderer on a shared host (only that tile goes;
  a page that breaks evals beside it stays) and replaces a host's GPU process
  (its tiles keep painting).
* `FLUTTER_CEF_LOG_FILE=<path>` appends the plugin's and every `cef_host`'s log
  lines to that file, each with a millisecond tick, as well as sending them to
  `OutputDebugString`.
* CI: the smoke test's crash-loop case kills the tile's renderer only once the
  previous reload has finished, re-sends a kill that didn't take, and uses a
  `data:` page so a reload never goes to the network. It runs 3 rounds per
  compositing mode and prints the host's crash-loop log lines.

## 0.1.0

* Authored documents at a real origin (`kOpSetAuthoredHtml` 0x3f and the
  `loadAuthored` verb). `loadHtmlString(baseUrl:)` is no longer limited by the
  2 MB `data:` URL cap.
* Document-start scripts and create-time JS channels (`kOpSetDocumentStart`
  0x41).
* `hostGroup`: ephemeral sessions in one group share a `cef_host`.
* Fix: a dispose that raced its own create no longer leaks the browser.
* Security: JS channels are registered per browser, not per host, and a `ch:`
  message for a channel the browser didn't register is refused.
* Ctrl editing shortcuts are the page's first: `cef_host` runs the edit command
  (`OnKeyEvent`) only for a key the page and Blink left unhandled.
* The CEF pin lives in one file, `native/cef_host/cef_pin.txt` (version and
  SHA-256), read by `fetch_cef.ps1` and both CMakeLists. The download is
  checked against the pinned SHA-256, and configure fails when `CEF_ROOT`
  points at a different CEF version.
* A host that dies before `kOpReady` is reported as `createFailed`, not
  `crashed` (exit code 2 is still `locked`).
* Fix: a view hidden right after `create()` kept painting: `cef_host` dropped a
  `kOpSetVisible` sent before the browser existed. The plugin re-sends the hide
  on `kOpCreated`.
* Fix: ops sent in the first moments after create (a resize, JS, input) were
  dropped because the browser didn't exist yet; `cef_host` now holds them and
  runs them once it does. A create queued before the host is ready is sent at
  the view's current size, and a frame the size gate rejects no longer counts
  as painted, so a tile stuck at the wrong size reports `paintStalled`.
* Fix: `cef_host` read its arguments in the ANSI code page, so a profile path
  under a non-ASCII user name failed. It reads the UTF-16 command line.
* Fix: a locked profile could be reported as `createFailed`.
* Fix: a pipe write to a host that stopped reading could freeze the UI thread.
  Writes time out after 3 s and end the host (`processGone('crashed')`).
* Fix: the reaper deleted an ephemeral profile dir while Chromium children
  still held files in it; it now ends the whole process tree first.
* A renderer that crashes 4 times within 10 s ends only its own tile
  (`processGone('crashed')`, via the new upstream `kOpBrowserGone` 0x42)
  instead of reloading forever; the other tiles on its host carry on. The host
  exits only when two tiles crash-loop within 10 s of each other, which means
  its children can't start. Same design as macOS.
* A liveness sweep ends a host whose renderer leaves a JS ping unanswered for
  15 s (GPU-process replacement isn't detected). `paintStalled` now repeats
  every grace, the macOS cadence.
* `sessionStats`, `setAudioMuted`, `setFrameInterval`, `freezeSession` and
  `thawSession` are implemented. `chooseContextMenu`, `respondMediaRequest`,
  `setMediaSetting`, `openAuthWindow` and `showEmojiPicker` reply
  `PlatformException('unsupported')`, and unknown verbs `NotImplemented`,
  instead of succeeding silently.
* `enableAgentControl` explains when a view asked for agent control but joined
  a profile whose host started without it.
* Security: the Chromium sandbox is on (`FLUTTER_CEF_NO_SANDBOX=1` turns it
  off for diagnosis). Downloads open a Save As dialog with a sanitized, unique
  name instead of writing silently. Page-sourced payloads are capped at 8 MiB so
  one page can't take down a shared host. `allowedSchemes` must be scheme
  tokens. The agent-control relay caps connections that haven't authenticated.
* Rendering: software-composited frames (no GPU, Remote Desktop, VMs) are
  uploaded into the shared texture, `<select>` dropdowns are drawn, and the
  host falls back to a WARP device. `FLUTTER_CEF_SOFTWARE_COMPOSITING=1`
  forces the software path.
* CI builds and runs `pipe_probe` and a runtime smoke test of the example app,
  each with and without software compositing.
* Protocol v6 (`kOpSetAudioMuted`, `kOpSetPumpInterval` and `kOpBrowserGone`
  on Windows).

# 0.1.0

- Initial Windows package skeleton (Phase 1 of the Windows-port vertical
  slice): endorsed federated plugin, stub C++ plugin answering every
  `flutter_cef` channel verb, `cef_host` Windows host skeleton
  (pipe connect + `kOpReady`), and `native/cef_host/PROTOCOL.md` — the
  transcribed wire/channel contract builders implement against.
