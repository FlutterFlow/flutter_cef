import Foundation

/// Pure decision logic for clearing a WEDGED resize — extracted so it can be unit-tested with
/// `swiftc` alone (no CEF, no Campus), exactly like ResizeWatchdogPolicy / LivenessProbePolicy.
///
/// PRODUCER-ALLOCATES context: `resize()` sets `resizeInFlight = true` and sends an opResize;
/// `handleFrame(opPresent)` clears it when it ADOPTS the producer's new surface. If that adopt
/// never lands (the producer freed the surface racing the present, or a frame was dropped and no
/// further paint comes — e.g. a static page), `resizeInFlight` would stay true: it blocks the
/// next `resize()` from sending (the coalescing guard) and keeps the watchdog re-kicking
/// opInvalidate forever. Clearing it after a grace is always SAFE here — there is no pending
/// consumer buffer to lose (always-latest adopts on the next present regardless), so clearing
/// only stops the blocking + the re-kick spam.
enum ResizeSupersedePolicy {
  /// Should a still-in-flight resize be force-cleared because its adopt never landed within the
  /// grace window? Returns false if not in flight (already adopted) or still within grace.
  static func shouldClearWedged(inFlight: Bool, elapsedNs: UInt64, graceNs: UInt64) -> Bool {
    guard inFlight else { return false }
    return elapsedNs > graceNs
  }
}
