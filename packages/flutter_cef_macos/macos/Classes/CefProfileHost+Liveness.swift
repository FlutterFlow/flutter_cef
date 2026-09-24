// CefProfileHost: the steady-state liveness sweep, and the GPU-process check
// that runs with it.

import Foundation

extension CefProfileHost {
  // ── F-6: steady-state liveness watchdog ─────────────────────────────────────────────
  // The first-paint watchdog RETIRES at first paint (firstPresentArrived), so a
  // browser that painted ≥1 frame then WEDGES (renderer/GPU stall inside a shared host
  // that keeps the pipe alive, so no processGone) had NO detector — silent blank until
  // relaunch. This periodic sweep covers steady state. A static page legitimately idles
  // (no presents), so staleness alone isn't a wedge: a discriminating kOpInvalidate is sent
  // first (a healthy page repaints → a present lands → cleared); only if no present follows
  // within the grace is paintStalled reported, routing into the consumer's BOUNDED recover.
  // Decision logic is in LivenessProbePolicy (standalone-unit-tested).

  /// The page's JS dialog `bid` was answered, so its renderer runs again.
  func noteDialogAnswered(_ bid: UInt32) {
    browsersLock.lock()
    if let s = browsers[bid], s.livenessDialogsOpen > 0 { s.livenessDialogsOpen -= 1 }
    browsersLock.unlock()
  }

  /// DevTools opened on `bid`. Its debugger can pause the page for as long as the
  /// user likes, so the liveness ping leaves that browser alone from now on.
  func noteDevToolsOpened(_ bid: UInt32) {
    browsersLock.lock()
    if let s = browsers[bid] { s.livenessDevToolsOpened = true; s.livenessPingSentAt = 0 }
    browsersLock.unlock()
  }

  /// Start the periodic liveness sweep once (idempotent). Called after the reader is up.
  func startLivenessSweep() {
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
    guard !wedgeEnded else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    // 1) Snapshot ESTABLISHED browsers + their liveness state under browsersLock.
    browsersLock.lock()
    var cands: [(bid: UInt32, sinceLast: UInt64, nudgedAt: UInt64,
                 pingSentAt: UInt64, pingRepliedAt: UInt64, mayPing: Bool)] = []
    for (bid, s) in browsers where s.firstPresentSeen && !s.goneReported {
      let mayPing = LivenessProbePolicy.mayPing(
        dialogsOpen: s.livenessDialogsOpen, devToolsOpened: s.livenessDevToolsOpened,
        cdpClientsCanPause: cdpClientsCanPause)
      if !mayPing { s.livenessPingSentAt = 0 }
      cands.append((bid, now &- s.lastPresentNs, s.livenessNudgedAt,
                    mayPing ? s.livenessPingSentAt : 0, s.livenessPingRepliedAt, mayPing))
    }
    let firstGpuPid = gpuPidAtFirstPresent
    browsersLock.unlock()
    // A replaced GPU process leaves every browser on this host frozen for good.
    if firstGpuPid != 0 {
      let gpuPid = Self.gpuProcessPid(of: hostPid())
      if LivenessProbePolicy.gpuReplaced(firstPid: firstGpuPid, currentPid: gpuPid) {
        endWedgedHost("GPU process \(gpuPid) replaced \(firstGpuPid), which painted the first frame")
        return
      }
    }
    if !cands.isEmpty {
      // 2) Exclude hidden (legitimately frameless) + still-first-paint-pending (the first-
      //    paint watchdog owns those). presentLock is taken AFTER releasing browsersLock —
      //    never nested — matching the host's browsersLock→presentLock order, so no deadlock.
      presentLock.lock()
      let hidden = hiddenBrowsers
      let pending = firstPresentPending
      presentLock.unlock()
      // A ping that went out before a browser was hidden says nothing about it now.
      browsersLock.lock()
      for c in cands where c.pingSentAt != 0 && (hidden.contains(c.bid) || pending.contains(c.bid)) {
        browsers[c.bid]?.livenessPingSentAt = 0
      }
      browsersLock.unlock()
      for c in cands where !hidden.contains(c.bid) && !pending.contains(c.bid) {
        // A renderer that has left the liveness ping unanswered this long is hung. The
        // nudge can't tell: the browser re-presents its last frame even for a hung renderer.
        // Only this browser is dropped: its siblings on the host are fine.
        if LivenessProbePolicy.pingAction(
             nowNs: now, pingSentNs: c.pingSentAt, pingRepliedNs: c.pingRepliedAt,
             pingIntervalNs: livenessStalenessNs, hangNs: livenessHangNs) == .hung {
          NSLog("[cef] profile '\(profileId)': browser \(c.bid)'s renderer left the liveness ping unanswered for \(livenessHangNs / 1_000_000_000)s — reporting it gone")
          reportBrowserGone(c.bid, "crashed")
          continue
        }
        let nudged = c.nudgedAt != 0
        let action = LivenessProbePolicy.evaluate(
          sinceLastPresentNs: c.sinceLast, stalenessThresholdNs: livenessStalenessNs,
          nudged: nudged, sinceNudgeNs: nudged ? (now &- c.nudgedAt) : UInt64(0),
          nudgeGraceNs: livenessGraceNs)
        switch action {
        case .healthy:
          break
        case .nudge:
          // A browser that has PAINTED but produced no frame for a while: nudge it once with a
          // full-view repaint. A genuinely wedged/evicted VISIBLE surface has real damage to
          // repair, so this produces a present (recovered → healthy next cycle). A STATIC idle
          // page (a counter, a finished form) has nothing new to paint, so it produces NO present
          // — and that is HEALTHY, not wedged (it is showing correct content; the begin-frame
          // pump simply has nothing to draw). See .declareStalled.
          send(c.bid, CefOp.invalidate, [])
          browsersLock.lock(); browsers[c.bid]?.livenessNudgedAt = now; browsersLock.unlock()
          // Ping the renderer too, at most once per staleness window: a static page answers
          // it, a hung renderer doesn't (checked at the top of the loop).
          if LivenessProbePolicy.pingAction(
               nowNs: now, pingSentNs: c.pingSentAt, pingRepliedNs: c.pingRepliedAt,
               pingIntervalNs: livenessStalenessNs, hangNs: livenessHangNs) == .ping,
             c.mayPing {
            let id = Self.livenessPingId
            var p: [UInt8] = [UInt8(id >> 24 & 0xff), UInt8(id >> 16 & 0xff),
                              UInt8(id >> 8 & 0xff), UInt8(id & 0xff)]
            p.append(contentsOf: Array("1".utf8))
            browsersLock.lock(); browsers[c.bid]?.livenessPingSentAt = now; browsersLock.unlock()
            send(c.bid, CefOp.evalReturning, p)
          }
        case .declareStalled:
          // The nudge above did NOT extract a frame. For an ESTABLISHED (already-painted) tile
          // this means STATIC-IDLE, not wedged — escalating to onPaintStalled here recreate-
          // looped every static tile (counter / status / checklist): paintStalled → recover →
          // paint → idle → paintStalled, ~every 10s, forever (observed: 36 stalls / 33 browsers
          // in one session). A converged idle tile is healthy by definition; we keep serving its
          // last good frame. Do NOT recreate. (Never-painted tiles are owned by the separate
          // first-paint watchdog via firstPresentPending; genuine renderer death is caught by
          // OnRenderProcessTerminated; eviction-while-hidden by the F-1 un-hide repaint.) Leave
          // nudgedAt set so we don't re-nudge every cycle; a real future repaint clears it.
          //
          // A VISIBLE renderer that HANGS post-establishment (a deadlock that keeps the process
          // alive, so OnRenderProcessTerminated never fires) looks the same here, so it is caught
          // by the JS ping sent with the nudge instead. A replaced GPU process, which leaves JS
          // answering but the view frozen, is caught by the GPU check above.
          if Self.debugEnabled {
            NSLog("[cef] profile '\(profileId)': browser \(c.bid) idle (no frames) — accepting as healthy-static (not recreating)")
          }
        }
      }
    }
    scheduleLivenessSweep()
  }

  func hostPid() -> pid_t {
    writeLock.lock(); defer { writeLock.unlock() }
    return process?.processIdentifier ?? spawnedPid
  }

  /// Looks up the GPU process that painted the host's first frame; see
  /// [gpuPidAtFirstPresent].
  func recordGpuProcess() {
    let pid = Self.gpuProcessPid(of: hostPid())
    browsersLock.lock()
    if gpuPidAtFirstPresent == 0 { gpuPidAtFirstPresent = pid }
    browsersLock.unlock()
  }

  /// The pid of `host`'s GPU process, or 0 if it has none. It runs as the generic
  /// `cef_host Helper`, so it is told apart by `--type=gpu-process`.
  private static func gpuProcessPid(of host: pid_t) -> pid_t {
    guard host > 0 else { return 0 }
    // Size the buffer from a first call: a host with many renderers has more
    // children than any fixed guess.
    let needed = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(host), nil, 0)
    guard needed > 0 else { return 0 }
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
    let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(host), &pids,
                              Int32(pids.count * MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return 0 }
    let marker = "--type=gpu-process"
    var args = [UInt8](repeating: 0, count: 64 * 1024)
    for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
      var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
      var size = args.count
      guard sysctl(&mib, 3, &args, &size, nil, 0) == 0 else { continue }
      let isGpu = args.withUnsafeBytes { buf in
        marker.withCString { memmem(buf.baseAddress, size, $0, strlen($0)) != nil }
      }
      if isGpu { return pid }
    }
    return 0
  }

  /// Waits (polling) until `pid` has exited, for at most `timeout` seconds. Doesn't
  /// reap it; its owner does.
  static func waitForExit(_ pid: pid_t, timeout: TimeInterval) {
    guard pid > 0 else { return }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      var info = proc_bsdinfo()
      let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
      // Gone, or a zombie waiting to be reaped: either way it has stopped running.
      if n != Int32(MemoryLayout<proc_bsdinfo>.size) || info.pbi_status == UInt32(SZOMB) { return }
      usleep(50_000)
    }
  }

  /// Ends a host whose browsers can't paint again. The plugin then reports
  /// processGone("crashed") for each of them, and the consumer's recreate path
  /// starts a fresh host, the same way it recovers from a real crash.
  private func endWedgedHost(_ why: String) {
    writeLock.lock()
    let alive = running && !crashed
    writeLock.unlock()
    let pid = hostPid()
    guard alive, pid > 0, !wedgeEnded else { return }
    wedgeEnded = true
    NSLog("[cef] profile '\(profileId)': \(why) — ending cef_host \(pid) so its views are recreated")
    kill(pid, SIGKILL)
  }
}
