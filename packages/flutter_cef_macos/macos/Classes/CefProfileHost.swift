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
  // CEF-2a: the token-gated localhost CDP relay (created lazily on the first
  // enableAgentControl()). Bridges a CDP client's WebSocket ⇄ this host's pipe.
  // Held strongly here; its pipe-send closure captures self weakly (no cycle).
  private var cdpRelay: CdpRelay?
  // Guards onCdpMessage and cdpRelay. CEF-2a mutates onCdpMessage LIVE (enable/
  // disable on the main thread) while the CDP reader thread reads it per message,
  // so — unlike CEF-1, which only set it before the reader started — both must be
  // synchronized. A plain closure property is a fat (ptr+context) value; a concurrent
  // read during a write can tear it and call into freed context.
  private let cdpHandlerLock = NSLock()
  // CEF-2b: the single relay is scoped to ONE browser's CDP target (first cut: one
  // agent-controlled tile per process). `relayBrowserId` is the browser it's scoped
  // to (0 = none); guarded by cdpHandlerLock.
  private var relayBrowserId: UInt32 = 0
  // Pending browserId→targetId resolutions (kOpResolveTargetId round-trip), keyed by
  // browserId. Set on the plugin thread, fulfilled on the reader thread (kOpTargetId)
  // or a timeout; guarded by targetIdLock. The completion fires exactly once.
  private var pendingTargetId: [UInt32: [(String?) -> Void]] = [:]
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
        self.sendCreate(id, session, url)
      }
    }
    writeLock.unlock()
    if isReady { sendCreate(id, session, url) }
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
    var payload = [UInt8]()
    appendU32(&payload, UInt32(session.w))
    appendU32(&payload, UInt32(session.h))
    appendF64(&payload, Double(session.scale))
    appendU32(&payload, session.surfaceId)
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

  /// Frame `[u32 bodyLen=4+1+payload.count][u32 browserId][op][payload]` and
  /// write it, or queue it if the pipe isn't up yet. A pre-connect opResize whose
  /// browserId hasn't had its create enqueued is DROPPED — that create carries
  /// the current geometry, so replaying the resize could reference a since-freed
  /// IOSurface id.
  func send(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8]) {
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
    send(browserId, Self.opDisposeBrowser, [])
    browsersLock.lock()
    browsers[browserId] = nil
    let remaining = browsers.count
    browsersLock.unlock()
    writeLock.lock()
    createEnqueued.remove(browserId)
    writeLock.unlock()
    // CEF-2b: if the disposed tile was the agent-controlled one, tear down its relay
    // (its scoped targetId is now dead) and free the one-per-process slot.
    cdpHandlerLock.lock()
    let relay = relayBrowserId == browserId ? cdpRelay : nil
    if relay != nil { cdpRelay = nil; relayBrowserId = 0; onCdpMessage = nil }
    cdpHandlerLock.unlock()
    relay?.stop()
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
    let wasRunning = running
    running = false
    writeLock.unlock()
    // CEF-2a: drop the relay (listener + any client) before tearing down the pipe,
    // so it stops bridging into a closing fd.
    cdpHandlerLock.lock()
    let relay = cdpRelay
    cdpRelay = nil
    relayBrowserId = 0
    onCdpMessage = nil
    cdpHandlerLock.unlock()
    relay?.stop()
    send(0, Self.opShutdown, [])
    writeLock.lock()
    let c = connFd, l = listenFd
    writeLock.unlock()
    // Darwin.shutdown — disambiguate from this class's own shutdown() method,
    // which Swift would otherwise resolve these unqualified calls to.
    if c >= 0 { Darwin.shutdown(c, SHUT_RDWR) }
    if l >= 0 { Darwin.shutdown(l, SHUT_RDWR) }
    if readerStarted && wasRunning { _ = readerDone.wait(timeout: .now() + 2) }
    writeLock.lock()
    if connFd >= 0 { close(connFd); connFd = -1 }
    if listenFd >= 0 { close(listenFd); listenFd = -1 }
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
    if cdpReaderStarted && wasRunning { _ = cdpReaderDone.wait(timeout: .now() + 2) }
    if cdpReadFd >= 0 { close(cdpReadFd); cdpReadFd = -1 }
  }

  /// SIGTERM (then SIGKILL escalation) the cef_host process. Handles BOTH launch
  /// paths: `process` (Foundation.Process, default) and `spawnedPid` (posix_spawn,
  /// agent-control). Idempotent — clears whichever handle it used.
  private func terminateProcess() {
    if let p = process {
      process = nil
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
    let pid = spawnedPid
    guard pid > 0 else { return }
    spawnedPid = 0
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
      if bodyLen <= 4 || bodyLen > (64 << 20) { break }
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
      } else {
        browsersLock.lock()
        let session = browsers[bid]
        browsersLock.unlock()
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
    let p = process
    let pid = spawnedPid
    let died = onHostDied
    writeLock.unlock()
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
    DispatchQueue.global().async {
      var status: Int32 = -1
      if let p = p {
        for _ in 0 ..< 20 {  // up to ~1s
          if !p.isRunning { status = p.terminationStatus; break }
          usleep(50_000)
        }
      } else if pid > 0 {
        for _ in 0 ..< 20 {  // up to ~1s
          var raw: Int32 = 0
          let r = waitpid(pid, &raw, WNOHANG)
          if r == pid {
            // Reaped. Mirror terminationStatus: exit code, or -1 if signaled.
            status = (raw & 0o177) == 0 ? ((raw >> 8) & 0xff) : -1
            break
          } else if r < 0 {
            break  // already reaped by terminateProcess() (or no child) — give up.
          }
          usleep(50_000)
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

  /// CEF-2b: start (lazily) the token-gated CDP relay SCOPED to `browserId`'s tile
  /// and return the brokered endpoint Campus hands an agent. Async: first resolves
  /// the browser's CDP targetId (round-trip to cef_host), then creates a relay whose
  /// Target-domain filter exposes only that tile, then starts it (so no client ever
  /// sees an unscoped relay). Requires agent-control (pipe) mode and a live host.
  /// First cut: one agent-controlled tile per process — a second, different tile is
  /// refused. Idempotent for the same tile. The completion fires exactly once.
  func enableAgentControl(browserId: UInt32,
                          completion: @escaping ((wsUrl: String, token: String, port: Int)?) -> Void) {
    writeLock.lock(); let alive = running && !crashed; writeLock.unlock()
    guard agentControl, alive, browserId > 0 else { completion(nil); return }

    cdpHandlerLock.lock()
    if let r = cdpRelay {
      let sameTile = relayBrowserId == browserId
      cdpHandlerLock.unlock()
      if sameTile { completion(endpoint(r)) }
      else { NSLog("[cef] agent-control already active for another tile in this process"); completion(nil) }
      return
    }
    cdpHandlerLock.unlock()

    resolveTargetId(browserId) { [weak self] tid in
      guard let self = self, let tid = tid, !tid.isEmpty else { completion(nil); return }
      self.cdpHandlerLock.lock()
      if self.cdpRelay == nil {  // re-check: a concurrent enable could have raced
        let relay = CdpRelay(sendToPipe: { [weak self] in self?.sendCdp($0) }, scopeTargetId: tid)
        guard relay.start() else { self.cdpHandlerLock.unlock(); completion(nil); return }
        self.cdpRelay = relay
        self.relayBrowserId = browserId
        // Route pipe → relay. Capture the relay directly (weakly) so the reader
        // thread never dereferences self.cdpRelay (which mutates across threads).
        self.onCdpMessage = { [weak relay] msg in relay?.deliverToClient(msg) }
      }
      let r = self.cdpRelay!
      let same = self.relayBrowserId == browserId
      self.cdpHandlerLock.unlock()
      completion(same ? self.endpoint(r) : nil)
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
    targetIdLock.unlock()
    guard first else { return }  // a resolve is already in flight for this browser
    send(browserId, Self.opResolveTargetId, [])
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.handleTargetId(browserId, nil)  // timeout: fulfill any still-pending waiters with nil
    }
  }

  /// Fulfill all pending targetId waiters for a browser (reader thread, or timeout).
  private func handleTargetId(_ browserId: UInt32, _ tid: String?) {
    targetIdLock.lock()
    let waiters = pendingTargetId.removeValue(forKey: browserId)
    targetIdLock.unlock()
    waiters?.forEach { $0(tid) }
  }

  /// CEF-2a/b: tear down the relay (closes the listener + any client, invalidates the
  /// token). Idempotent. The pipe itself stays up (the tile keeps running).
  func disableAgentControl() {
    cdpHandlerLock.lock()
    let relay = cdpRelay
    cdpRelay = nil
    relayBrowserId = 0
    onCdpMessage = nil
    cdpHandlerLock.unlock()
    relay?.stop()  // outside the lock: stop() may block briefly on a stuck client
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
        // Restore the prior handler now that the gate has passed, so the probe
        // wiring doesn't linger on the hot path.
        self.cdpHandlerLock.lock(); self.onCdpMessage = prior; self.cdpHandlerLock.unlock()
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
      if n <= 0 { return false }
      off += n
    }
    return true
  }

  private func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int) -> Bool {
    var off = 0
    while off < len {
      let n = write(fd, buf.advanced(by: off), len - off)
      if n <= 0 { return false }
      off += n
    }
    return true
  }
}
