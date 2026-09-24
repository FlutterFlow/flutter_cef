// The Mach port a cef_host hands its tile surfaces over.
//
// cef_host paints each tile into an IOSurface it owns, and the plugin shows that
// surface in Flutter. Created global (`IOSurfaceIsGlobal`), a surface could be
// looked up by its small integer id from any process on the machine, so any
// local process could read live page pixels. The surfaces are private now:
// cef_host sends each new one here as a Mach port right, from the process this
// plugin spawned, and the plugin looks it up from that port. Once this process
// holds a surface, `IOSurfaceLookup` by id works inside it again (consumers that
// resolve `onSurface` ids in the app process keep working).
//
// Wire format of one message (must match SendSurface in render_handler.mm): a complex
// message with one port descriptor (the surface's send right), then
// {u32 wire browser id, u32 IOSurface id}.
import Foundation
import IOSurface

final class SurfacePort {
  /// The bootstrap name cef_host looks the port up by (`--surface-port=`).
  let name: String
  private let port: mach_port_t
  private let lock = NSLock()
  private var closed = false
  /// The newest surface cef_host sent for each browser, until it is taken.
  private var latest: [UInt32: IOSurfaceRef] = [:]
  /// The cef_host allowed to send here; messages from any other process are
  /// dropped. Set once the host is spawned.
  var senderPid: pid_t = 0

  private typealias CheckIn = @convention(c) (
    mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>
  ) -> kern_return_t

  init?() {
    // bootstrap_check_in isn't imported into Swift.
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_check_in") else {
      NSLog("[cef] surface port: bootstrap_check_in not found")
      return nil
    }
    let checkIn = unsafeBitCast(sym, to: CheckIn.self)
    let bundle = Bundle.main.bundleIdentifier ?? "flutter_cef"
    name = "\(bundle).flutter_cef.surfaces.\(getpid()).\(UUID().uuidString)"
    var p: mach_port_t = 0
    let kr = name.withCString { checkIn(bootstrap_port, $0, &p) }
    guard kr == KERN_SUCCESS else {
      NSLog("[cef] surface port: bootstrap_check_in failed (\(kr))")
      return nil
    }
    port = p
    // Room for a burst of resizes across every tile on the host.
    var limits = mach_port_limits_t(mpl_qlimit: 1024)  // MACH_PORT_QLIMIT_LARGE
    let count = mach_msg_type_number_t(
      MemoryLayout<mach_port_limits_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &limits) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        mach_port_set_attributes(mach_task_self_, port, MACH_PORT_LIMITS_INFO, $0, count)
      }
    }
  }

  deinit { close() }

  /// The surface cef_host sent for `browserId` with id `surfaceId`, or nil if it
  /// hasn't arrived. cef_host sends a surface before the present that names it,
  /// so by the time a present is read the message is queued here.
  func take(browserId: UInt32, surfaceId: IOSurfaceID) -> IOSurfaceRef? {
    lock.lock(); defer { lock.unlock() }
    drainLocked()
    guard let s = latest[browserId], IOSurfaceGetID(s) == surfaceId else { return nil }
    return s
  }

  /// Drops what is held for a browser that is going away.
  func forget(browserId: UInt32) {
    lock.lock(); defer { lock.unlock() }
    drainLocked()
    latest[browserId] = nil
  }

  func close() {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { return }
    drainLocked()
    closed = true
    latest.removeAll()
    mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
  }

  private static let bufferSize = 256

  private func drainLocked() {
    guard !closed else { return }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
    defer { buf.deallocate() }
    let header = buf.assumingMemoryBound(to: mach_msg_header_t.self)
    // The audit trailer carries the sender's pid: MACH_RCV_TRAILER_ELEMENTS(
    // MACH_RCV_TRAILER_AUDIT), a C macro Swift doesn't import.
    let auditTrailer: mach_msg_option_t = 3 << 24
    let options = MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_LARGE | auditTrailer
    while true {
      let kr = mach_msg(header, options, 0, mach_msg_size_t(Self.bufferSize), port, 0,
                        mach_port_t(MACH_PORT_NULL))
      if kr == MACH_RCV_TOO_LARGE {
        // Not ours to parse; drop it (MACH_RCV_LARGE left it queued).
        _ = mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 0, port, 0,
                     mach_port_t(MACH_PORT_NULL))
        continue
      }
      guard kr == KERN_SUCCESS else { return }  // queue empty
      handleLocked(buf)
    }
  }

  // Offsets into the message: header 24, body 4, port descriptor 12.
  private static let descNameOffset = 28
  private static let payloadOffset = 40
  private static let messageSize = 48

  private func handleLocked(_ buf: UnsafeMutableRawPointer) {
    let header = buf.assumingMemoryBound(to: mach_msg_header_t.self)
    let size = Int(header.pointee.msgh_size)
    guard header.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0,
          buf.load(fromByteOffset: 24, as: mach_msg_size_t.self) == 1,
          size == Self.messageSize else {
      mach_msg_destroy(header)  // release whatever rights it carried
      return
    }
    let surfacePort = buf.load(fromByteOffset: Self.descNameOffset, as: mach_port_t.self)
    defer { mach_port_deallocate(mach_task_self_, surfacePort) }
    // The trailer follows the message.
    let trailer = buf.load(fromByteOffset: size, as: mach_msg_audit_trailer_t.self)
    let sender = pid_t(bitPattern: trailer.msgh_audit.val.5)
    guard senderPid != 0, sender == senderPid else {
      NSLog("[cef] surface port: dropped a surface from pid \(sender)")
      return
    }
    let browserId = buf.load(fromByteOffset: Self.payloadOffset, as: UInt32.self)
    let surfaceId = buf.load(fromByteOffset: Self.payloadOffset + 4, as: UInt32.self)
    guard let surface = IOSurfaceLookupFromMachPort(surfacePort),
          IOSurfaceGetID(surface) == surfaceId else { return }
    latest[browserId] = surface
  }
}
