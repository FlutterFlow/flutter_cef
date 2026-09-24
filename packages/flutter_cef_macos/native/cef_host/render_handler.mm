#include "render_handler.h"

#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "ipc.h"

namespace cef_host {

mach_port_t g_surface_port = MACH_PORT_NULL;

// External begin-frame pump. window_info.external_begin_frame_enabled (set in DoCreateBrowser)
// turns OFF CEF's internal frame timer, so the GPU/Viz compositor produces a frame ONLY when we
// call SendExternalBeginFrame — which, unlike Invalidate(), deterministically drives one frame
// the scheduler cannot coalesce away. We are now the frame clock. This re-posts itself per live
// slot on the CEF UI thread; it dies when the slot is disposed (LookupWireId -> null) and idles
// to a slow poll while the tile is hidden (no begin-frame -> the off-screen browser costs ~zero,
// and WasHidden(true) already stopped its rendering). Started in HostClient::OnAfterCreated.
// Runs on TID_UI, so slot->visible / slot->browser need no lock (only UI-thread code touches them).
void PumpBeginFrame(uint32_t wire_id) {
  std::shared_ptr<Slot> slot = LookupWireId(wire_id);
  if (!slot || !slot->browser) return;  // disposed mid-flight — let the pump die
  if (slot->visible) slot->browser->GetHost()->SendExternalBeginFrame();
  slot->diag_pump_ticks++;  // DIAG
  if (g_debug && slot->diag_pump_ticks % 120 == 0)
    SendLog(wire_id, "diag wire=" + std::to_string(wire_id) +
                         " pumpTicks=" + std::to_string(slot->diag_pump_ticks) +
                         " paints=" + std::to_string(slot->diag_paint_count) +
                         " visible=" + std::to_string(slot->visible ? 1 : 0));
  CefPostDelayedTask(TID_UI, base::BindOnce(&PumpBeginFrame, wire_id),
                     slot->visible ? slot->pump_interval_ms : 100);
}

void ApplyBlankFirstNav(const std::shared_ptr<Slot>& slot) {
  if (slot->pending_nav_url.empty() || !slot->browser) return;
  std::string nav = slot->pending_nav_url;
  slot->pending_nav_url.clear();
  if (auto frame = slot->browser->GetMainFrame()) frame->LoadURL(nav);
}

namespace {

// Process-wide Metal context for the GPU-blit present path (CompositeMetalLocked). One device +
// queue for the whole cef_host process; created lazily on first accelerated paint. MRC build, so
// these are owned singletons we intentionally never release. EnsureMetal() returns false (once,
// then cached) if Metal is unavailable — callers fall back to the CPU composite.
static id<MTLDevice> g_mtl_device = nil;
static id<MTLCommandQueue> g_mtl_queue = nil;
static bool EnsureMetal() {
  static bool tried = false;
  if (g_mtl_device) return true;
  if (tried) return false;
  tried = true;
  g_mtl_device = MTLCreateSystemDefaultDevice();
  if (!g_mtl_device) return false;
  g_mtl_queue = [g_mtl_device newCommandQueue];
  return g_mtl_queue != nil;
}

// One surface handed to the plugin. Must match SurfacePort.swift.
struct SurfaceMsg {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t surface;
  uint32_t browser_id;
  uint32_t surface_id;
};
static_assert(sizeof(SurfaceMsg) == 48, "must match SurfacePort.swift");

// Sends `surface` to the plugin before the present that names it: the plugin
// reads presents off the IPC socket and takes the surface from its port, where
// this message is already queued by then.
void SendSurface(uint32_t browser_id, IOSurfaceRef surface) {
  if (g_surface_port == MACH_PORT_NULL) return;
  SurfaceMsg msg = {};
  msg.header.msgh_bits =
      MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  msg.header.msgh_size = sizeof(msg);
  msg.header.msgh_remote_port = g_surface_port;
  msg.body.msgh_descriptor_count = 1;
  msg.surface.name = IOSurfaceCreateMachPort(surface);
  msg.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
  msg.surface.type = MACH_MSG_PORT_DESCRIPTOR;
  msg.browser_id = browser_id;
  msg.surface_id = IOSurfaceGetID(surface);
  const kern_return_t kr =
      mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(msg), 0,
               MACH_PORT_NULL, 100, MACH_PORT_NULL);
  if (kr != KERN_SUCCESS) {
    // Not sent: the surface right is still ours.
    mach_port_deallocate(mach_task_self(), msg.surface.name);
    fprintf(stderr, "[cef_host] handing a surface to the plugin failed: %d\n",
            kr);
  }
}

// Copy a tight BGRA source rect into the surface at (dx,dy), clipped to the
// surface bounds. CEF may deliver a frame at the pre-resize size while a resize
// is in flight, so over-large sources are clipped rather than rejected.
void BlitBGRA(uint8_t* dst, size_t dst_stride, int surf_w, int surf_h,
              const uint8_t* src, int src_w, int src_h, int dx, int dy) {
  for (int row = 0; row < src_h; ++row) {
    const int y = dy + row;
    if (y < 0 || y >= surf_h) continue;
    const int x0 = dx < 0 ? 0 : dx;
    const int sx0 = x0 - dx;
    int w = src_w - sx0;
    if (x0 + w > surf_w) w = surf_w - x0;
    if (w <= 0) continue;
    memcpy(
        dst + static_cast<size_t>(y) * dst_stride + static_cast<size_t>(x0) * 4,
        src + (static_cast<size_t>(row) * src_w + sx0) * 4,
        static_cast<size_t>(w) * 4);
  }
}

// ---- Render handler: OSR -> shared IOSurface ----
// One handler per browser; it holds a shared_ptr to that browser's Slot and
// derefs it instead of the old process-global surface/geometry. The CefBrowser*
// the callbacks are handed is ignored (this handler already owns exactly one
// slot — no map lookup on the hot paint path). All surface/popup access is under
// slot_->surface_mutex; OnPaint/OnAcceleratedPaint re-check slot_->surface after
// taking the lock, since OnBeforeClose nulls + CFReleases it under the same lock
// (a GPU-thread paint racing UI-thread teardown then sees null and no-ops).
class HostRenderHandler : public CefRenderHandler {
 public:
  explicit HostRenderHandler(std::shared_ptr<Slot> slot)
      : slot_(std::move(slot)) {}

  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    rect = CefRect(0, 0, slot_->width, slot_->height);
  }

  // The REAL display the app sits on (DIP). Reporting screen == the tile's own
  // viewport (the old behavior) is a textbook headless/OSR fingerprint — bot
  // detectors flag `window.screen.width == innerWidth`, `screen.colorDepth == 0`.
  // This is not spoofing: it's the actual monitor the browser is on. GetViewRect
  // (the render size) stays tile-sized, exactly like a real browser window is
  // smaller than its screen. Falls back to a plausible frame with no display
  // (headless CI). Returns rect(top-left DIP) + work-area (menu-bar/Dock excluded).
  static void RealScreenDip(CefRect& full, CefRect& work) {
    NSScreen* s = NSScreen.mainScreen;
    if (!s) {  // headless: a common 14" default so the value is never the tell
      full = CefRect(0, 0, 1512, 982);
      work = CefRect(0, 38, 1512, 982 - 38);
      return;
    }
    NSRect f = s.frame;          // points == DIP on macOS; primary screen at (0,0)
    NSRect v = s.visibleFrame;   // minus menu bar (top) + Dock; Cocoa bottom-left
    const int H = static_cast<int>(f.size.height);
    full = CefRect(0, 0, static_cast<int>(f.size.width), H);
    // Flip Cocoa bottom-left visibleFrame to CEF top-left work area.
    work = CefRect(static_cast<int>(v.origin.x),
                   H - static_cast<int>(v.origin.y + v.size.height),
                   static_cast<int>(v.size.width),
                   static_cast<int>(v.size.height));
  }

  // Report the device scale so CEF renders the OSR buffer at logical*dpr
  // (Retina-native) instead of 1x upscaled — fixes the blur on HiDPI displays —
  // AND the real screen bounds + color depth (see RealScreenDip).
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    info.device_scale_factor = static_cast<float>(slot_->dpr);
    info.depth = 24;             // screen.colorDepth — 0 was a headless tell
    info.depth_per_component = 8;
    info.is_monochrome = 0;
    CefRect full, work;
    RealScreenDip(full, work);
    info.rect = full;
    info.available_rect = work;
    return true;
  }

  // The browser's root-window rect on screen (DIP). Without this CEF falls back
  // to GetViewRect → window.outerWidth/Height == innerWidth/Height and
  // screenX/screenY == 0, another OSR tell. Report a plausible window frame at a
  // non-zero offset, taller than the view by typical browser chrome, so
  // outerHeight > innerHeight like a real window. Popups/IME are composited into
  // our own surface from view-relative coords, so this offset doesn't move them.
  bool GetRootScreenRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    constexpr int kChromeH = 87;  // tab strip + toolbar, ~ real Chrome on macOS
    rect = CefRect(100, 80, slot_->width, slot_->height + kChromeH);
    return true;
  }

  // Present the just-painted slot surface, TAGGING the frame with its IOSurface id
  // (BE u32). The host (Swift) uses this to promote a resized "pending" surface to the
  // Flutter texture only once a paint into THAT surface has actually landed — until
  // then it keeps serving the old surface, so a resize never flashes the fresh,
  // zero-filled IOSurface. Caller holds slot_->surface_mutex.
  // The present carries the SID of the surface presented AND the PHYSICAL pixel dims of the
  // frame that was actually composited into it (srcW/srcH). On a device-scale (zoom) resize
  // the host swaps to the new-size surface synchronously while the renderer re-rasters
  // async, so the first frame after a resize is the renderer's OLD-scale frame landing in
  // the NEW surface. With only a sid the consumer can't tell that provisional wrong-scale
  // frame from a correct one and promotes it → content renders too big/small. Carrying the
  // composited dims lets the consumer promote ONLY a frame whose dims match the new surface
  // (round(logical*dpr)), so it keeps serving the last correct-scale buffer until the real
  // re-rastered frame lands. UI thread; caller holds slot_->surface_mutex.
  void SendPresentLocked(int srcW, int srcH) {
    uint32_t sid = slot_->surface ? IOSurfaceGetID(slot_->surface) : 0;
    auto be32 = [](uint8_t* o, uint32_t v) {
      o[0] = (v >> 24) & 0xff; o[1] = (v >> 16) & 0xff;
      o[2] = (v >> 8) & 0xff;  o[3] = v & 0xff;
    };
    uint8_t p[12];
    be32(p, sid);
    be32(p + 4, static_cast<uint32_t>(srcW < 0 ? 0 : srcW));
    be32(p + 8, static_cast<uint32_t>(srcH < 0 ? 0 : srcH));
    SendFrame(slot_->browser_id, kOpPresent, p, 12);
  }

  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
               const void* buffer, int width, int height) override {
    ApplyBlankFirstNav(slot_);
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    // PRODUCER-ALLOCATES (software path): mint/resize the surface to the painted VIEW dims
    // before the guard, mirroring OnAcceleratedPaint — else the surface is never created and
    // nothing paints. A POPUP paint composites onto the existing view surface (don't resize).
    if (type == PET_VIEW) EnsureSurfaceForPaint(width, height);
    if (!slot_->surface) return;
    if (IOSurfaceLock(slot_->surface, 0, nullptr) != kIOReturnSuccess) return;
    uint8_t* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(slot_->surface));
    const size_t dst_stride = IOSurfaceGetBytesPerRow(slot_->surface);
    const int surf_w = static_cast<int>(IOSurfaceGetWidth(slot_->surface));
    const int surf_h = static_cast<int>(IOSurfaceGetHeight(slot_->surface));
    const uint8_t* src = static_cast<const uint8_t*>(buffer);
    // OnPopupSize reports the popup rect in LOGICAL (DIP) coords, but we blit
    // into the physical (device-scaled) IOSurface — so the paint offset must be
    // scaled by the device pixel ratio. Without this the dropdown paints at the
    // wrong position on HiDPI and mouse clicks miss it (CEF hit-tests the popup
    // against the logical rect, which no longer matches where it was drawn).
    const int popup_px = static_cast<int>(slot_->popup_rect.x * slot_->dpr);
    const int popup_py = static_cast<int>(slot_->popup_rect.y * slot_->dpr);
    if (type == PET_VIEW) {
      BlitBGRA(dst, dst_stride, surf_w, surf_h, src, width, height, 0, 0);
      // Keep an open popup (<select> dropdown) painted on top of the view.
      if (slot_->popup_visible && !slot_->popup_buf.empty()) {
        BlitBGRA(dst, dst_stride, surf_w, surf_h, slot_->popup_buf.data(),
                 slot_->popup_w, slot_->popup_h, popup_px, popup_py);
      }
    } else if (type == PET_POPUP) {
      slot_->popup_w = width;
      slot_->popup_h = height;
      slot_->popup_buf.assign(src, src + static_cast<size_t>(width) * height * 4);
      BlitBGRA(dst, dst_stride, surf_w, surf_h, src, width, height, popup_px,
               popup_py);
    }
    IOSurfaceUnlock(slot_->surface, 0, nullptr);
    // PET_VIEW reports the painted view-frame dims (the size-gate signal); a PET_POPUP
    // repaint didn't rescale the view, so report the surface dims (always correct-scale).
    SendPresentLocked(type == PET_VIEW ? width : surf_w,
                      type == PET_VIEW ? height : surf_h);
  }

  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override {
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      slot_->popup_visible = show;
      if (!show) {
        slot_->popup_buf.clear();
        slot_->popup_rect = CefRect();
      }
    }
    // Repaint the view so the render path switches: on show, the next view paint
    // takes the software-composite branch (to draw the popup on top); on hide, it
    // returns to zero-copy and the dropdown's pixels are gone.
    if (browser) browser->GetHost()->Invalidate(PET_VIEW);
  }

  void OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    slot_->popup_rect = rect;
  }

  // Copy a popup's GPU surface into the CPU popup buffer so the software
  // composite can draw it over the view. Caller holds slot_->surface_mutex.
  void CopyAccelToPopupBuf(IOSurfaceRef src) {
    if (IOSurfaceLock(src, kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess) {
      return;
    }
    const int pw = static_cast<int>(IOSurfaceGetWidth(src));
    const int ph = static_cast<int>(IOSurfaceGetHeight(src));
    const size_t ss = IOSurfaceGetBytesPerRow(src);
    const auto* s = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(src));
    slot_->popup_w = pw;
    slot_->popup_h = ph;
    slot_->popup_buf.resize(static_cast<size_t>(pw) * ph * 4);
    for (int y = 0; y < ph; ++y) {
      memcpy(slot_->popup_buf.data() + static_cast<size_t>(y) * pw * 4,
             s + static_cast<size_t>(y) * ss, static_cast<size_t>(pw) * 4);
    }
    IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, nullptr);
  }

  // PRODUCER-ALLOCATES: ensure slot_->surface is EXACTLY sw x sh — the dims CEF actually
  // painted (view_src). cef_host owns this surface (it mints it, the consumer adopts it by id
  // from the present). Because the blit dst is then the same size as the src, the copy is 1:1
  // and can NEVER crop (src>dst) or leave stale margins (src<dst) — the entire wrong-size class
  // is structurally gone. Reallocates on first paint or any size/dpr change (CEF re-rasters at
  // the new logical×dpr → a new view_src size → here). Caller holds slot_->surface_mutex.
  // Releases cef_host's ref on the OLD surface immediately; the consumer's CVPixelBuffer keeps
  // the old one alive (independent refcount) until it adopts the new id, so no UAF.
  void EnsureSurfaceForPaint(int sw, int sh) {
    if (sw < 1 || sh < 1) return;  // popup-only repaint (view_src null) keeps the current surface
    if (slot_->closing) return;    // a paint racing teardown must not re-mint a surface (leak)
    IOSurfaceRef cur = slot_->surface;
    if (cur && static_cast<int>(IOSurfaceGetWidth(cur)) == sw &&
        static_cast<int>(IOSurfaceGetHeight(cur)) == sh) {
      return;  // already the right size — the common steady-state path, zero allocation
    }
    const size_t bpr = ((static_cast<size_t>(sw) * 4) + 63) & ~static_cast<size_t>(63);
    NSDictionary* props = @{
      (id)kIOSurfaceWidth : @(sw),
      (id)kIOSurfaceHeight : @(sh),
      (id)kIOSurfaceBytesPerElement : @(4),
      (id)kIOSurfaceBytesPerRow : @(static_cast<long>(bpr)),
      (id)kIOSurfaceAllocSize : @(static_cast<long>(bpr * sh)),
      (id)kIOSurfacePixelFormat : @(0x42475241),  // 'BGRA' = kCVPixelFormatType_32BGRA
    };
    IOSurfaceRef fresh = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!fresh) {
      SendLog(slot_->browser_id, "EnsureSurfaceForPaint: IOSurfaceCreate failed");
      return;  // keep the old surface; next paint retries
    }
    slot_->surface = fresh;  // cef_host's +1 (mint, not Lookup)
    SendSurface(slot_->browser_id, fresh);
    [slot_->dst_mtl release];
    slot_->dst_mtl = nil;
    slot_->dst_mtl_sid = 0;  // the cached Metal wrap pointed at `cur`; rebuilt this same paint
    if (cur) CFRelease(cur);  // drop cef_host's +1 on the old; consumer's CVPixelBuffer still holds it
  }

  // Software-composite the view (optional GPU surface, stride-aware) and the open
  // popup into the host-allocated slot_->surface and present it. Used only while
  // a <select> dropdown is open, since a popup can't ride the zero-copy texture.
  // Caller holds slot_->surface_mutex.
  void CompositeSoftwareLocked(IOSurfaceRef view_src) {
    // Producer-allocates: size the host surface to the painted view BEFORE compositing, so the
    // memcpy below is 1:1 (no crop/partial). Popup-only repaint (view_src null) keeps the surface.
    if (view_src) {
      EnsureSurfaceForPaint(static_cast<int>(IOSurfaceGetWidth(view_src)),
                            static_cast<int>(IOSurfaceGetHeight(view_src)));
    }
    if (!slot_->surface) return;
    if (IOSurfaceLock(slot_->surface, 0, nullptr) != kIOReturnSuccess) return;
    auto* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(slot_->surface));
    const size_t ds = IOSurfaceGetBytesPerRow(slot_->surface);
    const int dw = static_cast<int>(IOSurfaceGetWidth(slot_->surface));
    const int dh = static_cast<int>(IOSurfaceGetHeight(slot_->surface));
    // The composited frame's physical dims (for the size-gated present). A popup-only
    // repaint (view_src == null) re-presents the existing view surface as-is → report the
    // surface dims so it counts as correct-scale.
    int srcW = dw, srcH = dh;
    if (view_src &&
        IOSurfaceLock(view_src, kIOSurfaceLockReadOnly, nullptr) ==
            kIOReturnSuccess) {
      srcW = static_cast<int>(IOSurfaceGetWidth(view_src));
      srcH = static_cast<int>(IOSurfaceGetHeight(view_src));
      const auto* s = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(view_src));
      const size_t ss = IOSurfaceGetBytesPerRow(view_src);
      const int rows = std::min<int>(dh, IOSurfaceGetHeight(view_src));
      const size_t rb = std::min<size_t>(
          static_cast<size_t>(dw) * 4,
          static_cast<size_t>(IOSurfaceGetWidth(view_src)) * 4);
      for (int y = 0; y < rows; ++y) {
        memcpy(dst + static_cast<size_t>(y) * ds, s + static_cast<size_t>(y) * ss, rb);
      }
      IOSurfaceUnlock(view_src, kIOSurfaceLockReadOnly, nullptr);
    }
    if (slot_->popup_visible && !slot_->popup_buf.empty()) {
      const int px = static_cast<int>(slot_->popup_rect.x * slot_->dpr);
      const int py = static_cast<int>(slot_->popup_rect.y * slot_->dpr);
      BlitBGRA(dst, ds, dw, dh, slot_->popup_buf.data(), slot_->popup_w,
               slot_->popup_h, px, py);
    }
    IOSurfaceUnlock(slot_->surface, 0, nullptr);
    SendPresentLocked(srcW, srcH);
  }

  // GPU-blit composite: copy CEF's accelerated view surface into the host-owned slot_->surface
  // with a Metal blit instead of the CPU IOSurfaceLock+memcpy in CompositeSoftwareLocked. CEF's
  // contract reclaims view_src back to its pool when this callback returns, so the blit's GPU READ
  // of view_src MUST complete before we return — hence waitUntilCompleted (the existing CPU path's
  // IOSurfaceLock+memcpy is likewise synchronous). The win is keeping frame data on the GPU
  // end-to-end: on discrete-GPU / Windows / Linux this avoids the GPU->CPU readback the memcpy
  // forces; on unified-memory Apple Silicon it's ~neutral. Caller holds slot_->surface_mutex.
  // Falls back to the CPU composite if Metal is unavailable or the IOSurface->texture wrap fails.
  // Popups never take this path — an open <select> dropdown is CPU-composited over the view.
  //
  // PORTING: this is the macOS half of the cross-platform "copy CEF's accelerated surface into a
  // client-owned texture via a GPU blit, INSIDE the callback" pattern that CEF's pool contract
  // mandates on every platform. A port swaps only this one method: Windows takes the D3D11 shared
  // HANDLE from CefAcceleratedPaintInfo -> ID3D11DeviceContext::CopyResource; Linux takes the
  // dmabuf fd -> import as a GL/VK image -> blit. The OnAcceleratedPaint call site, the
  // reclaim-at-return contract, and the present protocol are identical across platforms.
  void CompositeMetalLocked(IOSurfaceRef view_src) {
    // Producer-allocates: size the host surface to the painted view first → the blit is 1:1.
    if (view_src) {
      EnsureSurfaceForPaint(static_cast<int>(IOSurfaceGetWidth(view_src)),
                            static_cast<int>(IOSurfaceGetHeight(view_src)));
    }
    if (!slot_->surface) return;
    bool blitted = false;
    // Composited frame's physical dims — now ALWAYS == slot_->surface dims (producer-allocated),
    // so the present's srcW/srcH the consumer adopts always match the surface it Lookups.
    const int srcW = view_src ? static_cast<int>(IOSurfaceGetWidth(view_src)) : 0;
    const int srcH = view_src ? static_cast<int>(IOSurfaceGetHeight(view_src)) : 0;
    // DIAG (screen-independent verification — the box may be display-asleep, so a screenshot
    // can't tell content from blank): sample the renderer's composited frame on a throttle and
    // classify a 9-point grid. content>0 means real pixels landed; white==9 means only the
    // opaque background (page didn't paint content); clear==9 means a zero-filled / never-
    // committed frame (the shared-GPU multiplex failure). Under FLUTTER_CEF_DEBUG only.
    static const int kDiagEvery = []() {
      const char* e = std::getenv("FLUTTER_CEF_DIAGPX_EVERY");
      int n = e ? atoi(e) : 60;
      return n > 0 ? n : 60;  // sample 1-in-N accelerated paints (default 60 ≈ 1/s; set 6 ≈ 10/s)
    }();
    if (view_src && (slot_->diag_paint_count % kDiagEvery) == 2 &&
        g_debug &&
        IOSurfaceLock(view_src, kIOSurfaceLockReadOnly, nullptr) == kIOReturnSuccess) {
      const auto* base = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(view_src));
      const size_t bpr = IOSurfaceGetBytesPerRow(view_src);
      int content = 0, white = 0, clear = 0;
      uint32_t center = 0;
      const int xs[3] = {srcW / 4, srcW / 2, (3 * srcW) / 4};
      const int ys[3] = {srcH / 4, srcH / 2, (3 * srcH) / 4};
      for (int yi = 0; yi < 3; ++yi)
        for (int xi = 0; xi < 3; ++xi) {
          const uint8_t* p = base + static_cast<size_t>(ys[yi]) * bpr +
                             static_cast<size_t>(xs[xi]) * 4;  // BGRA8
          const uint8_t b = p[0], g = p[1], r = p[2], a = p[3];
          if (xi == 1 && yi == 1)
            center = (uint32_t)b | ((uint32_t)g << 8) | ((uint32_t)r << 16) | ((uint32_t)a << 24);
          if (a == 0) clear++;
          else if (r > 240 && g > 240 && b > 240) white++;
          else if (r < 12 && g < 12 && b < 12) clear++;  // black == empty too
          else content++;
        }
      IOSurfaceUnlock(view_src, kIOSurfaceLockReadOnly, nullptr);
      // want = the requested OSR surface dims (logical × dpr). Comparing painted (srcWxsrcH)
      // against want is the WRONG-SIZE oracle: painted << want past a grace = the small-surface-
      // scaled-up "4x" bug. content==0 with want>0 = BLANK. Both are screen-independent.
      const int wantW = static_cast<int>(slot_->width * slot_->dpr + 0.5);
      const int wantH = static_cast<int>(slot_->height * slot_->dpr + 0.5);
      char buf[200];
      snprintf(buf, sizeof(buf),
               "diagpx wire=%u painted=%dx%d want=%dx%d content=%d white=%d clear=%d "
               "center=0x%08x",
               slot_->browser_id, srcW, srcH, wantW, wantH, content, white, clear, center);
      SendLog(slot_->browser_id, buf);
    }
    if (view_src && EnsureMetal()) {
      @autoreleasepool {
        const int sw = static_cast<int>(IOSurfaceGetWidth(view_src));
        const int sh = static_cast<int>(IOSurfaceGetHeight(view_src));
        const int dw = static_cast<int>(IOSurfaceGetWidth(slot_->surface));
        const int dh = static_cast<int>(IOSurfaceGetHeight(slot_->surface));
        MTLTextureDescriptor* sd = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:sw
                                        height:sh
                                     mipmapped:NO];
        sd.storageMode = MTLStorageModeShared;
        // src wraps CEF's pooled view_src — it rotates, so wrap per-call.
        id<MTLTexture> src = [g_mtl_device newTextureWithDescriptor:sd
                                                          iosurface:view_src
                                                              plane:0];
        // dst wraps slot_->surface (stable except on resize) — cache it and only
        // recreate when the wrapped surface id changes, halving per-frame texture
        // churn on the GPU thread.
        const uint32_t dsid = IOSurfaceGetID(slot_->surface);
        if (slot_->dst_mtl == nil || slot_->dst_mtl_sid != dsid) {
          [slot_->dst_mtl release];
          MTLTextureDescriptor* dd = [MTLTextureDescriptor
              texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                           width:dw
                                          height:dh
                                       mipmapped:NO];
          dd.storageMode = MTLStorageModeShared;
          slot_->dst_mtl = [g_mtl_device newTextureWithDescriptor:dd
                                                        iosurface:slot_->surface
                                                            plane:0];
          slot_->dst_mtl_sid = dsid;
        }
        id<MTLTexture> dst = slot_->dst_mtl;  // cached (released on resize/close)
        if (src && dst) {
          const int cw = std::min(sw, dw), ch = std::min(sh, dh);
          // DIAG: a src≠dst blit crops (src>dst → top-left only) or partial-fills (src<dst →
          // stale margins). On a static page this single mismatched frame sticks. Log it.
          if ((sw != dw || sh != dh) && g_debug) {
            char b[160];
            snprintf(b, sizeof(b), "blitmismatch src=%dx%d dst=%dx%d copy=%dx%d", sw, sh, dw, dh, cw, ch);
            SendLog(slot_->browser_id, b);
          }
          id<MTLCommandBuffer> cb = [g_mtl_queue commandBuffer];
          id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
          [blit copyFromTexture:src
                    sourceSlice:0
                    sourceLevel:0
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(cw, ch, 1)
                      toTexture:dst
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
          [blit endEncoding];
          [cb commit];
          [cb waitUntilCompleted];
          blitted = true;
        }
        [src release];
        // dst is cached on the Slot (released on resize/close), not per-frame.
      }
    }
    if (blitted) {
      static bool logged = false;
      if (!logged) {
        logged = true;
        SendLog(slot_->browser_id, "present: GPU Metal blit path active");
      }
      SendPresentLocked(srcW, srcH);
    } else {
      static bool loggedFb = false;
      if (!loggedFb) {
        loggedFb = true;
        SendLog(slot_->browser_id,
                "present: CPU composite fallback (Metal unavailable or IOSurface wrap failed)");
      }
      CompositeSoftwareLocked(view_src);
    }
  }

  // GPU-accelerated OSR. With shared_texture_enabled, CEF's GPU/Viz process
  // COMPOSITES the page on the GPU and hands us the result as a shared IOSurface
  // (a rotating pool, valid only for this call). We copy it into the host-shared
  // surface and present that. The win is that compositing moves OFF the CPU —
  // software OSR's bottleneck for video / animation — while the copy itself is
  // cheap on unified-memory Macs. (True zero-copy, handing the GPU surface to
  // Flutter directly, would need cross-process Mach-port surface transfer since
  // these surfaces aren't resolvable by global id from another process; a future
  // optimization, mostly for discrete-GPU Macs where the copy is a real readback.)
  void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type,
                          const RectList&,
                          const CefAcceleratedPaintInfo& info) override {
    slot_->diag_paint_count++;  // DIAG
    ApplyBlankFirstNav(slot_);
    IOSurfaceRef src =
        reinterpret_cast<IOSurfaceRef>(info.shared_texture_io_surface);
    if (!src) {
      SendLog(slot_->browser_id, "OnAcceleratedPaint: null io_surface");
      return;
    }
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    // PRODUCER-ALLOCATES: the surface is minted lazily by the FIRST view paint (and re-minted on
    // any size change) inside the composite path — so we must NOT early-return on a null surface
    // before reaching it (that would deadlock: no surface → no paint → no surface). For a VIEW
    // paint, ensure the surface to the painted dims here; EnsureSurfaceForPaint no-ops if the
    // browser is closing. For a POPUP paint (no view dims) the view surface must already exist.
    if (type != PET_POPUP) {
      EnsureSurfaceForPaint(static_cast<int>(IOSurfaceGetWidth(src)),
                            static_cast<int>(IOSurfaceGetHeight(src)));
    }
    if (!slot_->surface) return;  // closing, or alloc failed — drop this frame
    if (type == PET_POPUP) {
      CopyAccelToPopupBuf(src);
      CompositeSoftwareLocked(nullptr);  // popup over latest view in slot->surface
      return;
    }
    // View frame. While a <select> dropdown is open we must CPU-composite so the popup is drawn
    // over the view; otherwise take the GPU-blit path (no CPU readback).
    if (slot_->popup_visible) {
      CompositeSoftwareLocked(src);  // GPU-composited view + the open popup
    } else {
      CompositeMetalLocked(src);  // GPU blit, no CPU readback
    }
  }

  // Report the composition caret rect (DIP, view coords) so the host can place
  // the OS IME candidate window under the text being composed.
  void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser>, const CefRange&,
                                    const RectList& bounds) override {
    CefRect r = bounds.empty() ? CefRect(0, 0, 0, 0) : bounds.front();
    uint8_t p[16];
    WriteU32BE(p + 0, static_cast<uint32_t>(std::max(0, r.x)));
    WriteU32BE(p + 4, static_cast<uint32_t>(std::max(0, r.y)));
    WriteU32BE(p + 8, static_cast<uint32_t>(std::max(0, r.width)));
    WriteU32BE(p + 12, static_cast<uint32_t>(std::max(0, r.height)));
    SendFrame(slot_->browser_id, kOpImeBounds, p, 16);
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostRenderHandler);
};

}  // namespace

CefRefPtr<CefRenderHandler> NewRenderHandler(std::shared_ptr<Slot> slot) {
  return new HostRenderHandler(std::move(slot));
}

}  // namespace cef_host
