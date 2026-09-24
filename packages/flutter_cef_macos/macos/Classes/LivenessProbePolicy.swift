// Pure decision policy for the STEADY-STATE liveness watchdog: the
// backstop that catches a browser which painted at least once and then WEDGED (blank /
// frozen) with no other detector — the first-present watchdog retires at first paint, so
// post-establishment wedges were previously silent until relaunch.
//
// A static page legitimately produces NO presents when idle, so staleness alone is not a
// wedge. `nudge` (an opInvalidate) is the discriminator: a healthy page repaints (a present
// arrives, the caller clears the nudge); a wedged page doesn't, and after the grace we
// `declareStalled` → onPaintStalled → the consumer's existing BOUNDED recover().
//
// Dependency-light (Swift stdlib only) → unit-testable standalone with `swiftc`:
//   ./test/run_liveness_probe_tests.sh
import Foundation

enum LivenessProbePolicy {
  enum Action: Equatable { case healthy, nudge, declareStalled }

  /// Decide what the sweep should do for ONE established, visible, not-first-paint-pending
  /// browser. The caller resets `nudged=false` (and refreshes `sinceLastPresentNs≈0`) the
  /// instant ANY present arrives, so reaching the post-nudge branch means no present since.
  /// - sinceLastPresentNs: now − the browser's last present.
  /// - nudged / sinceNudgeNs: whether an opInvalidate is outstanding, and how long ago.
  static func evaluate(sinceLastPresentNs: UInt64, stalenessThresholdNs: UInt64,
                       nudged: Bool, sinceNudgeNs: UInt64, nudgeGraceNs: UInt64) -> Action {
    if sinceLastPresentNs < stalenessThresholdNs { return .healthy } // painted recently
    if !nudged { return .nudge }                                     // stale → discriminate
    // Stale AND already nudged with no present since: wedged once the grace elapses;
    // otherwise keep waiting for the nudge to land a frame.
    return sinceNudgeNs >= nudgeGraceNs ? .declareStalled : .healthy
  }

  enum PingAction: Equatable { case wait, ping, hung }

  /// What to do for a browser [evaluate] left at `.declareStalled`: no present came back
  /// from the nudge. That is either a healthy static page with nothing to paint, or a hung
  /// renderer. A renderer that answers a JS ping is alive; one that doesn't answer within
  /// `hangNs` is hung.
  /// - pingSentNs: uptime an unanswered ping went out, 0 if none is outstanding.
  /// - pingRepliedNs: uptime the last ping was answered, 0 if never. A static page is
  ///   re-pinged once per `pingIntervalNs`, not every sweep.
  static func pingAction(nowNs: UInt64, pingSentNs: UInt64, pingRepliedNs: UInt64,
                         pingIntervalNs: UInt64, hangNs: UInt64) -> PingAction {
    if pingSentNs != 0 { return nowNs &- pingSentNs >= hangNs ? .hung : .wait }
    if pingRepliedNs != 0 && nowNs &- pingRepliedNs < pingIntervalNs { return .wait }
    return .ping
  }

  /// Whether an unanswered ping would mean a hung renderer. A renderer waiting on a JS
  /// dialog, or paused in a debugger (DevTools, or a CDP client such as an agent), is
  /// alive but can't answer, so such a browser isn't pinged.
  static func mayPing(dialogsOpen: Int, devToolsOpened: Bool, cdpClientsCanPause: Bool) -> Bool {
    dialogsOpen == 0 && !devToolsOpened && !cdpClientsCanPause
  }

  /// Whether the host's GPU process was replaced after the host first painted. Chromium
  /// relaunches a GPU process that dies (under memory pressure, say), but off-screen
  /// rendering never presents again after that: every browser on the host is frozen, with
  /// JS still answering, so neither the nudge nor the ping sees it. The first frame needed
  /// the original GPU process, so a different one now is a replacement. Compares pids
  /// rather than start times, so a wall-clock step can't fake a replacement.
  /// - firstPid: the GPU process running at the host's first frame, 0 if unknown.
  /// - currentPid: the GPU process running now, 0 if there is none (between a death and
  ///   its relaunch).
  static func gpuReplaced(firstPid: Int32, currentPid: Int32) -> Bool {
    firstPid != 0 && currentPid != 0 && currentPid != firstPid
  }
}
