// One cef_host.app subprocess per profile. Owns the process, the Unix-socket
// listen/conn fds, the write lock + pending-frame queue, and the reader thread;
// multiplexes N CefWebSession browsers over that single IPC pipe, each keyed by
// a Swift-assigned wire browserId (monotonic from 1).
//
// Wire frame (both directions): [u32 bodyLen BE][u32 browserId BE][u8 op][payload],
// where bodyLen = 4 + 1 + payloadLen. browserId 0 is process/profile-level
// (kOpReady, process logs, kOpShutdown). See native/cef_host/main.mm.
//
// Split out of CefWebSession: the session keeps only its texture/IOSurface and
// per-view verbs; everything process/socket/reader-shaped lives here, so several
// views sharing one `profile:` share one host -> one cookie jar -> one login.
//
// The class is split over several files: this one holds the stored state, the
// send path and teardown; the extensions hold the rest.
//   CefProfileHost+Ipc.swift           spawn, the socket, the reader thread,
//                                      host death
//   CefProfileHost+CreatePacing.swift  browser creates, the establishment
//                                      window, the first-present watchdog
//   CefProfileHost+Liveness.swift      the steady-state liveness sweep
//   CefProfileHost+Cdp.swift           agent control: the CDP pipe, relays,
//                                      targetId resolution
// Its members are internal rather than private only so those files can reach
// them. Nothing outside CefProfileHost*.swift should.
//
// Threads and locks. The plugin calls in on the main thread; the IPC reader
// (acceptAndRead), the CDP reader (readCdpLoop) and timer blocks on global
// queues call in from theirs. Each lock guards:
//   writeLock       the pipe (connFd, pendingFrames), the lifecycle flags
//                   (running, crashed, diedFired, ready, refused), the create
//                   queues (pendingCreates, createEnqueued, createSendQueue,
//                   createInFlight) and the process handles (process,
//                   spawnedPid)
//   browsersLock    browsers, nextBrowserId, each session's liveness fields,
//                   hostPainted, gpuPidAtFirstPresent, cdpClientsCanPause,
//                   livenessSweepStarted
//   presentLock     the first-present watchdog: firstPresentPending,
//                   hiddenBrowsers, watchdogArmed
//   targetIdLock    pendingTargetId, targetIdEpoch
//   cdpHandlerLock  onCdpMessage, cdpRelays, agentControlEpoch, cdpClosed
//   cdpWriteLock    writes to cdpWriteFd
// Order: cdpHandlerLock before browsersLock, and writeLock before a session's
// bufferLock. browsersLock and presentLock are never held together. Callbacks,
// relay stops and waiter completions run with no lock held. wedgeEnded belongs
// to the liveness sweep, which runs one pass at a time. The rest is set in
// spawn() before the threads start, or in teardown after they are joined.

import Foundation
import IOSurface

final class CefProfileHost {
  // Eval id of the liveness ping. Dart's eval ids count up from 0 and never reach it.
  // cef_host answers it from the renderer itself, not the page (kLivenessPingId).
  static let livenessPingId: UInt32 = .max
  static let livenessPingReplyPrefix = Array("\(livenessPingId):".utf8)

  /// FLUTTER_CEF_DEBUG, read once: the environment is rebuilt on every read, and
  /// some of the checks run per frame.
  static let debugEnabled = ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil


  // Profile identity / config.
  let profileId: String
  let profileDir: String
  let isEphemeral: Bool
  // The 127.0.0.1 port CEF's DevTools (CDP) server bound for this host, or 0
  // when CDP wasn't requested. Chosen here (free-port pick); CDP is only ever
  // requested for ephemeral hosts (named+CDP is rejected upstream). Reported
  // back to Dart in each create() result. NOT used by the pipe (agent-control)
  // path — that speaks CDP over inherited fds 3/4, not a TCP port.
  var cdpPort: Int = 0
  // The --allowed-schemes this host was spawned with. Like cdpPort it is fixed for
  // the process, so a session joining a running host is checked against both
  // (HostConfigPolicy). Set in spawn() on the main thread, read there too.
  var allowedSchemes = ""

  // Agent-control / pipe mode. When true, cef_host was launched via
  // posix_spawn so it inherits two CDP pipes (child reads CDP on fd 3, writes on
  // fd 4) and was passed --cdp-pipe; the Chromium "remote-debugging-pipe" switch
  // makes it speak NUL-delimited JSON over those fds instead of a TCP port. Off
  // by default; when off, spawn() takes the existing Foundation.Process launch
  // and behavior is byte-identical to the pre-pipe path.
  var agentControl = false
  // Parent-side CDP pipe ends (valid only when agentControl). cdpWriteFd =
  // cmd_pipe[1] (we write CDP here; child reads it on fd 3). cdpReadFd =
  // out_pipe[0] (we read CDP here; child writes it on fd 4). -1 when unused.
  var cdpWriteFd: Int32 = -1
  var cdpReadFd: Int32 = -1
  let cdpWriteLock = NSLock()  // serializes send(json) writes to cdpWriteFd
  var cdpReaderStarted = false
  // Signaled when the CDP reader thread exits, so shutdown() can join it before
  // closing cdpReadFd (closing an fd a thread is blocked on is a use-after-free —
  // mirrors readerDone for the IPC reader).
  let cdpReaderDone = DispatchSemaphore(value: 0)
  // Invoked (off the CDP reader thread) for each complete CDP message (one
  // NUL-delimited UTF-8 JSON line, NUL stripped). Set by the plugin/relay; the
  // debug validation hook installs a temporary one to prove the round-trip.
  var onCdpMessage: ((String) -> Void)?
  // The token-gated localhost CDP relays (created lazily by
  // enableAgentControl()). Each bridges a CDP client's WebSocket ⇄ this host's pipe
  // and is scoped to ONE browser's CDP target. Keyed by the wire browserId so N
  // tiles in the same shared cef_host can be agent-controlled concurrently — they
  // share the one browser-wide pipe, and each relay demuxes its own traffic (by
  // sessionId, plus a per-relay CDP-id rewrite for browser-level commands — see
  // CdpRelay's multiplex note). Held strongly here; each relay's pipe-send closure
  // captures self weakly (no cycle).
  var cdpRelays: [UInt32: CdpRelay] = [:]
  // Bumped per browser by disableAgentControl (cdpHandlerLock), so an enable whose
  // targetId resolve was in flight when the tile went away doesn't install a relay
  // nobody will ever stop.
  var agentControlEpoch: [UInt32: Int] = [:]
  // Set by shutdown()/handleHostDeath() (cdpHandlerLock): no relay is installed after.
  var cdpClosed = false
  // The CDP command ids every relay on this host's pipe uses.
  let cdpPipeIds = CdpPipeIds()
  // Guards onCdpMessage and cdpRelays. Agent control mutates onCdpMessage LIVE (enable/
  // disable on the main thread) while the CDP reader thread reads it per message,
  // so — unlike the debug validation hook, set before the reader starts — both must be
  // synchronized. A plain closure property is a fat (ptr+context) value; a concurrent
  // read during a write can tear it and call into freed context.
  let cdpHandlerLock = NSLock()
  // Pending browserId→targetId resolutions (kOpResolveTargetId round-trip), keyed by
  // browserId. Set on the plugin thread, fulfilled on the reader thread (kOpTargetId)
  // or a timeout; guarded by targetIdLock. The completion fires exactly once.
  var pendingTargetId: [UInt32: [(String?) -> Void]] = [:]
  // Per-browser resolve epoch, bumped on each fresh in-flight resolve. A resolve's 5s
  // timeout captures its epoch and only fulfills if still current — so an EARLY
  // response (which doesn't cancel the timer) can't let the stale timer clobber a
  // LATER resolve for the same browser (e.g. re-enabling agent-control within 5s of a
  // prior enable/disable). Guarded by targetIdLock.
  var targetIdEpoch: [UInt32: Int] = [:]
  let targetIdLock = NSLock()

  // Process + IPC machinery (hoisted from CefWebSession).
  // `process` backs the default Foundation.Process launch; `spawnedPid` backs
  // the posix_spawn (agent-control) launch. Exactly one is live per host:
  // process != nil  => default path (terminate()/isRunning/terminationStatus).
  // process == nil && spawnedPid > 0 => pipe path (kill()/waitpid()).
  // This keeps the hardened default path's process handling byte-identical while
  // the pipe path reuses the same teardown/crash-surfacing seams via the pid.
  var process: Process?
  var spawnedPid: pid_t = 0
  /// Where cef_host sends its tile surfaces (see SurfacePort). Set in spawn()
  /// before the reader starts and never replaced; close() makes it inert.
  var surfacePort: SurfacePort?
  var listenFd: Int32 = -1
  var connFd: Int32 = -1
  var socketPath = ""
  let writeLock = NSLock()
  var pendingFrames: [[UInt8]] = []  // queued until the pipe connects
  var running = false
  // Set true (under writeLock) when the host dies unexpectedly — reader EOF
  // while running, or a writeAll to a dead pipe. Distinct from `running=false`
  // (clean shutdown()): `crashed` stops the pacer, the sweeps and agent control
  // on a dead host.
  var crashed = false
  var readerStarted = false
  let readerDone = DispatchSemaphore(value: 0)  // signaled when the
  // acceptAndRead thread exits, so shutdown() can join it before freeing state.

  // Browser multiplexing. `browsers`/`nextBrowserId` are guarded by
  // `browsersLock`; `createEnqueued`/`pendingCreates`/`ready`/`refused` are
  // guarded by `writeLock` (they gate the send path).
  let browsersLock = NSLock()
  var browsers: [UInt32: CefWebSession] = [:]
  var nextBrowserId: UInt32 = 1
  var ready = false
  // The host refused its named profile at kOpReady (ad-hoc build): it
  // never becomes ready, so a create that lands before the plugin moves the
  // sessions off it stays queued instead of loading the profile.
  var refused = false
  var pendingCreates: [() -> Void] = []  // createBrowser closures queued until ready
  var createEnqueued: Set<UInt32> = []  // browserIds whose create has been sent

  // Per-host create pacing (guarded by writeLock). A BURST of kOpCreateBrowser frames
  // would otherwise make cef_host run a pile of browser creates concurrently, each doing
  // its first-frame GPU shared-image allocation against the one shared GPU/Viz process at
  // the same instant — that allocation RACES and the losers silently Stop() (permanent
  // blank tile). PROVEN: 12 animated tiles created concurrently → ~9/12 paint; created
  // ONE AT A TIME → 12/12 (and all 12 then animate at 60fps — steady state is fine, only
  // concurrent ESTABLISHMENT was the problem). So we admit creates through a SLIDING
  // WINDOW: at most `maxCreateInFlight` browsers may be establishing (awaiting first paint)
  // at once, and we gate each slot's release on that browser's FIRST PAINT
  // (firstPresentArrived), NOT the bind ack (kOpCreated). Window=1 is strict serial. A
  // window of K is materially safer than "K all-at-once": only the K still-establishing
  // browsers contend the first-frame allocator (established ones just blit from an existing
  // surface), and the K creates stagger by create+first-paint latency rather than firing
  // simultaneously. `createAckTimeout` is the per-browser paint backstop so a
  // bound-but-never-painting browser can't hold its slot forever. `createInFlight` is the
  // set of browserIds currently occupying an establishment slot.
  var createSendQueue: [(id: UInt32, session: CefWebSession, url: String)] = []
  var createInFlight: Set<UInt32> = []
  let maxCreateInFlight: Int = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_ESTAB_WINDOW"],
       let n = Int(s), n > 0 { return n }
    return 3  // K=3: ~3x faster cascade than strict serial on BOTH median and last-tile
              // first-paint for real-site boards (measured: median 36→10s, last 41→21s,
              // 20 real sites). The rare all-animation-burst knock-out is caught by the
              // watchdog→recreate (never blank). See docs/history/osr-many-views.md.
  }()
  let createAckTimeout: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_CREATE_TIMEOUT_MS"],
       let ms = Double(s) { return ms / 1000.0 }
    return 8  // backstop for a browser that binds but never first-paints; generous so a
              // heavy real site that's slow to composite isn't de-serialized prematurely.
  }()

  // First-present watchdog (guarded by presentLock). browserIds awaiting their FIRST
  // kOpPresent: if none arrives within the deadline we re-kick via kOpInvalidate, then (if
  // still blank) surface paintStalled to Dart — converting a silent never-painted tile
  // into self-healing-or-signalled.
  let presentLock = NSLock()
  var firstPresentPending: Set<UInt32> = []
  // Browsers the host has hidden (WasHidden(true) via kOpSetVisible). A hidden CEF
  // browser stops producing frames entirely, so it legitimately never sends kOpPresent —
  // the watchdog must NOT treat that as a stall (work_canvas creates tiles already
  // off-screen as a normal lazy-spawn pattern). Guarded by presentLock.
  var hiddenBrowsers: Set<UInt32> = []
  // At most one live checkFirstPresent chain per browserId. The watchdog re-arms itself
  // (repeating paintStalled signal) and noteVisibility re-arms on unhide, so without this
  // a hide/show flap of a still-blank tile would accumulate parallel chains (each one
  // re-kicking + logging + emitting paintStalled every firstPaintGrace forever). Guarded
  // by presentLock; cleared when a chain terminates (paint / hidden / dead / dispose).
  var watchdogArmed: Set<UInt32> = []

  /// Total grace for a browser to deliver its FIRST frame before the watchdog declares it
  /// stalled (→ consumer recreates). Cancelled the instant ANY frame arrives, so this only
  /// bounds the GENUINELY-blank case — it does NOT slow content that paints quickly.
  /// Must be generous: a heavy real site (WebGL, 3D, huge bundle) can take several seconds
  /// to composite its first frame, and recreating it just restarts that heavy load (churn).
  /// Env-tunable.
  let firstPaintGrace: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_FIRSTPAINT_MS"],
       let ms = Double(s) { return ms / 1000.0 }
    return 10.0
  }()

  /// How many present frames a browser must deliver before the pacer admits the next
  /// create. Gating on the bare first frame advances too eagerly — a 1-frame-old browser
  /// gets knocked back out by the next create's first-frame GPU allocation (paints 1-2
  /// frames then stops). Requiring a few consecutive frames proves it's stably producing
  /// before the next contends. Adaptive + fast: a healthy 60fps tile trips this in a few
  /// frames (~tens of ms) vs a fixed time settle. Env-tunable.
  let estabStableFrames: Int = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_ESTAB_FRAMES"],
       let n = Int(s), n > 0 { return n }
    return 6
  }()
  /// Settle window after a browser's FIRST paint as the OTHER pacer-advance trigger (the
  /// pacer advances on stable-frames OR this settle, whichever comes first). The frame
  /// threshold is the fast path for continuously-animating content (hits it in ~tens of
  /// ms); the settle is the path for STATIC content that paints a short burst on load then
  /// idles (a real website) and would never reach the frame threshold. Env-tunable.
  let estabSettle: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_ESTAB_SETTLE_MS"],
       let ms = Double(s) { return ms / 1000.0 }
    return 0.4
  }()

  // Steady-state liveness sweep (CefProfileHost+Liveness.swift).
  let livenessStalenessNs: UInt64 = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_LIVENESS_MS"],
       let ms = Double(s), ms > 0 { return UInt64(ms * 1_000_000) }
    return 10_000_000_000  // 10s — generous; a wedge is rare + a healthy idle page only
                           // costs one forced repaint per window.
  }()
  let livenessGraceNs: UInt64 = 3_000_000_000  // 3s after the nudge → declare wedged
  let livenessSweepInterval: TimeInterval = 2.0
  var livenessSweepStarted = false  // guarded by browsersLock
  // A stalled browser whose renderer leaves the JS ping unanswered this long is hung.
  // Chrome's own hang monitor waits about as long before offering to kill a page.
  let livenessHangNs: UInt64 = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_HANG_MS"],
       let ms = Double(s), ms > 0 { return UInt64(ms * 1_000_000) }
    return 15_000_000_000
  }()
  // Whether any browser on this host has presented, and the pid of the GPU process
  // that was running then (0 = not looked up yet, or none), both guarded by
  // browsersLock. A different GPU pid later means Chromium replaced that process.
  var hostPainted = false
  var gpuPidAtFirstPresent: pid_t = 0
  var wedgeEnded = false  // sweep-only (one pass at a time, each scheduling the next)
  // Set at spawn when a CDP client (agent control, or the TCP port) can reach the
  // pages; browsersLock-guarded.
  var cdpClientsCanPause = false

  // The plugin sets each callback below once, before spawn() starts the threads
  // that call them, and never reassigns it: a closure is two words, and a write
  // racing a read on another thread can tear it.
  //
  // Invoked (off the reader thread) when an ad-hoc host refuses to load a named
  // profile (no creds were written). The plugin tears this host down
  // and moves every session on it to an ephemeral host of its own.
  var onInsecureProfileRefused: (() -> Void)?

  // Invoked (off the reader thread) when the host announces a kOp wire-protocol
  // version other than [CefHostProtocol.version] in its kOpReady payload. The host is
  // refused before ANY create flushes (nothing was mis-parsed); the plugin emits
  // processGone("protocolMismatch") for every attached session and tears the host
  // down. Deliberately NO auto-respawn: respawning would re-resolve the same
  // mismatched binary and loop.
  var onProtocolMismatch: ((UInt8) -> Void)?

  // Invoked ON THE MAIN THREAD when the reader loop exits UNEXPECTEDLY
  // (cef_host died: EOF/ECONNRESET while running, or a writeAll to a dead pipe)
  // — NOT on a clean shutdown(). Carries the process exit status so the plugin
  // can distinguish a cache-lock loss (status 2: another process holds the
  // profile) from a generic crash, emit `processGone` to Dart, and drop the
  // host so the profile_in_use guard unblocks. Fires at most once per host.
  var onHostDied: ((Int32) -> Void)?
  var diedFired = false  // guarded by writeLock; one onHostDied per host

  // One browser can't continue while the host is otherwise fine — its create
  // failed ("createFailed"), its renderer kept crashing or hung ("crashed") — so
  // the plugin drops that one session and emits processGone(reason) for it. If a
  // browser never painted its first frame despite a re-kick, the plugin surfaces
  // paintStalled so the consumer can recover (e.g. recreate the view) instead of
  // staring at a silent blank tile. Both carry the wire browserId; invoked off the
  // reader / a timer thread.
  var onBrowserGone: ((UInt32, String) -> Void)?
  var onPaintStalled: ((UInt32) -> Void)?

  init(profileId: String, profileDir: String, isEphemeral: Bool) {
    self.profileId = profileId
    self.profileDir = profileDir
    self.isEphemeral = isEphemeral
  }

  /// Frame `[u32 bodyLen=4+1+payload.count][u32 browserId][op][payload]` and
  /// write it, or queue it if the pipe isn't up yet. A pre-connect kOpResize whose
  /// browserId hasn't had its create enqueued is DROPPED — that create carries
  /// the current geometry, so replaying the resize could reference a since-freed
  /// IOSurface id.
  func send(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8]) {
    // Peek visibility so the first-present watchdog doesn't flag an intentionally
    // hidden (WasHidden) browser as stalled — it produces no frames by design.
    if op == CefOp.setVisible, let v = payload.first {
      noteVisibility(browserId, visible: v != 0)
    }
    let frame = frameBytes(browserId, op, payload)
    writeLock.lock()
    if connFd < 0 {
      if op == CefOp.resize && !createEnqueued.contains(browserId) {
        writeLock.unlock()
        return
      }
      pendingFrames.append(frame)
      writeLock.unlock()
      return
    }
    let ok = frame.withUnsafeBytes { writeAll(connFd, $0.baseAddress!, frame.count) }
    writeLock.unlock()
    // A failed write means the pipe is dead — until now the return was
    // discarded and a dead pipe was indistinguishable from success. Surface it
    // (unlocked first: handleHostDeath re-takes writeLock).
    if !ok { handleHostDeath() }
  }

  /// Whether cef_host ever announced kOpReady at our protocol version. A host that
  /// died before that never created a browser, so the plugin reports its
  /// sessions' deaths as `createFailed`, not `crashed`.
  var everReady: Bool {
    writeLock.lock(); defer { writeLock.unlock() }
    return ready
  }

  /// Close ONE browser (kOpDisposeBrowser) and unregister it under lock. Returns
  /// the number of browsers still registered on this host afterward.
  func removeBrowser(_ browserId: UInt32) -> Int {
    // If this tile was agent-controlled, tear down ITS relay (its scoped
    // targetId is now dead) BEFORE disposing the browser — disableAgentControl is
    // a no-op when there's no relay for this id. Does its own locking + stops the
    // relay outside cdpHandlerLock.
    disableAgentControl(browserId: browserId)
    // A targetId resolve still in flight for it can't succeed now; fail its waiters
    // instead of leaving them to the timeout.
    targetIdLock.lock()
    let stranded = pendingTargetId.removeValue(forKey: browserId) ?? []
    targetIdLock.unlock()
    for w in stranded { w(nil) }
    send(browserId, CefOp.disposeBrowser, [])
    surfacePort?.forget(browserId: browserId)
    browsersLock.lock()
    browsers[browserId] = nil
    let remaining = browsers.count
    browsersLock.unlock()
    writeLock.lock()
    createEnqueued.remove(browserId)
    writeLock.unlock()
    // Drop any watchdog/visibility bookkeeping for the gone browser so the sets
    // don't grow across a long session of tile churn.
    presentLock.lock()
    firstPresentPending.remove(browserId)
    hiddenBrowsers.remove(browserId)
    watchdogArmed.remove(browserId)
    presentLock.unlock()
    // Free any create-pacer establishment slot this browser still held (disposed before
    // first paint) and re-fill the window — otherwise the slot stays pinned until the 8s
    // backstop, throttling new creates on this host. Idempotent (no-op if not in flight);
    // takes writeLock + re-pumps off-thread, so it must be OUTSIDE all locks here. Mirrors
    // the createInFlight.removeAll() that shutdown()/handleHostDeath() already do.
    advanceCreatePacer(after: browserId, timedOut: false)
    return remaining
  }

  // MARK: Teardown

  /// Tear down the WHOLE process: kOpShutdown(0), stop the reader thread (flag it,
  /// wake its blocking read() by shutting down the conn fd — a reader still waiting
  /// for the host to connect sees the flag at its next poll — wait for it to
  /// exit), close the fds, unlink the socket, drop an ephemeral profile dir, and
  /// terminate cef_host. Closing an fd a thread is blocked on, or freeing state
  /// under the reader, is a use-after-free — the join makes teardown deterministic.
  func shutdown() {
    // Clear `running` FIRST (before the kOpShutdown write and before closing the
    // fds): this is a CLEAN teardown, so neither the reader's read-EOF nor a
    // failed kOpShutdown write should be mistaken for a crash — handleHostDeath()
    // guards on `running`, so flipping it false here keeps onHostDied from firing
    // on the shutdown path.
    writeLock.lock()
    running = false
    // Abandon any paced creates so a stuck pacer can't wedge a reused host and
    // queued-never-sent sessions don't linger. The browsers map still holds them, so
    // disposeSession/onHostDied path cleans them up.
    createSendQueue.removeAll()
    createInFlight.removeAll()
    // Also abandon pre-kOpReady queued creates, so a host dying between spawn and
    // kOpReady tears down all THREE create-state queues symmetrically.
    pendingCreates.removeAll()
    writeLock.unlock()
    // Drop ALL relays (each a listener + any client) before tearing down
    // the pipe, so none keeps bridging into a closing fd. Snapshot under the lock,
    // clear the dict + onCdpMessage, then stop each OUTSIDE the lock (stop() may
    // block briefly on a stuck client and takes the relay's own locks).
    cdpHandlerLock.lock()
    cdpClosed = true
    let relays = Array(cdpRelays.values)
    cdpRelays.removeAll()
    onCdpMessage = nil
    cdpHandlerLock.unlock()
    for r in relays { r.stop() }
    send(0, CefOp.shutdown, [])
    writeLock.lock()
    let c = connFd
    writeLock.unlock()
    // Darwin.shutdown — disambiguate from this class's own shutdown() method,
    // which Swift would otherwise resolve this unqualified call to. Not the
    // listening socket: on Darwin that fails with ENOTCONN and wakes nothing.
    if c >= 0 { Darwin.shutdown(c, SHUT_RDWR) }
    // Gate the join on `readerStarted` ALONE (not the old `wasRunning`). The
    // semaphore is level-triggered — if the reader already exited (e.g. it drove the
    // crash path and signalled readerDone before this runs), wait() returns at once.
    // Gating on `wasRunning` could SKIP the join while the reader is still blocked in
    // read()/accept() on these fds and then close them under it (use-after-free). And
    // on a join TIMEOUT the reader is, by definition, still inside read()/accept() on
    // these fds — so do NOT close them; leak the fd rather than risk an fd-reuse UAF
    // (the same discipline CdpRelay.stop() uses). The fds were already Darwin.shutdown
    // -ed above to wake the reader, so a timeout here is genuinely pathological.
    let readerJoined = !readerStarted || readerDone.wait(timeout: .now() + 2) == .success
    writeLock.lock()
    if connFd >= 0 { if readerJoined { close(connFd) }; connFd = -1 }
    if listenFd >= 0 { if readerJoined { close(listenFd) }; listenFd = -1 }
    writeLock.unlock()
    if !socketPath.isEmpty { unlink(socketPath); socketPath = "" }
    // The ephemeral profile dir goes once cef_host has exited, below: it writes to it
    // until then.
    let exitingPid = hostPid()
    // Agent-control: close OUR CDP write end first — cef_host sees EOF on fd 3
    // (DevToolsPipeHandler's disconnect signal), a clean CDP shutdown. The read
    // end can't be Darwin.shutdown()'d (that's socket-only) and closing an fd the
    // CDP reader is blocked in read() on would be a use-after-free, so the SAME
    // discipline as the IPC reader applies: get the reader to EOF first (the
    // child exiting closes its fd 4), JOIN it, THEN close the read fd.
    cdpWriteLock.lock()
    if cdpWriteFd >= 0 { close(cdpWriteFd); cdpWriteFd = -1 }
    cdpWriteLock.unlock()
    // terminateProcess() (SIGTERM, SIGKILL escalation) makes the child exit,
    // which closes its CDP write end (fd 4) and yields EOF on cdpReadFd so the
    // CDP reader loop returns. Done before the CDP reader join for that reason.
    terminateProcess()
    surfacePort?.close()
    if isEphemeral && !profileDir.isEmpty {
      let dir = profileDir
      DispatchQueue.global().async {
        Self.waitForExit(exitingPid, timeout: 3)
        try? FileManager.default.removeItem(atPath: dir)
      }
    }
    // Same discipline for the CDP reader — gate on cdpReaderStarted alone, and
    // never close the read fd on a join timeout (the reader is still in read() on it).
    let cdpJoined = !cdpReaderStarted || cdpReaderDone.wait(timeout: .now() + 2) == .success
    if cdpReadFd >= 0 { if cdpJoined { close(cdpReadFd) }; cdpReadFd = -1 }
  }

  /// SIGTERM (then SIGKILL escalation) the cef_host process. Handles BOTH launch
  /// paths: `process` (Foundation.Process, default) and `spawnedPid` (posix_spawn,
  /// agent-control). Idempotent — clears whichever handle it used.
  private func terminateProcess() {
    // Take BOTH handles atomically under writeLock so this is the sole owner of
    // its terminate/waitpid — handleHostDeath's reaper can't be reaping the same pid
    // concurrently (it took ownership the same way, or handed it back to us).
    writeLock.lock()
    let p = process; process = nil
    let pid = spawnedPid; spawnedPid = 0
    writeLock.unlock()
    if let p = p {
      p.terminate()  // SIGTERM
      // Escalate to SIGKILL if the host is wedged and ignores SIGTERM.
      DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
      }
      return
    }
    // posix_spawn path: we own a raw pid, not a Process. SIGTERM then SIGKILL.
    // Reap with a non-blocking waitpid so the child doesn't linger as a zombie
    // (Foundation.Process reaps for us; for a bare pid we must do it ourselves).
    guard pid > 0 else { return }
    kill(pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
      var status: Int32 = 0
      // If it already exited, waitpid reaps it now; if not, SIGKILL then reap.
      if waitpid(pid, &status, WNOHANG) == 0 {
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
      }
    }
  }

  deinit {
    // Minimal net for a partial-spawn failure (host dropped without shutdown()).
    // shutdown() zeroes the fds, so this is a no-op after a clean teardown.
    if process?.isRunning == true { process?.terminate() }
    if spawnedPid > 0 {
      kill(spawnedPid, SIGTERM)
      var st: Int32 = 0
      _ = waitpid(spawnedPid, &st, WNOHANG)  // best-effort reap; avoid a zombie
    }
    if connFd >= 0 { close(connFd) }
    if listenFd >= 0 { close(listenFd) }
    if cdpWriteFd >= 0 { close(cdpWriteFd) }
    if cdpReadFd >= 0 { close(cdpReadFd) }
    if !socketPath.isEmpty { unlink(socketPath) }
  }

  // MARK: Wire helpers

  // Length-prefixed wire frame: [u32 bodyLen][u32 browserId][op][payload], where
  // bodyLen = 4 + 1 + payload.count. Pure — no lock.
  func frameBytes(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var frame = [UInt8]()
    frame.reserveCapacity(9 + payload.count)
    appendU32(&frame, UInt32(4 + 1 + payload.count))
    appendU32(&frame, browserId)
    frame.append(op)
    frame.append(contentsOf: payload)
    return frame
  }

  func appendU32(_ a: inout [UInt8], _ v: UInt32) {
    a.append(UInt8((v >> 24) & 0xff))
    a.append(UInt8((v >> 16) & 0xff))
    a.append(UInt8((v >> 8) & 0xff))
    a.append(UInt8(v & 0xff))
  }

  func appendF64(_ a: inout [UInt8], _ v: Double) {
    let bits = v.bitPattern
    for shift in stride(from: 56, through: 0, by: -8) {
      a.append(UInt8((bits >> UInt64(shift)) & 0xff))
    }
  }

  func beU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16)
      | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
  }

  // A filesystem-safe tag for the socket name derived from the profileId (which
  // for ephemeral hosts is "~ephemeral~"+sessionId — chars not in sun_path-safe
  // set get collapsed).
  func sanitizedSocketTag() -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    return String(profileId.map { allowed.contains($0) ? $0 : "_" })
  }

  func readAll(_ fd: Int32, _ buf: inout [UInt8], _ len: Int) -> Bool {
    var off = 0
    while off < len {
      let n = buf.withUnsafeMutableBytes { ptr -> Int in
        read(fd, ptr.baseAddress!.advanced(by: off), len - off)
      }
      if n <= 0 {
        // A signal (SIGALRM/SIGCHLD/…) interrupts the syscall: retry rather than
        // treat it as a dead pipe (which would tear down the whole shared host).
        if n < 0 && errno == EINTR { continue }
        return false
      }
      off += n
    }
    return true
  }

  func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int) -> Bool {
    var off = 0
    while off < len {
      let n = write(fd, buf.advanced(by: off), len - off)
      if n <= 0 {
        // Same EINTR resilience as readAll: a signal mid-write must not be
        // mistaken for a dead pipe (matches the C++ WriteAll on the host side).
        if n < 0 && errno == EINTR { continue }
        return false
      }
      off += n
    }
    return true
  }
}