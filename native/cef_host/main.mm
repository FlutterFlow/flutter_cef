// cef_host — a standalone CEF off-screen-rendering subprocess.
//
// The Flutter host (the flutter_cef macOS plugin) allocates an IOSurface-backed
// CVPixelBuffer, registers a FlutterTexture on it, and spawns one cef_host per
// CefWebView. cef_host runs CEF windowless (OSR), paints the page into the
// shared IOSurface, and notifies the host over a Unix-socket IPC so the host
// calls textureFrameAvailable. Because the page renders to an offscreen buffer
// (no NSWindow), it keeps rendering live even when the view is off-screen — the
// whole point of the CEF path.
//
// By default CEF runs --single-process: renderer + GPU live in this process, so
// there are no child processes and thus no Mach-port peer validation (Chromium
// 144's process_requirement.cc -67030). Define CEF_HOST_MULTIPROCESS (CMake
// -DCEF_MULTI_PROCESS=ON) to instead spawn the CEF helper subprocesses
// (GPU/Renderer/Plugin/Alerts) from Contents/Frameworks — required for the
// GPU/Viz process and OnAcceleratedPaint, but the whole bundle then needs to be
// hardened-runtime signed with one Developer-ID identity + notarized to clear
// peer validation cleanly.
//
// Args: --url=<url> --width=<px> --height=<px> --iosurface-id=<id> --ipc=<path>
//
// IPC wire format: 4-byte big-endian length prefix, then [opcode][payload].
//   host -> cef_host:  0x10 pointer {type:u8,button:u8,clicks:u8,_,mods:u32,
//                                    x,y,dx,dy:f64}
//                      0x11 resize {w:u32,h:u32,iosurfaceId:u32}
//                      0x12 key {type:u8,_,_,_,mods:u32,wkc:u32,nkc:u32,char:u32}
//                      0x14 shutdown {}
//                      0x20 navigate {utf8 url}
//                      0x21 reload / 0x22 stop / 0x23 back / 0x24 forward {}
//                      0x25 executeJs {utf8 code}
//   cef_host -> host:  0x01 present {}
//                      0x02 ready {}
//                      0x03 cursor {type:u32}
//                      0x04 log {utf8}
//                      0x05 loadState {loading,back,forward : u8}
//                      0x06 title {utf8} / 0x07 url {utf8}
//                      0x08 loadError {code:u32}{utf8 "url\ntext"}
//                      0x09 console {level:u32}{utf8 "source:line\tmsg"}

#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <libgen.h>
#include <mach-o/dyld.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

// ---- Opcodes ----
constexpr uint8_t kOpPresent = 0x01;
constexpr uint8_t kOpReady = 0x02;
constexpr uint8_t kOpCursor = 0x03;
constexpr uint8_t kOpLog = 0x04;
constexpr uint8_t kOpLoadState = 0x05;  // {loading,back,forward : u8}
constexpr uint8_t kOpTitle = 0x06;      // {utf8}
constexpr uint8_t kOpUrl = 0x07;        // {utf8} main-frame address
constexpr uint8_t kOpLoadErr = 0x08;    // {code:u32}{utf8 "url\ntext"}
constexpr uint8_t kOpConsole = 0x09;    // {level:u32}{utf8 "source:line\tmsg"}
constexpr uint8_t kOpPointer = 0x10;
constexpr uint8_t kOpResize = 0x11;
constexpr uint8_t kOpKey = 0x12;
constexpr uint8_t kOpShutdown = 0x14;
constexpr uint8_t kOpNavigate = 0x20;
constexpr uint8_t kOpReload = 0x21;
constexpr uint8_t kOpStop = 0x22;
constexpr uint8_t kOpBack = 0x23;
constexpr uint8_t kOpForward = 0x24;
constexpr uint8_t kOpExecuteJs = 0x25;  // {utf8 code}

// ---- Shared runtime state ----
int g_ipc_fd = -1;
std::mutex g_ipc_write_mutex;

std::mutex g_surface_mutex;      // guards g_surface / g_width / g_height / g_dpr
IOSurfaceRef g_surface = nullptr;
int g_width = 800;   // logical (DIP) — GetViewRect; CEF scales by g_dpr.
int g_height = 600;
double g_dpr = 1.0;  // device pixel ratio; the IOSurface is logical*g_dpr px.

CefRefPtr<CefBrowser> g_browser;

// Popup widgets (<select> dropdowns, autofill) paint into a separate PET_POPUP
// buffer that we composite over the view at the popup rect. Guarded by
// g_surface_mutex.
bool g_popup_visible = false;
CefRect g_popup_rect;
std::vector<uint8_t> g_popup_buf;
int g_popup_w = 0;
int g_popup_h = 0;

// ---- IPC helpers ----
bool WriteAll(int fd, const void* buf, size_t len) {
  const uint8_t* p = static_cast<const uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    ssize_t n = write(fd, p + off, len - off);
    if (n <= 0) {
      if (n < 0 && (errno == EINTR)) continue;
      return false;
    }
    off += static_cast<size_t>(n);
  }
  return true;
}

bool ReadAll(int fd, void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    ssize_t n = read(fd, p + off, len - off);
    if (n == 0) return false;  // peer closed
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    off += static_cast<size_t>(n);
  }
  return true;
}

void SendFrame(uint8_t opcode, const void* payload, uint32_t payload_len) {
  if (g_ipc_fd < 0) return;
  std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
  uint32_t body_len = 1 + payload_len;
  uint8_t hdr[4] = {static_cast<uint8_t>((body_len >> 24) & 0xff),
                    static_cast<uint8_t>((body_len >> 16) & 0xff),
                    static_cast<uint8_t>((body_len >> 8) & 0xff),
                    static_cast<uint8_t>(body_len & 0xff)};
  if (!WriteAll(g_ipc_fd, hdr, 4)) return;
  if (!WriteAll(g_ipc_fd, &opcode, 1)) return;
  if (payload_len) WriteAll(g_ipc_fd, payload, payload_len);
}

void SendLog(const std::string& msg) {
  SendFrame(kOpLog, msg.data(), static_cast<uint32_t>(msg.size()));
}

void SendUtf8(uint8_t op, const std::string& s) {
  SendFrame(op, s.data(), static_cast<uint32_t>(s.size()));
}

void SendLoadState(bool loading, bool back, bool forward) {
  uint8_t p[3];
  p[0] = loading ? 1 : 0;
  p[1] = back ? 1 : 0;
  p[2] = forward ? 1 : 0;
  SendFrame(kOpLoadState, p, 3);
}

// op payload: [u32 BE code][utf8 body]. Used for load-error and console.
void SendCodePlusUtf8(uint8_t op, uint32_t code, const std::string& body) {
  std::vector<uint8_t> p(4 + body.size());
  p[0] = (code >> 24) & 0xff;
  p[1] = (code >> 16) & 0xff;
  p[2] = (code >> 8) & 0xff;
  p[3] = code & 0xff;
  memcpy(p.data() + 4, body.data(), body.size());
  SendFrame(op, p.data(), static_cast<uint32_t>(p.size()));
}

uint32_t ReadU32BE(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) |
         uint32_t(p[3]);
}

uint64_t ReadU64BE(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
  return v;
}

double ReadF64BE(const uint8_t* p) {
  uint64_t bits = ReadU64BE(p);
  double d;
  memcpy(&d, &bits, sizeof(d));
  return d;
}

// ---- CEF NSApplication (CefAppProtocol) ----
}  // namespace

@interface CefHostApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end
@implementation CefHostApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}
- (void)setHandlingSendEvent:(BOOL)h {
  handlingSendEvent_ = h;
}
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

namespace {

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
class HostRenderHandler : public CefRenderHandler {
 public:
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    rect = CefRect(0, 0, g_width, g_height);
  }

  // Report the device scale so CEF renders the OSR buffer at logical*dpr
  // (Retina-native) instead of 1x upscaled — fixes the blur on HiDPI displays.
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    info.device_scale_factor = static_cast<float>(g_dpr);
    info.rect = CefRect(0, 0, g_width, g_height);
    info.available_rect = info.rect;
    return true;
  }

  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
               const void* buffer, int width, int height) override {
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    if (!g_surface) return;
    if (IOSurfaceLock(g_surface, 0, nullptr) != kIOReturnSuccess) return;
    uint8_t* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(g_surface));
    const size_t dst_stride = IOSurfaceGetBytesPerRow(g_surface);
    const int surf_w = static_cast<int>(IOSurfaceGetWidth(g_surface));
    const int surf_h = static_cast<int>(IOSurfaceGetHeight(g_surface));
    const uint8_t* src = static_cast<const uint8_t*>(buffer);
    if (type == PET_VIEW) {
      BlitBGRA(dst, dst_stride, surf_w, surf_h, src, width, height, 0, 0);
      // Keep an open popup (<select> dropdown) painted on top of the view.
      if (g_popup_visible && !g_popup_buf.empty()) {
        BlitBGRA(dst, dst_stride, surf_w, surf_h, g_popup_buf.data(), g_popup_w,
                 g_popup_h, g_popup_rect.x, g_popup_rect.y);
      }
    } else if (type == PET_POPUP) {
      g_popup_w = width;
      g_popup_h = height;
      g_popup_buf.assign(src, src + static_cast<size_t>(width) * height * 4);
      BlitBGRA(dst, dst_stride, surf_w, surf_h, src, width, height,
               g_popup_rect.x, g_popup_rect.y);
    }
    IOSurfaceUnlock(g_surface, 0, nullptr);
    SendFrame(kOpPresent, nullptr, 0);
  }

  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override {
    {
      std::lock_guard<std::mutex> lock(g_surface_mutex);
      g_popup_visible = show;
      if (!show) {
        g_popup_buf.clear();
        g_popup_rect = CefRect();
      }
    }
    // Repaint the view to erase the dropdown's pixels when it closes.
    if (!show && browser) browser->GetHost()->Invalidate(PET_VIEW);
  }

  void OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) override {
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    g_popup_rect = rect;
  }

  // Multi-process GPU path: CEF's GPU/Viz process hands us a shared IOSurface
  // (rotating pool — valid only for this call, must not be cached). Copy it into
  // our persistent FlutterTexture surface. This is how frames arrive in
  // multi-process (OnPaint isn't called when shared_texture_enabled is on).
  void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type,
                          const RectList&,
                          const CefAcceleratedPaintInfo& info) override {
    if (type != PET_VIEW) return;  // popups still TODO on this path
    IOSurfaceRef src =
        reinterpret_cast<IOSurfaceRef>(info.shared_texture_io_surface);
    if (!src) {
      SendLog("OnAcceleratedPaint: null io_surface");
      return;
    }
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    if (!g_surface) return;
    if (IOSurfaceLock(src, kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess) {
      return;
    }
    if (IOSurfaceLock(g_surface, 0, nullptr) != kIOReturnSuccess) {
      IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, nullptr);
      return;
    }
    auto* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(g_surface));
    const auto* s = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(src));
    const size_t dst_stride = IOSurfaceGetBytesPerRow(g_surface);
    const size_t src_stride = IOSurfaceGetBytesPerRow(src);
    const int rows = std::min<int>(IOSurfaceGetHeight(src),
                                   IOSurfaceGetHeight(g_surface));
    const size_t copy =
        std::min<size_t>(static_cast<size_t>(IOSurfaceGetWidth(src)) * 4,
                         static_cast<size_t>(IOSurfaceGetWidth(g_surface)) * 4);
    for (int y = 0; y < rows; ++y) {
      memcpy(dst + static_cast<size_t>(y) * dst_stride,
             s + static_cast<size_t>(y) * src_stride, copy);
    }
    IOSurfaceUnlock(g_surface, 0, nullptr);
    IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, nullptr);
    SendFrame(kOpPresent, nullptr, 0);
  }

  IMPLEMENT_REFCOUNTING(HostRenderHandler);
};

class HostClient : public CefClient,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefRequestHandler {
 public:
  CefRefPtr<CefRenderHandler> rh_ = new HostRenderHandler();
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return rh_; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // Recover from a renderer crash (multi-process only): reload rather than show
  // a dead page. In single-process a renderer CHECK kills the whole process, so
  // this never fires — which is why heavy pages need multi-process.
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int /*error_code*/,
                                 const CefString& /*error_string*/) override {
    SendLog("renderer terminated (status " + std::to_string(status) +
            ") — reloading");
    if (browser) browser->ReloadIgnoreCache();
  }

  // CefLoadHandler: spinner + back/forward enablement.
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    SendLoadState(isLoading, canGoBack, canGoForward);
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& text, const CefString& url) override {
    if (code == ERR_ABORTED) return;
    SendCodePlusUtf8(kOpLoadErr, static_cast<uint32_t>(code),
                     url.ToString() + "\n" + text.ToString());
  }

  // CefDisplayHandler: title / address / console -> host.
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    SendUtf8(kOpTitle, title.ToString());
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame->IsMain()) SendUtf8(kOpUrl, url.ToString());
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level,
                        const CefString& message, const CefString& source,
                        int line) override {
    SendCodePlusUtf8(kOpConsole, static_cast<uint32_t>(level),
                     source.ToString() + ":" + std::to_string(line) + "\t" +
                         message.ToString());
    return false;  // also keep CEF's default console logging
  }

  // The page's cursor (I-beam over text, hand over links, etc.). Forward the
  // type to the host so it can drive the Flutter MouseRegion cursor.
  bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle,
                      cef_cursor_type_t type, const CefCursorInfo&) override {
    uint8_t p[4];
    uint32_t t = static_cast<uint32_t>(type);
    p[0] = (t >> 24) & 0xff;
    p[1] = (t >> 16) & 0xff;
    p[2] = (t >> 8) & 0xff;
    p[3] = t & 0xff;
    SendFrame(kOpCursor, p, 4);
    return true;
  }
  IMPLEMENT_REFCOUNTING(HostClient);
};

std::string g_initial_url;

class HostApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString&, CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitch("use-mock-keychain");
    command_line->AppendSwitchWithValue("password-store", "basic");
#ifndef CEF_HOST_MULTIPROCESS
    // Single-process (default): renderer + GPU + utility all share this process,
    // so there are no Mach-port peers to validate (Chromium 144's -67030). The
    // catch: heavy pages whose work lands on the in-process utility thread (e.g.
    // Google sign-in probing WebAuthn/HID security keys) can CHECK-crash the
    // whole process. It's best for simpler/first-party content; multi-process
    // (-DCEF_MULTI_PROCESS=ON) isolates those crashes.
    command_line->AppendSwitch("single-process");
    command_line->AppendSwitchWithValue(
        "disable-features",
        "MachPortRendezvousValidatePeerRequirements,"
        "MachPortRendezvousEnforcePeerRequirements");
#endif
    command_line->AppendSwitch("enable-logging");
    command_line->AppendSwitchWithValue("log-file", "/tmp/cef_host_chromium.log");
    command_line->AppendSwitchWithValue("v", "1");
  }
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    fprintf(stderr, "[cef_host] OnContextInitialized\n");
    CefWindowInfo window_info;
    window_info.SetAsWindowless(0);
#ifdef CEF_HOST_MULTIPROCESS
    // Multi-process: ask the GPU process to deliver frames as a shared IOSurface
    // (OnAcceleratedPaint) instead of a CPU OnPaint readback.
    window_info.shared_texture_enabled = true;
#endif
    CefBrowserSettings settings;
    settings.windowless_frame_rate = 60;
    g_browser = CefBrowserHost::CreateBrowserSync(
        window_info, new HostClient(), g_initial_url, settings, nullptr,
        nullptr);
    fprintf(stderr, "[cef_host] browser=%p\n", (void*)g_browser.get());
    SendFrame(kOpReady, nullptr, 0);
  }
  IMPLEMENT_REFCOUNTING(HostApp);
};

// ---- CEF-thread task helpers (IPC reader runs off the UI thread) ----
void DoResize(int w, int h, uint32_t surface_id) {
  IOSurfaceRef next = IOSurfaceLookup(surface_id);
  if (!next) {
    SendLog("resize: IOSurfaceLookup failed for id " + std::to_string(surface_id));
    return;
  }
  {
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    if (g_surface) CFRelease(g_surface);
    g_surface = next;  // owns the +1 from Lookup
    g_width = w;
    g_height = h;
  }
  if (g_browser) g_browser->GetHost()->WasResized();
}

void DoNavigate(const std::string& url) {
  if (g_browser) g_browser->GetMainFrame()->LoadURL(url);
}

void DoReload() {
  if (g_browser) g_browser->Reload();
}
void DoStopLoad() {
  if (g_browser) g_browser->StopLoad();
}
void DoGoBack() {
  if (g_browser) g_browser->GoBack();
}
void DoGoForward() {
  if (g_browser) g_browser->GoForward();
}
void DoExecuteJs(const std::string& code) {
  if (g_browser) g_browser->GetMainFrame()->ExecuteJavaScript(code, "", 0);
}

// type: 0=move 1=down 2=up 3=wheel; button: 0=left 1=middle 2=right.
void DoPointer(int type, int button, int click_count, uint32_t modifiers,
               double x, double y, double dx, double dy) {
  if (!g_browser) return;
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;
  CefRefPtr<CefBrowserHost> host = g_browser->GetHost();
  switch (type) {
    case 0:
      host->SendMouseMoveEvent(ev, false);
      break;
    case 1:
      // Give the browser keyboard focus on press so text fields take input and
      // show a caret (CEF won't route key events to an unfocused OSR browser).
      host->SetFocus(true);
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), false, click_count);
      break;
    case 2:
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), true, click_count);
      break;
    case 3:
      host->SendMouseWheelEvent(ev, static_cast<int>(dx), static_cast<int>(dy));
      break;
    default:
      break;
  }
}

// type: 0=rawkeydown 2=keyup 3=char (cef_key_event_type_t).
void DoKey(int type, uint32_t modifiers, int32_t windows_key_code,
           int32_t native_key_code, uint32_t character) {
  if (!g_browser) return;
  CefKeyEvent ev;
  ev.type = static_cast<cef_key_event_type_t>(type);
  ev.modifiers = modifiers;
  ev.windows_key_code = windows_key_code;
  ev.native_key_code = native_key_code;
  if (type == 3) {
    ev.character = static_cast<char16_t>(character);
    ev.unmodified_character = static_cast<char16_t>(character);
  }
  g_browser->GetHost()->SendKeyEvent(ev);
}

void DoShutdown() {
  if (g_browser) {
    g_browser->GetHost()->CloseBrowser(true);
    g_browser = nullptr;
  }
  CefQuitMessageLoop();
}

// Reader thread: decode frames, marshal onto the CEF UI thread.
void IpcReadLoop() {
  for (;;) {
    uint8_t hdr[4];
    if (!ReadAll(g_ipc_fd, hdr, 4)) break;
    uint32_t body_len = ReadU32BE(hdr);
    if (body_len == 0 || body_len > (64u << 20)) break;
    std::vector<uint8_t> body(body_len);
    if (!ReadAll(g_ipc_fd, body.data(), body_len)) break;
    uint8_t opcode = body[0];
    const uint8_t* p = body.data() + 1;
    uint32_t plen = body_len - 1;
    switch (opcode) {
      case kOpResize: {
        if (plen < 12) break;
        int w = static_cast<int>(ReadU32BE(p));
        int h = static_cast<int>(ReadU32BE(p + 4));
        uint32_t sid = ReadU32BE(p + 8);
        CefPostTask(TID_UI, base::BindOnce(&DoResize, w, h, sid));
        break;
      }
      case kOpNavigate: {
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoNavigate, url));
        break;
      }
      case kOpReload:
        CefPostTask(TID_UI, base::BindOnce(&DoReload));
        break;
      case kOpStop:
        CefPostTask(TID_UI, base::BindOnce(&DoStopLoad));
        break;
      case kOpBack:
        CefPostTask(TID_UI, base::BindOnce(&DoGoBack));
        break;
      case kOpForward:
        CefPostTask(TID_UI, base::BindOnce(&DoGoForward));
        break;
      case kOpExecuteJs: {
        std::string code(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoExecuteJs, code));
        break;
      }
      case kOpPointer: {
        if (plen < 40) break;
        int type = p[0], button = p[1], clicks = p[2];
        uint32_t mods = ReadU32BE(p + 4);
        double x = ReadF64BE(p + 8), y = ReadF64BE(p + 16);
        double dx = ReadF64BE(p + 24), dy = ReadF64BE(p + 32);
        CefPostTask(TID_UI, base::BindOnce(&DoPointer, type, button, clicks,
                                           mods, x, y, dx, dy));
        break;
      }
      case kOpKey: {
        if (plen < 20) break;
        int type = p[0];
        uint32_t mods = ReadU32BE(p + 4);
        int32_t wkc = static_cast<int32_t>(ReadU32BE(p + 8));
        int32_t nkc = static_cast<int32_t>(ReadU32BE(p + 12));
        uint32_t ch = ReadU32BE(p + 16);
        CefPostTask(TID_UI, base::BindOnce(&DoKey, type, mods, wkc, nkc, ch));
        break;
      }
      case kOpShutdown:
        CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
        return;
      default:
        break;
    }
  }
  // Parent died / socket closed: quit.
  CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
}

// Belt-and-suspenders: if the host process dies without closing the socket
// cleanly, kqueue NOTE_EXIT still tears us down so no cef_host orphans.
void WatchParentDeath(pid_t parent) {
  int kq = kqueue();
  if (kq < 0) return;
  struct kevent change;
  EV_SET(&change, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0,
         nullptr);
  if (kevent(kq, &change, 1, nullptr, 0, nullptr) < 0) {
    close(kq);  // parent already gone (ESRCH) — socket EOF will catch it
    return;
  }
  struct kevent out;
  const int n = kevent(kq, nullptr, 0, &out, 1, nullptr);  // blocks until exit
  close(kq);
  if (n > 0) CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
}

// ---- Arg parsing ----
std::string ArgValue(int argc, char** argv, const char* key) {
  std::string prefix = std::string("--") + key + "=";
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], prefix.c_str(), prefix.size()) == 0) {
      return std::string(argv[i] + prefix.size());
    }
  }
  return std::string();
}

std::string ExecutableDir() {
  char buf[4096];
  uint32_t sz = sizeof(buf);
  if (_NSGetExecutablePath(buf, &sz) != 0) return std::string();
  char real[4096];
  const char* resolved = realpath(buf, real) ? real : buf;
  return std::string(dirname(const_cast<char*>(resolved)));
}

int ConnectUnixSocket(const std::string& path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
  if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

}  // namespace

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    fprintf(stderr, "[cef_host] failed to load CEF framework\n");
    return 1;
  }

  std::string url = ArgValue(argc, argv, "url");
  std::string ipc_path = ArgValue(argc, argv, "ipc");
  std::string ws = ArgValue(argc, argv, "width");
  std::string hs = ArgValue(argc, argv, "height");
  std::string dprs = ArgValue(argc, argv, "dpr");
  std::string sid = ArgValue(argc, argv, "iosurface-id");
  if (url.empty()) url = "about:blank";
  if (!ws.empty()) g_width = atoi(ws.c_str());
  if (!hs.empty()) g_height = atoi(hs.c_str());
  if (!dprs.empty()) g_dpr = atof(dprs.c_str());
  g_initial_url = url;

  if (!sid.empty()) {
    g_surface = IOSurfaceLookup(static_cast<uint32_t>(atoll(sid.c_str())));
    if (!g_surface) {
      fprintf(stderr, "[cef_host] IOSurfaceLookup failed for id %s\n",
              sid.c_str());
    }
  }
  if (!ipc_path.empty()) {
    g_ipc_fd = ConnectUnixSocket(ipc_path);
    if (g_ipc_fd < 0) {
      fprintf(stderr, "[cef_host] failed to connect IPC socket %s\n",
              ipc_path.c_str());
    }
  }

  // Hand Chromium ONLY the program name. Our custom switches (--url,
  // --iosurface-id, --ipc, --width, --height) are parsed by us above; if they
  // reach Chromium's CommandLine, cef_initialize CHECK-crashes on them.
  char* clean_argv[] = {argv[0]};
  CefMainArgs main_args(1, clean_argv);
  @autoreleasepool {
    [CefHostApplication sharedApplication];
    CefSettings settings;
    settings.no_sandbox = true;
    settings.windowless_rendering_enabled = true;
    settings.log_severity = LOGSEVERITY_INFO;
    CefString(&settings.root_cache_path) = "/tmp/cef_host_cache";
    // A plain (non-.app) executable can't auto-locate the framework Resources
    // (icudtl.dat, *.pak, locale .lproj), so point CEF at them explicitly via a
    // normalized (no "..") framework dir.
    std::string exe_dir = ExecutableDir();
    std::string fw_raw =
        exe_dir + "/../Frameworks/Chromium Embedded Framework.framework";
    char fw_real[4096];
    std::string fw =
        realpath(fw_raw.c_str(), fw_real) ? std::string(fw_real) : fw_raw;
    CefString(&settings.framework_dir_path) = fw;
    CefString(&settings.resources_dir_path) = fw + "/Resources";
    CefString(&settings.locales_dir_path) = fw + "/Resources";
#ifdef CEF_HOST_MULTIPROCESS
    // Multi-process: point CEF at the base helper subprocess + the cef_host
    // bundle. CEF derives the (GPU)/(Renderer)/(Plugin)/(Alerts) variants from
    // the base helper name.
    auto normalize = [](const std::string& p) {
      char buf[4096];
      return realpath(p.c_str(), buf) ? std::string(buf) : p;
    };
    CefString(&settings.browser_subprocess_path) = normalize(
        exe_dir + "/../Frameworks/cef_host Helper.app/Contents/MacOS/cef_host Helper");
    CefString(&settings.main_bundle_path) = normalize(exe_dir + "/../..");
#endif
    CefRefPtr<HostApp> app(new HostApp);
    if (!CefInitialize(main_args, settings, app, nullptr)) {
      fprintf(stderr, "[cef_host] CefInitialize failed\n");
      return 1;
    }
    fprintf(stderr, "[cef_host] CefInitialize OK (fd=%d surface=%p)\n", g_ipc_fd,
            (void*)g_surface);
    std::thread reader;
    if (g_ipc_fd >= 0) reader = std::thread(&IpcReadLoop);
    std::thread(&WatchParentDeath, getppid()).detach();
    CefRunMessageLoop();
    if (reader.joinable()) {
      shutdown(g_ipc_fd, SHUT_RDWR);
      reader.join();
    }
    CefShutdown();
  }
  return 0;
}
