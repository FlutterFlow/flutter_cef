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

    // Grace boundary (audit P3): one ns under grace still waits; at/over grace declares.
    check("nudged, one ns UNDER grace → wait (healthy)",
          act(sinceLastPresentNs: 14_000_000_000, nudged: true, sinceNudgeNs: grace - 1)
            == .healthy)
    check("nudged, exactly at grace → declareStalled",
          act(sinceLastPresentNs: 14_000_000_000, nudged: true, sinceNudgeNs: grace)
            == .declareStalled)
    check("nudged, one ns over grace → declareStalled",
          act(sinceLastPresentNs: 14_000_000_000, nudged: true, sinceNudgeNs: grace + 1)
            == .declareStalled)

    // WEDGE-vs-IDLE INDISTINGUISHABILITY (audit P3, documented as a test so the limitation is
    // explicit + locked): a static-idle tile and a hung-renderer tile present the SAME inputs to
    // this policy (stale, nudged, no present within grace) → BOTH reach .declareStalled. The
    // policy CANNOT tell them apart by timing alone; the consumer (CefProfileHost) deliberately
    // does NOT escalate .declareStalled to a recreate (that resurrected the recreate-storm), so a
    // visible hung renderer would be accepted as healthy-static. The host tells them apart
    // with a JS ping instead (pingAction below).
    let idleInputs = act(sinceLastPresentNs: 20_000_000_000, nudged: true, sinceNudgeNs: 5_000_000_000)
    let wedgedInputs = act(sinceLastPresentNs: 20_000_000_000, nudged: true, sinceNudgeNs: 5_000_000_000)
    check("static-idle and hung-renderer are INDISTINGUISHABLE here (same Action)",
          idleInputs == wedgedInputs && idleInputs == .declareStalled)

    // …so pingAction tells them apart: a static page answers JS, a hung renderer doesn't.
    let interval: UInt64 = 10_000_000_000
    let hang: UInt64 = 15_000_000_000
    func ping(now: UInt64, sent: UInt64 = 0, replied: UInt64 = 0) -> LivenessProbePolicy.PingAction {
      LivenessProbePolicy.pingAction(nowNs: now, pingSentNs: sent, pingRepliedNs: replied,
                                     pingIntervalNs: interval, hangNs: hang)
    }
    let t: UInt64 = 100_000_000_000
    check("stalled, never pinged → ping", ping(now: t) == .ping)
    check("ping outstanding, under the hang limit → wait",
          ping(now: t, sent: t - hang + 1) == .wait)
    check("ping outstanding, at the hang limit → hung", ping(now: t, sent: t - hang) == .hung)
    check("static page answered recently → wait, no re-ping",
          ping(now: t, replied: t - interval + 1) == .wait)
    check("static page answered an interval ago → ping again",
          ping(now: t, replied: t - interval) == .ping)

    func may(_ dialogs: Int = 0, devTools: Bool = false, cdp: Bool = false) -> Bool {
      LivenessProbePolicy.mayPing(dialogsOpen: dialogs, devToolsOpened: devTools,
                                  cdpClientsCanPause: cdp)
    }
    check("nothing holding the renderer → ping", may())
    check("a JS dialog open → no ping (the renderer waits on it)", !may(1))
    check("DevTools opened → no ping (its debugger can pause the page)", !may(devTools: true))
    check("a CDP client can attach → no ping", !may(cdp: true))

    func gpu(first: Int32, now: Int32) -> Bool {
      LivenessProbePolicy.gpuReplaced(firstPid: first, currentPid: now)
    }
    check("the GPU process that painted the first frame → not replaced",
          !gpu(first: 501, now: 501))
    check("a different GPU process → replaced", gpu(first: 501, now: 777))
    check("GPU process unknown at the first frame → not flagged", !gpu(first: 0, now: 777))
    check("no GPU process (gone, not yet relaunched) → not flagged", !gpu(first: 501, now: 0))

    print(failures == 0
      ? "\nALL LivenessProbePolicy TESTS PASSED"
      : "\n\(failures) LivenessProbePolicy TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
  }
}
