## Unreleased

* Authored documents at a real origin (`kOpSetAuthoredHtml` 0x3f and the
  `loadAuthored` verb). `loadHtmlString(baseUrl:)` is no longer limited by the
  2 MB `data:` URL cap.
* Document-start scripts and create-time JS channels (`kOpSetDocumentStart`
  0x41).
* `hostGroup`: ephemeral sessions in one group share a `cef_host`.
* Fix: a dispose that raced its own create no longer leaks the browser.
* Ctrl editing shortcuts are the page's first: `cef_host` runs the edit command
  (`OnKeyEvent`) only for a key the page and Blink left unhandled.
* `fetch_cef.ps1` checks the CEF download against a SHA-1 pinned in the script,
  not one fetched from the same CDN, and fails when it doesn't match.
* A host that dies before `kOpReady` is reported as `createFailed`, not
  `crashed` (exit code 2 is still `locked`).
* Fix: a view hidden right after `create()` kept painting: `cef_host` drops a
  `kOpSetVisible` sent before the browser's slot exists. The plugin re-sends
  the hide on `kOpCreated`.
* Protocol v4.

# 0.1.0

- Initial Windows package skeleton (Phase 1 of the Windows-port vertical
  slice): endorsed federated plugin, stub C++ plugin answering every
  `flutter_cef` channel verb, `cef_host` Windows host skeleton
  (pipe connect + `kOpReady`), and `native/cef_host/PROTOCOL.md` — the
  transcribed wire/channel contract builders implement against.
