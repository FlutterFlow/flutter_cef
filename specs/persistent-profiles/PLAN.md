# flutter_cef — persistent, shared browser profiles

Goal: make a `CefWebView` behave like a real browser tab — sign in once, stay
signed in across cef_host **and** host-app relaunch, and have multiple webviews
**share** one logged-in profile (cookies / `localStorage` / IndexedDB / saved
logins). At-rest security must match Chrome's: OSCrypt-encrypted secrets keyed by
a stable macOS Keychain item, renderer sandbox on. Passkeys/WebAuthn are out of
scope for this plan (tracked separately; they gate on an Apple-managed
entitlement on the *consumer's* bundle).

The app-facing change is one optional parameter: `CefWebView(profile: 'work')`.
Everything else is internal to this repo.

## The governing constraint

Chromium/CEF holds a **single-writer lock on a cache directory** (the on-disk
cookie DB + storage are not multi-process). So a profile that is *shared* by N
webviews must be served by **one** `cef_host` process hosting **N browsers** —
you cannot point two processes at the same `root_cache_path`. That collision is
exactly why today's cache path is per-pid and throwaway:

```
main.mm:1481  root_cache_path = NSTemporaryDirectory()/flutter_cef_cache_<pid>   // fresh every launch
```

And today the unit of everything is 1:1 — `CefWebSession` *is* the process
boundary: it owns {IOSurface + FlutterTexture + cef_host process + IPC socket +
the single browser} together (`CefWebSession.swift:117-133`,
`setupSocketAndSpawn` 394-460; `main.mm` `OnContextInitialized` creates exactly
one windowless browser into the one global surface, 835-862). Sharing a profile
means splitting that bundle along a new seam: **process-per-profile**, **texture
+ browser per view**.

## Target model

```
FlutterCefPlugin
  profiles: [profileId : CefProfileHost]      // NEW — one entry per live profile
    CefProfileHost                            // NEW — owns process + socket + reader thread
      cef_host process  (--profile-dir=<abs>) // ONE per profile; root_cache_path = that dir
      browsers: [browserId : CefWebSession]   // N browsers multiplexed over one socket
        CefWebSession                         // SLIMMED — owns IOSurface + CVPixelBuffer
          FlutterTexture                      //   + texture + event callbacks + geometry
                                              //   (no longer owns the process/socket)
```

- A **null/omitted `profile` = ephemeral** (today's behaviour: in-memory cache,
  nothing on disk, its own throwaway host). Existing consumers are unchanged.
- A **named `profile` = persistent + shared**: `root_cache_path =
  <AppSupport>/<bundleId>/flutter_cef/profiles/<profile>` (0700). Every webview
  with the same name shares one process → one cookie jar → one login.
- Within one process, all browsers use the **global request context**, so cookie
  / storage sharing is automatic — no per-browser `CefRequestContext` needed.

## Wire-protocol change: a browserId dimension

Every IPC frame gains a routing id (both directions):

```
old:  [u32 bodyLen][op:u8][payload]
new:  [u32 bodyLen][u32 browserId][op:u8][payload]     bodyLen = 4 + 1 + payload.len
```

- `browserId == 0` → process/profile-level (e.g. `opReady`, process log).
- New control ops (plugin → host):
  - `opCreateBrowser` — payload {url, w, h, dpr, iosurfaceId, allowedSchemes};
    establishes a new browserId. Replaces the implicit at-startup browser.
  - `opDisposeBrowser` — close one browser; keep the process if others remain.
  - `opShutdown` (browserId 0) — quit the whole process (last browser gone).
- All existing per-view ops (`opPointer`, `opResize`, `opPresent`, `opUrl`, …)
  are unchanged except they now carry the originating/target browserId.

`main.mm`: `CefInitialize` runs **once per process** with the profile's
`root_cache_path`; a `map<browserId, Slot{CefBrowser, IOSurface, RenderHandler,
geometry}>` replaces today's `g_surface`/`g_width`/… globals; the render handler
and client become per-browser (key off `browser->GetIdentifier()`); the IPC read
loop dispatches by browserId. `OnContextInitialized` stops auto-creating a
browser — it signals `opReady` and waits for `opCreateBrowser`.

## Security requirements (the "like Chrome" bar)

1. **Signed build = real crypto.** OSCrypt only encrypts for real under a
   Developer-ID-signed `cef_host` tree (`CEF_HOST_ADHOC=OFF`); the ad-hoc default
   uses `--use-mock-keychain` + `--password-store=basic` (`main.mm:792-793`) — a
   fixed key, i.e. plaintext-equivalent at rest.
2. **Dev safety rail.** In an ad-hoc build, a **named (persistent) profile is
   refused** and falls back to ephemeral with a logged warning, unless
   `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1`. Never write real credentials under a
   mock key by accident.
3. **Sandbox on** in signed builds (`no_sandbox=false`, already gated) — renderer
   can't read the cookie DB directly; the browser process brokers it.
4. **Stable, app-scoped Keychain item.** The OSCrypt "Safe Storage" item must be
   named per-product and stable across launches/builds (else: a Keychain prompt
   every launch, or key shared with other CEF apps). **VERIFY** the exact knob
   (likely `cef_host` bundle `CFBundleName` / CEF framework branding) experimentally.
5. **CDP is incompatible with a persistent profile.** `enableCdp` opens an
   *unauthenticated* localhost port that can read the whole cookie jar — and with
   multiplexing, every logged-in browser in the process. Reject `enableCdp == true`
   when `profile != null`.
6. Profile dir is `0700`; lives under Application Support, never `/tmp`.

Honest ceiling (same as every browser, state it): not safe against malware
running as the logged-in user; `localStorage`/IndexedDB are plaintext on disk
(OSCrypt covers cookie/password *values* only); FileVault is the real at-rest
backstop. `clearCookies` on a shared profile clears it for *all* tiles on it —
that's the intended profile-level semantics.

## API surface

Dart (`CefWebController` / `CefWebView`): add `String? profile` (null = ephemeral).
Threaded through `create()` into the method-channel `create` args as `profile`.
Method/event protocol is otherwise unchanged on the Dart↔native boundary; the
browserId dimension lives entirely below it (plugin ↔ cef_host).

## Phases (each ends at a green gate: analyze + test + signed-host smoke)

- **P1 — Durable profiles, single-view.** Add `--profile-dir` + the `profile:`
  API; stable App-Support path; real-OSCrypt path validated under
  `CEF_HOST_ADHOC=OFF`; dev safety rail; CDP gating; Keychain-name verification.
  **No multiplexing yet** — enforce "a named profile may be live in at most one
  session at a time" (plugin rejects a second concurrent `create` on a live
  profile). Ships the entire secure foundation.
  Gate: log into a real site in a tile → quit + relaunch cef_host *and* the host
  app → still logged in. Signed-host smoke confirms no Keychain prompt.
- **P2 — Multiplexed shared profiles.** The browserId wire refactor +
  `CefProfileHost` + `main.mm` multi-browser slots. Lifts the single-view
  restriction → many tiles share one live login.
  Gate: two webviews on `profile: 'x'`; sign in on one → the other sees the
  session without reload.
- **P3 — Crash recovery.** Process-per-profile means a browser-process crash
  blinks *all* tiles on that profile (renderer crashes stay isolated per CEF
  multi-process). On host death, re-spawn and re-create every browser from saved
  {url, geometry}; expose `onProcessRestart` so controllers can reload.
  Gate: kill a profile's cef_host → its tiles recover.
- **P4 — Docs + security checklist.** PORTING.md opcode table gains the browserId
  field; README documents profiles + the signed-build-for-secure-persistence
  requirement; CHANGELOG; a SECURITY.md checklist for credentialed profiles
  (signed, sandbox on, CDP off, Keychain scoping, FileVault note).

## Invariants

- API unchanged when `profile` is omitted — ephemeral, one process per view,
  byte-for-byte today's behaviour.
- macOS builds + renders at every phase gate (verify, don't assume).
- No real credentials ever persisted under mock-key crypto (the dev safety rail).
- CDP never coexists with a persistent profile.

## Open questions to resolve in P1

- Exact OSCrypt Keychain service-name knob under CEF (cef_host `CFBundleName` vs
  framework branding) — confirm by inspecting the created Keychain item.
- Model ephemeral as a throwaway `CefProfileHost` (one code path) vs. keep the
  legacy direct spawn? Prefer one code path if the refactor stays clean.
- `persist_session_cookies` default — ON for "stay signed in" through session
  cookies? (Persistent cookies already survive regardless.)
- Default profile name / whether Campus passes a single `'default'` or
  per-trust-zone names (untrusted tiles → ephemeral, by design).
