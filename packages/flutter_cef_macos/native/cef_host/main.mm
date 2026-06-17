// cef_host — a standalone CEF off-screen-rendering subprocess.
//
// The Flutter host (the flutter_cef macOS plugin) spawns one cef_host per
// PROFILE (persistent or ephemeral) and drives N browsers in it over a
// Unix-socket IPC. For each browser the host allocates an IOSurface-backed
// CVPixelBuffer, registers a FlutterTexture on it, and sends kOpCreateBrowser
// (carrying url/width/height/dpr/iosurface-id). cef_host runs CEF windowless
// (OSR), paints each page into its shared IOSurface, and notifies the host so
// it calls textureFrameAvailable. Because the page renders to an offscreen
// buffer (no NSWindow), it keeps rendering live even when the view is off-screen
// — the whole point of the CEF path. No browser is created at startup; the host
// waits for kOpReady, then issues kOpCreateBrowser per view.
//
// Multi-process is the default (CMake option CEF_MULTI_PROCESS, ON by default,
// defines CEF_HOST_MULTIPROCESS): the CEF helper subprocesses
// (GPU/Renderer/Plugin/Alerts) spawn from Contents/Frameworks, the GPU/Viz
// process composites the page, and OnAcceleratedPaint delivers it as a
// shared-texture IOSurface — crash-isolated, so heavy SPAs survive. Chromium
// 144's Mach-port peer validation (process_requirement.cc -67030) is cleared
// WITHOUT Developer-ID signing: the MACH_PORT_RENDEZVOUS_PEER_VALDATION=0 env
// var (inherited by children) plus
// --disable-features=MachPortRendezvousValidatePeerRequirements,
// MachPortRendezvousEnforcePeerRequirements in the browser process. Build with
// -DCEF_MULTI_PROCESS=OFF for the simpler single-process fallback (software
// OnPaint, no helpers, no peer validation at all).
//
// Those Mach-port shortcuts plus a mock keychain are gated behind the
// CEF_HOST_ADHOC compile flag (ON by default). A signed release builds with
// -DCEF_HOST_ADHOC=OFF, which enforces peer validation and uses the real
// Keychain (OSCrypt) — and so requires correct inside-out Developer-ID signing.
//
// Args (all per-PROCESS / per-profile): --ipc=<path> --cdp-port=<port>
//       --allowed-schemes=<csv> --profile-dir=<abs path>
// --profile-dir maps to settings.root_cache_path (empty/omitted -> a per-pid
// ephemeral temp dir; Swift always supplies it, so the fallback is defensive).
// The per-view args (url/width/height/dpr/iosurface-id) moved into the
// kOpCreateBrowser payload. --cdp-port is rejected upstream when a named profile
// is in use, so persistent profiles never expose the unauthenticated debug port.
//
// IPC wire format: 4-byte big-endian length prefix (bodyLen), then a 4-byte
// big-endian browserId, then [opcode][payload]. bodyLen = 4 + 1 + payloadLen.
// browserId is the Swift-assigned wire id (>=1); browserId 0 = process/profile
// level (kOpReady, process-level kOpLog, inbound kOpShutdown). The full opcode
// table lives in the `kOp*` constants below — each carries its payload layout;
// cef_host -> host are 0x01-0x1a, host -> cef_host 0x10-0x35.

#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
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
#include "include/cef_cookie.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

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
constexpr uint8_t kOpPageStart = 0x0a;  // {utf8 url} main frame load started
constexpr uint8_t kOpPageFinish = 0x0b; // {utf8 url} main frame load finished
constexpr uint8_t kOpProgress = 0x0c;   // {u32 percent 0-100}
constexpr uint8_t kOpNewWindow = 0x0d;  // {utf8 url} popup / target=_blank
constexpr uint8_t kOpFindResult = 0x0e; // {u32 count}{u32 activeOrdinal}{u8 final}
constexpr uint8_t kOpJsDialog = 0x0f;   // {u32 id}{u32 type}{u32 msgLen}{msg}{default}
constexpr uint8_t kOpEvalResult = 0x16; // {utf8 "id:json"} runJavaScriptReturningResult
constexpr uint8_t kOpChannelMsg = 0x17; // {utf8 "name:message"} JS channel -> host
constexpr uint8_t kOpDownload = 0x18;   // {utf8 suggestedName} a download started
constexpr uint8_t kOpImeBounds = 0x19;  // {u32 x}{u32 y}{u32 w}{u32 h} caret rect (DIP)
constexpr uint8_t kOpCookies = 0x1a;    // {u32 id}{utf8 json-array} visitAllCookies result
constexpr uint8_t kOpPointer = 0x10;
constexpr uint8_t kOpResize = 0x11;
constexpr uint8_t kOpKey = 0x12;
constexpr uint8_t kOpCreateBrowser = 0x13;  // {u32 w}{u32 h}{f64 dpr}{u32 iosurfaceId}{utf8 url}; frame browserId = NEW id
constexpr uint8_t kOpShutdown = 0x14;       // {} tear down the whole PROCESS (all browsers); frame browserId 0
constexpr uint8_t kOpDisposeBrowser = 0x15;  // {} close ONE browser (target = frame browserId); process survives
constexpr uint8_t kOpNavigate = 0x20;
constexpr uint8_t kOpReload = 0x21;
constexpr uint8_t kOpStop = 0x22;
constexpr uint8_t kOpBack = 0x23;
constexpr uint8_t kOpForward = 0x24;
constexpr uint8_t kOpExecuteJs = 0x25;  // {utf8 code}
constexpr uint8_t kOpSetZoom = 0x26;    // {f64 level} (factor = 1.2^level)
constexpr uint8_t kOpFind = 0x27;       // {u8 fwd}{u8 matchCase}{u8 findNext}{utf8}
constexpr uint8_t kOpStopFind = 0x28;   // {u8 clearSelection}
constexpr uint8_t kOpJsDialogResp = 0x29;  // {u32 id}{u8 ok}{utf8 text}
constexpr uint8_t kOpEvalReturning = 0x2a;  // {u32 id}{utf8 code}
constexpr uint8_t kOpAddChannel = 0x2b;     // {utf8 name} register a JS channel
constexpr uint8_t kOpSetCookie = 0x2c;      // {utf8 url\0name\0value\0domain\0path}
constexpr uint8_t kOpClearCookies = 0x2d;   // {} delete all cookies
constexpr uint8_t kOpVisitCookies = 0x2e;   // {u32 id}{utf8 url} enumerate (url empty = all)
constexpr uint8_t kOpDeleteCookie = 0x2f;   // {utf8 url\0name} delete one
constexpr uint8_t kOpImeSetComp = 0x30;     // {utf8 text} IME composition update
constexpr uint8_t kOpImeCommit = 0x31;      // {utf8 text} commit composed text
constexpr uint8_t kOpImeCancel = 0x32;      // {} cancel composition
constexpr uint8_t kOpShowDevTools = 0x33;   // {} open DevTools in a window
constexpr uint8_t kOpLoadTrusted = 0x34;    // {utf8 url} host content-load, exempt from allowlist
constexpr uint8_t kOpSetVisible = 0x35;     // {u8 visible} -> CefBrowserHost::WasHidden(!visible)

// ---- Shared runtime state ----
int g_ipc_fd = -1;
std::mutex g_ipc_write_mutex;

// Per-browser state. One cef_host process now multiplexes N browsers (one per
// CefWebView sharing this profile), so the state that used to be process-global
// (surface/geometry/dpr, the browser, pending JS dialogs, the trusted-load
// allowlist exemptions, popup compositing buffers) moves into a per-browser
// Slot. HostClient / HostRenderHandler each hold a shared_ptr to their slot, and
// per-op UI tasks bind a shared_ptr copy so the slot outlives the
// dispose/in-flight race. Slots are created in DoCreateBrowser and torn down in
// OnBeforeClose (both on the CEF UI thread).
struct Slot {
  uint32_t browser_id = 0;  // Swift-assigned wire id (>=1); NOT GetIdentifier().
  CefRefPtr<CefBrowser> browser;

  // Guards surface / width / height / dpr / popup_* for THIS browser. Per-slot
  // (not a single global) so paints on independent browsers don't contend.
  std::mutex surface_mutex;
  IOSurfaceRef surface = nullptr;  // host-shared IOSurface we paint into
  int width = 800;   // logical (DIP) — GetViewRect; CEF scales by dpr.
  int height = 600;
  double dpr = 1.0;  // device pixel ratio; the IOSurface is logical*dpr px.

  // Popup widgets (<select> dropdowns, autofill) paint into a separate PET_POPUP
  // buffer that we composite over the view at the popup rect. Guarded by
  // surface_mutex. Per-slot so two browsers' open dropdowns don't clobber.
  bool popup_visible = false;
  CefRect popup_rect;
  std::vector<uint8_t> popup_buf;
  int popup_w = 0;
  int popup_h = 0;

  // Exact URLs armed for a host-trusted content load (kOpLoadTrusted). The
  // exemption is bound to the specific URL, NOT to a moment in time: LoadURL does
  // not deliver OnBeforeBrowse synchronously (it enqueues the nav; the callback
  // arrives as a later UI task), so a global one-shot flag could be consumed by a
  // page-initiated navigation queued in the gap — an allowlist bypass. Matching
  // on the exact URL (and main frame) in OnBeforeBrowse means a page nav to a
  // different URL can never steal another load's exemption. A multiset tolerates
  // identical concurrent trusted loads. UI-thread only, so no lock. Per-slot so a
  // trusted load on one browser can't exempt a navigation on another.
  // (A page racing the host to the EXACT same data:/file: URL could consume one
  // armed entry, but that is benign — it loads the same content the host chose —
  // so it is not defended beyond exact-URL matching.)
  std::multiset<std::string> trusted_pending;

  // Pending JS dialog callbacks, keyed by id. UI-thread-only (OnJSDialog and the
  // host's response both run on the CEF UI thread), so no lock is needed.
  // Per-slot so dialog ids on one browser can't Continue() another's callback.
  std::map<uint32_t, CefRefPtr<CefJSDialogCallback>> dialogs;
  uint32_t dialog_next = 1;
};

// Routing map from a wire browser id to its Slot. MUTATED ONLY ON THE CEF UI
// THREAD (insert in DoCreateBrowser, erase in OnBeforeClose). The IPC reader
// thread takes g_slots_mutex, copies the shared_ptr, releases the lock, then
// operates — so a slot stays alive for the duration of an in-flight op even if
// it's disposed. Paint/display handlers don't consult this map: each HostClient
// / HostRenderHandler holds its slot_ shared_ptr directly (no hot-path lookup).
std::mutex g_slots_mutex;
std::map<uint32_t /*wire id*/, std::shared_ptr<Slot>>
    g_slots_by_wire_id;  // inbound IPC routing -> slot

// Look up a slot by its Swift-assigned wire id (used by the IPC reader to route
// an inbound per-browser op). Null for wire id 0 or an unknown/disposed id.
std::shared_ptr<Slot> LookupWireId(uint32_t wire_id) {
  if (wire_id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(g_slots_mutex);
  auto it = g_slots_by_wire_id.find(wire_id);
  return it == g_slots_by_wire_id.end() ? nullptr : it->second;
}

// Host-set navigation scheme allowlist (lowercased; `--allowed-schemes=a,b`).
// Empty = allow all. `about` is always allowed (the blank placeholder).
// Enforced in HostClient::OnBeforeBrowse so it covers the initial load,
// programmatic navigation (navigate), in-page clicks, and redirects. The host's
// explicit content-injection APIs (loadHtmlString -> data:, loadFile -> file:)
// are NOT subject to it — they arrive as kOpLoadTrusted and arm an exact-URL
// exemption in the browser's Slot::trusted_pending so their load isn't refused.
std::set<std::string> g_allowed_schemes;

// Registered JS channel names (UI-thread-only). On each frame load we inject a
// window.<name>.postMessage shim that routes to the host over window.cefQuery
// (the CefMessageRouter channel — renderer half lives in process_helper.mm).
std::set<std::string> g_channels;

// A JS channel name is interpolated into the injected shim's source, so it MUST
// be a plain JS identifier — otherwise a crafted name could break out of the
// string literal and run arbitrary script on every page load. Reject anything
// else (DoAddChannel drops invalid names).
bool IsValidChannelName(const std::string& n) {
  if (n.empty() || n.size() > 64) return false;
  auto isFirst = [](unsigned char c) {
    return std::isalpha(c) || c == '_' || c == '$';
  };
  auto isRest = [](unsigned char c) {
    return std::isalnum(c) || c == '_' || c == '$';
  };
  if (!isFirst(static_cast<unsigned char>(n[0]))) return false;
  for (size_t i = 1; i < n.size(); ++i) {
    if (!isRest(static_cast<unsigned char>(n[i]))) return false;
  }
  return true;
}

void InjectChannelShim(CefRefPtr<CefFrame> frame, const std::string& name) {
  if (!frame) return;
  std::string js = "window['" + name +
                   "']={postMessage:function(m){window.cefQuery({request:'ch:" +
                   name + ":'+String(m),persistent:false,"
                   "onSuccess:function(){},onFailure:function(){}});}};";
  frame->ExecuteJavaScript(js, "", 0);
}

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

// Frame layout: [u32 bodyLen BE][u32 browserId BE][u8 opcode][payload]. browserId
// is the Swift-assigned wire id of the originating browser; 0 for process-level
// frames (kOpReady, process-level kOpLog). bodyLen = 4 (browserId) + 1 (op) +
// payloadLen, counting every byte after the length prefix.
void SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload,
               uint32_t payload_len) {
  if (g_ipc_fd < 0) return;
  std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
  uint32_t body_len = 4 + 1 + payload_len;
  // Assemble the whole frame and write it in one WriteAll so a partial write
  // never leaves the peer with a length prefix it can't satisfy (stream desync).
  std::vector<uint8_t> frame(4 + body_len);
  frame[0] = static_cast<uint8_t>((body_len >> 24) & 0xff);
  frame[1] = static_cast<uint8_t>((body_len >> 16) & 0xff);
  frame[2] = static_cast<uint8_t>((body_len >> 8) & 0xff);
  frame[3] = static_cast<uint8_t>(body_len & 0xff);
  frame[4] = static_cast<uint8_t>((browser_id >> 24) & 0xff);
  frame[5] = static_cast<uint8_t>((browser_id >> 16) & 0xff);
  frame[6] = static_cast<uint8_t>((browser_id >> 8) & 0xff);
  frame[7] = static_cast<uint8_t>(browser_id & 0xff);
  frame[8] = opcode;
  if (payload_len) memcpy(frame.data() + 9, payload, payload_len);
  WriteAll(g_ipc_fd, frame.data(), frame.size());
}

void SendLog(uint32_t browser_id, const std::string& msg) {
  SendFrame(browser_id, kOpLog, msg.data(), static_cast<uint32_t>(msg.size()));
}

void SendUtf8(uint32_t browser_id, uint8_t op, const std::string& s) {
  SendFrame(browser_id, op, s.data(), static_cast<uint32_t>(s.size()));
}

void SendLoadState(uint32_t browser_id, bool loading, bool back, bool forward) {
  uint8_t p[3];
  p[0] = loading ? 1 : 0;
  p[1] = back ? 1 : 0;
  p[2] = forward ? 1 : 0;
  SendFrame(browser_id, kOpLoadState, p, 3);
}

// op payload: [u32 BE code][utf8 body]. Used for load-error and console.
void SendCodePlusUtf8(uint32_t browser_id, uint8_t op, uint32_t code,
                      const std::string& body) {
  std::vector<uint8_t> p(4 + body.size());
  p[0] = (code >> 24) & 0xff;
  p[1] = (code >> 16) & 0xff;
  p[2] = (code >> 8) & 0xff;
  p[3] = code & 0xff;
  memcpy(p.data() + 4, body.data(), body.size());
  SendFrame(browser_id, op, p.data(), static_cast<uint32_t>(p.size()));
}

uint32_t ReadU32BE(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) |
         uint32_t(p[3]);
}

void WriteU32BE(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>((v >> 24) & 0xff);
  p[1] = static_cast<uint8_t>((v >> 16) & 0xff);
  p[2] = static_cast<uint8_t>((v >> 8) & 0xff);
  p[3] = static_cast<uint8_t>(v & 0xff);
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

  // Report the device scale so CEF renders the OSR buffer at logical*dpr
  // (Retina-native) instead of 1x upscaled — fixes the blur on HiDPI displays.
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    info.device_scale_factor = static_cast<float>(slot_->dpr);
    info.rect = CefRect(0, 0, slot_->width, slot_->height);
    info.available_rect = info.rect;
    return true;
  }

  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
               const void* buffer, int width, int height) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
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
    SendFrame(slot_->browser_id, kOpPresent, nullptr, 0);
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

  // Software-composite the view (optional GPU surface, stride-aware) and the open
  // popup into the host-allocated slot_->surface and present it. Used only while
  // a <select> dropdown is open, since a popup can't ride the zero-copy texture.
  // Caller holds slot_->surface_mutex.
  void CompositeSoftwareLocked(IOSurfaceRef view_src) {
    if (!slot_->surface) return;
    if (IOSurfaceLock(slot_->surface, 0, nullptr) != kIOReturnSuccess) return;
    auto* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(slot_->surface));
    const size_t ds = IOSurfaceGetBytesPerRow(slot_->surface);
    const int dw = static_cast<int>(IOSurfaceGetWidth(slot_->surface));
    const int dh = static_cast<int>(IOSurfaceGetHeight(slot_->surface));
    if (view_src &&
        IOSurfaceLock(view_src, kIOSurfaceLockReadOnly, nullptr) ==
            kIOReturnSuccess) {
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
    SendFrame(slot_->browser_id, kOpPresent, nullptr, 0);
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
    IOSurfaceRef src =
        reinterpret_cast<IOSurfaceRef>(info.shared_texture_io_surface);
    if (!src) {
      SendLog(slot_->browser_id, "OnAcceleratedPaint: null io_surface");
      return;
    }
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    if (!slot_->surface) return;  // disposed under us (see OnBeforeClose)
    if (type == PET_POPUP) {
      CopyAccelToPopupBuf(src);
      CompositeSoftwareLocked(nullptr);  // popup over latest view in slot->surface
      return;
    }
    CompositeSoftwareLocked(src);  // GPU-composited view (+ any open popup)
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

class HostClient : public CefClient,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefFindHandler,
                   public CefJSDialogHandler,
                   public CefDownloadHandler,
                   public CefRequestHandler,
                   public CefMessageRouterBrowserSide::Handler {
 public:
  explicit HostClient(std::shared_ptr<Slot> slot) : slot_(std::move(slot)) {
    CefMessageRouterConfig config;  // default: window.cefQuery / cefQueryCancel
    router_ = CefMessageRouterBrowserSide::Create(config);
    router_->AddHandler(this, false);
    rh_ = new HostRenderHandler(slot_);
  }
  CefRefPtr<CefMessageRouterBrowserSide> router_;
  CefRefPtr<CefRenderHandler> rh_;
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return rh_; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefDownloadHandler: allow downloads (CEF blocks them without a handler) and
  // notify the host. Continue with an empty path + show_dialog so the user picks
  // where to save via the native panel.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    SendUtf8(slot_->browser_id, kOpDownload, suggested_name.ToString());
    callback->Continue(CefString(), true);
    return true;
  }

  // CefFindHandler: report find-in-page results to the host.
  void OnFindResult(CefRefPtr<CefBrowser>, int /*identifier*/, int count,
                    const CefRect& /*selectionRect*/, int activeMatchOrdinal,
                    bool finalUpdate) override {
    uint32_t c = static_cast<uint32_t>(count);
    uint32_t a = static_cast<uint32_t>(activeMatchOrdinal);
    uint8_t p[9] = {static_cast<uint8_t>((c >> 24) & 0xff),
                    static_cast<uint8_t>((c >> 16) & 0xff),
                    static_cast<uint8_t>((c >> 8) & 0xff),
                    static_cast<uint8_t>(c & 0xff),
                    static_cast<uint8_t>((a >> 24) & 0xff),
                    static_cast<uint8_t>((a >> 16) & 0xff),
                    static_cast<uint8_t>((a >> 8) & 0xff),
                    static_cast<uint8_t>(a & 0xff),
                    static_cast<uint8_t>(finalUpdate ? 1 : 0)};
    SendFrame(slot_->browser_id, kOpFindResult, p, 9);
  }

  // CefJSDialogHandler: forward alert/confirm/prompt to the host, which shows a
  // native dialog and answers back over the IPC (DoJsDialogResp -> Continue).
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& /*suppress_message*/) override {
    uint32_t id = slot_->dialog_next++;
    slot_->dialogs[id] = callback;
    uint32_t type = dialog_type == JSDIALOGTYPE_ALERT
                        ? 0
                        : (dialog_type == JSDIALOGTYPE_CONFIRM ? 1 : 2);
    std::string msg = message_text.ToString();
    std::string def = default_prompt_text.ToString();
    std::vector<uint8_t> p(12 + msg.size() + def.size());
    uint32_t ml = static_cast<uint32_t>(msg.size());
    for (int i = 0; i < 4; ++i) {
      p[i] = (id >> (24 - 8 * i)) & 0xff;
      p[4 + i] = (type >> (24 - 8 * i)) & 0xff;
      p[8 + i] = (ml >> (24 - 8 * i)) & 0xff;
    }
    memcpy(p.data() + 12, msg.data(), msg.size());
    memcpy(p.data() + 12 + msg.size(), def.data(), def.size());
    SendFrame(slot_->browser_id, kOpJsDialog, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // we answer asynchronously via Continue()
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString&, bool,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    // Always allow navigation away (don't block on "leave this page?").
    callback->Continue(true, CefString());
    return true;
  }
  // CEF calls this when a pending dialog is dismissed by navigation / reload /
  // renderer death. Drop any held callbacks so they don't leak (the host may
  // never send a response for a dialog the page already abandoned).
  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    slot_->dialogs.clear();
  }

  // Recover from a renderer crash (multi-process only): reload rather than show
  // a dead page. In single-process a renderer CHECK kills the whole process, so
  // this never fires — which is why heavy pages need multi-process.
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int /*error_code*/,
                                 const CefString& /*error_string*/) override {
    SendLog(slot_->browser_id, "renderer terminated (status " +
                                   std::to_string(status) + ") — reloading");
    if (router_) router_->OnRenderProcessTerminated(browser);
    if (browser) browser->ReloadIgnoreCache();
  }

  // CefLoadHandler: spinner + back/forward enablement.
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    SendLoadState(slot_->browser_id, isLoading, canGoBack, canGoForward);
  }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   TransitionType) override {
    if (!frame) return;
    if (frame->IsMain())
      SendUtf8(slot_->browser_id, kOpPageStart, frame->GetURL().ToString());
    // (Re)install JS-channel shims for this freshly-loaded frame.
    for (const auto& name : g_channels) InjectChannelShim(frame, name);
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                 int /*httpStatusCode*/) override {
    if (frame && frame->IsMain())
      SendUtf8(slot_->browser_id, kOpPageFinish, frame->GetURL().ToString());
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& text, const CefString& url) override {
    if (code == ERR_ABORTED) return;
    SendCodePlusUtf8(slot_->browser_id, kOpLoadErr, static_cast<uint32_t>(code),
                     url.ToString() + "\n" + text.ToString());
  }

  // CefDisplayHandler: title / address / console -> host.
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    SendUtf8(slot_->browser_id, kOpTitle, title.ToString());
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame && frame->IsMain())
      SendUtf8(slot_->browser_id, kOpUrl, url.ToString());
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level,
                        const CefString& message, const CefString& source,
                        int line) override {
    SendCodePlusUtf8(slot_->browser_id, kOpConsole,
                     static_cast<uint32_t>(level),
                     source.ToString() + ":" + std::to_string(line) + "\t" +
                         message.ToString());
    return false;  // also keep CEF's default console logging
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    uint32_t pct = static_cast<uint32_t>(progress * 100.0 + 0.5);
    uint8_t p[4] = {static_cast<uint8_t>((pct >> 24) & 0xff),
                    static_cast<uint8_t>((pct >> 16) & 0xff),
                    static_cast<uint8_t>((pct >> 8) & 0xff),
                    static_cast<uint8_t>(pct & 0xff)};
    SendFrame(slot_->browser_id, kOpProgress, p, 4);
  }

  // CefLifeSpanHandler: route popups (window.open / target=_blank) to the host
  // instead of opening a native window. Returning true cancels the native popup;
  // the host decides what to do (commonly load the URL in the same view). This
  // mirrors webview_flutter, which surfaces new-window requests through its
  // navigation delegate rather than a separate window.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     WindowOpenDisposition, bool, const CefPopupFeatures&,
                     CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (!target_url.empty())
      SendUtf8(slot_->browser_id, kOpNewWindow, target_url.ToString());
    return true;
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
    SendFrame(slot_->browser_id, kOpCursor, p, 4);
    return true;
  }

  // CefMessageRouter wiring: the renderer half (process_helper.mm) injects
  // window.cefQuery; queries land here. We forward the request string to the
  // host: "eval:<id>:<json>" for a runJavaScriptReturningResult result,
  // "ch:<name>:<message>" for a JS-channel post.
  bool OnQuery(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int64_t,
               const CefString& request, bool,
               CefRefPtr<Callback> callback) override {
    std::string r = request.ToString();
    if (r.rfind("eval:", 0) == 0) {
      SendUtf8(slot_->browser_id, kOpEvalResult, r.substr(5));
      callback->Success(CefString());
      return true;
    }
    if (r.rfind("ch:", 0) == 0) {
      SendUtf8(slot_->browser_id, kOpChannelMsg, r.substr(3));
      callback->Success(CefString());
      return true;
    }
    return false;
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    return router_->OnProcessMessageReceived(browser, frame, source_process,
                                             message);
  }
  // Centralized per-browser teardown (CEF UI thread). CloseBrowser(true) — sent
  // by DoDisposeBrowser or DoShutdown — lands here. Drop the routing-map entries
  // (so no inbound op or paint can find this slot again), release the host
  // IOSurface under the slot's lock (nulling it FIRST so a GPU-thread paint
  // racing this teardown sees null and no-ops, then CFRelease the old surface),
  // and break the HostClient -> Slot -> CefBrowser -> HostClient retain cycle by
  // nulling slot_->browser. The last shared_ptr<Slot> drops once any in-flight
  // paint refs (which copied the shared_ptr) drain.
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (router_) router_->OnBeforeClose(browser);
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(slot_->browser_id);
    }
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      IOSurfaceRef old = slot_->surface;
      slot_->surface = nullptr;
      if (old) CFRelease(old);
    }
    slot_->browser = nullptr;
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool, bool) override {
    if (!g_allowed_schemes.empty()) {
      const std::string url = request->GetURL().ToString();
      // Only gate MAIN-frame navigations. A subframe can't change the view's
      // top-level origin (it's already same-policy-constrained by Chromium), and
      // gating subframes would cancel legitimate cross-scheme embeds — blob: /
      // data: iframes, PDF/video viewers, ad frames — breaking real pages.
      const bool main_frame = !frame || frame->IsMain();
      // A host content-injection load (loadHtmlString -> data:, loadFile ->
      // file:) armed an exact-URL exemption in DoNavigateTrusted. Honor it only
      // for the matching main-frame request, and consume that one entry, so a
      // page navigation to a different URL can't steal it. A redirect of a
      // trusted load carries a different URL and so remains gated.
      bool host_trusted = false;
      if (main_frame) {
        auto it = slot_->trusted_pending.find(url);
        if (it != slot_->trusted_pending.end()) {
          slot_->trusted_pending.erase(it);
          host_trusted = true;
        }
      }
      if (main_frame && !host_trusted) {
        const size_t colon = url.find(':');
        std::string scheme =
            colon == std::string::npos ? std::string() : url.substr(0, colon);
        std::transform(scheme.begin(), scheme.end(), scheme.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        // `about:` (blank placeholder) is always allowed; anything else must be
        // in the host allowlist or the navigation is refused.
        if (scheme != "about" && g_allowed_schemes.count(scheme) == 0) {
          return true;  // cancel
        }
      }
    }
    if (router_) router_->OnBeforeBrowse(browser, frame);
    return false;  // allow
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostClient);
};

// The CDP port for this session (0 = CDP disabled). Set from --cdp-port before
// CefInitialize; read in OnBeforeCommandLineProcessing to allow CDP WebSocket
// origins (Chromium M113+ rejects them by default).
int g_cdp_port = 0;

class HostApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString&, CefRefPtr<CefCommandLine> command_line) override {
#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc-only (CEF_HOST_ADHOC is ON by default; a signed release sets
    // -DCEF_HOST_ADHOC=OFF). Mock keychain + basic password store so a launch
    // doesn't raise the macOS Keychain access prompt every time. A signed
    // release omits these and uses the real Keychain via OSCrypt.
    command_line->AppendSwitch("use-mock-keychain");
    command_line->AppendSwitchWithValue("password-store", "basic");
#endif
#ifndef CEF_HOST_MULTIPROCESS
    // Single-process (-DCEF_MULTI_PROCESS=OFF; NOT the default): renderer + GPU
    // + utility all share this process, so there are no Mach-port peers to
    // validate (Chromium 144's -67030). The catch: heavy pages whose work lands
    // on the in-process utility thread (e.g. Google sign-in probing WebAuthn/HID
    // security keys) can CHECK-crash the whole process. It's best for
    // simpler/first-party content; the default multi-process build isolates
    // those crashes.
    command_line->AppendSwitch("single-process");
#endif
#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc-only: disable Chromium 144's Mach-port peer-requirement
    // validation, which otherwise -67030s the multi-process GPU→browser handoff
    // (OnAcceleratedPaint) under an ad-hoc signature. (Harmless in
    // single-process, where there are no peers to validate.) Together with the
    // shared-texture GPU OSR path this lets the accelerated path run
    // multi-process (crash-isolated) WITHOUT Developer-ID signing. A signed
    // release omits this and enforces validation, which then requires correct
    // inside-out Developer-ID signing of the cef_host tree.
    command_line->AppendSwitchWithValue(
        "disable-features",
        "MachPortRendezvousValidatePeerRequirements,"
        "MachPortRendezvousEnforcePeerRequirements");
#endif
    // Verbose Chromium logging to /tmp only when explicitly debugging; off by
    // default so a shipped build doesn't write logs behind the user's back.
    if (std::getenv("FLUTTER_CEF_DEBUG")) {
      command_line->AppendSwitch("enable-logging");
      command_line->AppendSwitchWithValue("log-file", "/tmp/cef_host_chromium.log");
      command_line->AppendSwitchWithValue("v", "1");
    }
    // CDP WebSocket origin allow-list: Chromium M113+ rejects DevTools WS
    // connections whose Origin isn't allow-listed (anti-CSRF on the local debug
    // port). For local automation we allow all origins so any CDP client
    // (Playwright, chrome-remote-interface) connects; the endpoint is still
    // bound to 127.0.0.1 only and CDP is opt-in, so exposure is unchanged.
    if (g_cdp_port > 0) {
      command_line->AppendSwitchWithValue("remote-allow-origins", "*");
    }
  }
  // No browser is created here. We only announce readiness; the host then drives
  // browser creation on demand via kOpCreateBrowser (one per CefWebView sharing
  // this profile). Nothing loads — and nothing is written to the profile cache —
  // until the first kOpCreateBrowser, which is the safety window the host uses to
  // refuse a persistent profile under a mock-keychain (ad-hoc) build (F.5). The
  // readyFlags byte tells the host whether this is an ad-hoc build (bit0).
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      fprintf(stderr, "[cef_host] OnContextInitialized\n");
    uint8_t ready_flags = 0;
#ifdef CEF_HOST_ADHOC
    ready_flags |= 0x01;  // bit0 = ad-hoc / mock-keychain build
#endif
    SendFrame(/*browser_id=*/0, kOpReady, &ready_flags, 1);
  }
  IMPLEMENT_REFCOUNTING(HostApp);
};

// ---- CEF-thread task helpers (IPC reader runs off the UI thread) ----

// Create a windowless browser for a CefWebView (kOpCreateBrowser). Runs on the
// CEF UI thread. wire_id is the Swift-assigned browser id this slot is keyed by;
// sid is the host's IOSurface for this view (0 / lookup-failure -> no surface
// until the first resize). Builds the Slot, registers it in both routing maps,
// and creates the CEF browser bound to a HostClient that holds the slot.
void DoCreateBrowser(uint32_t wire_id, int w, int h, double dpr, uint32_t sid,
                     std::string url) {
  CEF_REQUIRE_UI_THREAD();
  auto slot = std::make_shared<Slot>();
  slot->browser_id = wire_id;
  slot->width = w < 1 ? 1 : w;
  slot->height = h < 1 ? 1 : h;
  slot->dpr = dpr;
  if (sid) {
    slot->surface = IOSurfaceLookup(sid);  // owns the +1 from Lookup
    if (!slot->surface)
      SendLog(wire_id, "createBrowser: IOSurfaceLookup failed for id " +
                           std::to_string(sid));
  }
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    g_slots_by_wire_id[wire_id] = slot;
  }
  CefWindowInfo window_info;
  window_info.SetAsWindowless(0);
#ifdef CEF_HOST_MULTIPROCESS
  // Multi-process GPU OSR: the GPU/Viz process composites on the GPU and hands
  // the frame to OnAcceleratedPaint as a shared IOSurface, which we copy into
  // the host surface. This used to be gated by -67030 (process_requirement.cc
  // peer validation of this process's ad-hoc signature), but disabling the
  // MachPortRendezvous*PeerRequirements features above clears it — so the
  // GPU-accelerated path runs multi-process (crash-isolated) without
  // Developer-ID signing. (The software OnPaint path remains the fallback if a
  // build leaves shared_texture_enabled off.) All browsers in this process share
  // one GPU/Viz process; set per-create, it resolves to that same process (the
  // second+ browser attaching cleanly is the one multiplex behavior to confirm
  // at runtime under a signed build — see CONTRACT H.6).
  window_info.shared_texture_enabled = true;
#endif
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 60;
  CefRefPtr<HostClient> client = new HostClient(slot);
  CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
      window_info, client, url, settings, nullptr, nullptr);
  slot->browser = browser;
  if (!browser) {
    // CreateBrowserSync failed: OnBeforeClose (the only path that erases the
    // wire-id entry and releases slot->surface) can never fire without a
    // browser, so reclaim here or the slot + the looked-up IOSurface (+1 ref)
    // leak forever and the wire id is stranded.
    SendLog(wire_id, "createBrowser: CreateBrowserSync returned null");
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(wire_id);
    }
    std::lock_guard<std::mutex> slock(slot->surface_mutex);
    if (slot->surface) {
      CFRelease(slot->surface);
      slot->surface = nullptr;
    }
  }
  if (std::getenv("FLUTTER_CEF_DEBUG"))
    fprintf(stderr, "[cef_host] createBrowser wire=%u browser=%p\n", wire_id,
            (void*)browser.get());
}

// Close one browser (kOpDisposeBrowser). Runs on the CEF UI thread. The actual
// map-erase + surface release happen in OnBeforeClose once CEF finishes closing.
void DoDisposeBrowser(uint32_t wire_id) {
  CEF_REQUIRE_UI_THREAD();
  std::shared_ptr<Slot> slot = LookupWireId(wire_id);
  if (slot && slot->browser) slot->browser->GetHost()->CloseBrowser(true);
}

void DoResize(const std::shared_ptr<Slot>& slot, int w, int h,
              uint32_t surface_id) {
  if (w < 1 || w > 16384 || h < 1 || h > 16384) {
    SendLog(slot->browser_id, "resize: out-of-range dims " + std::to_string(w) +
                                  "x" + std::to_string(h));
    return;
  }
  IOSurfaceRef next = IOSurfaceLookup(surface_id);
  if (!next) {
    SendLog(slot->browser_id,
            "resize: IOSurfaceLookup failed for id " + std::to_string(surface_id));
    return;
  }
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    if (slot->surface) CFRelease(slot->surface);
    slot->surface = next;  // owns the +1 from Lookup
    slot->width = w;
    slot->height = h;
  }
  if (slot->browser) slot->browser->GetHost()->WasResized();
}

void DoNavigate(const std::shared_ptr<Slot>& slot, const std::string& url) {
  if (!slot->browser) return;
  CefRefPtr<CefFrame> f = slot->browser->GetMainFrame();
  if (f) f->LoadURL(url);
}

// A host content-injection load (loadHtmlString -> data:, loadFile -> file:).
// Runs on the CEF UI thread. Arm an exact-URL exemption so this specific load's
// OnBeforeBrowse (a later UI task) skips the scheme allowlist, while a page nav
// to any other URL stays gated. Only arm when an allowlist is actually set —
// g_allowed_schemes is immutable after startup, so when the feature is off this
// is a plain navigate and we don't accumulate unconsumed entries. Trusted
// because the host explicitly chose this content, not the page.
void DoNavigateTrusted(const std::shared_ptr<Slot>& slot,
                       const std::string& url) {
  if (!g_allowed_schemes.empty()) slot->trusted_pending.insert(url);
  DoNavigate(slot, url);
}

void DoReload(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->Reload();
}
void DoStopLoad(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->StopLoad();
}
void DoGoBack(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GoBack();
}
void DoGoForward(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GoForward();
}
void DoExecuteJs(const std::shared_ptr<Slot>& slot, const std::string& code) {
  if (!slot->browser) return;
  CefRefPtr<CefFrame> f = slot->browser->GetMainFrame();
  if (f) f->ExecuteJavaScript(code, "", 0);
}
void DoSetZoom(const std::shared_ptr<Slot>& slot, double level) {
  if (slot->browser) slot->browser->GetHost()->SetZoomLevel(level);
}
// Off-screen render gating. WasHidden(true) makes CEF stop producing frames
// (no OnPaint, the compositor idles) until WasHidden(false); the browser stays
// alive, so this is a cheap pause/resume — not a teardown. The host pauses a
// tile that scrolls fully out of the canvas viewport and resumes it on return.
void DoSetVisible(const std::shared_ptr<Slot>& slot, bool visible) {
  if (slot->browser) slot->browser->GetHost()->WasHidden(!visible);
}
void DoFind(const std::shared_ptr<Slot>& slot, const std::string& text,
            bool forward, bool match_case, bool find_next) {
  if (slot->browser)
    slot->browser->GetHost()->Find(text, forward, match_case, find_next);
}
void DoStopFind(const std::shared_ptr<Slot>& slot, bool clear_selection) {
  if (slot->browser) slot->browser->GetHost()->StopFinding(clear_selection);
}
void DoJsDialogResp(const std::shared_ptr<Slot>& slot, uint32_t id, bool ok,
                    const std::string& text) {
  auto it = slot->dialogs.find(id);
  if (it == slot->dialogs.end()) return;
  it->second->Continue(ok, text);
  slot->dialogs.erase(it);
}
void DoEvalReturning(const std::shared_ptr<Slot>& slot, uint32_t id,
                     const std::string& code) {
  if (!slot->browser) return;
  CefRefPtr<CefFrame> frame = slot->browser->GetMainFrame();
  if (!frame) return;
  // Evaluate the user expression and post its JSON result back via window.cefQuery
  // (OnQuery -> kOpEvalResult). `code` is the trusted host's JS (same trust level
  // as executeJavaScript) and must be a single expression. We splice it rather
  // than eval() it so it still works under a strict page CSP (eval would be
  // blocked); the Dart side fails any pending result on navigation so a malformed
  // expression that wedges this callback can't leak a completer forever.
  std::string js =
      "window.cefQuery({request:'eval:" + std::to_string(id) +
      ":'+(function(){try{return JSON.stringify({ok:true,v:(" + code +
      "\n)});}catch(e){return JSON.stringify({ok:false,v:String(e)});}})(),"
      "persistent:false,onSuccess:function(){},onFailure:function(){}});";
  frame->ExecuteJavaScript(js, "", 0);
}
void DoAddChannel(const std::shared_ptr<Slot>& slot, const std::string& name) {
  if (!IsValidChannelName(name)) {
    SendLog(slot->browser_id, "addJavaScriptChannel: rejected invalid name '" +
                                  name + "' (must be a JS identifier)");
    return;
  }
  g_channels.insert(name);
  if (slot->browser) InjectChannelShim(slot->browser->GetMainFrame(), name);
}
// Cookie ops act on the GLOBAL cookie manager (= the shared profile jar), so a
// login in one browser is visible to every browser sharing this profile. They
// take `slot` only to stamp the reply browserId / route a log. Note clear/delete
// affect the WHOLE shared jar by design (the contract's kOpClearCookies semantics).
void DoSetCookie(const std::shared_ptr<Slot>& slot, const std::string& url,
                 const std::string& name, const std::string& value,
                 const std::string& domain, const std::string& path) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (!mgr) return;
  CefCookie cookie;
  CefString(&cookie.name).FromString(name);
  CefString(&cookie.value).FromString(value);
  if (!domain.empty()) CefString(&cookie.domain).FromString(domain);
  CefString(&cookie.path).FromString(path.empty() ? "/" : path);
  cookie.has_expires = false;
  if (!mgr->SetCookie(url, cookie, nullptr)) {
    SendLog(slot->browser_id,
            "setCookie rejected for " + url + " (name '" + name + "')");
  }
}
void DoClearCookies(const std::shared_ptr<Slot>& slot) {
  (void)slot;  // shared jar; slot unused beyond routing the op here
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(CefString(), CefString(), nullptr);
}

// JSON-escape a UTF-8 string for embedding in the cookie array.
std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (unsigned char ch : s) {
    switch (ch) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (ch < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", ch);
          out += buf;
        } else {
          out += static_cast<char>(ch);
        }
    }
  }
  return out;
}

std::string CookieToJson(const CefCookie& c) {
  std::string out = "{";
  out += "\"name\":\"" + JsonEscape(CefString(&c.name).ToString()) + "\",";
  out += "\"value\":\"" + JsonEscape(CefString(&c.value).ToString()) + "\",";
  out += "\"domain\":\"" + JsonEscape(CefString(&c.domain).ToString()) + "\",";
  out += "\"path\":\"" + JsonEscape(CefString(&c.path).ToString()) + "\",";
  out += "\"secure\":" + std::string(c.secure ? "true" : "false") + ",";
  out += "\"httpOnly\":" + std::string(c.httponly ? "true" : "false");
  return out + "}";
}

// Accumulates a Visit pass and flushes the JSON array on destruction, so the
// 0-cookie case (Visit never called) still replies (godot-cef does the same).
class HostCookieVisitor : public CefCookieVisitor {
 public:
  HostCookieVisitor(uint32_t browser_id, uint32_t id)
      : browser_id_(browser_id), id_(id) {}
  bool Visit(const CefCookie& cookie, int, int, bool&) override {
    if (!json_.empty()) json_ += ",";
    json_ += CookieToJson(cookie);
    return true;
  }
  ~HostCookieVisitor() override {
    // Stamp the reply with the browser that asked, so the host routes the
    // kOpCookies result back to the right CefWebSession.
    SendCodePlusUtf8(browser_id_, kOpCookies, id_, "[" + json_ + "]");
  }

 private:
  uint32_t browser_id_;
  uint32_t id_;
  std::string json_;
  IMPLEMENT_REFCOUNTING(HostCookieVisitor);
};

void DoVisitCookies(const std::shared_ptr<Slot>& slot, uint32_t id,
                    const std::string& url) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  // The visitor replies on destruction; a null manager just yields [].
  CefRefPtr<HostCookieVisitor> visitor =
      new HostCookieVisitor(slot->browser_id, id);
  if (!mgr) return;
  if (url.empty()) {
    mgr->VisitAllCookies(visitor);
  } else {
    mgr->VisitUrlCookies(url, true, visitor);
  }
}

void DoDeleteCookie(const std::shared_ptr<Slot>& slot, const std::string& url,
                    const std::string& name) {
  (void)slot;  // shared jar; slot unused beyond routing the op here
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(url, name, nullptr);
}

void DoShowDevTools(const std::shared_ptr<Slot>& slot) {
  if (!slot->browser) return;
  // Windowed DevTools (default CefWindowInfo is windowed) — the OSR host can
  // still host a real window. null client lets CEF manage it.
  CefWindowInfo window_info;
  CefBrowserSettings settings;
  slot->browser->GetHost()->ShowDevTools(window_info, nullptr, settings,
                                         CefPoint());
}
void DoImeSetComposition(const std::shared_ptr<Slot>& slot,
                         const std::string& text) {
  if (!slot->browser) return;
  CefString t(text);
  uint32_t len = static_cast<uint32_t>(t.length());
  // Mark the whole composition with a single underline so the in-progress text
  // is visibly distinguished (transparent color -> Blink picks an adaptive
  // default that reads on both light and dark pages). The caret sits at the end.
  std::vector<CefCompositionUnderline> underlines;
  if (len > 0) {
    CefCompositionUnderline u;
    u.range = CefRange(0, len);
    u.color = 0;             // transparent: let Blink choose a contrasting color
    u.background_color = 0;  // transparent background
    u.thick = 0;             // thin underline
    u.style = CEF_CUS_SOLID;
    underlines.push_back(u);
  }
  slot->browser->GetHost()->ImeSetComposition(t, underlines,
                                              CefRange::InvalidRange(),
                                              CefRange(len, len));
}
void DoImeCommitText(const std::shared_ptr<Slot>& slot,
                     const std::string& text) {
  if (slot->browser)
    slot->browser->GetHost()->ImeCommitText(text, CefRange::InvalidRange(), 0);
}
void DoImeCancel(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GetHost()->ImeCancelComposition();
}

// type: 0=move 1=down 2=up 3=wheel; button: 0=left 1=middle 2=right.
void DoPointer(const std::shared_ptr<Slot>& slot, int type, int button,
               int click_count, uint32_t modifiers, double x, double y,
               double dx, double dy) {
  if (!slot->browser) return;
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;
  CefRefPtr<CefBrowserHost> host = slot->browser->GetHost();
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
    case 4:
      // Cursor left the view: a move with mouseLeave=true clears hover state.
      host->SendMouseMoveEvent(ev, true);
      break;
    case 3:
      host->SendMouseWheelEvent(ev, static_cast<int>(dx), static_cast<int>(dy));
      break;
    default:
      break;
  }
}

// type: 0=rawkeydown 2=keyup 3=char (cef_key_event_type_t).
void DoKey(const std::shared_ptr<Slot>& slot, int type, uint32_t modifiers,
           int32_t windows_key_code, int32_t native_key_code,
           uint32_t character) {
  if (!slot->browser) return;
  CefKeyEvent ev;
  ev.type = static_cast<cef_key_event_type_t>(type);
  ev.modifiers = modifiers;
  ev.windows_key_code = windows_key_code;
  ev.native_key_code = native_key_code;
  // ALWAYS set the character fields, not just for CHAR. On macOS OSR, an editing
  // or navigation key (Backspace, arrows, …) with a zero character is applied
  // TWICE inside Blink — populating it with the real NSEvent codepoint
  // de-duplicates it (CEF forum t=11650). 0 for printable keys is fine: their
  // text rides the IME ImeCommitText path, and a raw keydown inserts nothing.
  ev.character = static_cast<char16_t>(character);
  ev.unmodified_character = static_cast<char16_t>(character);
  slot->browser->GetHost()->SendKeyEvent(ev);
}

// Tear down the WHOLE process: close every browser, then quit the message loop.
// Each browser's per-slot cleanup (maps, surface, retain-cycle break) runs in
// OnBeforeClose as CEF processes the CloseBrowser(true). Sent when the host
// disposes the last browser, on socket loss, or on parent death.
void DoShutdown() {
  std::vector<std::shared_ptr<Slot>> slots;
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    slots.reserve(g_slots_by_wire_id.size());
    for (auto& kv : g_slots_by_wire_id) slots.push_back(kv.second);
  }
  for (auto& slot : slots) {
    if (slot->browser) slot->browser->GetHost()->CloseBrowser(true);
  }
  CefQuitMessageLoop();
}

// Reader thread: decode frames, marshal onto the CEF UI thread.
void IpcReadLoop() {
  for (;;) {
    uint8_t hdr[4];
    if (!ReadAll(g_ipc_fd, hdr, 4)) break;
    uint32_t body_len = ReadU32BE(hdr);
    // Minimum valid body is 5 bytes (4 browserId + 1 op + 0 payload).
    if (body_len < 5 || body_len > (64u << 20)) break;
    std::vector<uint8_t> body(body_len);
    if (!ReadAll(g_ipc_fd, body.data(), body_len)) break;
    uint32_t wire_id = ReadU32BE(body.data());
    uint8_t opcode = body[4];
    const uint8_t* p = body.data() + 5;
    uint32_t plen = body_len - 5;
    // Resolve the target browser once. null for wire id 0 (process-level) or an
    // unknown/disposed id. Per-browser ops bind this shared_ptr into their UI
    // task, so the slot stays alive even if a dispose lands while the task is
    // queued (closes the dispose/in-flight race). Control ops handle slot==null.
    std::shared_ptr<Slot> slot = LookupWireId(wire_id);
    switch (opcode) {
      case kOpCreateBrowser: {
        if (plen < 20) break;  // {u32 w}{u32 h}{f64 dpr}{u32 sid}{utf8 url}
        int w = static_cast<int>(ReadU32BE(p));
        int h = static_cast<int>(ReadU32BE(p + 4));
        double dpr = ReadF64BE(p + 8);
        if (dpr <= 0.0 || dpr > 8.0) dpr = 1.0;  // guard a bad/forged dpr
        uint32_t sid = ReadU32BE(p + 16);
        std::string url(reinterpret_cast<const char*>(p + 20), plen - 20);
        if (url.empty()) url = "about:blank";
        CefPostTask(TID_UI, base::BindOnce(&DoCreateBrowser, wire_id, w, h, dpr,
                                           sid, url));
        break;
      }
      case kOpDisposeBrowser:
        if (slot)
          CefPostTask(TID_UI, base::BindOnce(&DoDisposeBrowser, wire_id));
        break;
      case kOpShutdown:
        CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
        return;
      case kOpResize: {
        if (!slot) break;
        if (plen < 12) break;
        int w = static_cast<int>(ReadU32BE(p));
        int h = static_cast<int>(ReadU32BE(p + 4));
        uint32_t sid = ReadU32BE(p + 8);
        CefPostTask(TID_UI, base::BindOnce(&DoResize, slot, w, h, sid));
        break;
      }
      case kOpNavigate: {
        if (!slot) break;
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoNavigate, slot, url));
        break;
      }
      case kOpLoadTrusted: {
        if (!slot) break;
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoNavigateTrusted, slot, url));
        break;
      }
      case kOpReload:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoReload, slot));
        break;
      case kOpStop:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoStopLoad, slot));
        break;
      case kOpBack:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoGoBack, slot));
        break;
      case kOpForward:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoGoForward, slot));
        break;
      case kOpExecuteJs: {
        if (!slot) break;
        std::string code(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoExecuteJs, slot, code));
        break;
      }
      case kOpSetZoom: {
        if (!slot) break;
        if (plen < 8) break;
        CefPostTask(TID_UI, base::BindOnce(&DoSetZoom, slot, ReadF64BE(p)));
        break;
      }
      case kOpSetVisible: {
        if (!slot) break;
        bool vis = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoSetVisible, slot, vis));
        break;
      }
      case kOpFind: {
        if (!slot) break;
        if (plen < 3) break;
        bool fwd = p[0] != 0, mc = p[1] != 0, fn = p[2] != 0;
        std::string text(reinterpret_cast<const char*>(p + 3), plen - 3);
        CefPostTask(TID_UI, base::BindOnce(&DoFind, slot, text, fwd, mc, fn));
        break;
      }
      case kOpStopFind: {
        if (!slot) break;
        bool clear = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoStopFind, slot, clear));
        break;
      }
      case kOpJsDialogResp: {
        if (!slot) break;
        if (plen < 5) break;
        uint32_t id = ReadU32BE(p);
        bool ok = p[4] != 0;
        std::string text(reinterpret_cast<const char*>(p + 5), plen - 5);
        CefPostTask(TID_UI, base::BindOnce(&DoJsDialogResp, slot, id, ok, text));
        break;
      }
      case kOpEvalReturning: {
        if (!slot) break;
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string code(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoEvalReturning, slot, id, code));
        break;
      }
      case kOpAddChannel: {
        if (!slot) break;
        std::string name(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoAddChannel, slot, name));
        break;
      }
      case kOpSetCookie: {
        if (!slot) break;
        std::string s(reinterpret_cast<const char*>(p), plen);
        std::vector<std::string> f;
        size_t start = 0;
        for (size_t i = 0; i <= s.size(); ++i) {
          if (i == s.size() || s[i] == '\0') {
            f.push_back(s.substr(start, i - start));
            start = i + 1;
          }
        }
        while (f.size() < 5) f.push_back("");
        CefPostTask(TID_UI, base::BindOnce(&DoSetCookie, slot, f[0], f[1], f[2],
                                           f[3], f[4]));
        break;
      }
      case kOpClearCookies:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoClearCookies, slot));
        break;
      case kOpVisitCookies: {
        if (!slot) break;
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string url(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoVisitCookies, slot, id, url));
        break;
      }
      case kOpDeleteCookie: {
        if (!slot) break;
        std::string s(reinterpret_cast<const char*>(p), plen);
        const size_t nul = s.find('\0');
        std::string url = nul == std::string::npos ? s : s.substr(0, nul);
        std::string name = nul == std::string::npos ? "" : s.substr(nul + 1);
        CefPostTask(TID_UI, base::BindOnce(&DoDeleteCookie, slot, url, name));
        break;
      }
      case kOpImeSetComp: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoImeSetComposition, slot, text));
        break;
      }
      case kOpImeCommit: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoImeCommitText, slot, text));
        break;
      }
      case kOpShowDevTools:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoShowDevTools, slot));
        break;
      case kOpImeCancel:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoImeCancel, slot));
        break;
      case kOpPointer: {
        if (!slot) break;
        if (plen < 40) break;
        int type = p[0], button = p[1], clicks = p[2];
        uint32_t mods = ReadU32BE(p + 4);
        double x = ReadF64BE(p + 8), y = ReadF64BE(p + 16);
        double dx = ReadF64BE(p + 24), dy = ReadF64BE(p + 32);
        CefPostTask(TID_UI, base::BindOnce(&DoPointer, slot, type, button,
                                           clicks, mods, x, y, dx, dy));
        break;
      }
      case kOpKey: {
        if (!slot) break;
        if (plen < 20) break;
        int type = p[0];
        uint32_t mods = ReadU32BE(p + 4);
        int32_t wkc = static_cast<int32_t>(ReadU32BE(p + 8));
        int32_t nkc = static_cast<int32_t>(ReadU32BE(p + 12));
        uint32_t ch = ReadU32BE(p + 16);
        CefPostTask(TID_UI, base::BindOnce(&DoKey, slot, type, mods, wkc, nkc,
                                           ch));
        break;
      }
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
#if defined(CEF_HOST_MULTIPROCESS) && defined(CEF_HOST_ADHOC)
  // Disable Chromium 144's Mach-port peer-requirement validation for the whole
  // process tree. The child processes read this policy from an env var (NOT the
  // FeatureList, which isn't up yet when the rendezvous runs), and the browser
  // injects it; pre-setting it here makes children inherit kNoValidation (0).
  // (Note Chromium's misspelling "VALDATION".) On macOS 26 a failed validation
  // TERMINATES children, so without this no paint callback ever fires. This is a
  // dev/CI unblock (ad-hoc only — compiled out of a signed -DCEF_HOST_ADHOC=OFF
  // release); the production fix is correct inside-out Developer-ID signing.
  setenv("MACH_PORT_RENDEZVOUS_PEER_VALDATION", "0", 1);
#endif
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    fprintf(stderr, "[cef_host] failed to load CEF framework\n");
    return 1;
  }

  // All args are now per-PROCESS / per-profile; the per-view geometry/url moved
  // into the kOpCreateBrowser payload.
  std::string ipc_path = ArgValue(argc, argv, "ipc");
  std::string allowed = ArgValue(argc, argv, "allowed-schemes");
  std::string cdp = ArgValue(argc, argv, "cdp-port");
  std::string profile_dir = ArgValue(argc, argv, "profile-dir");
  // Swift always passes --profile-dir (even for an ephemeral host, whose dir is a
  // throwaway temp dir), so profile_dir alone can't tell "persistent" from
  // "ephemeral". --ephemeral marks the throwaway case so the CDP / mock-keychain
  // guards below fire only for a real (named, persistent) profile.
  const bool is_ephemeral = !ArgValue(argc, argv, "ephemeral").empty();
  for (size_t start = 0; start < allowed.size();) {
    const size_t comma = allowed.find(',', start);
    const size_t len =
        comma == std::string::npos ? std::string::npos : comma - start;
    std::string s = allowed.substr(start, len);
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (!s.empty()) g_allowed_schemes.insert(s);
    if (comma == std::string::npos) break;
    start = comma + 1;
  }

  if (!ipc_path.empty()) {
    g_ipc_fd = ConnectUnixSocket(ipc_path);
    if (g_ipc_fd < 0) {
      fprintf(stderr, "[cef_host] failed to connect IPC socket %s\n",
              ipc_path.c_str());
    }
  }

  // Defense-in-depth (Swift is the real gate): CDP is an unauthenticated
  // localhost port that could read the shared cookie jar, so a *persistent*
  // profile must never expose it. CDP IS allowed on an ephemeral host, so gate
  // on !is_ephemeral — not on profile_dir alone, which is always set. Swift
  // already rejects CDP+named before spawn; this is belt-and-suspenders.
  if (!cdp.empty() && !profile_dir.empty() && !is_ephemeral) {
    SendLog(0,
            "ignoring --cdp-port: refusing CDP on a persistent --profile-dir");
    cdp.clear();
  }
#ifdef CEF_HOST_ADHOC
  // Ad-hoc / mock-keychain build: secrets at rest aren't really encrypted, so a
  // persistent (named) profile here is insecure. Swift downgrades named profiles
  // to ephemeral on an ad-hoc host (F.5); this is an advisory log only, and only
  // for a real persistent profile (an ephemeral throwaway dir is never at risk).
  if (!profile_dir.empty() && !is_ephemeral &&
      !std::getenv("FLUTTER_CEF_ALLOW_INSECURE_PROFILE")) {
    SendLog(0, "warning: persistent profile under mock keychain (ad-hoc build)");
  }
#endif

  // Hand Chromium ONLY the program name. Our custom switches (--ipc,
  // --cdp-port, --allowed-schemes, --profile-dir) are parsed by us above; if
  // they reach Chromium's CommandLine, cef_initialize CHECK-crashes on them.
  char* clean_argv[] = {argv[0]};
  CefMainArgs main_args(1, clean_argv);
  @autoreleasepool {
    [CefHostApplication sharedApplication];
    CefSettings settings;
#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc: the Chromium renderer/GPU sandbox is OFF. It only *validates*
    // under proper Developer-ID signing, so an ad-hoc build must run unsandboxed.
    settings.no_sandbox = true;
#else
    // Signed release (-DCEF_HOST_ADHOC=OFF): enable the Chromium renderer/GPU
    // sandbox. The browser process itself is never sandboxed on macOS — only the
    // helper subprocesses, which call CefScopedSandboxContext (process_helper.mm)
    // before loading the framework. Requires correct inside-out Developer-ID
    // signing of the cef_host tree (the libcef_sandbox.dylib + helpers + host).
    settings.no_sandbox = false;
#endif
    settings.windowless_rendering_enabled = true;
    settings.log_severity = LOGSEVERITY_INFO;
    // Chrome DevTools Protocol (CDP): the host picks a free port and passes it
    // via --cdp-port; CEF stands up the DevTools HTTP/WebSocket server on
    // 127.0.0.1:<port> (M113+ forces localhost-only). UNAUTHENTICATED — any local
    // client that reaches the port fully drives the page — so this is opt-in,
    // never set by default. CEF treats 0 as "disabled" (no auto-assign), so the
    // host must choose a real port (1024-65535).
    if (!cdp.empty()) {
      int port = atoi(cdp.c_str());
      if (port >= 1024 && port <= 65535) {
        settings.remote_debugging_port = port;
        g_cdp_port = port;  // OnBeforeCommandLineProcessing allows WS origins
      }
    }
    // Per-profile cache. The host supplies --profile-dir: a stable 0700 dir
    // under Application Support for a named (persistent, shared-login) profile,
    // or a unique throwaway temp dir for an ephemeral session. One root_cache_path
    // is shared by every browser in this process, which is what makes login
    // shared. The per-pid temp fallback is defensive — Swift always passes
    // --profile-dir, so it normally never fires. persist_session_cookies keeps
    // session cookies across relaunch (harmless for ephemeral; required for
    // "stay signed in").
    std::string cef_cache =
        !profile_dir.empty()
            ? profile_dir
            : std::string([NSTemporaryDirectory() UTF8String]) +
                  "flutter_cef_cache_" +
                  std::to_string([[NSProcessInfo processInfo] processIdentifier]);
    CefString(&settings.root_cache_path) = cef_cache;
    settings.persist_session_cookies = true;
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
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      fprintf(stderr, "[cef_host] CefInitialize OK (fd=%d)\n", g_ipc_fd);
    std::thread reader;
    if (g_ipc_fd >= 0) reader = std::thread(&IpcReadLoop);
    std::thread(&WatchParentDeath, getppid()).detach();
    CefRunMessageLoop();
    if (reader.joinable()) {
      shutdown(g_ipc_fd, SHUT_RDWR);  // unblock the reader's blocking read
      reader.join();
    }
    // Reader is joined (no more reads); close the socket under the write mutex
    // (no concurrent SendFrame) and clear the fd so any late write is a no-op.
    {
      std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
      if (g_ipc_fd >= 0) {
        close(g_ipc_fd);
        g_ipc_fd = -1;
      }
    }
    CefShutdown();
  }
  return 0;
}
