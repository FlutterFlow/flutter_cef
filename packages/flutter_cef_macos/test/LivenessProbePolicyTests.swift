// Standalone unit tests for LivenessProbePolicy — the F-6 steady-state liveness
// watchdog decision (catch a painted-then-wedged browser; discriminate a healthy idle
// static page via a nudge before declaring a stall). Swift stdlib only, so it compiles +
// runs with `swiftc` alone (no Xcode/pod harness/Campus):
//   ./test/run_liveness_probe_tests.sh
import Foundation

@main
enum LivenessProbePolicyTests {
  static var failures = 0
  static func check(_ name: String, _ cond: Bool) {
    print((cond ? "  PASS  " : "  FAIL  ") + name)
    if !cond { failures += 1 }
  }

  static let staleness: UInt64 = 10_000_000_000 // 10s
  static let grace: UInt64 = 3_000_000_000      // 3s

  static func act(sinceLastPresentNs: UInt64, nudged: Bool = false,
                  sinceNudgeNs: UInt64 = 0) -> LivenessProbePolicy.Action {
    LivenessProbePolicy.evaluate(
      sinceLastPresentNs: sinceLastPresentNs, stalenessThresholdNs: staleness,
      nudged: nudged, sinceNudgeNs: sinceNudgeNs, nudgeGraceNs: grace)
  }

  static func main() {
    // Recently painted (incl. a live 60fps tile) → leave it alone.
    check("painted just now → healthy", act(sinceLastPresentNs: 0) == .healthy)
    check("painted 5s ago (< staleness) → healthy",
          act(sinceLastPresentNs: 5_000_000_000) == .healthy)

    // Stale + not yet nudged → discriminate (a healthy idle static page repaints; a wedged
    // one does not). NOT a stall yet — this is the key "don't false-fire on idle" guard.
    check("stale, not nudged → NUDGE (discriminate, not stall)",
          act(sinceLastPresentNs: 12_000_000_000) == .nudge)

    // Nudged, present came back (caller resets sinceLastPresent≈0 + nudged=false) → healthy.
    check("nudge landed a frame → healthy",
          act(sinceLastPresentNs: 0, nudged: false) == .healthy)

    // Nudged, still stale, grace not elapsed → keep waiting (don't declare yet).
    check("nudged, within grace → wait (healthy)",
          act(sinceLastPresentNs: 12_000_000_000, nudged: true, sinceNudgeNs: 1_000_000_000)
            == .healthy)

    // Nudged, still stale, grace elapsed with no present → WEDGED.
    check("nudged, grace elapsed, no present → declareStalled",
          act(sinceLastPresentNs: 14_000_000_000, nudged: true, sinceNudgeNs: 4_000_000_000)
            == .declareStalled)

    // Boundary: exactly at the staleness threshold is still healthy (strict <).
    check("exactly at staleness → still healthy",
          act(sinceLastPresentNs: staleness) == .nudge) // >= threshold → nudge
    check("one ns under staleness → healthy",
          act(sinceLastPresentNs: staleness - 1) == .healthy)

    print(failures == 0
      ? "\nALL LivenessProbePolicy TESTS PASSED"
      : "\n\(failures) LivenessProbePolicy TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
  }
}
