// Pure decision policy for the STEADY-STATE liveness watchdog (F-6 / audit C-3): the
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
}
