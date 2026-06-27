// Standalone unit tests for ResizeWatchdogPolicy — the resize-watchdog force-promote
// gating, and specifically the F-4 fix: NEVER force-promote a pending surface while the
// browser is HIDDEN (the gated begin-frame pump never painted it, so promoting it wedges
// the texture permanently blank). ResizeWatchdogPolicy depends only on the Swift stdlib,
// so this compiles + runs without Xcode or the Flutter/pod harness:
//
//   ./test/run_resize_watchdog_tests.sh   (or)   swiftc macos/Classes/ResizeWatchdogPolicy.swift \
//        test/ResizeWatchdogPolicyTests.swift -o /tmp/rwd && /tmp/rwd
import Foundation

@main
enum ResizeWatchdogPolicyTests {
  static var failures = 0
  static func check(_ name: String, _ cond: Bool) {
    print((cond ? "  PASS  " : "  FAIL  ") + name)
    if !cond { failures += 1 }
  }

  static let threshold: UInt64 = 300_000_000  // 300ms, matching the watchdog
  static let pastGrace: UInt64 = 400_000_000
  static let withinGrace: UInt64 = 100_000_000

  static func promote(inFlight: Bool = true, gen: UInt64 = 1, currentGen: UInt64 = 1,
                      hidden: Bool = false, elapsedNs: UInt64 = pastGrace) -> Bool {
    ResizeWatchdogPolicy.shouldForcePromote(
      inFlight: inFlight, gen: gen, currentGen: currentGen,
      hidden: hidden, elapsedNs: elapsedNs, thresholdNs: threshold)
  }

  static func main() {
    // ── The F-4 fix: HIDDEN must never force-promote, no matter how long it's been ──
    check("hidden + timed-out → NO promote (the wedge guard)",
          promote(hidden: true, elapsedNs: pastGrace) == false)
    check("hidden + way past grace → still NO promote",
          promote(hidden: true, elapsedNs: threshold * 100) == false)

    // ── Visible: the normal force-promote fallback still works ──
    check("visible + in-flight + past grace → promote",
          promote(hidden: false, elapsedNs: pastGrace) == true)
    check("visible + within grace → wait, don't promote yet",
          promote(hidden: false, elapsedNs: withinGrace) == false)

    // ── Superseded / inactive resizes never promote (visible or not) ──
    check("newer resize (gen advanced) → no promote",
          promote(gen: 1, currentGen: 2, elapsedNs: pastGrace) == false)
    check("not in flight (already promoted) → no promote",
          promote(inFlight: false, elapsedNs: pastGrace) == false)
    check("newer resize while hidden → no promote",
          promote(gen: 1, currentGen: 2, hidden: true, elapsedNs: pastGrace) == false)

    // ── shouldKeepWaiting: the watchdog stays alive while the resize is current, INCLUDING
    //    while hidden (so it resumes promoting once visible) — independent of `hidden`. ──
    check("keep waiting while in-flight + current (visible)",
          ResizeWatchdogPolicy.shouldKeepWaiting(inFlight: true, gen: 1, currentGen: 1) == true)
    check("keep waiting while in-flight + current (hidden too)",
          ResizeWatchdogPolicy.shouldKeepWaiting(inFlight: true, gen: 1, currentGen: 1) == true)
    check("stop waiting once superseded",
          ResizeWatchdogPolicy.shouldKeepWaiting(inFlight: true, gen: 1, currentGen: 2) == false)
    check("stop waiting once promoted (not in flight)",
          ResizeWatchdogPolicy.shouldKeepWaiting(inFlight: false, gen: 1, currentGen: 1) == false)

    print(failures == 0
      ? "\nALL ResizeWatchdogPolicy TESTS PASSED"
      : "\n\(failures) ResizeWatchdogPolicy TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
  }
}
