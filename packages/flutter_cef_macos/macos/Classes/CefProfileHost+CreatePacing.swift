// CefProfileHost: browser creates. Creates are paced through a sliding
// establishment window (see createSendQueue), and a create that never paints
// its first frame is caught by the first-present watchdog.

import Foundation

extension CefProfileHost {
  // MARK: Browser multiplexing

  /// Allocate a wire browserId for `session`, register it, and (if the host is
  /// ready) send the kOpCreateBrowser; otherwise queue it until kOpReady. Returns
  /// the assigned browserId. The scheme allowlist isn't per browser: it's a
  /// process arg fixed at spawn (shared by every browser in the profile).
  func createBrowser(_ session: CefWebSession, url: String) -> UInt32 {
    browsersLock.lock()
    let id = nextBrowserId
    // browserIds are STRICTLY MONOTONIC and never reused: nextBrowserId only ever
    // increments (never reset/decremented) and a disposed id is never recycled, so
    // guard it — the slot we're about to hand out must be FREE (never previously
    // registered). H8: a UInt32 wrap (or any bug) reusing an id would SILENTLY
    // overwrite a live sibling's slot in a release build (the old guard was a
    // debug-only `assert`, compiled out) → the reader misroutes that wire id's frames
    // (paint/cookies/CDP/relay) to the wrong tile. Make it a hard runtime invariant (a
    // free, non-reserved slot). Unreachable in practice (2^32 creates per host), so
    // fail-fast >> silent corruption.
    precondition(id != 0 && browsers[id] == nil,
                 "cef browserId space exhausted/occupied — refusing to corrupt cross-tile routing")
    nextBrowserId += 1
    browsers[id] = session
    browsersLock.unlock()
    session.attach(host: self, browserId: id)

    writeLock.lock()
    let isReady = ready
    if !isReady {
      // Queue until kOpReady; the safety-rail (F.5) may refuse to flush these. The
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

  /// Send a kOpCreateBrowser frame and mark the browserId as enqueued so its
  /// pre-connect resizes are no longer dropped. The payload is assembled HERE
  /// (not at createBrowser time) so it carries the session's current surfaceId +
  /// geometry: {u32 w}{u32 h}{f64 dpr}{u32 iosurfaceId}{utf8 url}. allowedSchemes
  /// is NOT here — it's a process arg fixed at spawn (A.4).
  private func sendCreate(_ id: UInt32, _ session: CefWebSession, _ url: String) {
    writeLock.lock()
    // Read the session's LIVE geometry + surfaceId AND write the create frame in a
    // single writeLock section, so a racing resize can neither slip between the
    // surfaceId read and the create write, nor order its kOpResize ahead of the
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
    // Producer-allocates: no sid — cef_host mints its own surface on first paint and the
    // consumer adopts it from the present. (Sending only geometry also dissolves the
    // resize-before-create / since-freed-sid race the snapshot was guarding.)
    payload.append(contentsOf: Array(url.utf8))
    createEnqueued.insert(id)
    var frame = frameBytes(id, CefOp.createBrowser, payload)
    // Create ON an authored document: its kOpSetAuthoredHtml goes out as ONE write
    // with, and ahead of, the create — cef_host stores it on its reader thread, so
    // it is in place before the browser's first request can be made.
    if let authored = session.authoredPayload(for: url) {
      frame = frameBytes(id, CefOp.setAuthoredHtml, authored) + frame
    }
    // Same for the document-start config: cef_host folds it into the browser's
    // creation info, which is the only way it reaches the renderer in time for
    // the FIRST document.
    if let docStart = session.documentStartPayload() {
      frame = frameBytes(id, CefOp.setDocumentStart, docStart) + frame
    }
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

  /// Enqueue a create for PACED sending instead of writing its kOpCreateBrowser
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
  /// off kOpPresent) before sending the following one — so each browser's first-frame GPU
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
      // kOpPresent can never be observed before the id is registered as pending (which would
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

  /// `browserId` no longer needs its establishment slot: it painted (the stable-frames
  /// count or the settle after its first paint), it was hidden, disposed or reported
  /// gone, or the backstop timed out. Free the slot and send the next queued create.
  /// Idempotent: only the first of these for a browser advances.
  func advanceCreatePacer(after browserId: UInt32, timedOut: Bool) {
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

  /// This one browser can't continue (its create failed, its renderer kept crashing,
  /// or it hung): the plugin emits processGone(`reason`) and drops the session, and
  /// the pacer advances so the rest of a burst still proceeds. Reported once per
  /// browser; the host and its other browsers carry on.
  func reportBrowserGone(_ browserId: UInt32, _ reason: String) {
    browsersLock.lock()
    guard let s = browsers[browserId], !s.goneReported else { browsersLock.unlock(); return }
    s.goneReported = true
    browsersLock.unlock()
    firstPresentArrived(browserId)  // cancel the C1 watchdog for a browser that won't paint
    onBrowserGone?(browserId, reason)
    advanceCreatePacer(after: browserId, timedOut: false)
  }

  // MARK: C1 first-present watchdog

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
  func firstPresentArrived(_ browserId: UInt32) {
    presentLock.lock()
    firstPresentPending.remove(browserId)
    watchdogArmed.remove(browserId)  // the chain ends; an unhide may re-arm a fresh one
    presentLock.unlock()
  }

  /// C1: track WasHidden state (peeked from kOpSetVisible). A hidden browser produces no
  /// frames, so the watchdog suspends rather than flagging it stalled. On UNHIDE, re-arm
  /// the watchdog for a browser that's still blank, so a genuinely-stuck now-visible tile
  /// is still caught.
  func noteVisibility(_ browserId: UInt32, visible: Bool) {
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
    send(browserId, CefOp.invalidate, [])
    NSLog("[cef] profile '\(profileId)': browser \(browserId) still blank after \(Int(firstPaintGrace))s — reporting paintStalled (consumer may recreate)")
    onPaintStalled?(browserId)
    // Re-arm: keep watching on a backoff until it paints (firstPresentArrived clears it).
    DispatchQueue.global().asyncAfter(deadline: .now() + firstPaintGrace) { [weak self] in
      self?.checkFirstPresent(browserId)
    }
  }
}
