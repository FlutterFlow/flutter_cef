// CefProfileHost: agent control. CDP over the pipe cef_host inherits on fds
// 3/4, the per-browser relays that expose it, and browserId -> targetId
// resolution.

import Foundation

extension CefProfileHost {
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
    let epoch = agentControlEpoch[browserId] ?? 0
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
      // The tile was disposed (or agent control switched off) while the targetId
      // resolved: removeBrowser has already run its disableAgentControl, so a relay
      // installed now would keep a token-bearing listener open with no owner.
      self.browsersLock.lock(); let live = self.browsers[browserId] != nil; self.browsersLock.unlock()
      guard live, !self.cdpClosed, (self.agentControlEpoch[browserId] ?? 0) == epoch else {
        self.cdpHandlerLock.unlock()
        completion(nil)
        return
      }
      let relay = CdpRelay(sendToPipe: { [weak self] in self?.sendCdp($0) },
                           scopeTargetId: tid, pipeIds: self.cdpPipeIds)
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
    send(browserId, CefOp.resolveTargetId, [])
    // The page target may not have COMMITTED when the first probe fires — common
    // for a tile force-spawned in a burst, where GPU/page init is async after
    // create(). cef_host then finds no targetInfo and never sends kOpTargetId, so the
    // old fire-once probe silently timed out to nil (empty `webview snapshot`).
    // Re-probe within the deadline so a late-committing page still resolves. Each
    // kOpResolveTargetId uses a fresh per-browser DevTools message id (see the
    // 33858fb fix), so extra probes are harmless; handleTargetId removes the entry
    // on the first reply, stopping the retries.
    scheduleTargetIdRetry(browserId, epoch, attemptsLeft: 9)  // ~9 × 0.5s ≈ 4.5s
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.timeoutTargetId(browserId, epoch)  // fulfill with nil only if still this resolve
    }
  }

  /// Re-send kOpResolveTargetId every 0.5s while this exact resolve is still pending
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
      self.send(browserId, CefOp.resolveTargetId, [])
      self.scheduleTargetIdRetry(browserId, epoch, attemptsLeft: attemptsLeft - 1)
    }
  }

  /// Fulfill all pending targetId waiters for a browser with a real result (reader
  /// thread). The matching resolve's timer is left to no-op via the epoch guard.
  func handleTargetId(_ browserId: UInt32, _ tid: String?) {
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
    agentControlEpoch[browserId, default: 0] += 1
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
  func readCdpLoop() {
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
  func maybeRunCdpValidation() {
    guard agentControl, Self.debugEnabled else { return }
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
}
