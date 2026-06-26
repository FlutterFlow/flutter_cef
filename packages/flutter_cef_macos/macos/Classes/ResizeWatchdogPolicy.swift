// Pure decision policy for the resize watchdog (CefWebSession.resizeWatchdog) — the
// hidden/in-flight/elapsed gating, with NO dependency on Flutter, CEF, IOSurface, or the
// host IPC. Extracted so the gating that prevents the visibility/resize WEDGE (F-4: never
// force-promote a never-painted surface for a HIDDEN browser) is unit-testable standalone
// — compiles + runs with `swiftc` alone, exactly like CdpRelay's filter tests:
//
//   swiftc macos/Classes/ResizeWatchdogPolicy.swift test/ResizeWatchdogPolicyTests.swift \
//        -o /tmp/rwd && /tmp/rwd
//
// Depends only on the Swift stdlib.
import Foundation

enum ResizeWatchdogPolicy {
  /// Whether the watchdog should FORCE-PROMOTE the pending (post-resize) surface to the
  /// live texture. The fallback for a static page that produced its one post-resize frame
  /// but the present was dropped/mis-tagged.
  ///
  /// - `inFlight` / `gen` / `currentGen`: a newer resize (gen advanced) cancels this one.
  /// - `hidden`: **the F-4 fix** — while hidden the begin-frame pump is gated off, so the
  ///   pending surface is zero-filled (never painted); promoting it wedges the texture
  ///   permanently blank. Must NOT promote while hidden — wait for the native un-hide
  ///   repaint (F-1) to drive a real present that promotes through the normal path.
  /// - `elapsedNs` / `thresholdNs`: only after the grace window with no present.
  static func shouldForcePromote(inFlight: Bool, gen: UInt64, currentGen: UInt64,
                                 hidden: Bool, elapsedNs: UInt64,
                                 thresholdNs: UInt64) -> Bool {
    guard inFlight, gen == currentGen else { return false } // superseded / already promoted
    if hidden { return false }                               // F-4: never promote a hidden (blank) surface
    return elapsedNs > thresholdNs
  }

  /// Whether the watchdog should keep re-scheduling itself (stay alive) for this resize —
  /// true while the resize is still the in-flight one (incl. while hidden, so it resumes
  /// promoting once visible). Pairs with [shouldForcePromote]: exactly one is acted on.
  static func shouldKeepWaiting(inFlight: Bool, gen: UInt64, currentGen: UInt64) -> Bool {
    return inFlight && gen == currentGen
  }
}
