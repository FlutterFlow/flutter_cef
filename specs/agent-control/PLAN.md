# Agent-controllable CEF tiles — per-tile opt-in + Campus-only CDP

Goal: let a user point an agent (the Campus CLI / MCP, driving `agent-browser`) at a
**live, logged-in** webview tile — **without** duplicating the tile, losing page
state, or being asked permission every task — while keeping the credentialed
profile from being drivable by arbitrary local processes.

The UX reduces to one per-tile switch: **"Allow agent control."** Off by default.
On → an agent can drive that exact tile in place. The switch *is* the consent
(set once, not per task). The security comes from making the CDP channel reach
**only Campus**, and from scoping it to the one opted-in tile.

This builds on the persistent-profiles work (`specs/persistent-profiles/`); it
also **reverses the hard "CDP-rejected-on-named-profile" block** added in the
security hardening — that block is replaced by this opt-in.

## Why the obvious approaches don't fit

- **Clone the tile / hand off cookies** (persistent-profiles path #1): no state
  loss, but it *duplicates* the tile — the user explicitly doesn't want that.
- **Open a TCP CDP port** (today's `campus drive`): drives the live tile, but CDP
  is **unauthenticated** — *any* local process that reaches the port gets full
  control + can read the whole cookie jar. Unacceptable on a credentialed profile.
- **No live profile swap exists** (CEF binds the request context at browser
  creation), so "flip this tile to an agent profile" isn't possible anyway.

So: drive the live tile over CDP (no clone, no state loss), but (a) gate it on a
per-tile opt-in, and (b) make the CDP channel Campus-only + tile-scoped.

## Security model (the three gates)

1. **Per-tile opt-in** (`agentControllable`, default off) — consent, set once.
2. **Pipe transport, not a port** — cef_host exposes CDP over inherited fds
   (`--remote-debugging-pipe`), so there is **no listening socket** and the only
   process that can speak CDP is the one that launched cef_host with those fds:
   the Campus app. No arbitrary local process can connect, *by construction*
   (this is why Playwright/Puppeteer use it).
3. **Token-gated, tile-scoped relay** — the Campus app re-exposes CDP to
   `agent-browser` through a relay that (a) requires a per-grant token and (b)
   filters to the opted-in tile's target only. CDP-over-pipe is the *browser-wide*
   endpoint (lists every page in the process — and our model is one process per
   profile), so per-tile scoping **must** be enforced here; CDP can't do it.

**Owner-local by construction.** The agent only ever drives the *owner's own*
tiles — the relay runs on the owner's machine and peers can't run the owner's
cef_host (they only ever get the read-only `{url,title}` mirror), so there is no
"drive a peer's tile" path to build or secure. The `agentControllable` flag is
*synced* so peers can *see* which tiles are agent-controllable, but control itself
is owner-local. (This removes any cross-peer relay concern from the design.)

Net: the raw CDP never leaves the app; agents reach a tile only with a token, only
for tiles the user opted in. The credentialed jar is no longer exposed to local
processes.

## Architecture (layers)

```
agent-browser  ──ws(token)──►  flutter_cef relay  ──pipe fd3/4──►  cef_host (CDP)
  (the agent)                  (in the app/plugin)   NUL-JSON       (browser proc)
                                  │ token + target-scope
Campus: per-tile "Allow agent control" toggle ─ gates ─► `campus drive <tileId>`
        which asks the controller for a brokered {wsUrl, token} and hands it over
```

### Layer A — flutter_cef: cef_host CDP over a pipe (private to the app)

- **cef_host (`main.mm`):** when an opt-in flag is set, inject the Chromium switch
  in `OnBeforeCommandLineProcessing` (`main.mm:923-971`): `command_line->
  AppendSwitch("remote-debugging-pipe")` (default ASCIIZ = NUL-delimited JSON).
  Do **not** also set `settings.remote_debugging_port` (`main.mm:1806-1811`) for
  the pipe path. Browser-process only (`process_type` empty). cef_host reads CDP
  on **fd 3**, writes on **fd 4** (hard-coded in Chromium; not configurable on
  POSIX). The argv-scrub at `main.mm:1781-1782` means the switch must go through
  `OnBeforeCommandLineProcessing`, not `clean_argv`.
- **Swift spawn (`CefProfileHost.spawn`, `CefProfileHost.swift:122-163`):** THE
  mechanical change. `Foundation.Process` cannot place fds 3/4 — replace the
  `Process()` launch with **`posix_spawn` + `posix_spawn_file_actions`**: create
  two `pipe()` pairs, `adddup2` the child read-end→3 and write-end→4 (`dup2`
  auto-clears `CLOEXEC` on 3/4), `addclose` the originals, mark the parent-side
  ends `CLOEXEC` so they don't leak. The Swift side then speaks CDP over those
  fds (NUL-framed: append `\0` on send, split on `\0` on read — Puppeteer's
  `PipeTransport` is the reference). This replaces the `pickFreeTcpPort` /
  `--cdp-port` block (`CefProfileHost.swift:144-150`); `cdpPort:Int` is no longer
  the transport for the pipe path.
  - Gotcha: cef_host spawns its own macOS helper apps for renderers/GPU — ensure
    only the top-level browser process inherits fds 3/4 (CEF launches helpers
    itself; they get default-closed 3/4, which is correct).
- **Plugin API (`CefWebController`/`FlutterCefPlugin`):** expose a brokered,
  per-controller CDP endpoint instead of a raw port — e.g.
  `Future<({String wsUrl, String token})> enableAgentControl()` which (1) ensures
  the profile's cef_host is in pipe mode, (2) registers a token-gated relay scoped
  to *this* controller's browser target, (3) returns the brokered ws-url. A
  matching `disableAgentControl()` tears the grant down.

### Layer B — flutter_cef: the token-gated, tile-scoped relay (in the plugin)

The relay belongs in flutter_cef (CDP plumbing, reusable, and the plugin already
owns the pipe). It:
- binds a localhost CDP-WebSocket endpoint (this *is* a port, but it is
  **token-gated** — the only auth CDP otherwise lacks — and the token is minted
  per grant and embedded in the ws path Campus hands to `agent-browser`);
- bridges that WebSocket ⇄ the cef_host pipe;
- **scopes to the opted-in tile's target** (filters CDP target/session traffic to
  the `browserId` for this controller), so a grant for tile A can't reach tile B
  even though both share the profile's process.

`agent-browser` connects with `--cdp <wsUrl>` / `connect`, where `wsUrl` carries
the token — Campus controls that string (it already mints `endpoint`/`connect` in
`controlDescriptor`).

### Layer C — Campus (work_canvas): the per-tile toggle + CLI surface

- **`agentControllable` per-tile setting** (`cef_webview_tile.dart`):
  - Add `agentControllable` to `CefWebviewConfig` (`:771-797`) — persisted
    (omit-when-false in `toJson` like `enableCdp` at `:789`); stored as a
    **runtime-mutable** `ValueNotifier<bool>` on the instance (NOT `late final`
    like `_enableCdp` — it must flip live), added to `captureSnapshot()`
    (`:214-219`), with a `host.scheduleSave` listener (mirror `_url` at `:154`).
  - **Sync to peers** (unlike `enableCdp`, which is config-only): add it to
    `_contentState()` (`:224-227`), `CefWebviewMirror` (`:751-769`), and the
    `LwwRevisionPolicy.fields` of `cefWebviewSurfaceDeltaSpec` (`:99-101`) — add a
    `MergeFieldType.bool` variant in `tile_surface_delta.dart` if absent. Flip in
    `applyConfigPatch` (`:270-289`); the notifier self-broadcasts via
    `_emitContentDelta` (`:256`).
  - **Gate the drive surface on it:** `cdpEndpoint()` (`:331-364`) and
    `controlDescriptor()` (`:386-435`) return `{ok:false,
    reason:'agent-control-disabled'}` when `!agentControllable` — *before* the
    `_enableCdp` check. (`enableCdp` stays the process-spawn capability;
    `agentControllable` is the runtime consent gate on top.)
  - **Return the brokered endpoint:** change these two choke points to call the
    plugin's `enableAgentControl()` and return its `{wsUrl(token), token}` instead
    of the raw `127.0.0.1:<port>` (`:347-354`) — the raw port/pipe stays
    app-private. Update the `connect`/`examples` strings (`:396-400, :433`).
  - **UI:** `configChild` currently returns `null` (`:208`) — return a Campus-DS
    toggle row (per AGENTS.md rule 5: not Material `Switch`) bound to the notifier;
    optionally surface it in `headerTrailing` (`tile_kind_spec.dart:790`).
  - **CLI verb:** flows through the generic `tile.set_state` → `applyConfigPatch`;
    add an ergonomic verb + `CampusApi`/adapter/CLI per AGENTS.md rule 9, then
    `make codegen`. Existing `drive`/`webview-cdp` verbs
    (`bin/work_canvas_ctl.dart:1083, :1196, :3182-3187`) keep working, now gated.
  - Changelog fragment (`make changelog-add`).
- Agent discovery is unchanged (`cli_locator.dart` + `$CAMPUS_AGENT_BROWSER`);
  only the address `agent-browser` is pointed at changes (raw port → brokered).

## Reconciling with the CDP hardening (3 layers to relax)

The hardening hard-blocks CDP+named-profile; the opt-in + pipe make that safe, so:
1. **`FlutterCefPlugin.swift:181-189`** (`cdp_with_profile` hard reject) — becomes
   conditional: allowed when agent-control is opted in *and* uses the pipe
   transport (no open port → the cookie-exfil rationale no longer applies).
2. **`main.mm:1726-1730`** (native strip of `--cdp-port` on a persistent profile)
   — left as-is: it gates the *TCP* `--cdp-port` only; the pipe path never sets
   `cdp`, so the guard simply doesn't fire for it. (Keeps TCP locked down.)
3. **Dart asserts** (`cef_web_view.dart:56-59`, `cef_web_controller.dart:388-390`)
   — relaxed for the pipe/opt-in path.

The `remote-allow-origins=*` removal (also from hardening) stays — irrelevant to
the pipe.

## Phasing

- **P1 — toggle + (interim) TCP.** Ship the per-tile `agentControllable` setting
  (persist + sync + UI + gating) and relax the rejection so an opted-in tile may
  enable CDP over the **existing TCP `--cdp-port`**. Delivers the full UX (toggle
  once → agent drives the live tile, no clone/state-loss/prompt) immediately. The
  caveat is the unchanged TCP exposure: any local process could connect and it
  exposes sibling tiles in the same profile process. **Acceptable only on a
  single-user trusted machine** (agent-browser's own "trusted machines only"
  stance) — gate behind the toggle and document it. No flutter_cef native change.
- **P2 — pipe-broker (the version to ship).** Layers A + B: `--remote-debugging-
  pipe` in cef_host, the `posix_spawn` fd setup in Swift, and the token-gated
  tile-scoped relay. Removes the open port (Campus-only), enforces per-tile scope,
  and makes CDP-on-a-credentialed-profile genuinely safe. This is the larger lift
  (the `posix_spawn` rewrite is the crux).

P1 unblocks the workflow fast; P2 is the real security posture. They share the
Campus toggle (Layer C) verbatim — only the transport under it changes.

**Build order (decided):** the **flutter_cef (CEF) side ships first, then the
Campus consumer**, and we go straight for the **P2 pipe-broker** (the user's
"only Campus can connect" goal) rather than the P1 TCP shortcut. To de-risk the
crux, the CEF side itself lands in two increments:
- **CEF-1 — pipe foundation:** `--remote-debugging-pipe` in cef_host +
  `posix_spawn` fd 3/4 wiring in `CefProfileHost` (replacing `Process()` while
  PRESERVING the hardened spawn discipline — reader-thread join, `SO_NOSIGPIPE`,
  C1 crash-surfacing, dispose ordering, the `--profile-dir`/`--ephemeral`/
  `--allowed-schemes` argv) + a Swift CDP-over-pipe IO path + relax the CDP
  rejection. Validation gate: the plugin round-trips a `Browser.getVersion` over
  the pipe. This proves the foundation before any relay is built.
- **CEF-2 — token-gated, tile-scoped relay** + the `enableAgentControl()/
  disableAgentControl()` API. Itself staged, to de-risk the new server subsystem
  before the isolation boundary:
  - **CEF-2a — transport (DONE, validated):** a minimal, dependency-free localhost
    HTTP+WebSocket server (`CdpRelay.swift`: a raw loopback BSD socket on
    `127.0.0.1:0` + accept/handler threads + hand-rolled RFC-6455 server framing —
    no SwiftNIO/Starscream, matching the codebase's raw-socket/blocking-thread style
    and keeping the supply-chain surface the security review demanded). Serves `GET
    /json/version` (trailing-slash-tolerant — Playwright fetches `/json/version/`)
    advertising a token-free `webSocketDebuggerUrl: ws://127.0.0.1:<port>/devtools/
    browser`, accepts the ws upgrade, and bridges it ⇄ the CEF-1 pipe (full
    browser-level passthrough, **no** target filter yet).
    `enableAgentControl()→{wsUrl, token, port}` / `disableAgentControl()` threaded
    Swift→Dart→controller. Security (see the token-transport note): per-tile opt-in +
    ephemeral loopback port + relay-exists-only-during-grant + single active client;
    the token is validated-if-present defense-in-depth. Validated end-to-end: the
    real `agent-browser` CLI (`--cdp <port>`) drove the live tile — read url/title,
    navigated to a new page, read the DOM snapshot — through relay→pipe→cef_host.
    (The no-filter relay is dev-validation-only — never shipped — since a connected
    client could reach sibling tiles in the process.)
  - **CEF-2b — isolation:** resolve `browserId`→CDP `targetId` (new IPC op:
    cef_host `ExecuteDevToolsMethod(browser, "Target.getTargetInfo", {})` → the
    browser's own `targetId`), then add the Target-domain filter so each token's ws
    sees/attaches **only** its tile's target (`Target.getTargets`→the one;
    auto-attach/`targetCreated` events→the one; reject `attachToTarget`/`sessionId`
    for any other). This filter is THE per-tile security boundary — reviewed
    adversarially like CEF-1. Multi-grant per process via CDP `id` remapping +
    per-target `sessionId`.
Then the Campus consumer (Layer C).

## Open questions / to resolve in P2

- **`agent-browser` token transport — RESOLVED (empirically, against the installed
  CLI):** the installed `agent-browser` (v0.6.0, via npm) is **Playwright-based**
  (the CDP client UA is `Playwright/1.57.0`), NOT the Rust `cli/src/native/cdp`
  path. Its `--cdp <port>` parses a **bare integer** (it rejected `host:port?token`)
  and the CDP connection attaches **no** secret — Playwright's `connectOverCDP`
  fetches `GET /json/version/` (trailing slash) for the ws-url and upgrades with no
  token/auth header. So a client-supplied token **cannot** gate agent-browser. The
  achievable security is therefore NOT a token but: **per-tile opt-in + ephemeral
  loopback port + relay-exists-only-during-grant + single active client** (a second
  concurrent upgrade is rejected, so the agent's connection holds the slot). This is
  strictly better than raw Chrome's fixed, always-open, multi-client
  `--remote-debugging-port`. The relay still mints a token and validates it
  **if present** (defense-in-depth for a token-capable client or a future Campus-side
  forwarder that injects it), but does not require it. Residual: a same-UID process
  could race the ephemeral port in the sub-second gap before the agent connects —
  documented; tighten later with a Campus-side forwarder (relay stays strict, the
  unauth surface confined to Campus) or a token-capable client.
- **Relay lifecycle:** when does a grant expire? Tied to the `agentControllable`
  flag + an explicit `disableAgentControl()`; revoking the toggle kills live relay
  connections (closes the ws + invalidates the token).
- **CDP process-scope vs per-tile — RESOLVED (spike):** confirmed the relay can
  scope to one `browserId` cleanly. agent-browser is a *browser-level* CDP client
  (connects to `/devtools/browser`, manages targets itself), so the relay passes
  real browser-level CDP through the pipe and filters the Target domain:
  `Target.attachToTarget{flatten:true}`→`sessionId` is the modern routing, and "only
  targets matching a filter will be attached" — the relay exposes exactly one target.
  `browserId`→`targetId` resolved via cef_host `ExecuteDevToolsMethod(browser,
  "Target.getTargetInfo", {})` (a page agent reports its own target). This filter is
  the per-tile boundary (CEF-2b).
- **Pipe + our IPC coexistence:** cef_host already uses a Unix socket (our IPC) on
  other fds; confirm fds 3/4 for CDP don't collide with that or the helper spawns.
- **Posix-spawn migration risk:** moving `CefProfileHost.spawn` off `Foundation.
  Process` must preserve the existing reader-thread/`SO_NOSIGPIPE`/dispose
  discipline and the `--profile-dir`/`--ephemeral`/`--allowed-schemes` argv.

## Invariants / security checklist

- Agent control is **off by default**, per tile, persisted + synced.
- Raw CDP (pipe or TCP port) is **never** handed to an agent directly in P2 — only
  a token-gated, tile-scoped relay endpoint.
- A grant reaches exactly **one** tile's target, even within a shared-profile
  process.
- Revoking the toggle revokes access (kills live grants).
- The credentialed profile is never reachable by an un-tokened local process (P2).
- P1's TCP exposure is documented as trusted-machine-only and gated by the toggle.
