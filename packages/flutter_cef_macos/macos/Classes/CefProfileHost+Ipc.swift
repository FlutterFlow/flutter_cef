// CefProfileHost: launching cef_host and the IPC socket it connects back on —
// the reader thread that routes inbound frames, the process-level frames
// (kOpReady, logs), and host death.

import Foundation

extension CefProfileHost {
  // MARK: Spawn

  /// Bind the Unix socket and launch cef_host for this profile. Argv always
  /// carries `--ipc` and `--profile-dir=<profileDir>`; `--cdp-port=<port>` is
  /// added only when `enableCdp` (port picked here). `--allowed-schemes` is a
  /// process arg shared by every browser in the profile — it's taken from the
  /// first browser that triggered this spawn. Returns false on failure.
  ///
  /// `agentControl` switches the LAUNCH MECHANISM only: when true we use
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
    self.allowedSchemes = allowedSchemes
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

    // Per-process args only: per-view geometry/url now ride kOpCreateBrowser. The
    // cache path is always the resolved --profile-dir (ephemeral = throwaway temp).
    guard let surfaces = SurfacePort() else { return false }
    surfacePort = surfaces
    var args = [
      "--ipc=\(socketPath)",
      "--profile-dir=\(profileDir)",
      "--surface-port=\(surfaces.name)",
    ]
    // Mark the throwaway-temp case so the host's CDP / mock-keychain guards fire
    // only for a real persistent profile (--profile-dir is set for both).
    if isEphemeral {
      args.append("--ephemeral=1")
    }
    if !allowedSchemes.isEmpty {
      args.append("--allowed-schemes=\(allowedSchemes)")
    }
    if agentControl || enableCdp {
      // A CDP client can pause the page in the debugger, which the liveness ping can't
      // tell from a hang.
      browsersLock.lock(); cdpClientsCanPause = true; browsersLock.unlock()
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
    guard launched else {
      surfaces.close()
      return false
    }
    surfaces.senderPid = hostPid()

    running = true
    readerStarted = true
    Thread.detachNewThread { [weak self] in self?.acceptAndRead() }
    startLivenessSweep()  // steady-state post-establishment liveness watchdog
    // Agent-control: drain CDP off fd 3/4's parent ends on a dedicated reader,
    // splitting the NUL-delimited JSON stream into messages. Started only after
    // a successful spawn (the fds exist). Joined in shutdown() before close.
    // Install the (debug-only) validation handler BEFORE starting the reader so
    // the reader never observes a half-installed onCdpMessage (the only path that
    // mutates it before a relay exists); in normal flow it's a no-op and onCdpMessage stays
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
    // SIGPIPE guard on the WRITE end (same as the IPC socket's): the IPC conn
    // fd uses the SO_NOSIGPIPE socket option, but pipe fds don't take it, so a
    // write to a cef_host that closed its CDP read end (it died) would otherwise
    // raise SIGPIPE and kill the whole host APP. F_SETNOSIGPIPE is the Darwin
    // per-fd equivalent: the write returns -1/EPIPE and writeAll reports failure
    // instead. (CLOEXEC was set above — note F_SETFD/F_SETNOSIGPIPE are distinct
    // fcntl commands, so neither overwrites the other.)
    _ = fcntl(cdpWriteFd, F_SETNOSIGPIPE, 1)
    return true
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

  /// Wait for cef_host to connect and return the accepted fd; nil when the host
  /// exits first, shutdown() begins, or accept() fails. Polls instead of blocking
  /// in accept(): Darwin's shutdown() of a listening socket fails (ENOTCONN) and
  /// wakes nothing, so a blocked accept() outlived a host that died before
  /// connecting — no death was reported, and shutdown()'s join timed out.
  private func acceptHost() -> Int32? {
    var pfd = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
    while true {
      let r = poll(&pfd, 1, 100)
      if r > 0 {
        let fd = accept(listenFd, nil, nil)
        return fd >= 0 ? fd : nil
      }
      if r < 0 && errno != EINTR { return nil }
      writeLock.lock()
      let stopping = !running
      writeLock.unlock()
      if stopping || hostExited() { return nil }
    }
  }

  /// Whether cef_host has exited. Doesn't reap it: handleHostDeath() does that
  /// and reads its exit status.
  private func hostExited() -> Bool {
    writeLock.lock()
    let p = process, pid = spawnedPid
    writeLock.unlock()
    if let p = p { return !p.isRunning }
    guard pid > 0 else { return false }
    var info = siginfo_t()
    return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
      && info.si_pid == pid
  }

  private func acceptAndRead() {
    defer { readerDone.signal() }  // let shutdown() join us on every exit path
    guard let fd = acceptHost() else {
      // No connection and no clean shutdown in flight is a dead host too:
      // cef_host exited before connecting (e.g. a crash during CefInitialize, or
      // a FLUTTER_CEF_HOST that isn't cef_host), or accept() failed.
      // handleHostDeath() no-ops on a clean shutdown (running==false). A
      // cache-lock loss (another process holds the profile) connects first (it
      // SendLogs "profile-locked" then exits 2), so it usually surfaces via the read-loop EOF below; either way
      // handleHostDeath() reads the real exit status.
      NSLog("[cef] cef_host for profile '\(profileId)' never connected")
      handleHostDeath()
      return
    }
    // After accept(), guard the conn fd against SIGPIPE: a write() to a
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
    // kOpCreateBrowser carries its current geometry, and pre-create resizes were
    // dropped in send(); the queued frames are early control ops + the creates
    // that fall through after kOpReady.
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
    // A flush write that failed means the pipe is already dead — treat it
    // as a host death rather than spinning into the read loop on a broken fd.
    if !flushOk { handleHostDeath(); return }
    while running {
      var hdr = [UInt8](repeating: 0, count: 4)
      if !readAll(fd, &hdr, 4) { break }
      let bodyLen = (Int(hdr[0]) << 24) | (Int(hdr[1]) << 16) | (Int(hdr[2]) << 8) | Int(hdr[3])
      // Minimum valid body is 5 bytes (4 browserId + 1 op + 0 payload).
      // A malformed/oversized length means a wire desync and tears down EVERY
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
      } else if op == CefOp.targetId {
        // A targetId resolution result — route to the pending completion,
        // not the session.
        handleTargetId(bid, String(bytes: payload, encoding: .utf8))
      } else if op == CefOp.evalResult,
                payload.starts(with: Self.livenessPingReplyPrefix) {
        // The liveness sweep's own ping, not the page's: the renderer answered.
        browsersLock.lock()
        if let s = browsers[bid] {
          s.livenessPingSentAt = 0
          s.livenessPingRepliedAt = DispatchTime.now().uptimeNanoseconds
        }
        browsersLock.unlock()
      } else if op == CefOp.created {
        // Bind ack — intentionally does NOT advance the pacer anymore. We gate the
        // next create on this browser's first PAINT (firstPresentArrived), not its bind,
        // so establishment is serialized. kOpCreateFailed / the paint-timeout backstop
        // still advance for the bound-but-never-painted / failed cases. The session
        // re-sends a hide the host dropped before this browser's slot existed.
        browsersLock.lock()
        let session = browsers[bid]
        browsersLock.unlock()
        if let session = session {
          DispatchQueue.main.async { session.browserCreated(bid) }
        }
      } else if op == CefOp.createFailed {
        reportBrowserGone(bid, "createFailed")
      } else if op == CefOp.browserGone {
        // cef_host gave up on this browser (its renderer kept crashing); the process
        // and its other browsers are fine.
        reportBrowserGone(bid, String(bytes: payload, encoding: .utf8) ?? "crashed")
      } else {
        browsersLock.lock()
        let session = browsers[bid]
        // Detect the FIRST present under the browsersLock we already hold, via a
        // per-session flag, so the watchdog-cancel (presentLock) fires once per browser
        // instead of acquiring a second lock on every (up to 60fps) present frame.
        var firstPaint = false
        var reachedStableFrames = false
        if op == CefOp.present, let s = session {
          s.presentCount += 1
          if s.presentCount == 1 { s.firstPresentSeen = true; firstPaint = true }
          if !hostPainted {
            hostPainted = true
            // The first frame needed a working GPU process: remember which one it was
            // (off the reader, since it walks the host's children).
            DispatchQueue.global().async { [weak self] in self?.recordGpuProcess() }
          }
          if s.presentCount == estabStableFrames { reachedStableFrames = true }
          // Any present clears the liveness-stall state — the browser is alive.
          s.lastPresentNs = DispatchTime.now().uptimeNanoseconds
          s.livenessNudgedAt = 0
        } else if op == CefOp.pageStart, let s = session {
          // The ping's reply can be lost with the document it ran in, and a navigation
          // dismisses the page's dialogs.
          s.livenessPingSentAt = 0
          s.livenessDialogsOpen = 0
        } else if op == CefOp.jsDialog, let s = session {
          // The renderer waits on the dialog, so it can't answer the ping until then.
          s.livenessDialogsOpen += 1
          s.livenessPingSentAt = 0
        }
        browsersLock.unlock()
        if firstPaint {
          if Self.debugEnabled {
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
    // The loop exited. If `running` is still true this was NOT a clean
    // shutdown() (which clears `running` BEFORE shutting the fds down) — the
    // host died (EOF/ECONNRESET on the peer, or a malformed frame). Surface it.
    // shutdown() flips `running` false first, so its fd-close-driven read EOF
    // lands here with `running==false` and is correctly ignored.
    handleHostDeath()
  }

  /// The host has (apparently) died — the reader hit EOF while running,
  /// accept()/the pre-ready flush failed, or a send's writeAll failed. Fire
  /// `onHostDied` ONCE on the main thread (the plugin's maps are main-thread
  /// confined), passing the process exit status so the plugin can tell a
  /// cache-lock loss (cef_host exits 2) from a generic crash. A clean
  /// shutdown() (running==false) is not a death and is ignored.
  func handleHostDeath() {
    writeLock.lock()
    // Ignore clean teardown, and fire at most once: both the reader-exit path
    // and a writeAll-failure (possibly concurrent, on the main thread) can land
    // here. Set `crashed` synchronously so the pacer and sweeps stop at once.
    guard running, !diedFired else { writeLock.unlock(); return }
    diedFired = true
    crashed = true
    // Abandon paced creates — the host is gone. Sessions stay in `browsers`, so
    // the onHostDied → plugin path still emits processGone for each queued one.
    createSendQueue.removeAll()
    createInFlight.removeAll()
    let p = process
    // TAKE the posix_spawn pid (zero it) so this reaper is the SOLE owner of its
    // waitpid — a later terminateProcess()/shutdown() then sees 0 and won't
    // double-reap a pid this thread is about to harvest (which could kill an
    // OS-recycled pid). If it's wedged and we can't reap within the grace window
    // below, we SIGKILL + reap it ourselves so it never leaks as a zombie/orphan.
    let pid = spawnedPid
    spawnedPid = 0
    // Abandon pre-kOpReady queued creates too — symmetric with the createSendQueue/
    // createInFlight teardown above; the onHostDied path still emits processGone for the
    // sessions left in `browsers`.
    pendingCreates.removeAll()
    let died = onHostDied
    writeLock.unlock()
    surfacePort?.close()
    // The host is gone: tear down CDP relays (free their localhost listeners +
    // clients) and FAIL any in-flight targetId waiters so enableAgentControl
    // callers don't hang forever. Mirrors shutdown()'s teardown — snapshot under
    // each lock, act OUTSIDE it (stop()/completions may block + take other locks).
    // Idempotent: a later shutdown()/terminate finds the dicts already empty.
    cdpHandlerLock.lock()
    cdpClosed = true
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
    // on main (the plugin's maps are main-thread confined). Generic-crash
    // status (-1) if it outlives the grace window.
    //
    // Two launch paths: `process` (Foundation.Process) exposes isRunning/
    // terminationStatus; the posix_spawn path has only `pid`, so we poll waitpid
    // (WNOHANG) and extract the exit code via WEXITSTATUS so the cache-lock
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
        // Still alive after the grace window (a wedged child that didn't exit on
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

  /// Process/profile-level inbound frames (browserId 0): kOpReady (carries the
  /// ad-hoc build flag, gates the create flush) and process logs.
  private func handleProcessFrame(_ op: UInt8, _ payload: [UInt8]) {
    switch op {
    case CefOp.ready:
      // Protocol handshake FIRST: refuse a version-skewed host before anything is
      // flushed to it. Byte 1 is the host's wire-protocol version; a legacy 1-byte
      // payload (pre-handshake host) reads as v0 and is refused the same way —
      // same-framing semantic drift would otherwise mis-parse or silently drop
      // frames (frozen/blank tiles with no breadcrumb).
      let hostVersion: UInt8 = payload.count >= 2 ? payload[1] : 0
      if hostVersion != CefHostProtocol.version {
        NSLog("[cef] REFUSING cef_host for profile '\(profileId)': wire-protocol " +
              "version \(hostVersion) != expected \(CefHostProtocol.version). The " +
              "resolved cef_host binary does not match this plugin build " +
              "(FLUTTER_CEF_HOST override / stale from-source build / stale embed?).")
        writeLock.lock()
        pendingCreates.removeAll()  // never flushed — the plugin fails the sessions via processGone
        writeLock.unlock()
        onProtocolMismatch?(hostVersion)
        return
      }
      let flags = payload.first ?? 0
      let adhoc = (flags & 0x01) != 0
      // Dev safety rail: an ad-hoc (mock-keychain) host must NOT load a named
      // persistent profile unless explicitly allowed, because at-rest creds
      // wouldn't be protected. Nothing has been written yet (no browser was
      // created), so refusing here leaks nothing. The plugin respawns an
      // ephemeral host for the session and re-issues createBrowser.
      let allowInsecure =
        ProcessInfo.processInfo.environment["FLUTTER_CEF_ALLOW_INSECURE_PROFILE"] == "1"
      writeLock.lock()
      let refuse = adhoc && !isEphemeral && !allowInsecure
      refused = refuse
      ready = !refuse
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
    case CefOp.log:
      let msg = String(bytes: payload, encoding: .utf8) ?? ""
      NSLog("[cef_host:\(profileId)] \(msg)")
    default:
      break
    }
  }
}
