// One cef_host.app subprocess per profile. Owns the process, the Unix-socket
// listen/conn fds, the write lock + pending-frame queue, and the reader thread;
// multiplexes N CefWebSession browsers over that single IPC pipe, each keyed by
// a Swift-assigned wire browserId (monotonic from 1).
//
// Wire frame (both directions): [u32 bodyLen BE][u32 browserId BE][u8 op][payload],
// where bodyLen = 4 + 1 + payloadLen. browserId 0 is process/profile-level
// (opReady, process logs, opShutdown). See native/cef_host/main.mm.
//
// Split out of CefWebSession: the session keeps only its texture/IOSurface and
// per-view verbs; everything process/socket/reader-shaped lives here, so several
// views sharing one `profile:` share one host -> one cookie jar -> one login.

import Foundation
import IOSurface

final class CefProfileHost {
  // IPC opcodes this host layer needs to NAME (process-level + control). The
  // full per-view opcode table lives on CefWebSession; these must match
  // native/cef_host/main.mm.
  static let opCreateBrowser: UInt8 = 0x13
  static let opDisposeBrowser: UInt8 = 0x15
  static let opShutdown: UInt8 = 0x14
  static let opReady: UInt8 = 0x02
  static let opLog: UInt8 = 0x04
  static let opResize: UInt8 = 0x11
  static let opTargetId: UInt8 = 0x1b         // cef_host -> us: a browser's CDP targetId (CEF-2b)
  static let opResolveTargetId: UInt8 = 0x36  // us -> cef_host: resolve this browser's CDP targetId
  static let opPresent: UInt8 = 0x01          // cef_host -> us: a browser painted a frame (C1 watchdog peek)
  static let opCreated: UInt8 = 0x1c          // cef_host -> us: OnAfterCreated — advance the create pacer (H3)
  static let opCreateFailed: UInt8 = 0x1d     // cef_host -> us: create dispatch failed — drop the session (H7)
  static let opInvalidate: UInt8 = 0x37       // us -> cef_host: force a repaint to re-kick a stalled first frame (C1)
  static let opSetVisible: UInt8 = 0x35       // us -> cef_host: WasHidden(!visible); peeked to make the C1 watchdog visibility-aware

  // Profile identity / config.
  let profileId: String
  let profileDir: String
  let isEphemeral: Bool
  // The 127.0.0.1 port CEF's DevTools (CDP) server bound for this host, or 0
  // when CDP wasn't requested. Chosen here (free-port pick); CDP is only ever
  // requested for ephemeral hosts (named+CDP is rejected upstream). Reported
  // back to Dart in each create() result. NOT used by the pipe (agent-control)
  // path — that speaks CDP over inherited fds 3/4, not a TCP port.
  private(set) var cdpPort: Int = 0

  // Agent-control / pipe mode (CEF-1). When true, cef_host was launched via
  // posix_spawn so it inherits two CDP pipes (child reads CDP on fd 3, writes on
  // fd 4) and was passed --cdp-pipe; the Chromium "remote-debugging-pipe" switch
  // makes it speak NUL-delimited JSON over those fds instead of a TCP port. Off
  // by default; when off, spawn() takes the existing Foundation.Process launch
  // and behavior is byte-identical to the pre-pipe path.
  private(set) var agentControl = false
  // Parent-side CDP pipe ends (valid only when agentControl). cdpWriteFd =
  // cmd_pipe[1] (we write CDP here; child reads it on fd 3). cdpReadFd =
  // out_pipe[0] (we read CDP here; child writes it on fd 4). -1 when unused.
  private var cdpWriteFd: Int32 = -1
  private var cdpReadFd: Int32 = -1
  private let cdpWriteLock = NSLock()  // serializes send(json) writes to cdpWriteFd
  private var cdpReaderStarted = false
  // Signaled when the CDP reader thread exits, so shutdown() can join it before
  // closing cdpReadFd (closing an fd a thread is blocked on is a use-after-free —
  // mirrors readerDone for the IPC reader).
  private let cdpReaderDone = DispatchSemaphore(value: 0)
  // Invoked (off the CDP reader thread) for each complete CDP message (one
  // NUL-delimited UTF-8 JSON line, NUL stripped). Set by the plugin/relay; the
  // CEF-1 validation hook installs a temporary one to prove the round-trip.
  var onCdpMessage: ((String) -> Void)?
  // CEF-2a/b: the token-gated localhost CDP relays (created lazily by
  // enableAgentControl()). Each bridges a CDP client's WebSocket ⇄ this host's pipe
  // and is scoped to ONE browser's CDP target. Keyed by the wire browserId so N
  // tiles in the same shared cef_host can be agent-controlled concurrently — they
  // share the one browser-wide pipe, and each relay demuxes its own traffic (by
  // sessionId, plus a per-relay CDP-id rewrite for browser-level commands — see
  // CdpRelay's multiplex note). Held strongly here; each relay's pipe-send closure
  // captures self weakly (no cycle).
  private var cdpRelays: [UInt32: CdpRelay] = [:]
  // Guards onCdpMessage and cdpRelays. CEF-2a/b mutates onCdpMessage LIVE (enable/
  // disable on the main thread) while the CDP reader thread reads it per message,
  // so — unlike CEF-1, which only set it before the reader started — both must be
  // synchronized. A plain closure property is a fat (ptr+context) value; a concurrent
  // read during a write can tear it and call into freed context.
  private let cdpHandlerLock = NSLock()
  // Pending browserId→targetId resolutions (kOpResolveTargetId round-trip), keyed by
  // browserId. Set on the plugin thread, fulfilled on the reader thread (kOpTargetId)
  // or a timeout; guarded by targetIdLock. The completion fires exactly once.
  private var pendingTargetId: [UInt32: [(String?) -> Void]] = [:]
  // Per-browser resolve epoch, bumped on each fresh in-flight resolve. A resolve's 5s
  // timeout captures its epoch and only fulfills if still current — so an EARLY
  // response (which doesn't cancel the timer) can't let the stale timer clobber a
  // LATER resolve for the same browser (e.g. re-enabling agent-control within 5s of a
  // prior enable/disable). Guarded by targetIdLock.
  private var targetIdEpoch: [UInt32: Int] = [:]
  private let targetIdLock = NSLock()

  // Process + IPC machinery (hoisted from CefWebSession).
  // `process` backs the default Foundation.Process launch; `spawnedPid` backs
  // the posix_spawn (agent-control) launch. Exactly one is live per host:
  // process != nil  => default path (terminate()/isRunning/terminationStatus).
  // process == nil && spawnedPid > 0 => pipe path (kill()/waitpid()).
  // This keeps the hardened default path's process handling byte-identical while
  // the pipe path reuses the same teardown/crash-surfacing seams via the pid.
  private var process: Process?
  private var spawnedPid: pid_t = 0
  private var listenFd: Int32 = -1
  private var connFd: Int32 = -1
  private var socketPath = ""
  private let writeLock = NSLock()
  private var pendingFrames: [[UInt8]] = []  // queued until the pipe connects
  private var running = false
  // C1: set true (under writeLock) when the host dies unexpectedly — reader EOF
  // while running, or a writeAll to a dead pipe. Distinct from `running=false`
  // (clean shutdown()): `crashed` forces hasLiveBrowser false so the named
  // profile reopens, and gates onHostDied to fire once.
  private var crashed = false
  private var readerStarted = false
  private let readerDone = DispatchSemaphore(value: 0)  // signaled when the
  // acceptAndRead thread exits, so shutdown() can join it before freeing state.

  // Browser multiplexing. `browsers`/`nextBrowserId` are guarded by
  // `browsersLock`; `createEnqueued`/`pendingCreates`/`ready`/`adhocHost` are
  // guarded by `writeLock` (they gate the send path).
  private let browsersLock = NSLock()
  private var browsers: [UInt32: CefWebSession] = [:]
  private var nextBrowserId: UInt32 = 1
  private var ready = false
  private var pendingCreates: [() -> Void] = []  // createBrowser closures queued until ready
  private var adhocHost = false  // host reported a mock-keychain (ad-hoc) build
  private var createEnqueued: Set<UInt32> = []  // browserIds whose create has been sent

  // Per-host create pacing (guarded by writeLock). A BURST of opCreateBrowser frames
  // would otherwise make cef_host run a pile of browser creates concurrently, each doing
  // its first-frame GPU shared-image allocation against the one shared GPU/Viz process at
  // the same instant — that allocation RACES and the losers silently Stop() (permanent
  // blank tile). PROVEN: 12 animated tiles created concurrently → ~9/12 paint; created
  // ONE AT A TIME → 12/12 (and all 12 then animate at 60fps — steady state is fine, only
  // concurrent ESTABLISHMENT was the problem). So we admit creates through a SLIDING
  // WINDOW: at most `maxCreateInFlight` browsers may be establishing (awaiting first paint)
  // at once, and we gate each slot's release on that browser's FIRST PAINT
  // (firstPresentArrived), NOT the bind ack (opCreated). Window=1 is strict serial. A
  // window of K is materially safer than "K all-at-once": only the K still-establishing
  // browsers contend the first-frame allocator (established ones just blit from an existing
  // surface), and the K creates stagger by create+first-paint latency rather than firing
  // simultaneously. `createAckTimeout` is the per-browser paint backstop so a
  // bound-but-never-painting browser can't hold its slot forever. `createInFlight` is the
  // set of browserIds currently occupying an establishment slot.
  private var createSendQueue: [(id: UInt32, session: CefWebSession, url: String)] = []
  private var createInFlight: Set<UInt32> = []
  private let maxCreateInFlight: Int = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_ESTAB_WINDOW"],
       let n = Int(s), n > 0 { return n }
    return 3  // K=3: ~3x faster cascade than strict serial on BOTH median and last-tile
              // first-paint for real-site boards (measured: median 36→10s, last 41→21s,
              // 20 real sites). The rare all-animation-burst knock-out is caught by the
              // watchdog→recreate (never blank). See specs/osr-many-views.md.
  }()
  private let createAckTimeout: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_CREATE_TIMEOUT_MS"],
       let ms = Double(s) { return ms / 1000.0 }
    return 8  // backstop for a browser that binds but never first-paints; generous so a
              // heavy real site that's slow to composite isn't de-serialized prematurely.
  }()

  // C1 first-present watchdog (guarded by presentLock). browserIds awaiting their FIRST
  // opPresent: if none arrives within the deadline we re-kick via opInvalidate, then (if
  // still blank) surface paintStalled to Dart — converting a silent never-painted tile
  // into self-healing-or-signalled.
  private let presentLock = NSLock()
  private var firstPresentPending: Set<UInt32> = []
  // C1: browsers the host has hidden (WasHidden(true) via opSetVisible). A hidden CEF
  // browser stops producing frames entirely, so it legitimately never sends opPresent —
  // the watchdog must NOT treat that as a stall (work_canvas creates tiles already
  // off-screen as a normal lazy-spawn pattern). Guarded by presentLock.
  private var hiddenBrowsers: Set<UInt32> = []
  // At most one live checkFirstPresent chain per browserId. The watchdog re-arms itself
  // (repeating paintStalled signal) and noteVisibility re-arms on unhide, so without this
  // a hide/show flap of a still-blank tile would accumulate parallel chains (each one
  // re-kicking + logging + emitting paintStalled every firstPaintGrace forever). Guarded
  // by presentLock; cleared when a chain terminates (paint / hidden / dead / dispose).
  private var watchdogArmed: Set<UInt32> = []

  // Invoked (off the reader thread) when an ad-hoc host refuses to load a named
  // profile (no creds were written — see F.5). The plugin tears this host down
  // and respawns an ephemeral one for the same session.
  var onInsecureProfileRefused: (() -> Void)?

  // C1: invoked ON THE MAIN THREAD when the reader loop exits UNEXPECTEDLY
  // (cef_host died: EOF/ECONNRESET while running, or a writeAll to a dead pipe)
  // — NOT on a clean shutdown(). Carries the process exit status so the plugin
  // can distinguish a cache-lock loss (status 2 — see the C2 cross-group
  // contract) from a generic crash, emit `processGone` to Dart, and drop the
  // host so the profile_in_use guard unblocks. Fires at most once per host.
  var onHostDied: ((Int32) -> Void)?
  private var diedFired = false  // guarded by writeLock; one onHostDied per host

  // H7: a SINGLE browser's create failed (the host is otherwise fine) — the plugin drops
  // that one session + emits processGone for it. C1: a browser never painted its first
  // frame despite a re-kick — the plugin surfaces paintStalled so the consumer can
  // recover (e.g. recreate the view) instead of staring at a silent blank tile. Both
  // carry the wire browserId; invoked off the reader / a timer thread.
  var onBrowserFailed: ((UInt32) -> Void)?
  var onPaintStalled: ((UInt32) -> Void)?

  init(profileId: String, profileDir: String, isEphemeral: Bool) {
    self.profileId = profileId
    self.profileDir = profileDir
    self.isEphemeral = isEphemeral
  }

  // MARK: Spawn

  /// Bind the Unix socket and launch cef_host for this profile. Argv always
  /// carries `--ipc` and `--profile-dir=<profileDir>`; `--cdp-port=<port>` is
  /// added only when `enableCdp` (port picked here). `--allowed-schemes` is a
  /// process arg shared by every browser in the profile — it's taken from the
  /// first browser that triggered this spawn. Returns false on failure.
  ///
  /// `agentControl` (CEF-1) switches the LAUNCH MECHANISM only: when true we use
  /// posix_spawn instead of Foundation.Process so cef_host inherits two CDP pipes
  /// on fds 3/4 (Foundation.Process can't place arbitrary fds), and we add the
  /// `--cdp-pipe` flag so the native side injects the `remote-debugging-pipe`
  /// Chromium switch. Everything else (Unix-socket IPC, reader thread, dispose
  /// ordering, crash surfacing) is identical to the default path; `enableCdp`
  /// (TCP) and `agentControl` (pipe) are independent transports and the pipe
  /// path never picks/passes a `--cdp-port`.
  func spawn(cefHostPath: String, enableCdp: Bool, allowedSchemes: String,
             agentControl: Bool = false) -> Bool {
    self.agentControl = agentControl
    // Randomized name (not just the predictable profileId) in the per-user 0700
    // temp dir, so another same-UID process can't pre-bind it.
    let rnd = String(format: "%08x", UInt32.random(in: 0 ... UInt32.max))
    socketPath = NSTemporaryDirectory() + "wccef-\(sanitizedSocketTag())-\(rnd).sock"
    guard socketPath.utf8CString.count <= 104 else {
      NSLog("[cef] socket path exceeds sun_path (104); aborting")
      return false
    }
    unlink(socketPath)
    listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFd >= 0 else { NSLog("[cef] socket() failed"); return false }
    // Close-on-exec so the listening fd never leaks into the spawned cef_host (or
    // its CEF helper subprocesses). Foundation.Process spawns CLOEXEC-default, but
    // the posix_spawn path (attrp=nil) would otherwise inherit it; the child
    // connects via --ipc by path and never needs the listener. Harmless on both.
    fcntl(listenFd, F_SETFD, FD_CLOEXEC)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathC = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { raw in
      raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
        pathC.withUnsafeBufferPointer { src in
          dst.update(from: src.baseAddress!, count: min(pathC.count, 104))
        }
      }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFd, $0, len) }
    }
    guard bound == 0 else { NSLog("[cef] bind() failed: \(errno)"); return false }
    listen(listenFd, 1)

    // Per-process args only: per-view geometry/url now ride opCreateBrowser. The
    // cache path is always the resolved --profile-dir (ephemeral = throwaway temp).
    var args = [
      "--ipc=\(socketPath)",
      "--profile-dir=\(profileDir)",
    ]
    // Mark the throwaway-temp case so the host's CDP / mock-keychain guards fire
    // only for a real persistent profile (--profile-dir is set for both).
    if isEphemeral {
      args.append("--ephemeral=1")
    }
    if !allowedSchemes.isEmpty {
      args.append("--allowed-schemes=\(allowedSchemes)")
    }
    if agentControl {
      // Agent-control / pipe mode: CDP rides inherited fds 3/4 (set up below in
      // launchViaPosixSpawn), NOT a TCP port. --cdp-pipe is a no-value flag the
      // native side detects to inject Chromium's "remote-debugging-pipe" switch
      // (NUL-delimited JSON). cdpPort stays 0 — there is no listening socket, so
      // it's never reported to Dart. Mutually exclusive with --cdp-port here:
      // the pipe IS the transport for this path.
      args.append("--cdp-pipe")
    } else if enableCdp {
      // Chrome DevTools Protocol (CDP) over TCP: pick a free 127.0.0.1 port and
      // pass it via --cdp-port; cef_host sets CefSettings.remote_debugging_port
      // and CEF binds it (localhost-only, M113+). UNAUTHENTICATED — any local
      // client that reaches the port fully drives the page — so this is opt-in,
      // never on by default, and rejected for named profiles (it could read the
      // shared jar). The port is reported back to Dart in the create() result.
      let port = Self.pickFreeTcpPort()
      if port >= 1024 {
        cdpPort = port
        args.append("--cdp-port=\(port)")
      }
    }

    let launched =
      agentControl
        ? launchViaPosixSpawn(cefHostPath: cefHostPath, args: args)
        : launchViaProcess(cefHostPath: cefHostPath, args: args)
    guard launched else { return false }

    running = true
    readerStarted = true
    Thread.detachNewThread { [weak self] in self?.acceptAndRead() }
    startLivenessSweep()  // F-6: steady-state post-establishment liveness watchdog
    // Agent-control: drain CDP off fd 3/4's parent ends on a dedicated reader,
    // splitting the NUL-delimited JSON stream into messages. Started only after
    // a successful spawn (the fds exist). Joined in shutdown() before close.
    // Install the (debug-only) validation handler BEFORE starting the reader so
    // the reader never observes a half-installed onCdpMessage (the only path that
    // mutates it in CEF-1); in normal flow it's a no-op and onCdpMessage stays
    // nil. The probe-send loop it kicks off is fine to start first — the response
    // just buffers in the pipe until the reader drains it.
    if agentControl && cdpReadFd >= 0 {
      maybeRunCdpValidation()
      cdpReaderStarted = true
      Thread.detachNewThread { [weak self] in self?.readCdpLoop() }
    }
    return true
  }

  /// Default launch: Foundation.Process (unchanged behavior). Sets `process`.
  private func launchViaProcess(cefHostPath: String, args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cefHostPath)
    p.arguments = args
    do {
      try p.run()
      process = p
    } catch {
      NSLog("[cef] failed to spawn cef_host at \(cefHostPath): \(error)")
      return false
    }
    return true
  }

  /// Agent-control launch: posix_spawn so cef_host inherits the two CDP pipes on
  /// fds 3 (child reads CDP) and 4 (child writes CDP) — Foundation.Process can't
  /// place arbitrary fds. Builds the pipes, dup2s the child ends onto 3/4 via
  /// posix_spawn_file_actions (dup2 auto-clears CLOEXEC on the targets so they
  /// survive exec), closes the originals in the child, marks the parent ends
  /// CLOEXEC so cef_host's own renderer/GPU helper spawns don't inherit them, and
  /// captures the pid for teardown/crash-surfacing. Sets `spawnedPid`,
  /// `cdpReadFd`, `cdpWriteFd`. Returns false (cleaning up any half-built state)
  /// on failure. Recipe verified against Chromium DevToolsPipeHandler + Puppeteer.
  private func launchViaPosixSpawn(cefHostPath: String, args: [String]) -> Bool {
    // cmd_pipe: parent writes CDP -> child reads on fd 3.
    // out_pipe: child writes CDP on fd 4 -> parent reads.
    var cmdPipe: [Int32] = [-1, -1]
    var outPipe: [Int32] = [-1, -1]
    guard pipe(&cmdPipe) == 0 else {
      NSLog("[cef] cdp pipe() (cmd) failed: \(errno)")
      return false
    }
    guard pipe(&outPipe) == 0 else {
      NSLog("[cef] cdp pipe() (out) failed: \(errno)")
      close(cmdPipe[0]); close(cmdPipe[1])
      return false
    }
    var cmdRead = cmdPipe[0], cmdWrite = cmdPipe[1]
    var outRead = outPipe[0], outWrite = outPipe[1]

    // Helper to close all four pipe ends on a bail-out (before fds are adopted).
    func closeAll() {
      close(cmdRead); close(cmdWrite); close(outRead); close(outWrite)
    }

    // CRITICAL fd-collision guard: pipe() hands out the lowest free fds, and in a
    // GUI app 0/1/2 are open so the FIRST pipe can land exactly on fds 3 and/or 4
    // — our dup2 TARGETS. If a source fd already equals 3 or 4, the
    // adddup2(src,target)+addclose(src) pair would either no-op the dup2 (POSIX:
    // dup2 with oldfd==newfd does nothing AND does not clear FD_CLOEXEC) and then
    // close the fd we meant to keep, or close a sibling end. So first relocate any
    // end sitting on 3/4 to a high fd (>=10) via F_DUPFD; now all four sources are
    // >=5 and the dup2/close plan onto 3/4 is unambiguous. (We don't need them
    // CLOEXEC here — addclose removes the originals in the child, and the parent
    // closes them right after spawn.)
    func relocateAwayFromTargets(_ fd: inout Int32) -> Bool {
      while fd == 3 || fd == 4 {
        let hi = fcntl(fd, F_DUPFD, 10)
        if hi < 0 { return false }
        close(fd)
        fd = hi
      }
      return true
    }
    guard relocateAwayFromTargets(&cmdRead), relocateAwayFromTargets(&cmdWrite),
          relocateAwayFromTargets(&outRead), relocateAwayFromTargets(&outWrite)
    else {
      NSLog("[cef] cdp pipe fd relocation failed: \(errno)")
      closeAll()
      return false
    }

    // File actions: place the child read-end on fd 3 and write-end on fd 4, then
    // close the originals in the child. adddup2 onto a target auto-clears
    // FD_CLOEXEC on that target, so fds 3/4 survive exec (the originals do not).
    // posix_spawn_file_actions_t is `void *` on Darwin -> an optional raw pointer
    // in Swift; _init allocates it, _destroy frees it.
    var fa: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&fa) == 0 else {
      NSLog("[cef] posix_spawn_file_actions_init failed: \(errno)")
      closeAll()
      return false
    }
    posix_spawn_file_actions_adddup2(&fa, cmdRead, 3)
    posix_spawn_file_actions_adddup2(&fa, outWrite, 4)
    posix_spawn_file_actions_addclose(&fa, cmdRead)
    posix_spawn_file_actions_addclose(&fa, cmdWrite)
    posix_spawn_file_actions_addclose(&fa, outRead)
    posix_spawn_file_actions_addclose(&fa, outWrite)

    // Build a NULL-terminated C argv: [cefHostPath, args..., NULL]. strdup each
    // so the C strings outlive the Swift String bridging during posix_spawn.
    var cargv: [UnsafeMutablePointer<CChar>?] = []
    cargv.append(strdup(cefHostPath))
    for a in args { cargv.append(strdup(a)) }
    cargv.append(nil)
    defer { for p in cargv where p != nil { free(p) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, cefHostPath, &fa, nil, cargv, environ)
    posix_spawn_file_actions_destroy(&fa)
    guard rc == 0 else {
      NSLog("[cef] posix_spawn cef_host at \(cefHostPath) failed: \(rc)")
      closeAll()
      return false
    }
    spawnedPid = pid
    // Parent keeps the OPPOSITE ends from the child and closes the child's ends
    // (now duped onto 3/4 in the child). Mark the kept ends CLOEXEC so they don't
    // leak into any further exec the parent (the host app) might do — and, since
    // cef_host launches its OWN renderer/GPU helper subprocesses, only the
    // top-level browser process we just spawned inherits 3/4; those helpers are
    // launched by CEF and get default-closed 3/4 (correct, per the design).
    close(cmdRead)   // child's read end
    close(outWrite)  // child's write end
    cdpWriteFd = cmdWrite
    cdpReadFd = outRead
    _ = fcntl(cdpWriteFd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(cdpReadFd, F_SETFD, FD_CLOEXEC)
    // SIGPIPE guard on the WRITE end (H2 discipline, pipe edition): the IPC conn
    // fd uses the SO_NOSIGPIPE socket option, but pipe fds don't take it, so a
    // write to a cef_host that closed its CDP read end (it died) would otherwise
    // raise SIGPIPE and kill the whole host APP. F_SETNOSIGPIPE is the Darwin
    // per-fd equivalent: the write returns -1/EPIPE and writeAll reports failure
    // instead. (CLOEXEC was set above — note F_SETFD/F_SETNOSIGPIPE are distinct
    // fcntl commands, so neither overwrites the other.)
    _ = fcntl(cdpWriteFd, F_SETNOSIGPIPE, 1)
    return true
  }

  // MARK: Browser multiplexing

  /// Allocate a wire browserId for `session`, register it, and (if the host is
  /// ready) send the opCreateBrowser; otherwise queue it until opReady. Returns
  /// the assigned browserId. `allowedSchemes` is accepted for call-site symmetry
  /// but NOT used here — it's a process arg fixed at spawn (shared by every
  /// browser in the profile), not part of the opCreateBrowser payload (A.4).
  func createBrowser(_ session: CefWebSession, url: String, allowedSchemes: String) -> UInt32 {
    browsersLock.lock()
    let id = nextBrowserId
    // browserIds are STRICTLY MONOTONIC and never reused: nextBrowserId only ever
    // increments (never reset/decremented) and a disposed id is never recycled. The
    // CEF-2b relayId<->target binding (CdpRelay's pipeId = relayId<<21 | localSeq)
    // relies on this for global uniqueness across N concurrent relays, so guard it —
    // the slot we're about to hand out must be FREE (never previously registered).
    // H8: a UInt32 wrap (or any bug) reusing an id would SILENTLY overwrite a live
    // sibling's slot in a release build (the old guard was a debug-only `assert`,
    // compiled out) → the reader misroutes that wire id's frames (paint/cookies/CDP)
    // to the wrong tile, and CdpRelay's `relayId<<21` pipeId collides → cross-tile
    // agent-control leak. Make it a hard runtime invariant (a free, non-reserved slot).
    // Unreachable in practice (2^32 creates per host), so fail-fast >> silent corruption.
    precondition(id != 0 && browsers[id] == nil,
                 "cef browserId space exhausted/occupied — refusing to corrupt cross-tile routing")
    nextBrowserId += 1
    browsers[id] = session
    browsersLock.unlock()
    session.attach(host: self, browserId: id)

    writeLock.lock()
    let isReady = ready
    if !isReady {
      // Queue until opReady; the safety-rail (F.5) may refuse to flush these. The
      // payload is built at FLUSH time inside sendCreate from the session's LIVE
      // surfaceId/geometry — a resize during the pre-ready spawn window
      // reallocates the IOSurface (freeing the old global id) and updates the
      // size, so capturing them now would ship a since-freed id and a stale size.
      pendingCreates.append { [weak self, weak session] in
        guard let self = self, let session = session else { return }
        self.enqueueCreate(id, session, url)
      }
    }
    writeLock.unlock()
    if isReady { enqueueCreate(id, session, url) }
    return id
  }

  /// Send an opCreateBrowser frame and mark the browserId as enqueued so its
  /// pre-connect resizes are no longer dropped. The payload is assembled HERE
  /// (not at createBrowser time) so it carries the session's current surfaceId +
  /// geometry: {u32 w}{u32 h}{f64 dpr}{u32 iosurfaceId}{utf8 url}. allowedSchemes
  /// is NOT here — it's a process arg fixed at spawn (A.4).
  private func sendCreate(_ id: UInt32, _ session: CefWebSession, _ url: String) {
    writeLock.lock()
    // Read the session's LIVE geometry + surfaceId AND write the create frame in a
    // single writeLock section, so a racing resize can neither slip between the
    // surfaceId read and the create write, nor order its opResize ahead of the
    // create on the wire (cef_host drops a resize for a not-yet-created browser).
    // Any resize after this lands after the create, so cef_host has a slot and
    // self-heals the surface via DoResize. (writeLock→bufferLock here is safe: no
    // path holds bufferLock then takes writeLock.)
    // H4: read (w, h, dpr, surfaceId) as ONE atomic snapshot rather than four separate
    // bufferLock acquisitions — otherwise a resize interleaving between the reads could
    // ship e.g. old width + new surfaceId, blitting the first paint into a mis-sized
    // surface. (create-pacing widened this window: a browser can sit queued for N×
    // spacing, giving layout resizes more time to interleave.)
    let g = session.createSnapshot()
    var payload = [UInt8]()
    appendU32(&payload, UInt32(g.w))
    appendU32(&payload, UInt32(g.h))
    appendF64(&payload, Double(g.dpr))
    appendU32(&payload, g.sid)
    payload.append(contentsOf: Array(url.utf8))
    createEnqueued.insert(id)
    let frame = frameBytes(id, Self.opCreateBrowser, payload)
    var ok = true
    if connFd < 0 {
      pendingFrames.append(frame)
    } else {
      ok = frame.withUnsafeBytes { writeAll(connFd, $0.baseAddress!, frame.count) }
    }
    writeLock.unlock()
    // H2: surface a dead pipe (unlocked first — handleHostDeath re-takes writeLock).
    if !ok { handleHostDeath() }
  }

  /// Enqueue a create for PACED sending instead of writing its opCreateBrowser
  /// frame immediately. See `createSendQueue`: many tiles on one shared host
  /// created in a burst would otherwise hand cef_host's single UI thread a pile of
  /// blocking CreateBrowserSync calls at once. Idempotent pump kicks the pacer.
  private func enqueueCreate(_ id: UInt32, _ session: CefWebSession, _ url: String) {
    writeLock.lock()
    createSendQueue.append((id, session, url))
    writeLock.unlock()
    pumpCreateQueue()
  }

  /// Send the NEXT queued create and wait for that browser's FIRST PAINT (firstPresentArrived,
  /// off opPresent) before sending the following one — so each browser's first-frame GPU
  /// allocation completes before the next one contends, serializing establishment and
  /// avoiding the concurrent-first-frame race. `createAckTimeout` backstops a browser that
  /// binds but never paints so it can't stall the queue forever. A create whose browser was
  /// disposed while queued is skipped.
  private func pumpCreateQueue() {
    // Fill the sliding window: dispatch creates while a slot is free. Each dispatched
    // browser holds its slot until its first paint (or backstop) releases it via
    // advanceCreatePacer, which re-pumps.
    while true {
      writeLock.lock()
      // H6: never pump on a dead/dying host — the queue was abandoned in
      // shutdown()/handleHostDeath(); pumping would sendCreate into a closed pipe and a
      // stuck slot could wedge a reused host.
      if !running || crashed || createInFlight.count >= maxCreateInFlight ||
          createSendQueue.isEmpty {
        writeLock.unlock()
        return
      }
      let next = createSendQueue.removeFirst()
      createInFlight.insert(next.id)
      writeLock.unlock()

      browsersLock.lock()
      let stillLive = browsers[next.id] != nil
      browsersLock.unlock()
      guard stillLive else {
        // Disposed while queued — free the slot and continue filling (no recursion;
        // a "close all tiles" mid-burst could skip many disposed creates).
        writeLock.lock(); createInFlight.remove(next.id); writeLock.unlock()
        continue
      }

      // Arm the watchdog (insert into firstPresentPending) BEFORE sendCreate so a first
      // opPresent can never be observed before the id is registered as pending (which would
      // leave a healthy painting tile stuck "pending" → false perpetual paintStalled).
      armFirstPresentWatchdog(next.id)  // C1
      sendCreate(next.id, next.session, next.url)
      // Release this slot on the browser's FIRST PAINT (firstPresentArrived, in the
      // reader); this timer is only the backstop if it binds but never paints in time.
      DispatchQueue.global().asyncAfter(deadline: .now() + createAckTimeout) { [weak self] in
        self?.advanceCreatePacer(after: next.id, timedOut: true)
      }
    }
  }

  /// H3: the in-flight create for `browserId` completed (opCreated), failed
  /// (opCreateFailed), or timed out — release the pacer and send the next queued create.
  /// Idempotent: only the FIRST of {ack, timeout} for the current in-flight id advances.
  private func advanceCreatePacer(after browserId: UInt32, timedOut: Bool) {
    writeLock.lock()
    // Idempotent: only the FIRST of {first-paint, timeout} for this id frees its slot.
    guard createInFlight.remove(browserId) != nil else { writeLock.unlock(); return }
    writeLock.unlock()
    if timedOut {
      NSLog("[cef] profile '\(profileId)': create-ack timeout for browser \(browserId) — freeing establishment slot")
    }
    // Refill the freed slot OFF the reader thread (advanceCreatePacer is called from it on
    // first paint): pumpCreateQueue -> sendCreate writes to the same pipe the reader reads,
    // and the reader must never block on a write.
    DispatchQueue.global().async { [weak self] in self?.pumpCreateQueue() }
  }

  /// H7: cef_host couldn't create this browser — drop the session (the plugin emits
  /// processGone) and advance the pacer so the rest of the burst still proceeds.
  private func handleCreateFailed(_ browserId: UInt32) {
    firstPresentArrived(browserId)  // cancel the C1 watchdog for a browser that won't paint
    onBrowserFailed?(browserId)
    advanceCreatePacer(after: browserId, timedOut: false)
  }

  // MARK: C1 first-present watchdog

  /// Total grace for a browser to deliver its FIRST frame before the watchdog declares it
  /// stalled (→ consumer recreates). Cancelled the instant ANY frame arrives, so this only
  /// bounds the GENUINELY-blank case — it does NOT slow content that paints quickly.
  /// Must be generous: a heavy real site (WebGL, 3D, huge bundle) can take several seconds
  /// to composite its first frame, and recreating it just restarts that heavy load (churn).
  /// Env-tunable.
  private let firstPaintGrace: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_FIRSTPAINT_MS"],
       let ms = Double(s) { return ms / 1000.0 }
    return 10.0
  }()

  /// Arm the first-present watchdog for a freshly-sent create: after `firstPaintGrace`
  /// with no frame at all, run a liveness check.
  private func armFirstPresentWatchdog(_ browserId: UInt32) {
    presentLock.lock()
    firstPresentPending.insert(browserId)
    let already = watchdogArmed.contains(browserId)
    if !already { watchdogArmed.insert(browserId) }
    presentLock.unlock()
    guard !already else { return }  // a chain is already live for this id
    DispatchQueue.global().asyncAfter(deadline: .now() + firstPaintGrace) { [weak self] in
      self?.checkFirstPresent(browserId)
    }
  }

  /// Reader: a browser painted its first frame — cancel its watchdog. (Advancing the
  /// create pacer is NOT done here: the pacer advances on a SETTLE delay after first
  /// paint — see the reader — because a 1-frame-old browser isn't stably established yet
  /// and would be knocked out by the next create's contention.)
  private func firstPresentArrived(_ browserId: UInt32) {
    presentLock.lock()
    firstPresentPending.remove(browserId)
    watchdogArmed.remove(browserId)  // the chain ends; an unhide may re-arm a fresh one
    presentLock.unlock()
  }

  /// How many present frames a browser must deliver before the pacer admits the next
  /// create. Gating on the bare first frame advances too eagerly — a 1-frame-old browser
  /// gets knocked back out by the next create's first-frame GPU allocation (paints 1-2
  /// frames then stops). Requiring a few consecutive frames proves it's stably producing
  /// before the next contends. Adaptive + fast: a healthy 60fps tile trips this in a few
  /// frames (~tens of ms) vs a fixed time settle. Env-tunable.
  private let estabStableFrames: Int = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_ESTAB_FRAMES"],
       let n = Int(s), n > 0 { return n }
    return 6
  }()
  /// Settle window after a browser's FIRST paint as the OTHER pacer-advance trigger (the
  /// pacer advances on stable-frames OR this settle, whichever comes first). The frame
  /// threshold is the fast path for continuously-animating content (hits it in ~tens of
  /// ms); the settle is the path for STATIC content that paints a short burst on load then
  /// idles (a real website) and would never reach the frame threshold. Env-tunable.
  private let estabSettle: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_ESTAB_SETTLE_MS"],
       let ms = Double(s) { return ms / 1000.0 }
    return 0.4
  }()

  /// C1: track WasHidden state (peeked from opSetVisible). A hidden browser produces no
  /// frames, so the watchdog suspends rather than flagging it stalled. On UNHIDE, re-arm
  /// the watchdog for a browser that's still blank, so a genuinely-stuck now-visible tile
  /// is still caught.
  private func noteVisibility(_ browserId: UInt32, visible: Bool) {
    presentLock.lock()
    if !visible {
      hiddenBrowsers.insert(browserId)
      presentLock.unlock()
      // A browser hidden BEFORE its first paint produces no frames (PumpBeginFrame gates
      // on slot->visible), so it would never advance the create-pacer via first-paint and
      // the watchdog suspends it too — pinning its establishment slot until the backstop.
      // A hidden tile isn't contending the first-frame GPU allocator, so it must not count
      // against the window: free its slot now (idempotent no-op if it already painted /
      // wasn't in flight). This is the dominant case — work_canvas creates tiles off-screen.
      advanceCreatePacer(after: browserId, timedOut: false)
      return
    }
    hiddenBrowsers.remove(browserId)
    // Re-arm only if still blank AND no chain is already live (dedup across flapping).
    let reArm = firstPresentPending.contains(browserId) && !watchdogArmed.contains(browserId)
    if reArm { watchdogArmed.insert(browserId) }
    presentLock.unlock()
    guard reArm else { return }
    DispatchQueue.global().asyncAfter(deadline: .now() + firstPaintGrace) { [weak self] in
      self?.checkFirstPresent(browserId)
    }
  }

  /// Liveness check for a browser that hasn't produced its first frame within the grace.
  /// PATIENCE, not destruction: the create-pacer serializes establishment so a blank tile
  /// is almost always merely SLOW (heavy page, saturated GPU), not dead — and the
  /// begin-frame pump keeps running, so it paints on its own once resources free. So we:
  ///   1) advance the pacer ONCE (a slow tile must not block the rest of the queue), then
  ///   2) send a cheap re-kick and REPORT paintStalled — a REPEATING signal (re-armed each
  ///      grace while still blank) so the consumer owns recovery policy (e.g. a bounded,
  ///      backed-off recreate) without this layer ever churning a still-loading page.
  /// `firstPresentArrived` (real first frame) removes it from the pending set, ending the
  /// loop. Suspended (not retired) while hidden; re-armed on unhide.
  private func checkFirstPresent(_ browserId: UInt32) {
    presentLock.lock()
    let stillBlank = firstPresentPending.contains(browserId)
    let hidden = hiddenBrowsers.contains(browserId)
    // This chain terminates on paint or hide (re-armed fresh on unhide); release the
    // single-instance flag so a later unhide can start one new chain. The continuing
    // (still-blank, visible) path below keeps it armed by NOT clearing here.
    if !stillBlank || hidden { watchdogArmed.remove(browserId) }
    presentLock.unlock()
    guard stillBlank else { return }  // it painted — nothing to do
    guard !hidden else { return }     // hidden by design — suspended; re-armed on unhide
    browsersLock.lock(); let live = browsers[browserId] != nil; browsersLock.unlock()
    writeLock.lock(); let healthy = running && !crashed; writeLock.unlock()
    guard live, healthy else { firstPresentArrived(browserId); return }
    // Unblock the queue once (idempotent: only the in-flight id advances).
    advanceCreatePacer(after: browserId, timedOut: false)
    // Cheap nudge (harmless if it's just slow; helps a merely-dropped first frame).
    send(browserId, Self.opInvalidate, [])
    NSLog("[cef] profile '\(profileId)': browser \(browserId) still blank after \(Int(firstPaintGrace))s — reporting paintStalled (consumer may recreate)")
    onPaintStalled?(browserId)
    // Re-arm: keep watching on a backoff until it paints (firstPresentArrived clears it).
    DispatchQueue.global().asyncAfter(deadline: .now() + firstPaintGrace) { [weak self] in
      self?.checkFirstPresent(browserId)
    }
  }

  // ── F-6: steady-state liveness watchdog ─────────────────────────────────────────────
  // The first-paint watchdog above RETIRES at first paint (firstPresentArrived), so a
  // browser that painted ≥1 frame then WEDGES (renderer/GPU stall inside a shared host
  // that keeps the pipe alive, so no processGone) had NO detector — silent blank until
  // relaunch. This periodic sweep covers steady state. A static page legitimately idles
  // (no presents), so staleness alone isn't a wedge: a discriminating opInvalidate is sent
  // first (a healthy page repaints → a present lands → cleared); only if no present follows
  // within the grace is paintStalled reported, routing into the consumer's BOUNDED recover.
  // Decision logic is in LivenessProbePolicy (standalone-unit-tested).
  private let livenessStalenessNs: UInt64 = {
    if let s = ProcessInfo.processInfo.environment["FLUTTER_CEF_LIVENESS_MS"],
       let ms = Double(s), ms > 0 { return UInt64(ms * 1_000_000) }
    return 10_000_000_000  // 10s — generous; a wedge is rare + a healthy idle page only
                           // costs one forced repaint per window.
  }()
  private let livenessGraceNs: UInt64 = 3_000_000_000  // 3s after the nudge → declare wedged
  private let livenessSweepInterval: TimeInterval = 2.0
  private var livenessSweepStarted = false  // guarded by browsersLock

  /// Start the periodic liveness sweep once (idempotent). Called after the reader is up.
  private func startLivenessSweep() {
    browsersLock.lock()
    let already = livenessSweepStarted
    livenessSweepStarted = true
    browsersLock.unlock()
    guard !already else { return }
    scheduleLivenessSweep()
  }

  private func scheduleLivenessSweep() {
    writeLock.lock(); let alive = running && !crashed; writeLock.unlock()
    guard alive else { return }  // host gone → stop sweeping
    DispatchQueue.global().asyncAfter(deadline: .now() + livenessSweepInterval) { [weak self] in
      self?.livenessSweep()
    }
  }

  private func livenessSweep() {
    let now = DispatchTime.now().uptimeNanoseconds
    // 1) Snapshot ESTABLISHED browsers + their liveness state under browsersLock.
    browsersLock.lock()
    var cands: [(bid: UInt32, sinceLast: UInt64, nudgedAt: UInt64)] = []
    for (bid, s) in browsers where s.firstPresentSeen {
      cands.append((bid, now &- s.lastPresentNs, s.livenessNudgedAt))
    }
    browsersLock.unlock()
    if !cands.isEmpty {
      // 2) Exclude hidden (legitimately frameless) + still-first-paint-pending (the first-
      //    paint watchdog owns those). presentLock is taken AFTER releasing browsersLock —
      //    never nested — matching the host's browsersLock→presentLock order, so no deadlock.
      presentLock.lock()
      let hidden = hiddenBrowsers
      let pending = firstPresentPending
      presentLock.unlock()
      for c in cands where !hidden.contains(c.bid) && !pending.contains(c.bid) {
        let nudged = c.nudgedAt != 0
        let action = LivenessProbePolicy.evaluate(
          sinceLastPresentNs: c.sinceLast, stalenessThresholdNs: livenessStalenessNs,
          nudged: nudged, sinceNudgeNs: nudged ? (now &- c.nudgedAt) : UInt64(0),
          nudgeGraceNs: livenessGraceNs)
        switch action {
        case .healthy:
          break
        case .nudge:
          // Discriminate: a healthy idle page repaints (clearing the nudge on the present);
          // a wedged one stays blank.
          send(c.bid, Self.opInvalidate, [])
          browsersLock.lock(); browsers[c.bid]?.livenessNudgedAt = now; browsersLock.unlock()
        case .declareStalled:
          NSLog("[cef] profile '\(profileId)': browser \(c.bid) painted then wedged — reporting paintStalled (consumer may recreate)")
          onPaintStalled?(c.bid)
          // Re-discriminate next cycle; the consumer's recover() is bounded (kMaxCefRecreate).
          browsersLock.lock(); browsers[c.bid]?.livenessNudgedAt = 0; browsersLock.unlock()
        }
      }
    }
    scheduleLivenessSweep()
  }

  /// Frame `[u32 bodyLen=4+1+payload.count][u32 browserId][op][payload]` and
  /// write it, or queue it if the pipe isn't up yet. A pre-connect opResize whose
  /// browserId hasn't had its create enqueued is DROPPED — that create carries
  /// the current geometry, so replaying the resize could reference a since-freed
  /// IOSurface id.
  func send(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8]) {
    // C1: peek visibility so the first-present watchdog doesn't flag an intentionally
    // hidden (WasHidden) browser as stalled — it produces no frames by design.
    if op == Self.opSetVisible, let v = payload.first {
      noteVisibility(browserId, visible: v != 0)
    }
    let frame = frameBytes(browserId, op, payload)
    writeLock.lock()
    if connFd < 0 {
      if op == Self.opResize && !createEnqueued.contains(browserId) {
        writeLock.unlock()
        return
      }
      pendingFrames.append(frame)
      writeLock.unlock()
      return
    }
    let ok = frame.withUnsafeBytes { writeAll(connFd, $0.baseAddress!, frame.count) }
    writeLock.unlock()
    // H2: a failed write means the pipe is dead — until now the return was
    // discarded and a dead pipe was indistinguishable from success. Surface it
    // (unlocked first: handleHostDeath re-takes writeLock).
    if !ok { handleHostDeath() }
  }

  /// Whether this host currently has a LIVE browser — a registered browser AND
  /// a host that hasn't died. Used by the P1 single-view-per-named-profile
  /// guard (`FlutterCefPlugin.create`). Consulting liveness (not just map
  /// emptiness) is what lets a named profile reopen after a `cef_host` crash:
  /// C1's onHostDied path clears `browsers` on main, but the `crashed` flag is
  /// the belt-and-suspenders guard against any racing teardown ordering (M1).
  var hasLiveBrowser: Bool {
    writeLock.lock()
    let dead = crashed
    writeLock.unlock()
    if dead { return false }
    browsersLock.lock(); defer { browsersLock.unlock() }
    return !browsers.isEmpty
  }

  /// Close ONE browser (opDisposeBrowser) and unregister it under lock. Returns
  /// the number of browsers still registered on this host afterward.
  func removeBrowser(_ browserId: UInt32) -> Int {
    // CEF-2b: if this tile was agent-controlled, tear down ITS relay (its scoped
    // targetId is now dead) BEFORE disposing the browser — disableAgentControl is
    // a no-op when there's no relay for this id. Does its own locking + stops the
    // relay outside cdpHandlerLock.
    disableAgentControl(browserId: browserId)
    send(browserId, Self.opDisposeBrowser, [])
    browsersLock.lock()
    browsers[browserId] = nil
    let remaining = browsers.count
    browsersLock.unlock()
    writeLock.lock()
    createEnqueued.remove(browserId)
    writeLock.unlock()
    // C1: drop any watchdog/visibility bookkeeping for the gone browser so the sets
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

  /// Tear down the WHOLE process: opShutdown(0), stop the reader thread (flag it,
  /// wake its blocking accept()/read() by shutting down the fds, wait for it to
  /// exit), close the fds, unlink the socket, drop an ephemeral profile dir, and
  /// terminate cef_host. Closing an fd a thread is blocked on, or freeing state
  /// under the reader, is a use-after-free — the join makes teardown deterministic.
  func shutdown() {
    // Clear `running` FIRST (before the opShutdown write and before closing the
    // fds): this is a CLEAN teardown, so neither the reader's read-EOF nor a
    // failed opShutdown write should be mistaken for a crash — handleHostDeath()
    // guards on `running`, so flipping it false here keeps onHostDied from firing
    // on the shutdown path (C1).
    writeLock.lock()
    running = false
    // H6: abandon any paced creates so a stuck pacer can't wedge a reused host and
    // queued-never-sent sessions don't linger. The browsers map still holds them, so
    // disposeSession/onHostDied path cleans them up.
    createSendQueue.removeAll()
    createInFlight.removeAll()
    writeLock.unlock()
    // Also abandon pre-opReady queued creates (pendingCreates is browsersLock-guarded, not
    // writeLock) so a host dying between spawn and opReady tears down all THREE create-state
    // queues symmetrically — the old asymmetry left these closures dangling.
    browsersLock.lock()
    pendingCreates.removeAll()
    browsersLock.unlock()
    // CEF-2a/b: drop ALL relays (each a listener + any client) before tearing down
    // the pipe, so none keeps bridging into a closing fd. Snapshot under the lock,
    // clear the dict + onCdpMessage, then stop each OUTSIDE the lock (stop() may
    // block briefly on a stuck client and takes the relay's own locks).
    cdpHandlerLock.lock()
    let relays = Array(cdpRelays.values)
    cdpRelays.removeAll()
    onCdpMessage = nil
    cdpHandlerLock.unlock()
    for r in relays { r.stop() }
    send(0, Self.opShutdown, [])
    writeLock.lock()
    let c = connFd, l = listenFd
    writeLock.unlock()
    // Darwin.shutdown — disambiguate from this class's own shutdown() method,
    // which Swift would otherwise resolve these unqualified calls to.
    if c >= 0 { Darwin.shutdown(c, SHUT_RDWR) }
    if l >= 0 { Darwin.shutdown(l, SHUT_RDWR) }
    // H1: gate the join on `readerStarted` ALONE (not the old `wasRunning`). The
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
    if isEphemeral && !profileDir.isEmpty {
      try? FileManager.default.removeItem(atPath: profileDir)
    }
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
    // H1: same discipline for the CDP reader — gate on cdpReaderStarted alone, and
    // never close the read fd on a join timeout (the reader is still in read() on it).
    let cdpJoined = !cdpReaderStarted || cdpReaderDone.wait(timeout: .now() + 2) == .success
    if cdpReadFd >= 0 { if cdpJoined { close(cdpReadFd) }; cdpReadFd = -1 }
  }

  /// SIGTERM (then SIGKILL escalation) the cef_host process. Handles BOTH launch
  /// paths: `process` (Foundation.Process, default) and `spawnedPid` (posix_spawn,
  /// agent-control). Idempotent — clears whichever handle it used.
  private func terminateProcess() {
    // H5: take BOTH handles atomically under writeLock so this is the sole owner of
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

  // MARK: Subprocess + IPC

  /// Ask the OS for a free TCP port on 127.0.0.1 (bind :0, read it back, close).
  /// Brief TOCTOU window until cef_host's CEF binds it — acceptable on loopback.
  /// Returns 0 on failure.
  private static func pickFreeTcpPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return 0 }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return 0 }
    var assigned = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    guard got == 0 else { return 0 }
    return Int(UInt16(bigEndian: assigned.sin_port))
  }

  private func acceptAndRead() {
    defer { readerDone.signal() }  // let shutdown() join us on every exit path
    let fd = accept(listenFd, nil, nil)
    guard fd >= 0 else {
      // A failed accept() with no clean shutdown in flight is a dead host too
      // (cef_host exited before connecting — e.g. a crash during CefInitialize
      // that never reached the IPC). handleHostDeath() no-ops on a clean
      // shutdown (running==false, which wakes accept() via the listen-fd
      // shutdown). The C2 cache-lock loss connects first (it SendLogs
      // "profile-locked" then exits 2), so it surfaces via the read-loop EOF
      // below with a real terminationStatus, not here.
      NSLog("[cef] accept() failed")
      handleHostDeath()
      return
    }
    // After accept(), guard the conn fd against SIGPIPE (H2): a write() to a
    // peer-closed socket would otherwise raise SIGPIPE and kill the whole host
    // APP, not just fail the write. With SO_NOSIGPIPE the write returns -1/EPIPE
    // and writeAll() reports failure, which we route to handleHostDeath().
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    // Close-on-exec: accept() does NOT inherit the listener's CLOEXEC, and the
    // agent-control launch (launchViaPosixSpawn, attrp=nil) does not set
    // POSIX_SPAWN_CLOEXEC_DEFAULT — so without this, this host's accepted IPC fd would
    // leak into a LATER agent-control cef_host spawn (cross-profile fd leak that keeps
    // this socket's refcount > 0 and delays its EOF teardown).
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    // Bring the pipe up and drain anything queued before it connected — all under
    // writeLock so a concurrent send can't interleave with the flush. Unlike the
    // old per-view path, geometry is NOT re-synced here: each browser's
    // opCreateBrowser carries its current geometry, and pre-create resizes were
    // dropped in send(); the queued frames are early control ops + the creates
    // that fall through after opReady.
    writeLock.lock()
    connFd = fd
    var flushOk = true
    for f in pendingFrames {
      if !(f.withUnsafeBytes { writeAll(fd, $0.baseAddress!, f.count) }) {
        flushOk = false
        break
      }
    }
    pendingFrames.removeAll()
    writeLock.unlock()
    // A flush write that failed means the pipe is already dead (H2) — treat it
    // as a host death rather than spinning into the read loop on a broken fd.
    if !flushOk { handleHostDeath(); return }
    while running {
      var hdr = [UInt8](repeating: 0, count: 4)
      if !readAll(fd, &hdr, 4) { break }
      let bodyLen = (Int(hdr[0]) << 24) | (Int(hdr[1]) << 16) | (Int(hdr[2]) << 8) | Int(hdr[3])
      // Minimum valid body is 5 bytes (4 browserId + 1 op + 0 payload).
      // H9: a malformed/oversized length means a wire desync and tears down EVERY
      // browser on this host — log the rejected length first so it isn't a silent,
      // breadcrumb-less all-tiles crash (the IPC peer is trusted, so this only fires
      // on a genuine framing bug).
      if bodyLen <= 4 || bodyLen > (64 << 20) {
        NSLog("[cef] profile '\(profileId)': rejecting malformed IPC frame, bodyLen=\(bodyLen) — tearing down host")
        break
      }
      var body = [UInt8](repeating: 0, count: bodyLen)
      if !readAll(fd, &body, bodyLen) { break }
      let bid = beU32(body, 0)
      let op = body[4]
      let payload = Array(body[5...])  // empty slice when bodyLen == 5 (no payload)
      if bid == 0 {
        handleProcessFrame(op, payload)
      } else if op == Self.opTargetId {
        // CEF-2b: a targetId resolution result — route to the pending completion,
        // not the session.
        handleTargetId(bid, String(bytes: payload, encoding: .utf8))
      } else if op == Self.opCreated {
        // Bind ack only — intentionally does NOT advance the pacer anymore. We gate the
        // next create on this browser's first PAINT (firstPresentArrived), not its bind,
        // so establishment is serialized. opCreateFailed / the paint-timeout backstop
        // still advance for the bound-but-never-painted / failed cases. (No-op here.)
        _ = bid
      } else if op == Self.opCreateFailed {
        handleCreateFailed(bid)  // H7
      } else {
        browsersLock.lock()
        let session = browsers[bid]
        // C1: detect the FIRST present under the browsersLock we already hold, via a
        // per-session flag, so the watchdog-cancel (presentLock) fires once per browser
        // instead of acquiring a second lock on every (up to 60fps) present frame.
        var firstPaint = false
        var reachedStableFrames = false
        if op == Self.opPresent, let s = session {
          s.presentCount += 1
          if s.presentCount == 1 { s.firstPresentSeen = true; firstPaint = true }
          if s.presentCount == estabStableFrames { reachedStableFrames = true }
          // F-6: any present clears the liveness-stall state — the browser is alive.
          s.lastPresentNs = DispatchTime.now().uptimeNanoseconds
          s.livenessNudgedAt = 0
        }
        browsersLock.unlock()
        if firstPaint {
          if ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil {
            NSLog("[cef] FIRSTPAINT browser \(bid)")  // one-shot, timestamped — cascade probe
          }
          // A browser that painted ANY frame is alive + has content (NOT blank) — cancel
          // the watchdog now. (Gating the cancel on the frame threshold falsely recreated
          // STATIC real sites that paint a short burst < threshold then idle.)
          firstPresentArrived(bid)
          // Pacer settle path: admit the next create after the settle window — covers
          // static content that won't reach the frame threshold. The threshold below is
          // the faster path for continuously-animating content; whichever fires first
          // wins (advanceCreatePacer is idempotent).
          let id = bid
          DispatchQueue.global().asyncAfter(deadline: .now() + estabSettle) { [weak self] in
            self?.advanceCreatePacer(after: id, timedOut: false)
          }
        }
        if reachedStableFrames { advanceCreatePacer(after: bid, timedOut: false) }
        session?.handleFrame(op, payload)
      }
    }
    // C1: the loop exited. If `running` is still true this was NOT a clean
    // shutdown() (which clears `running` BEFORE shutting the fds down) — the
    // host died (EOF/ECONNRESET on the peer, or a malformed frame). Surface it.
    // shutdown() flips `running` false first, so its fd-close-driven read EOF
    // lands here with `running==false` and is correctly ignored.
    handleHostDeath()
  }

  /// C1/H2: the host has (apparently) died — the reader hit EOF while running,
  /// accept()/the pre-ready flush failed, or a send's writeAll failed. Fire
  /// `onHostDied` ONCE on the main thread (the plugin's maps are main-thread
  /// confined — H3), passing the process exit status so the plugin can tell a
  /// cache-lock loss (status 2 — C2 contract) from a generic crash. A clean
  /// shutdown() (running==false) is not a death and is ignored.
  private func handleHostDeath() {
    writeLock.lock()
    // Ignore clean teardown, and fire at most once: both the reader-exit path
    // and a writeAll-failure (possibly concurrent, on the main thread) can land
    // here. Set `crashed` synchronously so hasLiveBrowser flips immediately.
    guard running, !diedFired else { writeLock.unlock(); return }
    diedFired = true
    crashed = true  // forces hasLiveBrowser false so the named profile reopens
    // H6: abandon paced creates — the host is gone. Sessions stay in `browsers`, so
    // the onHostDied → plugin path still emits processGone for each queued one.
    createSendQueue.removeAll()
    createInFlight.removeAll()
    let p = process
    // H5: TAKE the posix_spawn pid (zero it) so this reaper is the SOLE owner of its
    // waitpid — a later terminateProcess()/shutdown() then sees 0 and won't
    // double-reap a pid this thread is about to harvest (which could kill an
    // OS-recycled pid). If it's wedged and we can't reap within the grace window
    // below, we SIGKILL + reap it ourselves so it never leaks as a zombie/orphan.
    let pid = spawnedPid
    spawnedPid = 0
    let died = onHostDied
    writeLock.unlock()
    // Abandon pre-opReady queued creates too (pendingCreates is browsersLock-guarded) —
    // symmetric with the createSendQueue/createInFlight teardown above; the onHostDied path
    // still emits processGone for the sessions left in `browsers`.
    browsersLock.lock()
    pendingCreates.removeAll()
    browsersLock.unlock()
    // The host is gone: tear down CDP relays (free their localhost listeners +
    // clients) and FAIL any in-flight targetId waiters so enableAgentControl
    // callers don't hang forever. Mirrors shutdown()'s teardown — snapshot under
    // each lock, act OUTSIDE it (stop()/completions may block + take other locks).
    // Idempotent: a later shutdown()/terminate finds the dicts already empty.
    cdpHandlerLock.lock()
    let deadRelays = Array(cdpRelays.values)
    cdpRelays.removeAll()
    onCdpMessage = nil
    cdpHandlerLock.unlock()
    for r in deadRelays { r.stop() }
    targetIdLock.lock()
    let strandedWaiters = pendingTargetId.values.flatMap { $0 }
    pendingTargetId.removeAll()
    targetIdEpoch.removeAll()
    targetIdLock.unlock()
    for w in strandedWaiters { w(nil) }  // nil = resolution failed (host died)
    // Resolve the exit status + invoke onHostDied off the caller's thread: this
    // can be the MAIN thread (a writeAll failure in send()/sendCreate()), and
    // terminationStatus traps if read while the process is still running — so we
    // must not busy-wait here. Hop to a background queue, wait briefly for the
    // process to actually exit (EOF usually means it already has), then deliver
    // on main (the plugin's maps are main-thread confined — H3). Generic-crash
    // status (-1) if it outlives the grace window.
    //
    // Two launch paths: `process` (Foundation.Process) exposes isRunning/
    // terminationStatus; the posix_spawn path has only `pid`, so we poll waitpid
    // (WNOHANG) and extract the exit code via WEXITSTATUS so the C2 cache-lock
    // signal (exit 2 -> "locked") matches Process.terminationStatus's semantics.
    DispatchQueue.global().async { [weak self] in
      var status: Int32 = -1
      if let p = p {
        for _ in 0 ..< 20 {  // up to ~1s
          if !p.isRunning { status = p.terminationStatus; break }
          usleep(50_000)
        }
      } else if pid > 0 {
        // We already TOOK ownership of `pid` (zeroed spawnedPid under writeLock), so
        // we are the only thread that may waitpid it here.
        var reaped = false
        for _ in 0 ..< 20 {  // up to ~1s
          var raw: Int32 = 0
          let r = waitpid(pid, &raw, WNOHANG)
          if r == pid {
            // Reaped. Mirror terminationStatus: exit code, or -1 if signaled.
            status = (raw & 0o177) == 0 ? ((raw >> 8) & 0xff) : -1
            reaped = true; break
          } else if r < 0 {
            reaped = true; break  // ECHILD / already gone — nothing to hand back.
          }
          usleep(50_000)
        }
        // H5: still alive after the grace window (a wedged child that didn't exit on
        // EOF). Don't merely hand it back — the clean-shutdown path may never call
        // terminateProcess() again, leaving a zombie/orphan cef_host. SIGKILL + reap it
        // right here. We exclusively own this pid (spawnedPid was zeroed above) and it
        // is still unreaped, so it can't be a recycled or relaunched pid.
        if !reaped {
          kill(pid, SIGKILL)
          var raw: Int32 = 0
          waitpid(pid, &raw, 0)  // blocking reap, off the main thread
        }
      }
      DispatchQueue.main.async { died?(status) }
    }
  }

  /// Process/profile-level inbound frames (browserId 0): opReady (carries the
  /// ad-hoc build flag, gates the create flush) and process logs.
  private func handleProcessFrame(_ op: UInt8, _ payload: [UInt8]) {
    switch op {
    case Self.opReady:
      let flags = payload.first ?? 0
      let adhoc = (flags & 0x01) != 0
      // F.5 dev safety-rail: an ad-hoc (mock-keychain) host must NOT load a named
      // persistent profile unless explicitly allowed, because at-rest creds
      // wouldn't be protected. Nothing has been written yet (no browser was
      // created), so refusing here leaks nothing. The plugin respawns an
      // ephemeral host for the session and re-issues createBrowser.
      let allowInsecure =
        ProcessInfo.processInfo.environment["FLUTTER_CEF_ALLOW_INSECURE_PROFILE"] == "1"
      writeLock.lock()
      adhocHost = adhoc
      ready = true
      let refuse = adhoc && !isEphemeral && !allowInsecure
      let creates = refuse ? [] : pendingCreates
      pendingCreates.removeAll()
      writeLock.unlock()
      if refuse {
        NSLog("[cef] refusing persistent profile '\(profileId)' under an ad-hoc " +
              "(mock-keychain) cef_host build; downgrading to ephemeral. Set " +
              "FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 to override.")
        onInsecureProfileRefused?()
        return
      }
      for c in creates { c() }
    case Self.opLog:
      let msg = String(bytes: payload, encoding: .utf8) ?? ""
      NSLog("[cef_host:\(profileId)] \(msg)")
    default:
      break
    }
  }

  // MARK: Wire helpers

  // Length-prefixed wire frame: [u32 bodyLen][u32 browserId][op][payload], where
  // bodyLen = 4 + 1 + payload.count. Pure — no lock.
  private func frameBytes(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var frame = [UInt8]()
    frame.reserveCapacity(9 + payload.count)
    appendU32(&frame, UInt32(4 + 1 + payload.count))
    appendU32(&frame, browserId)
    frame.append(op)
    frame.append(contentsOf: payload)
    return frame
  }

  private func appendU32(_ a: inout [UInt8], _ v: UInt32) {
    a.append(UInt8((v >> 24) & 0xff))
    a.append(UInt8((v >> 16) & 0xff))
    a.append(UInt8((v >> 8) & 0xff))
    a.append(UInt8(v & 0xff))
  }

  private func appendF64(_ a: inout [UInt8], _ v: Double) {
    let bits = v.bitPattern
    for shift in stride(from: 56, through: 0, by: -8) {
      a.append(UInt8((bits >> UInt64(shift)) & 0xff))
    }
  }

  private func beU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16)
      | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
  }

  // A filesystem-safe tag for the socket name derived from the profileId (which
  // for ephemeral hosts is "~ephemeral~"+sessionId — chars not in sun_path-safe
  // set get collapsed).
  private func sanitizedSocketTag() -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    return String(profileId.map { allowed.contains($0) ? $0 : "_" })
  }

  // MARK: CDP over pipe (agent-control)

  /// Send one CDP message to cef_host: UTF-8 JSON followed by a single 0x00 NUL
  /// (the ASCIIZ framing Chromium's DevToolsPipeHandler and Puppeteer's
  /// PipeTransport use). Serialized under cdpWriteLock; writeAll handles short
  /// writes. Safe to call before the round-trip is proven — a dead/absent pipe
  /// (fd < 0, or EPIPE caught harmlessly via the write end's F_SETNOSIGPIPE) just
  /// drops the message. No-op when not in agent-control mode.
  func sendCdp(_ json: String) {
    guard agentControl else { return }
    cdpWriteLock.lock()
    let fd = cdpWriteFd
    var bytes = Array(json.utf8)
    bytes.append(0)  // NUL terminator
    if fd >= 0 {
      _ = bytes.withUnsafeBytes { writeAll(fd, $0.baseAddress!, bytes.count) }
    }
    cdpWriteLock.unlock()
  }

  /// CEF-2b: deliver one CDP pipe message to EVERY live relay. Snapshot the relays
  /// under cdpHandlerLock, then call deliverToClient OUTSIDE the lock on each —
  /// deliverToClient does blocking IO and takes the relay's own locks, so holding
  /// cdpHandlerLock across it would invert the lock order (and could deadlock /
  /// stall the reader). Each relay demuxes its own traffic (sessionId + CDP-id
  /// rewrite); a sibling relay drops what isn't its.
  private func deliverCdpToRelays(_ msg: String) {
    cdpHandlerLock.lock()
    let relays = Array(cdpRelays.values)
    cdpHandlerLock.unlock()
    for r in relays { r.deliverToClient(msg) }
  }

  /// CEF-2b: start (lazily) a token-gated CDP relay SCOPED to `browserId`'s tile and
  /// return the brokered endpoint Campus hands an agent. Async: first resolves the
  /// browser's CDP targetId (round-trip to cef_host), then creates a relay whose
  /// Target-domain filter exposes only that tile, then starts it (so no client ever
  /// sees an unscoped relay). Requires agent-control (pipe) mode and a live host.
  /// N tiles in the same shared cef_host can be agent-controlled concurrently — one
  /// relay per browserId, all sharing the one browser-wide pipe. Idempotent for the
  /// same tile. The completion fires exactly once.
  func enableAgentControl(browserId: UInt32,
                          completion: @escaping ((wsUrl: String, token: String, port: Int)?) -> Void) {
    writeLock.lock(); let alive = running && !crashed; writeLock.unlock()
    guard agentControl, alive, browserId > 0 else { completion(nil); return }

    // Idempotent fast-path: this tile already has a relay — hand back its endpoint.
    cdpHandlerLock.lock()
    if let r = cdpRelays[browserId] {
      cdpHandlerLock.unlock()
      completion(endpoint(r))
      return
    }
    cdpHandlerLock.unlock()

    resolveTargetId(browserId) { [weak self] tid in
      guard let self = self, let tid = tid, !tid.isEmpty else { completion(nil); return }
      self.cdpHandlerLock.lock()
      // Re-check under the lock: a concurrent enable for the SAME browserId could
      // have raced us between the fast-path check and here.
      if let r = self.cdpRelays[browserId] {
        self.cdpHandlerLock.unlock()
        completion(self.endpoint(r))
        return
      }
      // relayId: browserId binds this relay into the shared pipe's CDP id space, so
      // its rewritten command ids never collide with a sibling tile's.
      let relay = CdpRelay(sendToPipe: { [weak self] in self?.sendCdp($0) },
                           scopeTargetId: tid, relayId: Int(browserId))
      guard relay.start() else { self.cdpHandlerLock.unlock(); completion(nil); return }
      // Install the fan-out pipe → relays handler ONCE, when the first relay appears,
      // CHAINING any prior handler (preserves the debug CEF-1 validation probe) rather
      // than clobbering it. Subsequent relays just join cdpRelays; deliverCdpToRelays
      // snapshots the dict per message, so it picks them up automatically.
      if self.cdpRelays.isEmpty {
        let prior = self.onCdpMessage
        self.onCdpMessage = { [weak self] msg in prior?(msg); self?.deliverCdpToRelays(msg) }
      }
      self.cdpRelays[browserId] = relay
      self.cdpHandlerLock.unlock()
      completion(self.endpoint(relay))
    }
  }

  /// The brokered endpoint for a relay: token-free discovery url + the secret as a
  /// query (see CdpRelay security model).
  private func endpoint(_ r: CdpRelay) -> (wsUrl: String, token: String, port: Int) {
    ("ws://127.0.0.1:\(r.port)/devtools/browser?token=\(r.token)", r.token, Int(r.port))
  }

  /// CEF-2b: resolve `browserId`'s CDP targetId via cef_host (Target.getTargetInfo).
  /// All waiters for that browserId fire exactly once — on the response or a 5s
  /// timeout, whichever removes the entry first. Concurrent calls for the SAME
  /// browserId COALESCE onto one in-flight resolve (a second call appends its waiter
  /// rather than overwriting the first — so no waiter is silently dropped).
  private func resolveTargetId(_ browserId: UInt32, _ completion: @escaping (String?) -> Void) {
    targetIdLock.lock()
    let first = pendingTargetId[browserId] == nil
    pendingTargetId[browserId, default: []].append(completion)
    let epoch = (targetIdEpoch[browserId] ?? 0) + (first ? 1 : 0)
    if first { targetIdEpoch[browserId] = epoch }
    targetIdLock.unlock()
    guard first else { return }  // a resolve is already in flight for this browser
    send(browserId, Self.opResolveTargetId, [])
    // The page target may not have COMMITTED when the first probe fires — common
    // for a tile force-spawned in a burst, where GPU/page init is async after
    // create(). cef_host then finds no targetInfo and never sends opTargetId, so the
    // old fire-once probe silently timed out to nil (empty `webview snapshot`).
    // Re-probe within the deadline so a late-committing page still resolves. Each
    // opResolveTargetId uses a fresh per-browser DevTools message id (see the
    // 33858fb fix), so extra probes are harmless; handleTargetId removes the entry
    // on the first reply, stopping the retries.
    scheduleTargetIdRetry(browserId, epoch, attemptsLeft: 9)  // ~9 × 0.5s ≈ 4.5s
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.timeoutTargetId(browserId, epoch)  // fulfill with nil only if still this resolve
    }
  }

  /// Re-send opResolveTargetId every 0.5s while this exact resolve is still pending
  /// (not yet answered by handleTargetId, not superseded by a newer epoch), up to
  /// `attemptsLeft` times — so a page that commits a second or two after create()
  /// still resolves its targetId instead of the fire-once probe missing it.
  private func scheduleTargetIdRetry(_ browserId: UInt32, _ epoch: Int, attemptsLeft: Int) {
    guard attemptsLeft > 0 else { return }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self = self else { return }
      self.targetIdLock.lock()
      let stillPending =
        self.targetIdEpoch[browserId] == epoch && self.pendingTargetId[browserId] != nil
      self.targetIdLock.unlock()
      guard stillPending else { return }  // resolved or superseded — stop
      self.send(browserId, Self.opResolveTargetId, [])
      self.scheduleTargetIdRetry(browserId, epoch, attemptsLeft: attemptsLeft - 1)
    }
  }

  /// Fulfill all pending targetId waiters for a browser with a real result (reader
  /// thread). The matching resolve's timer is left to no-op via the epoch guard.
  private func handleTargetId(_ browserId: UInt32, _ tid: String?) {
    targetIdLock.lock()
    let waiters = pendingTargetId.removeValue(forKey: browserId)
    targetIdLock.unlock()
    waiters?.forEach { $0(tid) }
  }

  /// A resolve's own 5s timeout: fulfill its still-pending waiters with nil — but
  /// ONLY if a fresh resolve hasn't superseded it (epoch bumped). Without this guard
  /// an early response leaves the timer armed and it would clobber the NEXT resolve.
  private func timeoutTargetId(_ browserId: UInt32, _ epoch: Int) {
    targetIdLock.lock()
    guard targetIdEpoch[browserId] == epoch,
          let waiters = pendingTargetId.removeValue(forKey: browserId) else {
      targetIdLock.unlock(); return
    }
    targetIdLock.unlock()
    waiters.forEach { $0(nil) }
  }

  /// CEF-2a/b: tear down `browserId`'s relay (closes the listener + any client,
  /// invalidates the token). Idempotent — a no-op if that tile has no relay. When
  /// the LAST relay goes, drop the fan-out onCdpMessage too. The pipe itself stays
  /// up (the tile keeps running). The relay is stopped OUTSIDE the lock: stop() may
  /// block briefly on a stuck client and takes the relay's own locks.
  func disableAgentControl(browserId: UInt32) {
    cdpHandlerLock.lock()
    let relay = cdpRelays.removeValue(forKey: browserId)
    if cdpRelays.isEmpty { onCdpMessage = nil }
    cdpHandlerLock.unlock()
    relay?.stop()
  }

  /// CDP reader thread: drain cdpReadFd (parent end of out_pipe; child writes CDP
  /// on fd 4) and split the byte stream on 0x00 into complete UTF-8 JSON messages,
  /// delivering each (NUL stripped) to `onCdpMessage`. Exits on EOF/error (the
  /// host died or shutdown closed the fd). Signals cdpReaderDone on every exit so
  /// shutdown() can join before closing the fd (mirrors acceptAndRead/readerDone).
  /// A CDP message can exceed one read(), and one read() can carry several
  /// messages or straddle a boundary, so we accumulate across reads.
  private func readCdpLoop() {
    defer { cdpReaderDone.signal() }
    let fd = cdpReadFd
    if fd < 0 { return }
    var acc = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
      if n <= 0 { break }  // EOF (0) or error (<0): host gone / fd closed.
      var start = 0
      for i in 0 ..< n {
        if chunk[i] == 0 {
          acc.append(contentsOf: chunk[start ..< i])
          if let msg = String(bytes: acc, encoding: .utf8) {
            // Snapshot the handler under the lock, then invoke OUTSIDE it (the
            // handler may run for a while / take other locks).
            cdpHandlerLock.lock(); let handler = onCdpMessage; cdpHandlerLock.unlock()
            handler?(msg)
          }
          acc.removeAll(keepingCapacity: true)
          start = i + 1
        }
      }
      if start < n { acc.append(contentsOf: chunk[start ..< n]) }
      // Bound the accumulator (mirrors the IPC reader's frame cap): a malformed
      // never-NUL-terminated stream shouldn't grow memory unbounded. The peer is
      // our own cef_host (M113+ always NUL-frames), so this is defensive.
      if acc.count > (64 << 20) { break }
    }
  }

  /// CEF-1 validation gate: prove the pipe round-trips end to end. Only when
  /// agent-control AND FLUTTER_CEF_DEBUG is set, install a temporary CDP handler
  /// and send {"id":1,"method":"Browser.getVersion"}; the first response line is
  /// NSLogged. Behind the debug env so it never runs in normal flow, and it
  /// chains (does not clobber) any handler a relay later installs. cef_host's CDP
  /// endpoint comes up shortly after launch, so a couple of retries cover the
  /// race between our write and DevToolsPipeHandler being ready.
  private func maybeRunCdpValidation() {
    guard agentControl,
          ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil
    else { return }
    cdpHandlerLock.lock()
    let prior = onCdpMessage
    var logged = false
    onCdpMessage = { [weak self] msg in
      prior?(msg)
      guard let self = self, !logged else { return }
      // Only the response to our probe (id:1) proves the round-trip; ignore any
      // unsolicited CDP events that may arrive first.
      if msg.contains("\"id\":1") {
        logged = true
        NSLog("[cef][cdp-pipe:\(self.profileId)] Browser.getVersion round-trip OK: \(msg)")
        // Do NOT restore onCdpMessage here. enableAgentControl may have chained the relay
        // fan-out ON TOP of this probe handler (it captures the then-current handler as
        // its own `prior`); overwriting back to OUR captured `prior` (the pre-probe
        // handler, usually nil) would silently DROP that fan-out so relays receive no
        // pipe messages. The handler is harmless once `logged`: it forwards to `prior`
        // and short-circuits the id:1 check.
      }
    }
    cdpHandlerLock.unlock()
    // Retry a few times in case DevToolsPipeHandler isn't reading fd 3 yet.
    let probe = "{\"id\":1,\"method\":\"Browser.getVersion\"}"
    DispatchQueue.global().async { [weak self] in
      for _ in 0 ..< 10 {
        guard let self = self else { return }
        if logged { return }
        self.sendCdp(probe)
        usleep(200_000)  // 200ms between attempts (~2s total)
      }
    }
  }

  private func readAll(_ fd: Int32, _ buf: inout [UInt8], _ len: Int) -> Bool {
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

  private func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int) -> Bool {
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
