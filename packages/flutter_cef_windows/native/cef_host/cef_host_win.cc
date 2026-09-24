// cef_host (Windows) — a standalone CEF off-screen-rendering subprocess.
//
// The Flutter plugin (packages/flutter_cef_windows/windows/) spawns one
// cef_host per profile and drives N browsers in it over a named-pipe IPC.
// The wire contract is PROTOCOL.md + cef_host_protocol.h in this directory —
// transcribed verbatim from the macOS reference host
// (packages/flutter_cef_macos/native/cef_host/), with ONE payload
// difference: kOpPresent carries {u64 bridgeHandle BE}{u32 srcW BE}
// {u32 srcH BE} where bridgeHandle is the DXGI LEGACY shared handle of the
// host-minted D3D11_RESOURCE_MISC_SHARED bridge texture.
//
// Ship shape: this builds as cef_host.dll exporting
// RunConsoleMain, loaded by CEF's prebuilt bootstrapc.exe shipped RENAMED to
// cef_host.exe beside it. bootstrapc's sandbox_info is forwarded to BOTH
// CefExecuteProcess and CefInitialize, so the renderer, GPU and utility
// children run sandboxed. FLUTTER_CEF_NO_SANDBOX=1 turns the sandbox off.
//
// Rules this file keeps (measured on CEF 144 during the Windows port):
//  1. external_begin_frame_enabled = FALSE; windowless_frame_rate = 60.
//     (With the external pump only the FIRST browser in the process ever
//     paints. The macOS PumpBeginFrame pacer is NOT ported; everywhere the
//     macOS host calls SendExternalBeginFrame we use Invalidate(PET_VIEW) —
//     with the internal frame timer ON that is sufficient to drive a repaint.)
//  2. OnAcceleratedPaint's NT handle is valid ONLY inside the callback:
//     OpenSharedResource1 + CopyResource to the legacy bridge INSIDE the
//     callback, synchronously. The NT handle is never stored.
//  3. Identity is never keyed on shared_texture_handle VALUES (they alias
//     across sizes and browsers). The bridge texture handle WE mint is the
//     identity Flutter sees.
//  4. Every WasResized discards CEF's pool; late frames at the OLD size still
//     arrive — every kOpPresent carries the TRUTHFUL composited dims
//     (srcW/srcH) so the plugin's size-gate (the macOS SendPresentLocked
//     consumer contract, PROTOCOL.md §5) can refuse stale-size frames.
//  5. Bridge textures are D3D11_RESOURCE_MISC_SHARED (LEGACY handle via
//     IDXGIResource::GetSharedHandle, not NT) — what ANGLE/Flutter accepts.
//  6. The plugin holds its own opened reference to the bridge it shows; this
//     side helps by keeping the retired bridge alive until the present
//     announcing its replacement has been written to the pipe.
//
// Args (per-PROCESS / per-profile, as on macOS), read from the wide command
// line as UTF-8:
//   --ipc=<pipe name>          the plugin's already-created named pipe
//   --profile-dir=<abs path>   -> settings.root_cache_path
//   --ephemeral                marks the profile dir throwaway
//   --allowed-schemes=<csv>    optional navigation scheme allowlist
//                              (empty/omitted = allow all)
//   --cdp-io-pipes=<r>,<w>     agent control: inherited CDP pipe handles

#include <windows.h>

#include <d3d11.h>
#include <d3d11_1.h>
#include <shellapi.h>  // CommandLineToArgvW
#include <shlobj.h>  // SHGetKnownFolderPath / FOLDERID_Downloads (downloads)
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_render_handler.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_sandbox_win.h"
#include "include/cef_task.h"
#include "include/cef_v8.h"
#include "include/cef_values.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_message_router.h"

#include "cef_host_policy.h"
#include "cef_host_protocol.h"
#include "document_start.h"

// SHGetKnownFolderPath (downloads dir) + CoTaskMemFree live in shell32/ole32.
// These pragmas keep the TU self-linking without touching CMake.
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

namespace {

using namespace flutter_cef;  // opcodes + BE codecs (cef_host_protocol.h)
using Microsoft::WRL::ComPtr;

// ---- Shared runtime state ----
// The IPC pipe handle. Atomic for the same reason the macOS host's g_ipc_fd
// (ipc.mm) is: the reader thread, SendFrame (any CEF thread), and teardown all
// touch it.
std::atomic<HANDLE> g_ipc_pipe{INVALID_HANDLE_VALUE};
std::mutex g_ipc_write_mutex;

// One hidden window per host process, passed to SetAsWindowless(parent) so
// dialogs/menus/IMM degrade gracefully (the WebAuthn passkey UI shows either
// way, but an HWND is the better default).
HWND g_hidden_hwnd = nullptr;

// Host-set navigation scheme allowlist (lowercased; --allowed-schemes=a,b).
// Empty = allow all. `about` is always allowed. Enforced in
// HostClient::OnBeforeBrowse exactly like the macOS host (SchemeAllowed in
// host_state.mm, OnBeforeBrowse in host_client.mm).
std::set<std::string> g_allowed_schemes;

// Agent-control CDP-over-pipe. "<read>,<write>" decimal inherited-HANDLE
// values of two anonymous pipes, from the plugin's --cdp-io-pipes= switch: the
// browser READS CDP commands from <read> and WRITES responses/events to
// <write>. Set in RunConsoleMain (browser process only) BEFORE CefInitialize;
// OnBeforeCommandLineProcessing then injects Chromium's --remote-debugging-pipe
// + --remote-debugging-io-pipes. Empty = agent control off (byte-identical to
// a launch without agent control). Mirrors the macOS host's --cdp-pipe
// translation (OnBeforeCommandLineProcessing in main.mm).
std::string g_cdp_io_pipes;

// The plugin's liveness ping: kOpEvalReturning under this id, which Dart never
// issues. DoEvalReturning asks the renderer itself (kPingMessage, answered
// from the renderer's main thread with kPongMessage), not the page, so a hung
// renderer doesn't answer and a page can't stop a live one from answering (by
// replacing window.cefQuery or JSON, say). As on macOS.
constexpr uint32_t kLivenessPingId = 0xFFFFFFFFu;
constexpr char kPingMessage[] = "flutter_cef.ping";
constexpr char kPongMessage[] = "flutter_cef.pong";

// JS channels: on each MAIN-frame load OnLoadStart injects a
// window.<name>.postMessage shim for each of the browser's Slot::channels,
// routed to the browser process over window.cefQuery (the CefMessageRouter
// channel; the renderer half lives in HostApp below). As on macOS.

// document_start::IsValidChannelName (DoAddChannel drops invalid names).
using document_start::IsValidChannelName;

// Inject the per-channel page-side shim (window.<name>.postMessage ->
// window.cefQuery 'ch:<name>:<msg>'). document_start::ChannelShimJs is the one
// definition shared with macOS, so a page cannot detect a Windows-vs-macOS
// divergence.
void InjectChannelShim(CefRefPtr<CefFrame> frame, const std::string& name) {
  if (!frame) return;
  frame->ExecuteJavaScript(document_start::ChannelShimJs(name), "", 0);
}

// Document-start config parked by kOpSetDocumentStart until its browser's
// DoCreateBrowser takes it. Keyed by wire id and set on the reader thread ahead
// of the create frame (like g_authored), read on TID_UI — hence the mutex.
std::mutex g_doc_start_mutex;
std::map<uint32_t, document_start::Config> g_doc_start;

void SetDocumentStart(uint32_t wire_id, document_start::Config config) {
  std::lock_guard<std::mutex> lock(g_doc_start_mutex);
  if (config.empty()) {
    g_doc_start.erase(wire_id);
  } else {
    g_doc_start[wire_id] = std::move(config);
  }
}

// The browser's creation info carrying its document-start config to every
// renderer that hosts it, or null when it has none. Consumes the parked entry.
// Adds the config's channels to `channels`.
CefRefPtr<CefDictionaryValue> TakeDocumentStartExtraInfo(
    uint32_t wire_id, std::set<std::string>* channels) {
  document_start::Config config;
  {
    std::lock_guard<std::mutex> lock(g_doc_start_mutex);
    auto it = g_doc_start.find(wire_id);
    if (it == g_doc_start.end()) return nullptr;
    config = std::move(it->second);
    g_doc_start.erase(it);
  }
  channels->insert(config.channels.begin(), config.channels.end());
  auto to_list = [](const std::vector<std::string>& v) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    for (size_t i = 0; i < v.size(); ++i) list->SetString(i, v[i]);
    return list;
  };
  CefRefPtr<CefDictionaryValue> info = CefDictionaryValue::Create();
  info->SetList(document_start::kChannelsKey, to_list(config.channels));
  info->SetList(document_start::kScriptsKey, to_list(config.scripts));
  return info;
}

// The user's Downloads folder (Windows analogue of macOS's native save panel).
// Empty on failure — OnBeforeDownload then falls back to a Save-As dialog.
std::wstring GetDownloadsDir() {
  PWSTR path = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, 0, nullptr, &path)) &&
      path) {
    std::wstring dir(path);
    CoTaskMemFree(path);
    return dir;
  }
  if (path) CoTaskMemFree(path);
  // Fallback: %USERPROFILE%\Downloads.
  wchar_t up[MAX_PATH] = {};
  const DWORD n = GetEnvironmentVariableW(L"USERPROFILE", up, MAX_PATH);
  if (n > 0 && n < MAX_PATH) return std::wstring(up) + L"\\Downloads";
  return std::wstring();
}

void LogErr(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  fflush(stderr);
  va_end(ap);
}

// ---- Pipe I/O (framing per PROTOCOL.md §1) ----
//
// OVERLAPPED, EMPIRICALLY REQUIRED (found via pipe_probe, 2026-07-20): on a
// SYNCHRONOUS pipe handle Windows serializes all I/O on the file object, so
// the reader thread's pending blocking ReadFile makes any WriteFile from a
// CEF thread queue behind it — the UI thread froze inside
// SendFrame(kOpCreated), CefRunMessageLoop stalled, and every child process
// then died with "Terminating current process after 15 seconds with no
// connection" (no renderer/GPU/network — browsers never came up). A Unix
// socket fd is full-duplex so macOS never sees this. The pipe is therefore
// opened with FILE_FLAG_OVERLAPPED and every read/write runs event-based
// overlapped I/O; concurrent read+write on the one handle is then legal.
// (The plugin side of the pipe needs the same treatment — ipc_pipe.cpp.)

bool OverlappedIo(HANDLE pipe, void* buf, size_t len, bool write) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  HANDLE ev = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ev) return false;
  bool ok = true;
  size_t off = 0;
  while (off < len) {
    OVERLAPPED ov = {};
    ov.hEvent = ev;
    DWORD n = 0;
    BOOL res = write ? WriteFile(pipe, p + off,
                                 static_cast<DWORD>(len - off), nullptr, &ov)
                     : ReadFile(pipe, p + off, static_cast<DWORD>(len - off),
                                nullptr, &ov);
    if (!res && GetLastError() != ERROR_IO_PENDING) {
      ok = false;  // broken pipe / cancelled / error
      break;
    }
    if (!GetOverlappedResult(pipe, &ov, &n, TRUE)) {
      ok = false;
      break;
    }
    if (n == 0) {
      ok = false;  // peer closed
      break;
    }
    off += n;
  }
  CloseHandle(ev);
  return ok;
}

bool ReadAllPipe(HANDLE pipe, void* buf, size_t len) {
  return OverlappedIo(pipe, buf, len, /*write=*/false);
}

bool WriteAllPipe(HANDLE pipe, const void* buf, size_t len) {
  return OverlappedIo(pipe, const_cast<void*>(buf), len, /*write=*/true);
}

// Frame layout: [u32 bodyLen BE][u32 browserId BE][u8 opcode][payload].
// bodyLen = 4 + 1 + payloadLen. Assembled whole + written under the write
// mutex so a partial write never desyncs the peer (mirrors the macOS host's
// SendFrame in ipc.mm). Ordering: the handle is snapshotted UNDER the write
// lock; teardown exchanges INVALID_HANDLE_VALUE + closes under this same lock,
// so a late paint-thread send can never write into a recycled handle.
void SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload,
               size_t payload_len) {
  if (g_ipc_pipe.load() == INVALID_HANDLE_VALUE) return;  // racy early-out
  // The plugin drops the whole host on a body over kMaxBodyLen (it reads as a
  // desynced stream). Page-sourced payloads are capped well below that where
  // they are built; this is the backstop, so no frame can end every tile.
  if (payload_len > kMaxBodyLen - 5) {
    LogErr("[cef_host] dropping an oversized frame (op 0x%02x, %zu bytes)",
           opcode, payload_len);
    return;
  }
  std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
  HANDLE pipe = g_ipc_pipe.load();
  if (pipe == INVALID_HANDLE_VALUE) return;
  const uint32_t body_len = static_cast<uint32_t>(4 + 1 + payload_len);
  std::vector<uint8_t> frame(4 + static_cast<size_t>(body_len));
  WriteU32BE(frame.data(), body_len);
  WriteU32BE(frame.data() + 4, browser_id);
  frame[8] = opcode;
  if (payload_len) memcpy(frame.data() + 9, payload, payload_len);
  WriteAllPipe(pipe, frame.data(), frame.size());
}

void SendLog(uint32_t browser_id, const std::string& msg) {
  SendFrame(browser_id, kOpLog, msg.data(), msg.size());
}

void SendUtf8(uint32_t browser_id, uint8_t op, const std::string& s) {
  SendFrame(browser_id, op, s.data(), s.size());
}

void SendLoadState(uint32_t browser_id, bool loading, bool back, bool forward) {
  uint8_t p[3];
  p[0] = loading ? 1 : 0;
  p[1] = back ? 1 : 0;
  p[2] = forward ? 1 : 0;
  SendFrame(browser_id, kOpLoadState, p, 3);
}

// op payload: [u32 BE code][utf8 body]. Used for load-error, console, cookies.
void SendCodePlusUtf8(uint32_t browser_id, uint8_t op, uint32_t code,
                      const std::string& body) {
  std::vector<uint8_t> p(4 + body.size());
  WriteU32BE(p.data(), code);
  memcpy(p.data() + 4, body.data(), body.size());
  SendFrame(browser_id, op, p.data(), p.size());
}

// ---- argv helpers ----

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1)
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}

std::string Narrow(const std::wstring& w) {
  if (w.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr,
                              nullptr);
  std::string s(n > 0 ? n - 1 : 0, '\0');
  if (n > 1)
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, nullptr, nullptr);
  return s;
}

// The process's arguments as UTF-8. bootstrapc passes RunConsoleMain an argv
// in the ANSI code page, which can't carry a profile path under a user name
// like "José" or a CJK one (the lock file and cache path then fail to open),
// so read the wide command line instead.
std::vector<std::string> Utf8Args() {
  std::vector<std::string> out;
  int argc = 0;
  LPWSTR* wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!wargv) return out;
  for (int i = 0; i < argc; ++i) out.push_back(Narrow(wargv[i]));
  LocalFree(wargv);
  return out;
}

std::string GetSwitch(const std::vector<std::string>& args,
                      const std::string& prefix) {
  for (const auto& a : args) {
    if (a.compare(0, prefix.size(), prefix) == 0) return a.substr(prefix.size());
  }
  return std::string();
}

bool HasFlag(const std::vector<std::string>& args, const std::string& flag) {
  return std::find(args.begin(), args.end(), flag) != args.end();
}

bool EnvFlag(const char* name) {
  const char* v = std::getenv(name);
  return v && *v && strcmp(v, "0") != 0;
}

std::string TempDirUtf8() {
  wchar_t tmp[MAX_PATH] = {};
  const DWORD n = GetTempPathW(MAX_PATH, tmp);
  return (n > 0 && n < MAX_PATH) ? Narrow(tmp) : std::string(".\\");
}

// ---- Process-wide D3D11 device for the bridge-blit present path ----
// One device + immediate context for the whole cef_host process, created
// lazily on the first accelerated paint (mirrors the macOS host's
// g_mtl_device singleton in render_handler.mm). The immediate context is NOT
// thread-safe; OnAcceleratedPaint arrives on the CEF UI thread only, but
// g_d3d_mutex serializes it anyway (belt + suspenders, and future-proof).
ComPtr<ID3D11Device> g_d3d_device;
ComPtr<ID3D11Device1> g_d3d_device1;
ComPtr<ID3D11DeviceContext> g_d3d_ctx;
std::mutex g_d3d_mutex;
// EnsureD3D's "already tried and failed" latch. A file-global (not a function
// static) so device-loss recovery can clear it; touched only on the CEF UI
// thread (the sole OnAcceleratedPaint thread).
bool g_d3d_tried = false;
// Bumped on every device (re)create / loss so a Slot can tell its bridge was
// minted on a now-dead device and re-mint (see EnsureBridgeForPaintLocked).
// Atomic because Slots read it while only the UI thread writes it.
std::atomic<uint64_t> g_d3d_epoch{0};

// Returns false (once, then cached until a device-loss reset) if D3D11 is
// unavailable, in which case no frame can be presented. Falls back to WARP
// (the software rasterizer) when there is no hardware device, as on a VM or
// over RDP; Chromium then composites in software and frames arrive through
// OnPaint, which only needs a device to upload into.
bool EnsureD3D() {
  if (g_d3d_device1) return true;
  if (g_d3d_tried) return false;
  g_d3d_tried = true;
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  D3D_FEATURE_LEVEL fl;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, nullptr, 0, D3D11_SDK_VERSION,
                                 &g_d3d_device, &fl, &g_d3d_ctx);
  if (FAILED(hr)) {
    LogErr("[cef_host] hardware D3D11 device failed 0x%08lx; trying WARP",
           hr);
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                           nullptr, 0, D3D11_SDK_VERSION, &g_d3d_device, &fl,
                           &g_d3d_ctx);
  }
  if (FAILED(hr)) {
    LogErr("[cef_host] D3D11CreateDevice failed 0x%08lx", hr);
    return false;
  }
  hr = g_d3d_device.As(&g_d3d_device1);
  if (FAILED(hr)) {
    LogErr("[cef_host] ID3D11Device1 unavailable 0x%08lx", hr);
    g_d3d_device.Reset();
    g_d3d_ctx.Reset();
    return false;
  }
  g_d3d_epoch.fetch_add(1);  // a fresh device — all bridges must re-mint on it
  return true;
}

// True if the cached device has been removed/reset (any GetDeviceRemovedReason
// failure). Caller holds g_d3d_mutex.
bool D3DDeviceLostLocked() {
  return g_d3d_device && FAILED(g_d3d_device->GetDeviceRemovedReason());
}

// Drop the cached device/context so the NEXT EnsureD3D re-creates from scratch,
// and bump the epoch so every Slot re-mints its bridge on the new device (their
// old bridge textures died with the removed device). Caller holds g_d3d_mutex.
void ResetD3DDeviceLocked() {
  g_d3d_device1.Reset();
  g_d3d_device.Reset();
  g_d3d_ctx.Reset();
  g_d3d_tried = false;
  g_d3d_epoch.fetch_add(1);
}

struct Slot;
// An op for a browser, run on the UI thread once the browser is bound.
using BrowserOp = std::function<void(Slot&)>;

// Per-browser state: one cef_host process multiplexes N browsers, one Slot
// per plugin-assigned wire id (mirrors the macOS host's Slot in host_state.h,
// with the IOSurface/Metal fields swapped for the D3D11 bridge and the
// begin-frame-pump fields dropped: this host never uses external begin frames).
//
// The slot is registered by the IPC reader when the create frame arrives, so
// every frame behind it (a resize, zoom, JS, input) finds it. The browser binds
// later, in OnAfterCreated; ops that arrive before then wait in `deferred`.
struct Slot {
  uint32_t browser_id = 0;  // plugin-assigned wire id (>=1); NOT GetIdentifier().
  CefRefPtr<CefBrowser> browser;
  // Async-create dispose-loss guard: a dispose arriving while CreateBrowser
  // is in flight records intent here; OnAfterCreated honors it the instant the
  // browser binds. UI-thread-confined.
  bool close_requested = false;
  // Ops that arrived before the browser bound, run in order by OnAfterCreated
  // (see PostBrowserOp). UI-thread only.
  std::vector<BrowserOp> deferred;
  // The size the browser was created at, so OnAfterCreated can tell whether a
  // resize landed while the create was in flight. UI-thread only.
  int created_w = 0;
  int created_h = 0;
  double created_dpr = 1.0;

  // Guards bridge / width / height / dpr for THIS browser. Per-slot so paints
  // on independent browsers don't contend (as the macOS Slot's surface_mutex).
  std::mutex surface_mutex;
  // The host-minted legacy MISC_SHARED bridge texture (legacy handle because
  // that is what ANGLE/Flutter accepts) — the identity Flutter sees, since
  // CEF's own handle values alias. Re-minted whenever CEF paints at a new size
  // (producer-allocates: the bridge always matches the painted frame, so the
  // CopyResource below is always 1:1 — the wrong-size class is structurally
  // gone, same rationale as the macOS host's EnsureSurfaceForPaint in
  // render_handler.mm).
  ComPtr<ID3D11Texture2D> bridge;
  uint64_t bridge_handle = 0;  // IDXGIResource::GetSharedHandle of `bridge`
  int bridge_w = 0;
  int bridge_h = 0;
  // g_d3d_epoch the current `bridge` was minted at. A mismatch means the device
  // it lives on was lost/reset, so the bridge must be re-minted.
  uint64_t bridge_epoch = 0;
  // The OLD bridge is kept alive here across a re-mint until the kOpPresent
  // announcing its replacement has been written to the pipe (the plugin also
  // holds its own opened D3D reference to the bridge it shows; this is the
  // producer-side half of keeping a shown texture alive).
  ComPtr<ID3D11Texture2D> retired_bridge;
  // Set under surface_mutex in OnBeforeClose BEFORE releasing `bridge`, so a
  // paint racing teardown doesn't re-mint a bridge for a closing browser.
  bool closing = false;
  // The <select> dropdown (PET_POPUP): its latest pixels, kept on our device
  // and drawn over every view frame while it shows, and where it sits in the
  // view (DIP, from OnPopupSize). Under surface_mutex.
  bool popup_visible = false;
  CefRect popup_rect;
  ComPtr<ID3D11Texture2D> popup_tex;
  int popup_w = 0;
  int popup_h = 0;
  uint64_t popup_epoch = 0;

  int width = 800;   // logical (DIP) — GetViewRect; CEF scales by dpr.
  int height = 600;
  double dpr = 1.0;

  // Exact URLs armed for a host-trusted content load (kOpLoadTrusted /
  // data:-file: create). Exact-URL matched + consumed in OnBeforeBrowse. It is
  // URL-bound, not a one-shot flag, because OnBeforeBrowse arrives as a later
  // task and a page navigation queued in the gap could consume a flag.
  // UI-thread only.
  std::multiset<std::string> trusted_pending;

  // Pending JS dialog callbacks, keyed by id. UI-thread-only.
  std::map<uint32_t, CefRefPtr<CefJSDialogCallback>> dialogs;
  uint32_t dialog_next = 1;

  // Visibility (kOpSetVisible -> WasHidden). UI-thread only. On Windows there
  // is no begin-frame pump to gate (no external begin frames); this drives
  // WasHidden plus the hidden->visible repaint kick (as the macOS host's
  // DoSetVisible in browser_ops.mm).
  bool visible = true;
  // A dpr change landing while hidden defers its screen-info re-assert to the
  // hidden->visible edge, where the repaint kick picks it up. UI-thread only.
  bool needs_screen_info_on_show = false;

  // The JS channels this browser's consumer registered, before create (they
  // also ride in extra_info) or after. Only these are injected into its pages
  // and honored from them: channels are per browser, not per host. UI-thread
  // only.
  std::set<std::string> channels;

  uint64_t diag_paint_count = 0;  // DIAG (FLUTTER_CEF_DEBUG logging)
  uint32_t open_failures = 0;     // OpenSharedResource1 misses, for log pacing
};

// Routing map from a wire browser id to its Slot. Inserted by the IPC reader
// at the create frame (RegisterSlot), erased on the UI thread (OnBeforeClose,
// or a failed create). Readers take g_slots_mutex, copy the shared_ptr, release
// the lock, then operate — a slot stays alive for an in-flight op even if
// disposed.
std::mutex g_slots_mutex;
std::map<uint32_t, std::shared_ptr<Slot>> g_slots_by_wire_id;

std::shared_ptr<Slot> LookupWireId(uint32_t wire_id) {
  if (wire_id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(g_slots_mutex);
  auto it = g_slots_by_wire_id.find(wire_id);
  return it == g_slots_by_wire_id.end() ? nullptr : it->second;
}

// Registers the slot for a create frame. Null when the wire id is already in
// use: a collision would let the old browser's OnBeforeClose erase the new
// slot, so the create is refused instead.
std::shared_ptr<Slot> RegisterSlot(uint32_t wire_id, int w, int h,
                                   double dpr) {
  if (wire_id == 0) return nullptr;
  auto slot = std::make_shared<Slot>();
  slot->browser_id = wire_id;
  slot->width = w;
  slot->height = h;
  slot->dpr = dpr;
  std::lock_guard<std::mutex> lock(g_slots_mutex);
  if (g_slots_by_wire_id.count(wire_id)) return nullptr;
  g_slots_by_wire_id[wire_id] = slot;
  return slot;
}

void EraseSlot(uint32_t wire_id) {
  std::lock_guard<std::mutex> lock(g_slots_mutex);
  g_slots_by_wire_id.erase(wire_id);
}

// At most this many ops wait for a browser to bind. Input can pile up during
// a slow create; past this the oldest intent is already stale.
constexpr size_t kMaxDeferredOps = 256;

void RunBrowserOp(std::shared_ptr<Slot> slot, BrowserOp op) {
  CEF_REQUIRE_UI_THREAD();
  if (slot->browser) {
    op(*slot);
    return;
  }
  if (slot->closing || slot->close_requested) return;
  if (slot->deferred.size() < kMaxDeferredOps)
    slot->deferred.push_back(std::move(op));
}

// Runs `op` on the UI thread against `slot`'s browser. An op that arrives
// before the browser has bound (the create is asynchronous) is kept and run by
// OnAfterCreated, in order, instead of being dropped.
void PostBrowserOp(std::shared_ptr<Slot> slot, BrowserOp op) {
  CefPostTask(TID_UI,
              base::BindOnce(&RunBrowserOp, std::move(slot), std::move(op)));
}

// ---- Render handler: OSR -> legacy shared bridge texture ----
// One handler per browser; holds a shared_ptr to that browser's Slot. All
// bridge access is under slot_->surface_mutex; paints re-check slot_->closing
// after taking the lock since OnBeforeClose releases the bridge under the
// same lock.
class HostRenderHandler : public CefRenderHandler {
 public:
  explicit HostRenderHandler(std::shared_ptr<Slot> slot)
      : slot_(std::move(slot)) {}

  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    rect = CefRect(0, 0, slot_->width, slot_->height);
  }

  // The REAL display (DIP), not the tile: `window.screen == innerWidth` is a
  // textbook headless/OSR fingerprint (see the macOS host's RealScreenDip in
  // render_handler.mm and commit 855042d). GetSystemMetrics returns px in this
  // process's DPI context; divide by dpr for DIP. Falls back to a plausible
  // frame.
  static void RealScreenDip(double dpr, CefRect& full, CefRect& work) {
    const double s = dpr > 0.0 ? dpr : 1.0;
    const int pw = GetSystemMetrics(SM_CXSCREEN);
    const int ph = GetSystemMetrics(SM_CYSCREEN);
    RECT wa = {};
    if (pw <= 0 || ph <= 0 ||
        !SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0)) {
      full = CefRect(0, 0, 1920, 1080);       // headless fallback: common 24"
      work = CefRect(0, 0, 1920, 1080 - 48);  // minus a taskbar
      return;
    }
    full = CefRect(0, 0, static_cast<int>(pw / s), static_cast<int>(ph / s));
    work = CefRect(static_cast<int>(wa.left / s), static_cast<int>(wa.top / s),
                   static_cast<int>((wa.right - wa.left) / s),
                   static_cast<int>((wa.bottom - wa.top) / s));
  }

  // Device scale so CEF renders logical*dpr (HiDPI-native) + real screen
  // bounds and color depth (mirrors the macOS host's GetScreenInfo).
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    info.device_scale_factor = static_cast<float>(slot_->dpr);
    info.depth = 24;  // screen.colorDepth — 0 was a headless tell
    info.depth_per_component = 8;
    info.is_monochrome = 0;
    CefRect full, work;
    RealScreenDip(slot_->dpr, full, work);
    info.rect = full;
    info.available_rect = work;
    return true;
  }

  // Plausible window frame at a non-zero offset, taller than the view by
  // typical browser chrome (outerHeight > innerHeight like a real window), as
  // the macOS host's GetRootScreenRect does.
  bool GetRootScreenRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    constexpr int kChromeH = 87;
    rect = CefRect(100, 80, slot_->width, slot_->height + kChromeH);
    return true;
  }

  // PRODUCER-ALLOCATES: ensure the bridge is EXACTLY sw x sh — the dims CEF
  // actually painted. Because the copy/upload destination is then the same
  // size as the source, it can never crop or leave stale margins. Re-mints on
  // first paint, a size change, or a device change; the OLD bridge is parked in
  // retired_bridge until the present that announces its replacement is on the
  // wire. False when no bridge of that size exists (the frame is skipped and
  // Flutter keeps the last one). `*reminted` says the bridge is new, so it
  // holds no pixels yet. Caller holds slot_->surface_mutex AND g_d3d_mutex.
  bool EnsureBridgeForPaintLocked(int sw, int sh, bool* reminted) {
    *reminted = false;
    if (sw < 1 || sh < 1) return false;
    if (slot_->closing) return false;  // paint racing teardown: no re-mint
    if (slot_->bridge && slot_->bridge_w == sw && slot_->bridge_h == sh &&
        slot_->bridge_epoch == g_d3d_epoch.load())
      return true;  // steady state: zero allocation (same device + same size)
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = static_cast<UINT>(sw);
    d.Height = static_cast<UINT>(sh);
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    d.MiscFlags = D3D11_RESOURCE_MISC_SHARED;  // LEGACY handle, for ANGLE
    ComPtr<ID3D11Texture2D> fresh;
    HRESULT hr = g_d3d_device->CreateTexture2D(&d, nullptr, &fresh);
    if (FAILED(hr)) {
      SendLog(slot_->browser_id,
              "EnsureBridgeForPaint: CreateTexture2D failed hr=" +
                  std::to_string(static_cast<long>(hr)));
      return false;  // keep serving the old bridge; retry next paint
    }
    ComPtr<IDXGIResource> res;
    HANDLE legacy = nullptr;
    if (FAILED(fresh.As(&res)) || FAILED(res->GetSharedHandle(&legacy)) ||
        !legacy) {
      SendLog(slot_->browser_id,
              "EnsureBridgeForPaint: GetSharedHandle failed");
      return false;
    }
    // Park the old bridge until the present carrying the NEW handle is sent
    // (a courtesy — the plugin's own opened ref is what keeps it alive).
    slot_->retired_bridge = slot_->bridge;
    slot_->bridge = fresh;
    slot_->bridge_handle =
        static_cast<uint64_t>(reinterpret_cast<uintptr_t>(legacy));
    slot_->bridge_w = sw;
    slot_->bridge_h = sh;
    slot_->bridge_epoch = g_d3d_epoch.load();
    *reminted = true;
    return true;
  }

  // Present the just-filled bridge, tagging the frame with the bridge handle
  // (the identity Flutter sees) and the PHYSICAL px dims of the frame actually
  // composited (so the plugin's size-gate can refuse stale-size frames,
  // PROTOCOL.md §5). Caller holds slot_->surface_mutex. Windows-only payload:
  // {u64 bridgeHandle BE}{u32 srcW BE}{u32 srcH BE} = 16 bytes.
  void SendPresentLocked(int srcW, int srcH) {
    uint8_t p[16];
    WriteU64BE(p, slot_->bridge_handle);
    WriteU32BE(p + 8, static_cast<uint32_t>(srcW < 0 ? 0 : srcW));
    WriteU32BE(p + 12, static_cast<uint32_t>(srcH < 0 ? 0 : srcH));
    SendFrame(slot_->browser_id, kOpPresent, p, 16);
    // The present announcing the new bridge is on the wire — the old bridge
    // may now die (the plugin holds its own reference to it).
    slot_->retired_bridge.Reset();
  }

  // The dropdown's position in bridge pixels. Caller holds surface_mutex.
  void PopupOriginPxLocked(int* x, int* y) const {
    *x = static_cast<int>(slot_->popup_rect.x * slot_->dpr + 0.5);
    *y = static_cast<int>(slot_->popup_rect.y * slot_->dpr + 0.5);
  }

  // Draw the kept dropdown pixels over the bridge, clipped to it. Caller holds
  // surface_mutex and g_d3d_mutex.
  void CompositePopupLocked() {
    if (!slot_->popup_visible || !slot_->popup_tex || !slot_->bridge) return;
    if (slot_->popup_epoch != g_d3d_epoch.load()) return;  // dead device
    int x = 0, y = 0;
    PopupOriginPxLocked(&x, &y);
    // Clip the source box so the destination stays inside the bridge.
    int sx = 0, sy = 0;
    if (x < 0) { sx = -x; x = 0; }
    if (y < 0) { sy = -y; y = 0; }
    const int w = (std::min)(slot_->popup_w - sx, slot_->bridge_w - x);
    const int h = (std::min)(slot_->popup_h - sy, slot_->bridge_h - y);
    if (w <= 0 || h <= 0) return;
    D3D11_BOX box = {static_cast<UINT>(sx), static_cast<UINT>(sy), 0,
                     static_cast<UINT>(sx + w), static_cast<UINT>(sy + h), 1};
    g_d3d_ctx->CopySubresourceRegion(slot_->bridge.Get(), 0,
                                     static_cast<UINT>(x),
                                     static_cast<UINT>(y), 0,
                                     slot_->popup_tex.Get(), 0, &box);
  }

  // A popup texture of exactly w x h on the current device. Caller holds
  // surface_mutex and g_d3d_mutex.
  bool EnsurePopupTexLocked(int w, int h) {
    if (w < 1 || h < 1) return false;
    if (slot_->popup_tex && slot_->popup_w == w && slot_->popup_h == h &&
        slot_->popup_epoch == g_d3d_epoch.load())
      return true;
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = static_cast<UINT>(w);
    d.Height = static_cast<UINT>(h);
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> fresh;
    if (FAILED(g_d3d_device->CreateTexture2D(&d, nullptr, &fresh))) return false;
    slot_->popup_tex = fresh;
    slot_->popup_w = w;
    slot_->popup_h = h;
    slot_->popup_epoch = g_d3d_epoch.load();
    return true;
  }

  // Flush the device and check it survived; on loss reset it so the next paint
  // re-creates it and every bridge. False = don't present this frame.
  // Caller holds g_d3d_mutex.
  bool FlushAndCheckDeviceLocked(const char* where) {
    g_d3d_ctx->Flush();
    if (!D3DDeviceLostLocked()) return true;
    SendLog(slot_->browser_id, std::string("D3D device lost (") + where +
                                   ") — resetting; next paint re-creates");
    ResetD3DDeviceLocked();
    return false;
  }

  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override {
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      slot_->popup_visible = show;
      if (!show) slot_->popup_tex.Reset();
    }
    // Hidden: repaint the view so the dropdown's pixels leave the bridge.
    if (!show && browser && browser->GetHost())
      browser->GetHost()->Invalidate(PET_VIEW);
  }

  void OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    slot_->popup_rect = rect;
  }

  // GPU pixel path: CEF's GPU process composites the page and hands an NT
  // shared handle valid ONLY inside this callback. Open it on our device, copy
  // it into the legacy bridge (the view) or the kept dropdown texture
  // (PET_POPUP), Flush — all synchronously, never storing the NT handle.
  void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type,
                          const RectList&,
                          const CefAcceleratedPaintInfo& info) override {
    slot_->diag_paint_count++;
    HANDLE nt = info.shared_texture_handle;
    if (!nt) {
      SendLog(slot_->browser_id, "OnAcceleratedPaint: null shared handle");
      return;
    }
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    if (slot_->closing) return;
    if (!EnsureD3D()) {
      static std::atomic<bool> logged{false};
      if (!logged.exchange(true))
        SendLog(slot_->browser_id,
                "OnAcceleratedPaint: D3D11 unavailable — no pixel path");
      return;
    }
    int srcW = 0, srcH = 0;
    {
      std::lock_guard<std::mutex> d3d(g_d3d_mutex);
      // Open + copy INSIDE the callback (the NT handle dies with it). `src`
      // (the ComPtr) is released before we return; the handle is never kept.
      ComPtr<ID3D11Texture2D> src;
      HRESULT hr = g_d3d_device1->OpenSharedResource1(
          nt, __uuidof(ID3D11Texture2D), &src);
      if (FAILED(hr)) {
        // Distinguish a transient bad-handle miss from real device loss. On
        // loss, drop the cached device (+ bump the epoch) so the next paint
        // re-creates the device and every bridge — otherwise the dead device is
        // cached forever and the tile never repaints.
        if (D3DDeviceLostLocked()) {
          SendLog(slot_->browser_id,
                  "OnAcceleratedPaint: D3D device lost (open) — resetting; next "
                  "paint re-creates");
          ResetD3DDeviceLocked();
        } else if (++slot_->open_failures <= 3 ||
                   slot_->open_failures % 600 == 0) {
          // Paced: this can repeat every frame (60/s) while it lasts.
          SendLog(slot_->browser_id,
                  "OnAcceleratedPaint: OpenSharedResource1 failed hr=" +
                      std::to_string(static_cast<long>(hr)) + " (x" +
                      std::to_string(slot_->open_failures) + ")");
        }
        return;
      }
      // The opened texture's own desc is the truth about the frame's physical
      // dims (info.extra.coded_size matches it; the desc can't lie).
      D3D11_TEXTURE2D_DESC sd = {};
      src->GetDesc(&sd);
      if (type == PET_POPUP) {
        // The <select> dropdown: keep its pixels and draw them over the view.
        if (!EnsurePopupTexLocked(static_cast<int>(sd.Width),
                                  static_cast<int>(sd.Height)))
          return;
        g_d3d_ctx->CopyResource(slot_->popup_tex.Get(), src.Get());
        if (!slot_->bridge || slot_->bridge_epoch != g_d3d_epoch.load())
          return;  // no view frame yet to draw it on
        CompositePopupLocked();
        if (!FlushAndCheckDeviceLocked("popup")) return;
        srcW = slot_->bridge_w;
        srcH = slot_->bridge_h;
      } else {
        srcW = static_cast<int>(sd.Width);
        srcH = static_cast<int>(sd.Height);
        bool reminted = false;
        if (!EnsureBridgeForPaintLocked(srcW, srcH, &reminted)) return;
        g_d3d_ctx->CopyResource(slot_->bridge.Get(), src.Get());
        CompositePopupLocked();
        // CopyResource/Flush return void; device loss surfaces via
        // GetDeviceRemovedReason. If it went down mid-blit, reset and skip this
        // frame — never present pixels from a dead device.
        if (!FlushAndCheckDeviceLocked("blit")) return;
      }
    }
    if (std::getenv("FLUTTER_CEF_DEBUG") &&
        (slot_->diag_paint_count <= 3 || slot_->diag_paint_count % 120 == 0)) {
      const int wantW = static_cast<int>(slot_->width * slot_->dpr + 0.5);
      const int wantH = static_cast<int>(slot_->height * slot_->dpr + 0.5);
      char buf[160];
      snprintf(buf, sizeof(buf),
               "diag wire=%u paint#%llu painted=%dx%d want=%dx%d bridge=%llu",
               slot_->browser_id,
               static_cast<unsigned long long>(slot_->diag_paint_count), srcW,
               srcH, wantW, wantH,
               static_cast<unsigned long long>(slot_->bridge_handle));
      SendLog(slot_->browser_id, buf);
    }
    SendPresentLocked(srcW, srcH);
  }

  // Software pixel path. Chromium hands frames to OnPaint instead of
  // OnAcceleratedPaint when it composites in software: no usable GPU (a VM,
  // RDP, a blocklisted driver), or GPU compositing disabled. Upload the BGRA
  // buffer into the same bridge the GPU path uses, so the plugin can't tell
  // the difference. `buffer` is width*height*4 bytes, top row first.
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type,
               const RectList& dirty, const void* buffer, int width,
               int height) override {
    slot_->diag_paint_count++;
    if (!buffer || width < 1 || height < 1) return;
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    if (slot_->closing) return;
    if (!EnsureD3D()) {
      static std::atomic<bool> logged{false};
      if (!logged.exchange(true))
        SendLog(slot_->browser_id, "OnPaint: D3D11 unavailable — no pixel path");
      return;
    }
    const UINT pitch = static_cast<UINT>(width) * 4;
    int srcW = 0, srcH = 0;
    {
      std::lock_guard<std::mutex> d3d(g_d3d_mutex);
      if (type == PET_POPUP) {
        if (!EnsurePopupTexLocked(width, height)) return;
        g_d3d_ctx->UpdateSubresource(slot_->popup_tex.Get(), 0, nullptr, buffer,
                                     pitch, 0);
        if (!slot_->bridge || slot_->bridge_epoch != g_d3d_epoch.load())
          return;
        CompositePopupLocked();
        if (!FlushAndCheckDeviceLocked("popup upload")) return;
        srcW = slot_->bridge_w;
        srcH = slot_->bridge_h;
      } else {
        bool reminted = false;
        if (!EnsureBridgeForPaintLocked(width, height, &reminted)) return;
        const uint8_t* px = static_cast<const uint8_t*>(buffer);
        if (reminted || dirty.empty()) {
          g_d3d_ctx->UpdateSubresource(slot_->bridge.Get(), 0, nullptr, px,
                                       pitch, 0);
        } else {
          // Only the damaged rects (pixel coordinates in `buffer`).
          for (const CefRect& r : dirty) {
            const int x0 = (std::max)(0, r.x), y0 = (std::max)(0, r.y);
            const int x1 = (std::min)(width, r.x + r.width);
            const int y1 = (std::min)(height, r.y + r.height);
            if (x1 <= x0 || y1 <= y0) continue;
            D3D11_BOX box = {static_cast<UINT>(x0), static_cast<UINT>(y0), 0,
                             static_cast<UINT>(x1), static_cast<UINT>(y1), 1};
            const uint8_t* src =
                px + (static_cast<size_t>(y0) * width + x0) * 4;
            g_d3d_ctx->UpdateSubresource(slot_->bridge.Get(), 0, &box, src,
                                         pitch, 0);
          }
        }
        CompositePopupLocked();
        if (!FlushAndCheckDeviceLocked("upload")) return;
        srcW = width;
        srcH = height;
      }
    }
    if (std::getenv("FLUTTER_CEF_DEBUG") && slot_->diag_paint_count <= 3) {
      SendLog(slot_->browser_id, "OnPaint (software) " + std::to_string(width) +
                                     "x" + std::to_string(height));
    }
    SendPresentLocked(srcW, srcH);
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostRenderHandler);
};

// Renderer crash loops, per browser (see policy::RendererCrashPolicy). CEF
// calls OnRenderProcessTerminated and OnBeforeClose on the UI thread; the lock
// only keeps that from being load-bearing.
std::mutex g_renderer_crash_mutex;
policy::RendererCrashPolicy g_renderer_crashes;

policy::RendererCrashPolicy::Action NoteRendererTerminated(
    uint32_t browser_id) {
  std::lock_guard<std::mutex> lock(g_renderer_crash_mutex);
  return g_renderer_crashes.OnRendererTerminated(
      browser_id, std::chrono::steady_clock::now());
}

void ForgetRendererCrashes(uint32_t browser_id) {
  std::lock_guard<std::mutex> lock(g_renderer_crash_mutex);
  g_renderer_crashes.Forget(browser_id);
}

std::string CrashBurstText() {
  return std::to_string(policy::RendererCrashPolicy::kBurstLimit) +
         " renderer crashes in " +
         std::to_string(policy::RendererCrashPolicy::kWindow.count()) + "s";
}

void DoShutdown();  // defined below; the crash-loop exit reuses it

// Deny-default permission gate (verbatim port of the macOS host's
// HostPermissionHandler in host_client.mm): no per-site UI exists here, so
// every permission prompt and media-access request is denied up front.
class HostPermissionHandler : public CefPermissionHandler {
 public:
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString&, uint32_t,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    callback->Continue(CEF_MEDIA_PERMISSION_NONE);
    return true;
  }
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser>, uint64_t, const CefString&, uint32_t,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  IMPLEMENT_REFCOUNTING(HostPermissionHandler);
};

// ---- Authored documents at a real origin (loadHtmlString(baseUrl:)) ----
//
// A data: URL gives the document an OPAQUE origin (relative URLs don't resolve;
// every fetch/XHR/worker is cross-origin with `Origin: null`) and Chromium caps
// it at 2 MB. So the plugin can hand us the HTML plus the URL it should appear
// to come from, and we answer the MAIN-FRAME request for exactly that URL with
// the HTML instead of the network. Everything else the page loads goes to the
// network as normal. Verbatim port of the macOS host's g_authored
// (authored_content.mm).
//
// Keyed by WIRE ID and written on the reader thread, not stored on the Slot: the
// frame is sent immediately ahead of the create / load it belongs to and must be
// in place before that op runs — including when the slot doesn't exist yet.
// Read on the IO thread (GetResourceRequestHandler), hence the mutex. Sticky
// across reloads; replaced by the next set, cleared by a plain navigate or by
// dispose.
struct AuthoredDoc {
  std::string url;  // normalized (NormalizeAuthoredUrl)
  std::string html;
};
std::mutex g_authored_mutex;
std::map<uint32_t, AuthoredDoc> g_authored;

// Compare URLs the way the network stack will present them: no fragment, and a
// bare authority ("https://host") carries the implicit "/" path.
std::string NormalizeAuthoredUrl(std::string url) {
  // http(s) only: a data: URL is matched verbatim (its payload may contain "://").
  if (url.rfind("http://", 0) != 0 && url.rfind("https://", 0) != 0) return url;
  const size_t hash = url.find('#');
  if (hash != std::string::npos) url.resize(hash);
  const size_t scheme_end = url.find("://");
  if (scheme_end != std::string::npos &&
      url.find('/', scheme_end + 3) == std::string::npos) {
    const size_t q = url.find('?', scheme_end + 3);
    if (q == std::string::npos) url += '/';
    else url.insert(q, "/");
  }
  return url;
}

void SetAuthoredDoc(uint32_t wire_id, const std::string& url,
                    const std::string& html) {
  std::lock_guard<std::mutex> lock(g_authored_mutex);
  if (html.empty() || url.empty()) {
    g_authored.erase(wire_id);
  } else {
    g_authored[wire_id] = AuthoredDoc{NormalizeAuthoredUrl(url), html};
  }
}
// Drop the authored doc unless it is for `keep_url` (the load that follows a set
// targets the same URL and must keep it).
void ClearAuthoredDocUnless(uint32_t wire_id, const std::string& keep_url) {
  std::lock_guard<std::mutex> lock(g_authored_mutex);
  auto it = g_authored.find(wire_id);
  if (it == g_authored.end()) return;
  if (keep_url.empty() || it->second.url != NormalizeAuthoredUrl(keep_url))
    g_authored.erase(it);
}
bool LookupAuthoredDoc(uint32_t wire_id, const std::string& url,
                       std::string* html) {
  std::lock_guard<std::mutex> lock(g_authored_mutex);
  auto it = g_authored.find(wire_id);
  if (it == g_authored.end()) return false;
  if (it->second.url != NormalizeAuthoredUrl(url)) return false;
  if (html) *html = it->second.html;
  return true;
}

// Serves one authored document. Owns its bytes (the doc can be replaced
// mid-read).
class AuthoredResourceHandler : public CefResourceHandler {
 public:
  explicit AuthoredResourceHandler(std::string html) : html_(std::move(html)) {}
  bool Open(CefRefPtr<CefRequest>, bool& handle_request,
            CefRefPtr<CefCallback>) override {
    handle_request = true;
    return true;
  }
  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length, CefString&) override {
    response->SetStatus(200);
    response->SetStatusText("OK");
    response->SetMimeType("text/html");
    response->SetCharset("utf-8");
    response->SetHeaderByName("Cache-Control", "no-store", true);
    response_length = static_cast<int64_t>(html_.size());
  }
  bool Read(void* data_out, int bytes_to_read, int& bytes_read,
            CefRefPtr<CefResourceReadCallback>) override {
    bytes_read = 0;
    if (offset_ >= html_.size() || bytes_to_read <= 0) return false;
    const size_t n = (std::min)(static_cast<size_t>(bytes_to_read),
                                html_.size() - offset_);
    memcpy(data_out, html_.data() + offset_, n);
    offset_ += n;
    bytes_read = static_cast<int>(n);
    return true;
  }
  void Cancel() override {}

 private:
  std::string html_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(AuthoredResourceHandler);
};

class AuthoredRequestHandler : public CefResourceRequestHandler {
 public:
  explicit AuthoredRequestHandler(std::string html) : html_(std::move(html)) {}
  CefRefPtr<CefResourceHandler> GetResourceHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
      CefRefPtr<CefRequest>) override {
    return new AuthoredResourceHandler(html_);
  }

 private:
  std::string html_;
  IMPLEMENT_REFCOUNTING(AuthoredRequestHandler);
};

class HostClient : public CefClient,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefFindHandler,
                   public CefJSDialogHandler,
                   public CefKeyboardHandler,
                   public CefDownloadHandler,
                   public CefRequestHandler,
                   public CefMessageRouterBrowserSide::Handler {
 public:
  explicit HostClient(std::shared_ptr<Slot> slot) : slot_(std::move(slot)) {
    // Browser-side message router (default config: window.cefQuery /
    // cefQueryCancel) — the SAME config the renderer half uses (as on macOS,
    // host_client.mm + process_helper.mm). One router per HostClient, i.e. per
    // browser: OnQuery below stamps slot_->browser_id so a page message is
    // delivered ONLY to the originating session (per-session routing,
    // channel_probe_shared).
    CefMessageRouterConfig config;
    router_ = CefMessageRouterBrowserSide::Create(config);
    router_->AddHandler(this, false);
    rh_ = new HostRenderHandler(slot_);
    ph_ = new HostPermissionHandler();
  }
  CefRefPtr<CefMessageRouterBrowserSide> router_;
  CefRefPtr<CefRenderHandler> rh_;
  CefRefPtr<CefPermissionHandler> ph_;
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return rh_; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return ph_;
  }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefDownloadHandler: tell the plugin, then let the user decide. Every
  // download goes through the Save As dialog, as macOS goes through its save
  // panel: a page can't write a file without the user choosing to keep it. The
  // dialog opens on the user's Downloads folder, on a name that doesn't
  // replace an existing file.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    SendUtf8(slot_->browser_id, kOpDownload,
             policy::TruncateUtf8(suggested_name.ToString(), 4096));
    const std::wstring dir = GetDownloadsDir();
    CefString path;
    if (!dir.empty()) {
      // SECURITY: suggested_name is page-controlled (Content-Disposition), so
      // it is reduced to a bare, legal leaf before it is joined to Downloads.
      const std::wstring leaf =
          policy::SanitizeDownloadLeaf(suggested_name.ToWString());
      path.FromWString(policy::UniqueDownloadPath(
          dir, leaf, [](const std::wstring& candidate) {
            return GetFileAttributesW(candidate.c_str()) !=
                   INVALID_FILE_ATTRIBUTES;
          }));
    }
    callback->Continue(path, /*show_dialog=*/true);
    return true;
  }

  // CefFindHandler (as on macOS).
  void OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect&,
                    int activeMatchOrdinal, bool finalUpdate) override {
    uint8_t p[9];
    WriteU32BE(p, static_cast<uint32_t>(count));
    WriteU32BE(p + 4, static_cast<uint32_t>(activeMatchOrdinal));
    p[8] = finalUpdate ? 1 : 0;
    SendFrame(slot_->browser_id, kOpFindResult, p, 9);
  }

  // CefJSDialogHandler (as on macOS): forward alert/confirm/prompt;
  // the plugin answers via kOpJsDialogResp -> DoJsDialogResp -> Continue.
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool&) override {
    uint32_t id = slot_->dialog_next++;
    slot_->dialogs[id] = callback;
    uint32_t type = dialog_type == JSDIALOGTYPE_ALERT
                        ? 0
                        : (dialog_type == JSDIALOGTYPE_CONFIRM ? 1 : 2);
    // Page-controlled text; a dialog has no use for megabytes of it.
    const std::string msg =
        policy::CapText(message_text.ToString(), policy::kMaxPagePayload / 2);
    const std::string def = policy::CapText(default_prompt_text.ToString(),
                                            policy::kMaxPagePayload / 2);
    std::vector<uint8_t> p(12 + msg.size() + def.size());
    WriteU32BE(p.data(), id);
    WriteU32BE(p.data() + 4, type);
    WriteU32BE(p.data() + 8, static_cast<uint32_t>(msg.size()));
    memcpy(p.data() + 12, msg.data(), msg.size());
    memcpy(p.data() + 12 + msg.size(), def.data(), def.size());
    SendFrame(slot_->browser_id, kOpJsDialog, p.data(), p.size());
    return true;  // answered asynchronously via Continue()
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString&, bool,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    callback->Continue(true, CefString());  // never block navigation away
    return true;
  }
  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    slot_->dialogs.clear();
  }

  // Renderer crash: reload rather than show a dead page. A renderer that keeps
  // crashing ends only this browser: the plugin reports processGone for its
  // tile and the host's other browsers carry on. Several browsers doing it at
  // once end the host (see policy::RendererCrashPolicy).
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int,
                                 const CefString&) override {
    if (router_) router_->OnRenderProcessTerminated(browser);
    using Crash = policy::RendererCrashPolicy::Action;
    switch (NoteRendererTerminated(slot_->browser_id)) {
      case Crash::kIgnore:
        return;  // already reported; left alone
      case Crash::kReload:
        SendLog(slot_->browser_id, "renderer terminated (status " +
                                       std::to_string(status) +
                                       ") — reloading");
        if (browser) browser->ReloadIgnoreCache();
        return;
      case Crash::kBrowserGone:
        SendLog(slot_->browser_id,
                CrashBurstText() + " — giving up on this browser");
        SendUtf8(slot_->browser_id, kOpBrowserGone, "crashed");
        return;
      case Crash::kHostExit:
        SendLog(0, CrashBurstText() +
                       " on several browsers — children cannot start; "
                       "exiting so the host is respawned");
        DoShutdown();
        return;
    }
  }

  // CefMessageRouter wiring (as on macOS). The renderer half (HostApp
  // below) injects window.cefQuery; queries land here. Forward the request to
  // the plugin: "eval:<id>:<json>" -> kOpEvalResult (a
  // runJavaScriptReturningResult result); "ch:<name>:<message>" ->
  // kOpChannelMsg (a JS-channel post). Both are stamped with slot_->browser_id
  // (this HostClient owns exactly one browser), so the message reaches ONLY the
  // originating session's Dart channel — the per-session routing boundary
  // (channel_probe_shared). 'eval:'/'ch:' are privileged (they hit the trusted
  // host eval path / the channel bridge) and the shim is injected per-frame, so
  // honor them ONLY from the MAIN frame; refuse a forged subframe query.
  bool OnQuery(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int64_t,
               const CefString& request, bool,
               CefRefPtr<Callback> callback) override {
    std::string r = request.ToString();
    const bool main_frame = !frame || frame->IsMain();
    if (r.rfind("eval:", 0) == 0) {
      if (!main_frame) {
        callback->Failure(403, "subframe");
        return true;
      }
      // Only the renderer answers the liveness ping (OnProcessMessageReceived
      // below), never the page.
      static const std::string kPingReply =
          "eval:" + std::to_string(kLivenessPingId) + ":";
      if (r.rfind(kPingReply, 0) == 0) {
        callback->Failure(403, "reserved eval id");
        return true;
      }
      SendUtf8(slot_->browser_id, kOpEvalResult,
               policy::CapEvalResult(r.substr(5)));
      callback->Success(CefString());
      return true;
    }
    if (r.rfind("ch:", 0) == 0) {
      if (!main_frame) {
        callback->Failure(403, "subframe");
        return true;
      }
      // Only a channel this browser's consumer registered. The page can call
      // window.cefQuery itself, shim or not.
      const size_t name_end = r.find(':', 3);
      if (name_end == std::string::npos ||
          slot_->channels.count(r.substr(3, name_end - 3)) == 0) {
        callback->Failure(404, "no such channel");
        return true;
      }
      if (r.size() - 3 > policy::kMaxPagePayload) {
        // Too large for the wire, and a cut message would be corrupt: refuse
        // it so the page can tell.
        callback->Failure(413, "message too large");
        return true;
      }
      SendUtf8(slot_->browser_id, kOpChannelMsg, r.substr(3));
      callback->Success(CefString());
      return true;
    }
    return false;
  }

  // Route renderer->browser process messages through the message router
  // (as on macOS). This carries the cefQuery payloads that surface in
  // OnQuery above.
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    // The renderer answered the liveness ping (see DoEvalReturning); reply as
    // the plugin's ping eval would have.
    if (message->GetName().ToString() == kPongMessage) {
      if (frame && frame->IsMain())
        SendUtf8(slot_->browser_id, kOpEvalResult,
                 std::to_string(kLivenessPingId) + ":{\"ok\":true,\"v\":1}");
      return true;
    }
    return router_->OnProcessMessageReceived(browser, frame, source_process,
                                             message);
  }

  // CefLoadHandler: spinner + back/forward enablement.
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    SendLoadState(slot_->browser_id, isLoading, canGoBack, canGoForward);
  }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   TransitionType) override {
    if (frame && frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageStart,
               policy::TruncateUtf8(frame->GetURL().ToString(),
                                    policy::kMaxPagePayload));
      // SECURITY (as on macOS): install the JS-channel shims ONLY into
      // the MAIN frame — injecting the privileged window.<name> bridge into a
      // cross-origin subframe would hand an untrusted iframe that bridge.
      for (const auto& name : slot_->channels) InjectChannelShim(frame, name);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int) override {
    if (frame && frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageFinish,
               policy::TruncateUtf8(frame->GetURL().ToString(),
                                    policy::kMaxPagePayload));
      // Render floor (the macOS host's OnLoadEnd, minus the external
      // begin-frame this host never sends): re-assert size + damage when the
      // main frame finishes so a coalesced/dropped first frame is re-driven
      // instead of leaving a blank tile. Hidden tiles stay paused.
      if (browser && browser->GetHost() && slot_->visible) {
        auto h = browser->GetHost();
        h->WasResized();
        h->Invalidate(PET_VIEW);
      }
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& text, const CefString& url) override {
    if (code == ERR_ABORTED) return;
    SendCodePlusUtf8(slot_->browser_id, kOpLoadErr, static_cast<uint32_t>(code),
                     policy::CapText(url.ToString() + "\n" + text.ToString()));
  }

  // CefDisplayHandler: title / address / console / progress -> plugin.
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    SendUtf8(slot_->browser_id, kOpTitle, policy::CapText(title.ToString()));
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame && frame->IsMain())
      SendUtf8(slot_->browser_id, kOpUrl,
               policy::TruncateUtf8(url.ToString(), policy::kMaxPagePayload));
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level,
                        const CefString& message, const CefString& source,
                        int line) override {
    SendCodePlusUtf8(slot_->browser_id, kOpConsole,
                     static_cast<uint32_t>(level),
                     policy::CapText(source.ToString() + ":" +
                                     std::to_string(line) + "\t" +
                                     message.ToString()));
    return false;  // also keep CEF's default console logging
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    uint8_t p[4];
    WriteU32BE(p, static_cast<uint32_t>(progress * 100.0 + 0.5));
    SendFrame(slot_->browser_id, kOpProgress, p, 4);
  }

  // The async create completes here. Bind the browser, ack kOpCreated,
  // honor a deferred close, then catch the browser up on everything that
  // arrived while the create was in flight: visibility, a resize, and the ops
  // kept in slot_->deferred, in order. No begin-frame pump to start (CEF's
  // internal frame timer drives paints).
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      LogErr("[cef_host] OnAfterCreated wire=%u", slot_->browser_id);
    slot_->browser = browser;
    SendFrame(slot_->browser_id, kOpCreated, nullptr, 0);
    if (slot_->close_requested) {
      slot_->deferred.clear();
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    CefRefPtr<CefBrowserHost> host = browser->GetHost();
    if (!slot_->visible) host->WasHidden(true);
    bool resized = false, dpr_changed = false;
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      resized = slot_->width != slot_->created_w ||
                slot_->height != slot_->created_h;
      dpr_changed = slot_->dpr != slot_->created_dpr;
    }
    if (resized || dpr_changed) {
      if (slot_->visible) {
        if (dpr_changed) host->NotifyScreenInfoChanged();
        host->WasResized();
        host->Invalidate(PET_VIEW);
      } else if (dpr_changed) {
        slot_->needs_screen_info_on_show = true;
      }
    }
    std::vector<BrowserOp> ops = std::move(slot_->deferred);
    slot_->deferred.clear();
    for (auto& op : ops) {
      if (!slot_->browser) break;  // an op closed it
      op(*slot_);
    }
  }

  // Popups. macOS (OnBeforePopup in host_client.mm) splits by disposition: a
  // SIZED popup (CEF_WOD_NEW_POPUP — the window.open-with-features shape
  // OAuth/"Sign in with Google" uses) gets a REAL native window so
  // window.opener/postMessage/window.close work; everything else
  // (target=_blank / plain new tab) diverts to kOpNewWindow and loads
  // in-place. The native popup window is not ported to Windows yet, so sized
  // popups still divert in-tab — but that CANNOT complete the
  // opener/postMessage handshake (it strands sign-in). Emit a distinct log per
  // CEF_WOD_NEW_POPUP so the regression is visible, not silent.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     CefLifeSpanHandler::WindowOpenDisposition disposition, bool,
                     const CefPopupFeatures&,
                     CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (disposition == CEF_WOD_NEW_POPUP) {
      static std::atomic<bool> logged{false};
      if (!logged.exchange(true))
        SendLog(slot_->browser_id,
                "OnBeforePopup: sized popup (CEF_WOD_NEW_POPUP) diverted in-tab "
                "— Windows has no native OAuth-popup window yet, so "
                "window.open sign-in (opener/postMessage) will not complete "
                "(macOS opens one: OpenNativeAuthPopup)");
    }
    // Non-native case (matches macOS's non-popup branch):
    // load the target in this tile.
    if (!target_url.empty())
      SendUtf8(slot_->browser_id, kOpNewWindow,
               policy::TruncateUtf8(target_url.ToString(),
                                    policy::kMaxPagePayload));
    return true;  // cancel the native popup
  }

  // Page cursor -> plugin (drives the Flutter MouseRegion cursor).
  bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle,
                      cef_cursor_type_t type, const CefCursorInfo&) override {
    uint8_t p[4];
    WriteU32BE(p, static_cast<uint32_t>(type));
    SendFrame(slot_->browser_id, kOpCursor, p, 4);
    return true;
  }

  // Centralized per-browser teardown (as the macOS OnBeforeClose): drop the
  // routing entry, release the bridge under the slot lock (closing set FIRST so
  // a racing paint can't re-mint), break the retain cycle.
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (router_) router_->OnBeforeClose(browser);
    SetAuthoredDoc(slot_->browser_id, "", "");
    ForgetRendererCrashes(slot_->browser_id);
    EraseSlot(slot_->browser_id);
    slot_->deferred.clear();
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      slot_->closing = true;
      slot_->bridge.Reset();
      slot_->retired_bridge.Reset();
      slot_->popup_tex.Reset();
      slot_->bridge_handle = 0;
      slot_->bridge_w = 0;
      slot_->bridge_h = 0;
    }
    slot_->browser = nullptr;
  }

  // Ctrl-key editing shortcuts as the FALLBACK they are in a real browser
  // (as macOS OnKeyEvent). CefWebView sends Ctrl+C/X/V/A/Z/Y to the page as raw
  // keys, so an editor that owns its undo stack and selection (Monaco) handles
  // them in its keydown listener; Blink's own key bindings run the edit command
  // when the page doesn't. OnKeyEvent is called only for a key both left
  // unhandled, so this can't run a command twice.
  bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event,
                  CefEventHandle) override {
    if (event.type != KEYEVENT_RAWKEYDOWN) return false;
    const uint32_t m = event.modifiers;
    if (!(m & EVENTFLAG_CONTROL_DOWN) ||
        (m & (EVENTFLAG_ALT_DOWN | EVENTFLAG_COMMAND_DOWN)))
      return false;
    CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
    if (!frame) return false;
    const bool shift = (m & EVENTFLAG_SHIFT_DOWN) != 0;
    switch (event.windows_key_code) {
      case 'C': if (shift) return false; frame->Copy(); return true;
      case 'X': if (shift) return false; frame->Cut(); return true;
      case 'V': if (shift) return false; frame->Paste(); return true;
      case 'A': if (shift) return false; frame->SelectAll(); return true;
      case 'Z': if (shift) frame->Redo(); else frame->Undo(); return true;
      case 'Y': if (shift) return false; frame->Redo(); return true;
      default: return false;
    }
  }

  // IO thread. Answer the main-frame navigation to an authored document's URL
  // with the document itself (see g_authored); everything else is untouched.
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool is_navigation, bool is_download,
      const CefString&, bool&) override {
    if (!is_navigation || is_download) return nullptr;
    if (frame && !frame->IsMain()) return nullptr;
    if (request->GetMethod().ToString() != "GET") return nullptr;
    std::string html;
    if (!LookupAuthoredDoc(slot_->browser_id, request->GetURL().ToString(),
                           &html))
      return nullptr;
    return new AuthoredRequestHandler(std::move(html));
  }

  // Navigation scheme allowlist (as on macOS). Empty allowlist = allow
  // all. Main-frame only; kOpLoadTrusted's exact-URL exemptions are consumed
  // here.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool, bool) override {
    // Clean up any pending message-router queries for the frame about to
    // navigate (as on macOS) — otherwise a channel query in flight across a
    // navigation can misfire or leak its callback.
    if (router_) router_->OnBeforeBrowse(browser, frame);
    if (g_allowed_schemes.empty()) return false;  // allow
    const std::string url = request->GetURL().ToString();
    const bool main_frame = !frame || frame->IsMain();
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
      if (scheme != "about" && g_allowed_schemes.count(scheme) == 0)
        return true;  // cancel
    }
    return false;  // allow
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostClient);
};

// ---- CEF app ----

// The one CefApp, used for BOTH the browser process (CefInitialize) and every
// re-exec'd sub-process (CefExecuteProcess). CEF calls GetBrowserProcessHandler
// in the browser process and GetRenderProcessHandler in the render process, so
// the SAME binary hosts both halves of CefMessageRouter (the macOS split across
// host_client.mm + the helper's process_helper.mm collapses here — Windows
// re-runs cef_host.exe as the render subprocess). The renderer half owns a
// CefMessageRouterRendererSide with the DEFAULT config (must match the
// browser-side HostClient config); it injects window.cefQuery into every frame
// and relays cefQuery calls to the browser process.
class HostApp : public CefApp,
                public CefBrowserProcessHandler,
                public CefRenderProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  // ---- Render-process half (the macOS HelperApp counterpart) ----
  // Render-process-only callback; create the renderer-side router here with the
  // default config (window.cefQuery / cefQueryCancel).
  void OnWebKitInitialized() override {
    CefMessageRouterConfig config;
    render_router_ = CefMessageRouterRendererSide::Create(config);
  }
  // Called in THIS renderer for every browser it hosts, with the extra_info the
  // browser process passed to CreateBrowser (again in each new renderer after a
  // cross-process navigation) — the browser's document-start config.
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (!extra_info) return;
    auto read = [&](const char* key, std::vector<std::string>* out) {
      CefRefPtr<CefListValue> list = extra_info->GetList(key);
      if (!list) return;
      for (size_t i = 0; i < list->GetSize(); ++i)
        out->push_back(list->GetString(i).ToString());
    };
    document_start::Config config;
    read(document_start::kChannelsKey, &config.channels);
    read(document_start::kScriptsKey, &config.scripts);
    if (!config.empty()) document_start_[browser->GetIdentifier()] = config;
  }
  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    document_start_.erase(browser->GetIdentifier());
  }
  // Every main-frame JavaScript context gets the create-time channel shims and
  // the document-start scripts synchronously, before the page's own scripts.
  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    // window.cefQuery first: the channel shims below post through it.
    if (render_router_) render_router_->OnContextCreated(browser, frame,
                                                         context);
    if (!frame->IsMain()) return;
    auto it = document_start_.find(browser->GetIdentifier());
    if (it == document_start_.end()) return;
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    for (const std::string& name : it->second.channels) {
      if (!document_start::IsValidChannelName(name)) continue;
      context->Eval(document_start::ChannelShimJs(name), CefString(), 0, result,
                    exception);
    }
    for (const std::string& script : it->second.scripts) {
      exception = nullptr;
      if (context->Eval(script, CefString(), 0, result, exception) ||
          !exception)
        continue;
      // A broken script must not take the page down with it — report it where
      // the page's own errors go (the console, forwarded to the plugin).
      CefRefPtr<CefV8Exception> ignored;
      context->Eval(
          "console.error(\"[flutter_cef] document-start script failed: \" + " +
              document_start::JsStringLiteral(
                  exception->GetMessage().ToString()) +
              ")",
          CefString(), 0, result, ignored);
    }
  }
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    if (render_router_)
      render_router_->OnContextReleased(browser, frame, context);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    // The liveness ping: answered from this (the renderer's main) thread,
    // which a hung page or renderer never gets back to.
    if (message->GetName().ToString() == kPingMessage) {
      if (frame)
        frame->SendProcessMessage(PID_BROWSER,
                                  CefProcessMessage::Create(kPongMessage));
      return true;
    }
    return render_router_ &&
           render_router_->OnProcessMessageReceived(browser, frame,
                                                    source_process, message);
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    (void)process_type;
    // OSR establishment latency (as on macOS): OSR views have no real
    // OS window, so Chromium backgrounds their renderers during first load.
    if (!std::getenv("FLUTTER_CEF_KEEP_BG_THROTTLE")) {
      command_line->AppendSwitch("disable-renderer-backgrounding");
      command_line->AppendSwitch("disable-backgrounding-occluded-windows");
    }
    // FLUTTER_CEF_SOFTWARE_COMPOSITING=1 turns the GPU off, so frames arrive
    // through OnPaint as they do on a machine with no usable GPU. CI uses it to
    // cover that path, and it tells a GPU-driver bug from a page bug.
    if (EnvFlag("FLUTTER_CEF_SOFTWARE_COMPOSITING")) {
      command_line->AppendSwitch("disable-gpu");
      command_line->AppendSwitch("disable-gpu-compositing");
    }
    // Verbose Chromium logging (browser + propagated to children) only when
    // explicitly debugging (the macOS host's pattern).
    if (std::getenv("FLUTTER_CEF_DEBUG")) {
      command_line->AppendSwitch("enable-logging");
      command_line->AppendSwitchWithValue(
          "log-file", TempDirUtf8() + "cef_host_chromium.log");
      command_line->AppendSwitchWithValue("v", "1");
    }
    // Agent-control CDP-over-pipe translation: the plugin passed the
    // two inherited pipe HANDLE values as --cdp-io-pipes=<read>,<write>; turn
    // them into Chromium's real switches. Browser process only (process_type
    // empty) — the renderer/GPU children never get the debugging pipe (and never
    // inherited the handles). Mirrors the macOS --cdp-pipe injection in
    // main.mm. (disable-blink-features=AutomationControlled is not ported.)
    if (process_type.empty() && !g_cdp_io_pipes.empty()) {
      command_line->AppendSwitch("remote-debugging-pipe");
      command_line->AppendSwitchWithValue("remote-debugging-io-pipes",
                                           g_cdp_io_pipes);
    }
  }

  // Announce readiness. Payload = {readyFlags, protocolVersion}
  // (as the macOS OnContextInitialized). Bit0 (ad-hoc/mock-keychain build) is
  // a macOS-only concern — Windows sends 0. The plugin sends NOTHING until this
  // arrives, then refuses on protocolVersion skew.
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      LogErr("[cef_host] OnContextInitialized");
    const uint8_t ready_payload[2] = {0, kCefHostProtocolVersion};
    SendFrame(/*browser_id=*/0, kOpReady, ready_payload,
              sizeof(ready_payload));
  }

 private:
  // Renderer-side message router (render process only; created in
  // OnWebKitInitialized). Null in the browser process.
  CefRefPtr<CefMessageRouterRendererSide> render_router_;
  // Browser identifier -> its document-start config. Renderer main thread only.
  std::map<int, document_start::Config> document_start_;

  IMPLEMENT_REFCOUNTING(HostApp);
};

// ---- CEF-UI-thread op helpers (the IPC reader posts these) ----

// Create the windowless browser for a slot the reader registered at its create
// frame. CEF UI thread. Producer-allocates: no surface/bridge is created here
// — the first paint mints the bridge sized to the actual painted frame.
void DoCreateBrowser(std::shared_ptr<Slot> slot, std::string url) {
  CEF_REQUIRE_UI_THREAD();
  const uint32_t wire_id = slot->browser_id;
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    slot->created_w = slot->width;
    slot->created_h = slot->height;
    slot->created_dpr = slot->dpr;
  }
  CefWindowInfo window_info;
  // The hidden per-process WS_POPUP window as the windowless parent so
  // dialogs/menus/IMM degrade gracefully (null works too for WebAuthn).
  window_info.SetAsWindowless(g_hidden_hwnd);
  // GPU OSR: the GPU process composites and hands OnAcceleratedPaint an NT
  // shared handle (the GPU pixel path). Without GPU compositing Chromium falls
  // back to OnPaint, which the render handler uploads into the same bridge.
  window_info.shared_texture_enabled = true;
  // external_begin_frame_enabled stays FALSE (default). With the external
  // pump only the FIRST browser in the process ever paints; CEF's internal
  // frame timer at windowless_frame_rate drives paints.
  window_info.external_begin_frame_enabled = false;
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 60;
  // Render floor: opaque background so a dropped frame reads as a blank white
  // tile, not an invisible transparent ghost.
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  // create-with-html/file: a data:/file: create URL is host-trusted content
  // injection — arm the exact-URL allowlist exemption for the initial load.
  if (!g_allowed_schemes.empty() &&
      (url.rfind("data:", 0) == 0 || url.rfind("file:", 0) == 0)) {
    slot->trusted_pending.insert(url);
  }
  // Same exemption for a create ON an authored document's URL (the plugin
  // chose that content), armed normalized: OnBeforeBrowse sees the canonical
  // request URL.
  if (!g_allowed_schemes.empty() && url.rfind("data:", 0) != 0 &&
      url.rfind("file:", 0) != 0 && LookupAuthoredDoc(wire_id, url, nullptr)) {
    slot->trusted_pending.insert(NormalizeAuthoredUrl(url));
  }
  CefRefPtr<HostClient> client = new HostClient(slot);
  // ASYNC create. OnAfterCreated binds the browser and acks kOpCreated.
  // Document-start scripts + create-time JS channels ride into the renderer as
  // the browser's extra_info (see document_start.h) — the only channel that is
  // in place before the first document's scripts run.
  bool dispatched = CefBrowserHost::CreateBrowser(
      window_info, client, url, settings,
      TakeDocumentStartExtraInfo(wire_id, &slot->channels), nullptr);
  if (!dispatched) {
    // Dispatch failed: reclaim the slot + tell the plugin.
    SendLog(wire_id, "createBrowser: CreateBrowser dispatch failed");
    SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
    SetAuthoredDoc(wire_id, "", "");
    EraseSlot(wire_id);
    slot->deferred.clear();
    std::lock_guard<std::mutex> slock(slot->surface_mutex);
    slot->closing = true;
    slot->bridge.Reset();
    slot->retired_bridge.Reset();
    slot->bridge_handle = 0;
  }
  if (std::getenv("FLUTTER_CEF_DEBUG"))
    LogErr("[cef_host] createBrowser wire=%u dispatched=%d", wire_id,
           dispatched ? 1 : 0);
}

// Close one browser (kOpDisposeBrowser). The map-erase + bridge release run
// in OnBeforeClose once CEF finishes closing.
void DoDisposeBrowser(uint32_t wire_id) {
  CEF_REQUIRE_UI_THREAD();
  std::shared_ptr<Slot> slot = LookupWireId(wire_id);
  if (!slot) {
    // Never created, or already closed: drop whatever was parked for it.
    SetAuthoredDoc(wire_id, "", "");
    SetDocumentStart(wire_id, {});
    return;
  }
  if (slot->browser) {
    slot->browser->GetHost()->CloseBrowser(true);
  } else {
    slot->close_requested = true;  // OnAfterCreated closes it on bind
    slot->deferred.clear();
  }
}

// Every WasResized discards CEF's frame pool; late frames at the old
// size still arrive and are refused by the plugin's size-gate (each present
// carries its truthful dims). Producer-allocates: the bridge re-mints on the
// first NEW-size paint, not here (the macOS DoResize in browser_ops.mm, with
// Invalidate standing in for SendExternalBeginFrame).
void DoResize(const std::shared_ptr<Slot>& slot, int w, int h, double dpr) {
  if (w < 1 || w > 16384 || h < 1 || h > 16384) {
    SendLog(slot->browser_id, "resize: out-of-range dims " + std::to_string(w) +
                                  "x" + std::to_string(h));
    return;
  }
  bool dpr_changed = false;
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    slot->width = w;
    slot->height = h;
    if (dpr > 0.0 && dpr != slot->dpr) {
      slot->dpr = dpr;
      dpr_changed = true;
    }
  }
  if (slot->browser) {
    if (slot->visible) {
      if (dpr_changed) slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->browser->GetHost()->WasResized();
      slot->browser->GetHost()->Invalidate(PET_VIEW);
    } else {
      // Hidden — no frame can result; defer the screen-info re-assert +
      // repaint to the hidden->visible edge (DoSetVisible).
      if (dpr_changed) slot->needs_screen_info_on_show = true;
    }
  }
}

// Navigate a bound browser. A host-trusted load (kOpLoadTrusted) first arms
// the exact-URL allowlist exemption, normalized: OnBeforeBrowse matches against
// the CANONICAL request URL, so an authored load for "https://host" must be
// armed as "https://host/".
void DoNavigate(Slot& slot, const std::string& url, bool trusted) {
  if (trusted && !g_allowed_schemes.empty())
    slot.trusted_pending.insert(NormalizeAuthoredUrl(url));
  CefRefPtr<CefFrame> f = slot.browser->GetMainFrame();
  if (f) f->LoadURL(url);
}

void DoExecuteJs(Slot& slot, const std::string& code) {
  CefRefPtr<CefFrame> f = slot.browser->GetMainFrame();
  if (f) f->ExecuteJavaScript(code, "", 0);
}
// Focused-frame edit command: OSR has no native responder chain, so the
// plugin invokes these explicitly.
void DoEditCommand(Slot& slot, int command) {
  CEF_REQUIRE_UI_THREAD();
  CefRefPtr<CefFrame> frame = slot.browser->GetFocusedFrame();
  if (!frame) return;
  switch (command) {
    case 0: frame->Copy(); break;
    case 1: frame->Cut(); break;
    case 2: frame->Paste(); break;
    case 3: frame->SelectAll(); break;
    case 4: frame->Undo(); break;
    case 5: frame->Redo(); break;
    default: break;
  }
}
// Off-screen render gating + the hidden->visible repaint kick that stops a
// culled tile coming back blank (the macOS DoSetVisible in browser_ops.mm,
// Invalidate in place of the external begin-frame).
void DoSetVisible(const std::shared_ptr<Slot>& slot, bool visible) {
  const bool was_visible = slot->visible;
  slot->visible = visible;
  if (!slot->browser) return;
  slot->browser->GetHost()->WasHidden(!visible);
  if (visible && !was_visible) {
    if (slot->needs_screen_info_on_show) {
      slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->needs_screen_info_on_show = false;
    }
    slot->browser->GetHost()->WasResized();
    slot->browser->GetHost()->Invalidate(PET_VIEW);
  }
}
void DoJsDialogResp(const std::shared_ptr<Slot>& slot, uint32_t id, bool ok,
                    const std::string& text) {
  auto it = slot->dialogs.find(id);
  if (it == slot->dialogs.end()) return;
  // On Windows, CefJSDialogCallback::Continue() synchronously re-enters
  // OnResetDialogState(), which clears slot->dialogs — so a Continue()-then-
  // erase(it) (as macOS does, where the reset is async) would erase() through an
  // invalidated iterator and crash the host. Take the ref and drop our map entry
  // BEFORE Continue(); the callback stays alive in `cb`. No wire-observable
  // difference from macOS — this only fixes the iterator lifetime on Windows.
  CefRefPtr<CefJSDialogCallback> cb = it->second;
  slot->dialogs.erase(it);
  cb->Continue(ok, text);
}

// runJavaScriptReturningResult (the macOS DoEvalReturning, verbatim).
// Evaluate the user expression and post its JSON result back through
// window.cefQuery (-> HostClient::OnQuery -> kOpEvalResult "id:json",
// correlated to the Dart Future). `code` is the trusted host's JS (same trust
// level as executeJavaScript) and must be a single expression. It is spliced
// (not eval()'d) so it works under a strict page CSP; the Dart side fails any
// pending result on navigation so a wedged callback can't leak a completer.
void DoEvalReturning(Slot& slot, uint32_t id, const std::string& code) {
  CefRefPtr<CefFrame> frame = slot.browser->GetMainFrame();
  if (!frame) return;
  if (id == kLivenessPingId) {
    // Asked of the renderer itself, not the page.
    frame->SendProcessMessage(PID_RENDERER,
                              CefProcessMessage::Create(kPingMessage));
    return;
  }
  std::string js =
      "window.cefQuery({request:'eval:" + std::to_string(id) +
      ":'+(function(){try{return JSON.stringify({ok:true,v:(" + code +
      "\n)});}catch(e){return JSON.stringify({ok:false,v:String(e)});}})(),"
      "persistent:false,onSuccess:function(){},onFailure:function(){}});";
  frame->ExecuteJavaScript(js, "", 0);
}

// Registers a JS channel for one browser (UI thread; mirrors the macOS
// DoAddChannel). The slot exists from its create frame on, before the browser
// binds; a channel registered by then rides into the page at load.
void DoAddChannel(const std::shared_ptr<Slot>& slot, const std::string& name) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsValidChannelName(name)) {
    SendLog(slot->browser_id, "addJavaScriptChannel: rejected invalid name '" +
                                  name + "' (must be a JS identifier)");
    return;
  }
  slot->channels.insert(name);
  // Inject into the current page too, for a channel registered after it loaded.
  if (slot->browser) InjectChannelShim(slot->browser->GetMainFrame(), name);
}

// ---- Cookies (global manager = the shared profile jar, as on macOS) ----

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

const char* SameSiteToString(cef_cookie_same_site_t v);
std::string CookieToJson(const CefCookie& c) {
  std::string out = "{";
  out += "\"name\":\"" + JsonEscape(CefString(&c.name).ToString()) + "\",";
  out += "\"value\":\"" + JsonEscape(CefString(&c.value).ToString()) + "\",";
  out += "\"domain\":\"" + JsonEscape(CefString(&c.domain).ToString()) + "\",";
  out += "\"path\":\"" + JsonEscape(CefString(&c.path).ToString()) + "\",";
  out += "\"secure\":" + std::string(c.secure ? "true" : "false") + ",";
  out += "\"httpOnly\":" + std::string(c.httponly ? "true" : "false") + ",";
  out += "\"sameSite\":\"" + std::string(SameSiteToString(c.same_site)) + "\"";
  return out + "}";
}

// Flushes the JSON array on destruction so the 0-cookie case still replies.
class HostCookieVisitor : public CefCookieVisitor {
 public:
  HostCookieVisitor(uint32_t browser_id, uint32_t id)
      : browser_id_(browser_id), id_(id) {}
  bool Visit(const CefCookie& cookie, int, int, bool&) override {
    std::string one = CookieToJson(cookie);
    // A jar too large for the wire replies with the cookies that fit.
    if (json_.size() + one.size() + 3 > policy::kMaxPagePayload) return false;
    if (!json_.empty()) json_ += ",";
    json_ += one;
    return true;
  }
  ~HostCookieVisitor() override {
    SendCodePlusUtf8(browser_id_, kOpCookies, id_, "[" + json_ + "]");
  }

 private:
  uint32_t browser_id_;
  uint32_t id_;
  std::string json_;
  IMPLEMENT_REFCOUNTING(HostCookieVisitor);
};

// Map the wire sameSite token to Chromium's enum (and back for getCookies).
cef_cookie_same_site_t ParseSameSite(const std::string& s) {
  if (s == "none") return CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
  if (s == "lax") return CEF_COOKIE_SAME_SITE_LAX_MODE;
  if (s == "strict") return CEF_COOKIE_SAME_SITE_STRICT_MODE;
  return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
}
const char* SameSiteToString(cef_cookie_same_site_t v) {
  switch (v) {
    case CEF_COOKIE_SAME_SITE_NO_RESTRICTION: return "none";
    case CEF_COOKIE_SAME_SITE_LAX_MODE: return "lax";
    case CEF_COOKIE_SAME_SITE_STRICT_MODE: return "strict";
    default: return "unspecified";
  }
}

// COOKIE VERBS TAKE A WIRE ID, NOT A SLOT (parity with macOS). The jar is
// process-global, so nothing here needs the browser — the id only routes the
// reply/log. Requiring a live slot on the reader thread silently DROPPED any cookie
// verb that raced the create (the slot is registered by a later TID_UI task): a
// dropped setCookie meant an unauthenticated first load, and a dropped getCookies
// never replied, so the caller's future hung forever.
void DoSetCookie(uint32_t wire_id, const std::string& url,
                 const std::string& name, const std::string& value,
                 const std::string& domain, const std::string& path,
                 bool secure, bool http_only, const std::string& same_site) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (!mgr) return;
  CefCookie cookie;
  CefString(&cookie.name).FromString(name);
  CefString(&cookie.value).FromString(value);
  if (!domain.empty()) CefString(&cookie.domain).FromString(domain);
  CefString(&cookie.path).FromString(path.empty() ? "/" : path);
  cookie.has_expires = false;
  // SameSite=None without Secure is rejected by Chromium (the cookie is
  // dropped at SetCookie time), so force Secure on for that combination.
  cookie.secure = (secure || same_site == "none") ? 1 : 0;
  cookie.httponly = http_only ? 1 : 0;
  cookie.same_site = ParseSameSite(same_site);
  if (!mgr->SetCookie(url, cookie, nullptr)) {
    SendLog(wire_id,
            "setCookie rejected for " + url + " (name '" + name + "')");
  }
}
void DoClearCookies() {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(CefString(), CefString(), nullptr);
}
void DoVisitCookies(uint32_t wire_id, uint32_t id, const std::string& url) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  CefRefPtr<HostCookieVisitor> visitor =
      new HostCookieVisitor(wire_id, id);
  if (!mgr) return;
  if (url.empty()) {
    mgr->VisitAllCookies(visitor);
  } else {
    mgr->VisitUrlCookies(url, true, visitor);
  }
}
void DoDeleteCookie(const std::string& url, const std::string& name) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(url, name, nullptr);
}

void DoShowDevTools(Slot& slot) {
  CefWindowInfo window_info;  // default = windowed DevTools
  CefBrowserSettings settings;
  slot.browser->GetHost()->ShowDevTools(window_info, nullptr, settings,
                                        CefPoint());
}

// ---- IME (as on macOS) ----
void DoImeSetComposition(Slot& slot, const std::string& text) {
  CefString t(text);
  uint32_t len = static_cast<uint32_t>(t.length());
  std::vector<CefCompositionUnderline> underlines;
  if (len > 0) {
    CefCompositionUnderline u;
    u.range = CefRange(0, len);
    u.color = 0;
    u.background_color = 0;
    u.thick = 0;
    u.style = CEF_CUS_SOLID;
    underlines.push_back(u);
  }
  slot.browser->GetHost()->ImeSetComposition(t, underlines,
                                             CefRange::InvalidRange(),
                                             CefRange(len, len));
}

// type: 0=move 1=down 2=up 3=wheel 4=leave; button: 0=left 1=middle 2=right.
// x/y logical (DIP) view coords, exactly like macOS.
void DoPointer(Slot& slot, int type, int button, int click_count,
               uint32_t modifiers, double x, double y, double dx, double dy) {
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;
  CefRefPtr<CefBrowserHost> host = slot.browser->GetHost();
  switch (type) {
    case 0:
      host->SendMouseMoveEvent(ev, false);
      break;
    case 1:
      // Focus on press so text fields take input (CEF won't route keys to an
      // unfocused OSR browser).
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
    case 4:
      host->SendMouseMoveEvent(ev, true);  // mouseLeave: clear hover state
      break;
    default:
      break;
  }
}

// type: 0=rawkeydown 2=keyup 3=char (cef_key_event_type_t). The Dart side
// sends REAL Windows virtual-key codes in windowsKeyCode on Windows (and the
// Unicode codepoint for char events) — native CefKeyEvent semantics, no
// translation needed (as the macOS DoKey; character fields always set
// per the CEF t=11650 de-dup note, harmless on Windows).
void DoKey(Slot& slot, int type, uint32_t modifiers, int32_t windows_key_code,
           int32_t native_key_code, uint32_t character) {
  CefKeyEvent ev;
  ev.type = static_cast<cef_key_event_type_t>(type);
  ev.modifiers = modifiers;
  ev.windows_key_code = windows_key_code;
  ev.native_key_code = native_key_code;
  ev.is_system_key = 0;
  ev.character = static_cast<char16_t>(character);
  ev.unmodified_character = static_cast<char16_t>(character);
  slot.browser->GetHost()->SendKeyEvent(ev);
}

// Force a repaint: the plugin's first-present watchdog sends kOpInvalidate
// when a browser's first frame never arrived (the macOS DoInvalidate). No
// SendExternalBeginFrame — the internal frame timer honors Invalidate.
void DoInvalidate(const std::shared_ptr<Slot>& slot) {
  CEF_REQUIRE_UI_THREAD();
  if (slot && slot->browser && slot->browser->GetHost())
    slot->browser->GetHost()->Invalidate(PET_VIEW);
}

// Quit the message loop exactly once (the FlushStore completion and the
// bounded fallback both route here; whichever wins quits, the other is a no-op).
std::atomic<bool> g_quit_posted{false};
void FinishShutdownQuit() {
  CEF_REQUIRE_UI_THREAD();
  if (g_quit_posted.exchange(true)) return;
  CefQuitMessageLoop();
}

// Ends the process if it is still running a while after a shutdown was
// requested (policy::kHardExitAfterShutdown; see cef_host_policy.h). Armed
// once, wherever a shutdown is requested; any thread. As the macOS host's
// ArmHardExit, except that its thread starts with the process
// (StartHardExitWatchdog): starting a thread takes the loader lock, which a
// wedged thread may hold.
std::once_flag g_hard_exit_armed;
HANDLE g_hard_exit_event = nullptr;  // set when armed
std::atomic<int64_t> g_hard_exit_at_ms{0};  // GetTickCount64 clock
std::atomic<const char*> g_hard_exit_why{""};

int64_t TickMs() { return static_cast<int64_t>(GetTickCount64()); }

void StartHardExitWatchdog() {
  g_hard_exit_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!g_hard_exit_event) {
    LogErr("[cef_host] CreateEvent failed (%lu): no hard exit after shutdown",
           GetLastError());
    return;
  }
  std::thread([] {
    WaitForSingleObject(g_hard_exit_event, INFINITE);
    policy::WaitForDeadline(
        TickMs, [] { return g_hard_exit_at_ms.load(); },
        [](int64_t ms) { Sleep(static_cast<DWORD>(ms)); });
    LogErr("[cef_host] still running after shutdown (%s); exiting now",
           g_hard_exit_why.load());
    // Not exit(): that runs DLL detach code, which can block on a lock the
    // wedged thread holds.
    TerminateProcess(GetCurrentProcess(), 0);
  }).detach();
}

// `why` must be a string literal.
void ArmHardExit(const char* why) {
  std::call_once(g_hard_exit_armed, [why] {
    g_hard_exit_why = why;
    g_hard_exit_at_ms =
        TickMs() + std::chrono::milliseconds(policy::kHardExitAfterShutdown)
                       .count();
    if (g_hard_exit_event) SetEvent(g_hard_exit_event);
  });
}

// The message loop has quit and CefShutdown is next: allow it
// policy::kHardExitAfterTeardown from now.
void ExtendHardExitForTeardown() {
  ArmHardExit("teardown");
  g_hard_exit_at_ms =
      TickMs() +
      std::chrono::milliseconds(policy::kHardExitAfterTeardown).count();
}

// Cookie-store flush completion: once the on-disk jar is written, quit.
class ShutdownFlushCallback : public CefCompletionCallback {
 public:
  void OnComplete() override { FinishShutdownQuit(); }

 private:
  IMPLEMENT_REFCOUNTING(ShutdownFlushCallback);
};

// Tear down the WHOLE process (kOpShutdown / pipe EOF): close every browser,
// flush the cookie jar to disk, then quit the message loop. Per-slot cleanup
// runs in OnBeforeClose (as the macOS DoShutdown in host_state.mm).
//
// WINDOWS COOKIE DURABILITY (no macOS analogue): unlike macOS — where the
// implicit CefShutdown flush reliably persists the jar — a fast Windows teardown
// exits cleanly (code 0) yet leaves the on-disk cookie store EMPTY (verified:
// a plugin-driven dispose+kOpShutdown flushed nothing, while the SAME host binary
// under a slow standalone driver did). Session cookies (has_expires=false, kept
// by persist_session_cookies) are only guaranteed durable once explicitly
// flushed, so we FlushStore here and defer the quit into its completion — that is
// what makes "stay signed in" survive relaunch. A bounded fallback quits anyway
// if the callback never fires, so teardown can't wedge inside the plugin reaper's
// grace. The macOS host does not need this.
void DoShutdown() {
  CEF_REQUIRE_UI_THREAD();
  ArmHardExit("shutdown");
  std::vector<std::shared_ptr<Slot>> slots;
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    slots.reserve(g_slots_by_wire_id.size());
    for (auto& kv : g_slots_by_wire_id) slots.push_back(kv.second);
  }
  for (auto& slot : slots) {
    if (slot->browser) slot->browser->GetHost()->CloseBrowser(true);
  }
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) {
    mgr->FlushStore(new ShutdownFlushCallback());
    // Fallback well inside the plugin reaper's 3s grace: never let a missing
    // flush callback wedge the quit.
    CefPostDelayedTask(TID_UI, base::BindOnce(&FinishShutdownQuit), 2000);
  } else {
    FinishShutdownQuit();
  }
}

// Reader thread: decode frames, marshal onto the CEF UI thread (mirrors the
// macOS IpcReadLoop in ipc_reader.mm; payload layouts PROTOCOL.md §2).
// Per-browser ops go through PostBrowserOp, which holds an op that beats the
// browser's bind until OnAfterCreated instead of dropping it.
void IpcReadLoop() {
  HANDLE pipe = g_ipc_pipe.load();
  for (;;) {
    uint8_t hdr[4];
    if (!ReadAllPipe(pipe, hdr, 4)) break;
    uint32_t body_len = ReadU32BE(hdr);
    // Malformed/oversized length = wire desync: log + tear down everything
    // (the IPC peer is trusted, so this only fires on a framing bug).
    if (body_len < kMinBodyLen || body_len > kMaxBodyLen) {
      LogErr("[cef_host] rejecting malformed IPC frame, body_len=%u — exiting",
             body_len);
      break;
    }
    std::vector<uint8_t> body(body_len);
    if (!ReadAllPipe(pipe, body.data(), body_len)) break;
    uint32_t wire_id = ReadU32BE(body.data());
    uint8_t opcode = body[4];
    const uint8_t* p = body.data() + 5;
    uint32_t plen = body_len - 5;
    // Resolve the target slot once. It exists from its create frame on (see
    // RegisterSlot), so a null slot means the browser was disposed or never
    // created, and the op is dropped.
    std::shared_ptr<Slot> slot = LookupWireId(wire_id);
    switch (opcode) {
      case kOpCreateBrowser: {
        // {u32 w}{u32 h}{f64 dpr}{utf8 url}; frame browserId = the NEW id.
        if (plen < 16) break;
        const int w = static_cast<int>(
            (std::min)(ReadU32BE(p), static_cast<uint32_t>(16384)));
        const int h = static_cast<int>(
            (std::min)(ReadU32BE(p + 4), static_cast<uint32_t>(16384)));
        double dpr = ReadF64BE(p + 8);
        if (!(dpr > 0.0) || dpr > 8.0) dpr = 1.0;  // guard a bad/forged dpr
        std::string url(reinterpret_cast<const char*>(p + 16), plen - 16);
        if (url.empty()) url = "about:blank";
        if (std::getenv("FLUTTER_CEF_DEBUG"))
          LogErr("[cef_host] reader: create wire=%u %dx%d dpr=%.2f url=%s",
                 wire_id, w, h, dpr, url.c_str());
        // Register the slot HERE, so every frame behind this one finds it.
        std::shared_ptr<Slot> fresh =
            RegisterSlot(wire_id, w < 1 ? 1 : w, h < 1 ? 1 : h, dpr);
        if (!fresh) {
          SendLog(wire_id,
                  "createBrowser: wire id already in use — refusing (id-reuse "
                  "bug)");
          SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
          break;
        }
        CefPostTask(TID_UI, base::BindOnce(&DoCreateBrowser, fresh, url));
        break;
      }
      case kOpDisposeBrowser:
        // Resolved on TID_UI, FIFO behind the create.
        CefPostTask(TID_UI, base::BindOnce(&DoDisposeBrowser, wire_id));
        break;
      case kOpSetAuthoredHtml: {
        // Stored HERE, on the reader thread, so it is in place before the
        // create / load frame right behind it is even dispatched. No slot
        // needed.
        std::string s(reinterpret_cast<const char*>(p), plen);
        const size_t nul = s.find('\0');
        if (nul == std::string::npos) break;
        SetAuthoredDoc(wire_id, s.substr(0, nul), s.substr(nul + 1));
        break;
      }
      case kOpSetDocumentStart:
        // Parked on the reader thread, ahead of the create frame right behind it.
        SetDocumentStart(wire_id, document_start::ParsePayload(p, plen));
        break;
      case kOpShutdown:
        ArmHardExit("kOpShutdown");
        CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
        return;
      case kOpResize: {
        // {u32 w}{u32 h}[{f64 dpr}]; dpr 0/absent = unchanged. Before the
        // browser binds this only records the size, which the browser picks
        // up when it is created.
        if (!slot) break;
        if (plen < 8) break;
        int w = static_cast<int>(
            (std::min)(ReadU32BE(p), static_cast<uint32_t>(1u << 30)));
        int h = static_cast<int>(
            (std::min)(ReadU32BE(p + 4), static_cast<uint32_t>(1u << 30)));
        double dpr = (plen >= 16) ? ReadF64BE(p + 8) : 0.0;
        if (!(dpr >= 0.0) || dpr > 8.0) dpr = 0.0;  // guard a bad/forged dpr
        CefPostTask(TID_UI, base::BindOnce(&DoResize, slot, w, h, dpr));
        break;
      }
      case kOpNavigate:
      case kOpLoadTrusted: {
        if (!slot) break;
        std::string url(reinterpret_cast<const char*>(p), plen);
        const bool trusted = opcode == kOpLoadTrusted;
        // A plain navigate means the consumer wants the real site again; a
        // trusted load keeps the authored doc it is for.
        ClearAuthoredDocUnless(wire_id, trusted ? url : std::string());
        PostBrowserOp(slot, [url, trusted](Slot& s) {
          DoNavigate(s, url, trusted);
        });
        break;
      }
      case kOpReload:
        if (!slot) break;
        PostBrowserOp(slot, [](Slot& s) { s.browser->Reload(); });
        break;
      case kOpStop:
        if (!slot) break;
        PostBrowserOp(slot, [](Slot& s) { s.browser->StopLoad(); });
        break;
      case kOpBack:
        if (!slot) break;
        PostBrowserOp(slot, [](Slot& s) { s.browser->GoBack(); });
        break;
      case kOpForward:
        if (!slot) break;
        PostBrowserOp(slot, [](Slot& s) { s.browser->GoForward(); });
        break;
      case kOpExecuteJs: {
        if (!slot) break;
        std::string code(reinterpret_cast<const char*>(p), plen);
        PostBrowserOp(slot, [code](Slot& s) { DoExecuteJs(s, code); });
        break;
      }
      case kOpSetZoom: {
        if (!slot) break;
        if (plen < 8) break;
        const double level = ReadF64BE(p);
        PostBrowserOp(slot, [level](Slot& s) {
          s.browser->GetHost()->SetZoomLevel(level);
        });
        break;
      }
      case kOpEditCommand: {
        if (!slot) break;
        if (plen < 1) break;
        const int command = p[0];
        PostBrowserOp(slot, [command](Slot& s) { DoEditCommand(s, command); });
        break;
      }
      case kOpSetVisible: {
        if (!slot) break;
        bool vis = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoSetVisible, slot, vis));
        break;
      }
      case kOpSetAudioMuted: {
        if (!slot) break;
        const bool muted = plen >= 1 ? p[0] != 0 : true;
        PostBrowserOp(slot, [muted](Slot& s) {
          s.browser->GetHost()->SetAudioMuted(muted);
        });
        break;
      }
      case kOpSetPumpInterval: {
        // {u16 ms}: the visible frame cadence, as a windowless frame rate.
        if (!slot) break;
        if (plen < 2) break;
        const int ms = (p[0] << 8) | p[1];
        const int fps = policy::FrameRateForIntervalMs(ms);
        PostBrowserOp(slot, [fps](Slot& s) {
          s.browser->GetHost()->SetWindowlessFrameRate(fps);
        });
        break;
      }
      case kOpFind: {
        if (!slot) break;
        if (plen < 3) break;
        bool fwd = p[0] != 0, mc = p[1] != 0, fn = p[2] != 0;
        std::string text(reinterpret_cast<const char*>(p + 3), plen - 3);
        PostBrowserOp(slot, [text, fwd, mc, fn](Slot& s) {
          s.browser->GetHost()->Find(text, fwd, mc, fn);
        });
        break;
      }
      case kOpStopFind: {
        if (!slot) break;
        bool clear = plen >= 1 ? p[0] != 0 : true;
        PostBrowserOp(slot, [clear](Slot& s) {
          s.browser->GetHost()->StopFinding(clear);
        });
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
      case kOpSetCookie: {
        // No slot needed — see DoSetCookie (a verb racing the create must not drop).
        std::string s(reinterpret_cast<const char*>(p), plen);
        std::vector<std::string> f;
        size_t start = 0;
        for (size_t i = 0; i <= s.size(); ++i) {
          if (i == s.size() || s[i] == '\0') {
            f.push_back(s.substr(start, i - start));
            start = i + 1;
          }
        }
        while (f.size() < 8) f.push_back("");
        CefPostTask(TID_UI,
                    base::BindOnce(&DoSetCookie, wire_id, f[0], f[1], f[2], f[3],
                                   f[4], f[5] == "1", f[6] == "1", f[7]));
        break;
      }
      case kOpClearCookies:
        CefPostTask(TID_UI, base::BindOnce(&DoClearCookies));
        break;
      case kOpVisitCookies: {
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string url(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoVisitCookies, wire_id, id, url));
        break;
      }
      case kOpDeleteCookie: {
        std::string s(reinterpret_cast<const char*>(p), plen);
        const size_t nul = s.find('\0');
        std::string url = nul == std::string::npos ? s : s.substr(0, nul);
        std::string name = nul == std::string::npos ? "" : s.substr(nul + 1);
        CefPostTask(TID_UI, base::BindOnce(&DoDeleteCookie, url, name));
        break;
      }
      case kOpImeSetComp: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        PostBrowserOp(slot,
                      [text](Slot& s) { DoImeSetComposition(s, text); });
        break;
      }
      case kOpImeCommit: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        PostBrowserOp(slot, [text](Slot& s) {
          s.browser->GetHost()->ImeCommitText(text, CefRange::InvalidRange(),
                                              0);
        });
        break;
      }
      case kOpImeCancel:
        if (!slot) break;
        PostBrowserOp(slot, [](Slot& s) {
          s.browser->GetHost()->ImeCancelComposition();
        });
        break;
      case kOpShowDevTools:
        if (!slot) break;
        PostBrowserOp(slot, [](Slot& s) { DoShowDevTools(s); });
        break;
      case kOpInvalidate:
        // A repaint kick: meaningless before the browser exists, so not kept.
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoInvalidate, slot));
        break;
      case kOpPointer: {
        // 40 bytes: {u8 type}{u8 btn}{u8 clicks}{u8 pad}{u32 mods}{f64 x}
        // {f64 y}{f64 dx}{f64 dy}.
        if (!slot) break;
        if (plen < 40) break;
        int type = p[0], button = p[1], clicks = p[2];
        uint32_t mods = ReadU32BE(p + 4);
        double x = ReadF64BE(p + 8), y = ReadF64BE(p + 16);
        double dx = ReadF64BE(p + 24), dy = ReadF64BE(p + 32);
        PostBrowserOp(slot, [=](Slot& s) {
          DoPointer(s, type, button, clicks, mods, x, y, dx, dy);
        });
        break;
      }
      case kOpKey: {
        // 20 bytes: {u8 type}{pad*3}{u32 mods}{u32 wkc}{u32 nkc}{u32 char}.
        if (!slot) break;
        if (plen < 20) break;
        int type = p[0];
        uint32_t mods = ReadU32BE(p + 4);
        int32_t wkc = static_cast<int32_t>(ReadU32BE(p + 8));
        int32_t nkc = static_cast<int32_t>(ReadU32BE(p + 12));
        uint32_t ch = ReadU32BE(p + 16);
        PostBrowserOp(slot, [=](Slot& s) { DoKey(s, type, mods, wkc, nkc, ch); });
        break;
      }
      case kOpEvalReturning: {
        // {u32 id}{utf8 code}; DoEvalReturning posts the value back via the
        // message router as kOpEvalResult "id:json", correlated to the Dart
        // Future (or, for the liveness ping id, consumed by the plugin).
        if (!slot) break;
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string code(reinterpret_cast<const char*>(p + 4), plen - 4);
        PostBrowserOp(slot,
                      [id, code](Slot& s) { DoEvalReturning(s, id, code); });
        break;
      }
      case kOpAddChannel: {
        if (!slot) break;
        std::string name(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoAddChannel, slot, name));
        break;
      }
      case kOpResolveTargetId: {
        // Needs the DevTools observer (the macOS per-tile CDP path), which
        // Windows doesn't have. Fire-and-forget, so dropping it can't hang a
        // Dart Future. Log ONCE per opcode; never kill the stream.
        static bool logged_stub[256] = {false};
        if (!logged_stub[opcode]) {
          logged_stub[opcode] = true;
          SendLog(0, "cef_host: opcode " + std::to_string(opcode) +
                         " is not implemented on Windows — dropping");
        }
        break;
      }
      default: {
        // Unknown opcode = protocol skew. Log ONCE per opcode; never kill the
        // stream.
        static bool logged_unknown[256] = {false};
        if (!logged_unknown[opcode]) {
          logged_unknown[opcode] = true;
          SendLog(0, "unknown opcode " + std::to_string(opcode) +
                         " (protocol skew? plugin newer than host) — dropping");
        }
        break;
      }
    }
  }
  // Plugin died / pipe closed: quit. (Orphan-kill backstop is the plugin's
  // Job Object — JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE — not a parent watch.)
  ArmHardExit("IPC closed");
  CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
}

// Create the ONE hidden window this host passes to SetAsWindowless(parent).
// WS_POPUP, never shown. (A null parent degrades dialogs/menus/IMM;
// browser_platform_delegate_native_win.cc bails on !msg.hwnd.)
HWND CreateHiddenHostWindow() {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"flutter_cef_host_hidden";
  RegisterClassW(&wc);
  return CreateWindowExW(0, wc.lpszClassName, L"flutter_cef_host", WS_POPUP, 0,
                         0, 1, 1, nullptr, nullptr, wc.hInstance, nullptr);
}

}  // namespace

// Entry point, invoked by CEF's bootstrap (bootstrapc.exe renamed to
// cef_host.exe). sandbox_info is forwarded to both CefExecuteProcess and
// CefInitialize, so the child processes run sandboxed.
extern "C" CEF_BOOTSTRAP_EXPORT int RunConsoleMain(
    int argc,
    char* argv[],
    void* sandbox_info,
    cef_version_info_t* version_info) {
  (void)argc;
  (void)argv;  // ANSI-codepage argv; Utf8Args re-reads the real command line
  (void)version_info;
  CefMainArgs main_args(GetModuleHandle(nullptr));

  // Sub-process (--type=renderer/gpu/...)? Let CEF take over. Windows
  // relaunches this same exe, so no helper-app fan-out (process_helper.mm's
  // 5-helper model collapses to this early return).
  CefRefPtr<HostApp> app(new HostApp);
  int code = CefExecuteProcess(main_args, app, sandbox_info);
  if (code >= 0) return code;

  // ---- Browser process from here on. ----
  StartHardExitWatchdog();
  const std::vector<std::string> args = Utf8Args();
  std::string ipc_name = GetSwitch(args, "--ipc=");
  std::string profile_dir = GetSwitch(args, "--profile-dir=");
  std::string allowed = GetSwitch(args, "--allowed-schemes=");
  bool ephemeral = HasFlag(args, "--ephemeral");
  // Agent control: "<read>,<write>" inherited-HANDLE values. Stored in the
  // file-global so OnBeforeCommandLineProcessing (called from CefInitialize
  // below) can inject the Chromium CDP-pipe switches. Empty when off.
  g_cdp_io_pipes = GetSwitch(args, "--cdp-io-pipes=");
  // NB: the PLUGIN owns ephemeral profile-dir deletion — its reaper deletes the
  // dir once this host is confirmed dead, and a startup sweep reclaims dirs
  // orphaned by a crash (the plugin's reaper thread and
  // SweepStaleEphemeralProfiles). The host need not delete its own dir (it
  // can't reliably, holding it open).

  // Navigation scheme allowlist (lowercased csv). Empty = allow all. The
  // plugin rejects a malformed list before spawning; entries that still aren't
  // schemes are skipped here rather than trusted.
  g_allowed_schemes = policy::ParseSchemeList(allowed);

  if (ipc_name.empty() && !std::getenv("FLUTTER_CEF_TEST_NOPIPE")) {
    LogErr("[cef_host] missing --ipc=<pipe name>");
    return 3;
  }

  if (!ipc_name.empty()) {
    // Connect the plugin's named pipe (the plugin created it BEFORE spawning
    // us, so a plain CreateFileW connects immediately). SECURITY_SQOS_PRESENT
    // | SECURITY_ANONYMOUS: never let a squatted pipe impersonate us.
    // FILE_FLAG_OVERLAPPED: full-duplex — see the OverlappedIo note above.
    HANDLE pipe = CreateFileW(Widen(ipc_name).c_str(),
                              GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING,
                              FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                                  SECURITY_ANONYMOUS,
                              nullptr);
    if (pipe == INVALID_HANDLE_VALUE) {
      LogErr("[cef_host] cannot open IPC pipe '%s' (gle=%lu)",
             ipc_name.c_str(), GetLastError());
      return 4;
    }
    g_ipc_pipe.store(pipe);
  }

  // Profile dir fallback: a per-pid ephemeral temp dir (defensive — the
  // plugin always supplies --profile-dir, mirroring the macOS main()).
  if (profile_dir.empty()) {
    profile_dir = TempDirUtf8() + "flutter_cef_ephem_" +
                  std::to_string(GetCurrentProcessId());
    ephemeral = true;
  }
  CreateDirectoryW(Widen(profile_dir).c_str(), nullptr);  // ok if it exists

  // Cross-process single-writer lock on a PERSISTENT profile dir (as the
  // macOS main()): exclusive-open <profile>/.flutter_cef.lock; on
  // contention emit the machine-parseable kOpLog "profile-locked" and exit 2
  // (the plugin keys processGone("locked") on that pair). The handle is held
  // for the process lifetime — the OS drops it on exit. Ephemeral dirs are
  // per-spawn and can never contend.
  if (!ephemeral) {
    const std::wstring lock_path = Widen(profile_dir + "\\.flutter_cef.lock");
    // Retry with bounded backoff before declaring the profile locked. A rapid
    // dispose+recreate of the SAME profile (route change / hot reload) races
    // the OUTGOING host, which still holds this exclusive handle until it exits
    // — it defers its quit up to ~2s to flush cookies, and the plugin's reaper
    // waits up to 3s before Terminate. Without the retry the fresh host loses
    // the lock instantly and surfaces a spurious processGone("locked") with no
    // other app open. ~5s of 50ms tries covers the outgoing host's release;
    // a GENUINE cross-app conflict still reports "locked" after the window.
    HANDLE lock = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 100; ++attempt) {
      lock = CreateFileW(lock_path.c_str(), GENERIC_READ | GENERIC_WRITE,
                         /*dwShareMode=*/0, nullptr, OPEN_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
      if (lock != INVALID_HANDLE_VALUE) break;
      const DWORD gle = GetLastError();
      if (gle != ERROR_SHARING_VIOLATION && gle != ERROR_ACCESS_DENIED) break;
      Sleep(50);
    }
    if (lock == INVALID_HANDLE_VALUE) {
      SendLog(0, "profile-locked");
      LogErr("[cef_host] profile already in use (%s, gle=%lu)",
             profile_dir.c_str(), GetLastError());
      return 2;
    }
    // Intentionally leaked: the lock must live as long as the profile does.
  }

  g_hidden_hwnd = CreateHiddenHostWindow();

  CefSettings settings;
  settings.windowless_rendering_enabled = 1;
  // The Chromium sandbox is on whenever bootstrapc hands us sandbox_info.
  // FLUTTER_CEF_NO_SANDBOX=1 is the escape hatch for diagnosing a child that
  // won't start under it (README "Sandbox").
  const bool sandboxed =
      sandbox_info != nullptr && !EnvFlag("FLUTTER_CEF_NO_SANDBOX");
  settings.no_sandbox = sandboxed ? 0 : 1;
  settings.multi_threaded_message_loop = 0;
  // Per-profile cache: one root_cache_path shared by every browser in this
  // process is what makes login shared across the tiles on a profile
  // (CefCookieManager::GetGlobalManager -> this jar). persist_session_cookies
  // keeps session cookies across relaunch — set UNCONDITIONALLY, mirroring
  // the macOS main() (harmless for an ephemeral host, whose dir the plugin's
  // reaper deletes on teardown; required for a named profile's "stay signed
  // in").
  //
  // AT-REST: Windows OSCrypt encrypts the cookie/login stores with DPAPI,
  // which is ALWAYS available and signing-INDEPENDENT — so a
  // named profile persists directly here, with NO analogue of the macOS ad-hoc
  // "mock-keychain -> downgrade named profile to ephemeral" rule (there is no
  // readyFlags bit0 gate on Windows; OnContextInitialized sends 0). DPAPI is
  // same-user-readable (weaker than the macOS Keychain), so the plugin's
  // current-user protected DACL on the profile dir is defense-in-depth.
  CefString(&settings.root_cache_path) = profile_dir;
  CefString(&settings.cache_path) = profile_dir;
  settings.persist_session_cookies = 1;
  if (std::getenv("FLUTTER_CEF_DEBUG"))
    settings.log_severity = LOGSEVERITY_INFO;
  else
    settings.log_severity = LOGSEVERITY_ERROR;

  // no_sandbox and the sandbox_info passed here must agree. Passing the real
  // sandbox_info while no_sandbox=1 makes every child fail its mojo handshake
  // ("Terminating current process after 15 seconds with no connection"), so
  // the escape hatch passes nullptr. sandbox_info is always forwarded to
  // CefExecuteProcess above: children must see it.
  if (sandbox_info != nullptr && !sandboxed)
    LogErr("[cef_host] FLUTTER_CEF_NO_SANDBOX=1: running without the sandbox");
  if (!CefInitialize(main_args, settings, app,
                     /*windows_sandbox_info=*/sandboxed ? sandbox_info
                                                        : nullptr)) {
    LogErr("[cef_host] CefInitialize failed, exit_code=%d", CefGetExitCode());
    return 10;
  }

  // Reader thread (same model as the macOS host: reader posts to TID_UI via
  // CefPostTask; CefRunMessageLoop owns the main thread).
  std::thread reader;
  if (g_ipc_pipe.load() != INVALID_HANDLE_VALUE) reader = std::thread(IpcReadLoop);
  // Standalone diagnostic mode (FLUTTER_CEF_TEST_NOPIPE): create one browser
  // directly so the process can be exercised without a plugin/pipe peer.
  if (std::getenv("FLUTTER_CEF_TEST_NOPIPE")) {
    std::shared_ptr<Slot> probe = RegisterSlot(1, 800, 600, 1.0);
    if (probe)
      CefPostTask(TID_UI, base::BindOnce(&DoCreateBrowser, probe,
                                         std::string("about:blank")));
    CefPostDelayedTask(TID_UI, base::BindOnce([]() {
      LogErr("[cef_host] NOPIPE probe: slots=%zu", g_slots_by_wire_id.size());
      auto slot = LookupWireId(1);
      LogErr("[cef_host] NOPIPE probe: browser bound=%d",
             slot && slot->browser ? 1 : 0);
      CefQuitMessageLoop();
    }), 25000);
  }

  CefRunMessageLoop();
  ExtendHardExitForTeardown();

  // Teardown: invalidate the pipe FIRST (atomic exchange), THEN close — so a
  // late SendFrame from a CEF thread can't write into a recycled handle
  // (mirrors the macOS host's teardown ordering). Closing the pipe also
  // unblocks the reader's ReadFile, bounding the join... except a reader
  // blocked in ReadFile on a still-open pipe: cancel it explicitly first.
  {
    std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
    HANDLE old = g_ipc_pipe.exchange(INVALID_HANDLE_VALUE);
    if (old != INVALID_HANDLE_VALUE) {
      CancelIoEx(old, nullptr);  // unblock a reader parked in ReadFile
      CloseHandle(old);
    }
  }
  if (reader.joinable()) reader.join();

  CefShutdown();
  return 0;
}
