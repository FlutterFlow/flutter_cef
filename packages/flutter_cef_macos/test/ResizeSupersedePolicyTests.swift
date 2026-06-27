// Standalone unit tests for ResizeSupersedePolicy — the "clear a wedged resize after the grace"
// decision used by BOTH resize() and resizeWatchdog (so a failed/never-landed adopt can't leave
// resizeInFlight stuck, blocking coalescing + re-kicking forever). Pure Swift-stdlib logic, so:
//
//   ./test/run_resize_supersede_tests.sh   (or)   swiftc macos/Classes/ResizeSupersedePolicy.swift \
//        test/ResizeSupersedePolicyTests.swift -o /tmp/rsp && /tmp/rsp
import Foundation

@main
enum ResizeSupersedePolicyTests {
  static var failures = 0
  static func check(_ name: String, _ cond: Bool) {
    print((cond ? "  PASS  " : "  FAIL  ") + name)
    if !cond { failures += 1 }
  }

  static let grace: UInt64 = 450_000_000  // 450ms, matching CefWebSession
  static let withinGrace: UInt64 = 100_000_000
  static let pastGrace: UInt64 = 500_000_000

  static func clears(inFlight: Bool = true, elapsedNs: UInt64 = pastGrace) -> Bool {
    ResizeSupersedePolicy.shouldClearWedged(
      inFlight: inFlight, elapsedNs: elapsedNs, graceNs: grace)
  }

  static func main() {
    // Not in flight (already adopted) → never clear.
    check("not in flight → no clear", !clears(inFlight: false, elapsedNs: pastGrace))
    // In flight, still within grace → keep waiting (a slow heavy page is legitimately painting).
    check("in flight within grace → no clear", !clears(elapsedNs: withinGrace))
    // In flight, past grace → clear (adopt never landed; unblock future resizes).
    check("in flight past grace → clear", clears(elapsedNs: pastGrace))
    // Boundary: exactly at grace is NOT past (strict >), one ns past IS.
    check("exactly at grace → no clear", !clears(elapsedNs: grace))
    check("one ns past grace → clear", clears(elapsedNs: grace + 1))
    // Not-in-flight dominates regardless of elapsed.
    check("not in flight + huge elapsed → no clear", !clears(inFlight: false, elapsedNs: 10 * grace))

    print(failures == 0 ? "\nALL ResizeSupersedePolicy TESTS PASSED"
                        : "\n\(failures) ResizeSupersedePolicy TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
  }
}
