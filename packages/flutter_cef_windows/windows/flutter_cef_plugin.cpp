#include "flutter_cef_plugin.h"

#include <windows.h>

#include <flutter/encodable_value.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <string>

#include "cef_host_protocol.h"
#include "include/flutter_cef_windows/flutter_cef_plugin.h"

namespace flutter_cef {
namespace {

constexpr wchar_t kMessageWindowClass[] = L"FlutterCefPluginMessageWindow";
constexpr UINT kDrainMessage = WM_APP + 1;

// C1 first-present watchdog grace (macOS firstPaintGrace = 10s, env
// FLUTTER_CEF_FIRSTPAINT_MS; CefProfileHost.swift:649-653). Generous so a heavy
// real site slow to composite isn't churned.
UINT WatchdogGraceMs() {
  wchar_t buf[32] = {};
  const DWORD n =
      GetEnvironmentVariableW(L"FLUTTER_CEF_FIRSTPAINT_MS", buf, 32);
  if (n > 0 && n < 32) {
    const long ms = wcstol(buf, nullptr, 10);
    if (ms > 0) return static_cast<UINT>(ms);
  }
  return 10000;
}

void Log(const std::string& msg) {
  OutputDebugStringA(("[flutter_cef_windows] " + msg + "\n").c_str());
}

void WarnStub(const std::string& verb) {
  Log("verb '" + verb + "' not implemented (slice stub) — replying success");
}

// ---- EncodableMap arg helpers (mirror the tolerant Swift `as?` reads) ----

std::string GetString(const flutter::EncodableMap& m, const char* key,
                      const std::string& fallback = std::string()) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : fallback;
}

int64_t GetInt(const flutter::EncodableMap& m, const char* key,
               int64_t fallback = 0) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  if (const auto* i32 = std::get_if<int32_t>(&it->second)) return *i32;
  if (const auto* i64 = std::get_if<int64_t>(&it->second)) return *i64;
  return fallback;
}

double GetDouble(const flutter::EncodableMap& m, const char* key,
                 double fallback = 0.0) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i32 = std::get_if<int32_t>(&it->second))
    return static_cast<double>(*i32);
  if (const auto* i64 = std::get_if<int64_t>(&it->second))
    return static_cast<double>(*i64);
  return fallback;
}

bool GetBool(const flutter::EncodableMap& m, const char* key, bool fallback) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  const auto* b = std::get_if<bool>(&it->second);
  return b ? *b : fallback;
}

// ---- wire payload builders (BE, per cef_host_protocol.h codecs) ----

void AppendU32(std::vector<uint8_t>& out, uint32_t v) {
  uint8_t b[4];
  WriteU32BE(b, v);
  out.insert(out.end(), b, b + 4);
}

void AppendF64(std::vector<uint8_t>& out, double v) {
  uint8_t b[8];
  WriteF64BE(b, v);
  out.insert(out.end(), b, b + 8);
}

void AppendUtf8(std::vector<uint8_t>& out, const std::string& s) {
  out.insert(out.end(), s.begin(), s.end());
}

// ---- inbound payload decoding ----

std::string PayloadString(const std::vector<uint8_t>& payload,
                          size_t offset = 0) {
  if (payload.size() <= offset) return std::string();
  return std::string(reinterpret_cast<const char*>(payload.data()) + offset,
                     payload.size() - offset);
}

uint32_t PayloadU32(const std::vector<uint8_t>& payload, size_t offset) {
  return ReadU32BE(payload.data() + offset);
}

flutter::EncodableValue Ev(const char* s) {
  return flutter::EncodableValue(std::string(s));
}

}  // namespace

// ---- registration / lifecycle ----

// static
void FlutterCefPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<FlutterCefPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

FlutterCefPlugin::FlutterCefPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  // Reclaim ephemeral profile dirs orphaned by a previous crash/kill before we
  // start minting new ones (macOS: sweepStaleEphemeralProfiles at plugin init,
  // FlutterCefPlugin.swift:97-109). No host is live yet.
  SweepStaleEphemeralProfiles();
  // Channel name is the cross-platform contract
  // (FlutterCefPlatform.channelName == "flutter_cef"; see
  // FlutterCefPlugin.swift:48-49 and PROTOCOL.md §3).
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "flutter_cef",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  texture_bridge_ =
      std::make_unique<TextureBridge>(registrar->texture_registrar());

  // Message-only window: the platform-thread drain target for reader/watcher
  // events (flutter::MethodChannel is not thread-safe).
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &FlutterCefPlugin::MsgWndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kMessageWindowClass;
  // Idempotent: RegisterClassExW fails with ERROR_CLASS_ALREADY_EXISTS on a
  // second plugin instance (multi-engine) — that is fine.
  RegisterClassExW(&wc);
  message_window_ =
      CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                      nullptr, wc.hInstance, nullptr);
  if (message_window_) {
    SetWindowLongPtrW(message_window_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));
  } else {
    Log("FATAL: message window creation failed — host events cannot be "
        "delivered");
  }
}

FlutterCefPlugin::~FlutterCefPlugin() {
  channel_->SetMethodCallHandler(nullptr);
  // Graceful path for every live host (the Job Object guarantees no orphan
  // even on a hard kill). Snapshot ids — TeardownSession mutates the map.
  std::vector<std::string> ids;
  for (const auto& kv : sessions_) ids.push_back(kv.first);
  for (const auto& id : ids) TeardownSession(id, /*send_shutdown=*/true);
  // Reapers are bounded (<=3s wait, then kill); they own the pipes/watchers,
  // and joining them here guarantees no thread outlives `this`.
  for (auto& r : reapers_) {
    if (r.thread.joinable()) r.thread.join();
  }
  if (message_window_) {
    SetWindowLongPtrW(message_window_, GWLP_USERDATA, 0);
    DestroyWindow(message_window_);
    message_window_ = nullptr;
  }
}

// static
LRESULT CALLBACK FlutterCefPlugin::MsgWndProc(HWND hwnd, UINT msg,
                                              WPARAM wparam, LPARAM lparam) {
  if (msg == kDrainMessage) {
    auto* self = reinterpret_cast<FlutterCefPlugin*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) self->DrainEvents();
    return 0;
  }
  if (msg == WM_TIMER) {
    auto* self = reinterpret_cast<FlutterCefPlugin*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) self->OnWatchdogTimer(static_cast<UINT_PTR>(wparam));
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

void FlutterCefPlugin::PostEvent(HostEvent event) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.push_back(std::move(event));
  }
  // Wakeup only; the queue is the payload channel. Failure (window gone
  // during teardown) is harmless — the destructor stops all posters first.
  if (message_window_) PostMessageW(message_window_, kDrainMessage, 0, 0);
}

void FlutterCefPlugin::DrainEvents() {
  std::deque<HostEvent> events;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    events.swap(queue_);
  }
  for (auto& e : events) {
    switch (e.kind) {
      case HostEvent::Kind::kFrame:
        HandleHostFrame(e.session_id, e.generation, e.browser_id, e.opcode,
                        e.payload);
        break;
      case HostEvent::Kind::kDisconnect:
        HandleHostGone(e.session_id, e.generation, /*exit_code_known=*/false, 0);
        break;
      case HostEvent::Kind::kExited:
        HandleHostGone(e.session_id, e.generation, /*exit_code_known=*/true,
                       e.exit_code);
        break;
    }
  }
}

void FlutterCefPlugin::EmitEvent(const std::string& method,
                                 const std::string& session_id,
                                 flutter::EncodableMap args) {
  args[Ev("sessionId")] = flutter::EncodableValue(session_id);
  channel_->InvokeMethod(
      method, std::make_unique<flutter::EncodableValue>(std::move(args)));
}

// ---- channel dispatch ----

void FlutterCefPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args_ptr = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap args =
      args_ptr ? *args_ptr : flutter::EncodableMap();
  const std::string& method = call.method_name();

  // Verb table: PROTOCOL.md §3 (names/args verbatim from
  // FlutterCefPlugin.swift:113-241 / cef_web_controller.dart).
  if (method == "create") {
    HandleCreate(args, result);
    return;
  }
  if (method == "resize") {
    HandleResize(args, result);
    return;
  }
  if (method == "dispose") {
    DisposeSession(GetString(args, "sessionId"));
    result->Success();
    return;
  }

  Session* s = FindSession(args);

  if (method == "navigate" || method == "loadTrusted") {
    const std::string url = GetString(args, "url");
    if (s && !url.empty()) {
      std::vector<uint8_t> p;
      AppendUtf8(p, url);
      SendOrQueue(s, method == "navigate" ? kOpNavigate : kOpLoadTrusted,
                  std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "reload" || method == "stop" || method == "goBack" ||
      method == "goForward") {
    if (s) {
      uint8_t op = kOpReload;
      if (method == "stop") op = kOpStop;
      if (method == "goBack") op = kOpBack;
      if (method == "goForward") op = kOpForward;
      SendOrQueue(s, op, {});
    }
    result->Success();
    return;
  }
  if (method == "executeJavaScript") {
    const std::string code = GetString(args, "code");
    if (s && !code.empty()) {
      std::vector<uint8_t> p;
      AppendUtf8(p, code);
      SendOrQueue(s, kOpExecuteJs, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "pointer") {
    // {u8 type}{u8 button}{u8 clickCount}{u8 pad}{u32 modifiers}
    // {f64 x}{f64 y}{f64 dx}{f64 dy} = 40 bytes (main.mm:2560-2570).
    if (s) {
      std::vector<uint8_t> p;
      p.reserve(40);
      p.push_back(static_cast<uint8_t>(GetInt(args, "type", 0)));
      p.push_back(static_cast<uint8_t>(GetInt(args, "button", 0)));
      p.push_back(static_cast<uint8_t>(GetInt(args, "clickCount", 1)));
      p.push_back(0);
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "modifiers", 0)));
      AppendF64(p, GetDouble(args, "x"));
      AppendF64(p, GetDouble(args, "y"));
      AppendF64(p, GetDouble(args, "dx"));
      AppendF64(p, GetDouble(args, "dy"));
      SendOrQueue(s, kOpPointer, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "key") {
    // {u8 type}{u8 pad×3}{u32 modifiers}{u32 wkc}{u32 nkc}{u32 char} = 20
    // bytes (main.mm:2571-2582).
    if (s) {
      std::vector<uint8_t> p;
      p.reserve(20);
      p.push_back(static_cast<uint8_t>(GetInt(args, "type", 0)));
      p.push_back(0);
      p.push_back(0);
      p.push_back(0);
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "modifiers", 0)));
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "windowsKeyCode", 0)));
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "nativeKeyCode", 0)));
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "character", 0)));
      SendOrQueue(s, kOpKey, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "setVisible") {
    if (s) {
      const bool visible = GetBool(args, "visible", true);
      SendOrQueue(s, kOpSetVisible, {visible ? uint8_t{1} : uint8_t{0}});
      // C1 watchdog: a hidden CEF browser produces no frames by design, so
      // suspend the first-present watchdog while hidden and re-arm it on show
      // if still blank (macOS noteVisibility, CefProfileHost.swift:706-729).
      s->visible = visible;
      if (!visible) {
        CancelWatchdog(s);
      } else if (!s->painted && s->watchdog_timer == 0) {
        ArmWatchdog(s);
      }
    }
    result->Success();
    return;
  }
  if (method == "setZoomLevel") {
    if (s) {
      std::vector<uint8_t> p;
      AppendF64(p, GetDouble(args, "level", 0.0));
      SendOrQueue(s, kOpSetZoom, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "editCommand") {
    if (s) {
      SendOrQueue(s, kOpEditCommand,
                  {static_cast<uint8_t>(GetInt(args, "command", 0))});
    }
    result->Success();
    return;
  }
  if (method == "find") {
    const std::string text = GetString(args, "text");
    if (s && !text.empty()) {
      std::vector<uint8_t> p;
      p.push_back(GetBool(args, "forward", true) ? 1 : 0);
      p.push_back(GetBool(args, "matchCase", false) ? 1 : 0);
      p.push_back(GetBool(args, "findNext", false) ? 1 : 0);
      AppendUtf8(p, text);
      SendOrQueue(s, kOpFind, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "stopFind") {
    if (s) {
      SendOrQueue(
          s, kOpStopFind,
          {GetBool(args, "clearSelection", true) ? uint8_t{1} : uint8_t{0}});
    }
    result->Success();
    return;
  }
  if (method == "respondJsDialog") {
    if (s) {
      std::vector<uint8_t> p;
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "id", 0)));
      p.push_back(GetBool(args, "ok", true) ? 1 : 0);
      AppendUtf8(p, GetString(args, "text"));
      SendOrQueue(s, kOpJsDialogResp, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "evalReturning") {
    const std::string code = GetString(args, "code");
    if (s && !code.empty()) {
      std::vector<uint8_t> p;
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "id", 0)));
      AppendUtf8(p, code);
      SendOrQueue(s, kOpEvalReturning, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "addJavaScriptChannel") {
    const std::string name = GetString(args, "name");
    if (s && !name.empty()) {
      std::vector<uint8_t> p;
      AppendUtf8(p, name);
      SendOrQueue(s, kOpAddChannel, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "setCookie") {
    if (s) {
      const std::string payload = GetString(args, "url") + '\0' +
                                  GetString(args, "name") + '\0' +
                                  GetString(args, "value") + '\0' +
                                  GetString(args, "domain") + '\0' +
                                  GetString(args, "path", "/");
      std::vector<uint8_t> p(payload.begin(), payload.end());
      SendOrQueue(s, kOpSetCookie, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "clearCookies") {
    if (s) SendOrQueue(s, kOpClearCookies, {});
    result->Success();
    return;
  }
  if (method == "visitCookies") {
    if (s) {
      std::vector<uint8_t> p;
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "id", 0)));
      AppendUtf8(p, GetString(args, "url"));
      SendOrQueue(s, kOpVisitCookies, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "deleteCookie") {
    if (s) {
      const std::string payload =
          GetString(args, "url") + '\0' + GetString(args, "name");
      std::vector<uint8_t> p(payload.begin(), payload.end());
      SendOrQueue(s, kOpDeleteCookie, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "showDevTools") {
    if (s) SendOrQueue(s, kOpShowDevTools, {});
    result->Success();
    return;
  }
  if (method == "imeSetComposition" || method == "imeCommitText") {
    if (s) {
      std::vector<uint8_t> p;
      AppendUtf8(p, GetString(args, "text"));
      SendOrQueue(s,
                  method == "imeSetComposition" ? kOpImeSetComp : kOpImeCommit,
                  std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "imeCancelComposition") {
    if (s) SendOrQueue(s, kOpImeCancel, {});
    result->Success();
    return;
  }
  if (method == "getFrameSurface") {
    // Windows: surfaceId = the bridge-handle token (PROTOCOL.md §4 onSurface
    // note); width/height = current expected physical px. Null for an
    // unknown session; surfaceId 0 before the first present (Swift:649-658).
    if (s) {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {Ev("surfaceId"),
           flutter::EncodableValue(static_cast<int64_t>(s->current_handle))},
          {Ev("width"),
           flutter::EncodableValue(static_cast<int64_t>(s->expected_pw))},
          {Ev("height"),
           flutter::EncodableValue(static_cast<int64_t>(s->expected_ph))},
      }));
    } else {
      result->Success();
    }
    return;
  }

  // SLICE RULE: every not-yet-implemented verb — macOS-only ones
  // (showEmojiPicker) and post-slice ones (enableAgentControl /
  // disableAgentControl / future additions) — replies success/null with an
  // OutputDebugString warning. NEVER an error, NEVER NotImplemented: the
  // example app must run against this plugin unmodified.
  WarnStub(method);
  result->Success();
}

// ---- create / resize / dispose ----

void FlutterCefPlugin::HandleCreate(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  const std::string session_id = GetString(args, "sessionId");
  if (session_id.empty()) {
    // Mirror Swift:261-265 (the one create failure mode that IS an error).
    result->Error("bad_args", "missing sessionId");
    return;
  }
  const int64_t width = (std::max)(int64_t{1}, GetInt(args, "width", 800));
  const int64_t height = (std::max)(int64_t{1}, GetInt(args, "height", 600));
  double dpr = GetDouble(args, "dpr", 1.0);
  if (!(dpr > 0.0) || dpr > 8.0) dpr = 1.0;  // main.mm:2364-2376 guard
  const std::string url = GetString(args, "url", "about:blank");
  // Navigation scheme allowlist (csv, PROTOCOL.md §3). Threaded to the host as
  // --allowed-schemes; the host enforces it in OnBeforeBrowse (Swift:277,437 /
  // CefProfileHost.spawn appends --allowed-schemes=<csv>).
  const std::string allowed_schemes = GetString(args, "allowedSchemes");

  // Re-creating the same id is idempotent (Swift:293-295).
  DisposeSession(session_id);

  const std::wstring host_exe = ResolveCefHostPath();
  if (host_exe.empty()) {
    // Mirror Swift:267-271.
    result->Error("no_cef_host",
                  "cef_host.exe not found (set FLUTTER_CEF_HOST)");
    return;
  }

  auto session = std::make_unique<Session>();
  session->id = session_id;
  session->generation = next_generation_++;
  session->width = static_cast<int>(width);
  session->height = static_cast<int>(height);
  session->dpr = dpr;
  session->expected_pw = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(width) * dpr)));
  session->expected_ph = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(height) * dpr)));

  // Pipe FIRST (so the child's CreateFileW connects first try), then spawn.
  auto pipe = std::make_unique<IpcPipe>();
  if (!pipe->Create(IpcPipe::NextPipeName())) {
    result->Error("spawn_failed", "failed to create IPC pipe");
    return;
  }
  auto host = std::make_unique<HostProcess>();
  const std::wstring profile_dir = MakeEphemeralProfileDir();
  session->profile_dir = profile_dir;
  // Slice: ONE host per create, always ephemeral (`profile` arg accepted but
  // profile-sharing host reuse is P6).
  if (!host->Spawn(host_exe, pipe->pipe_name(), profile_dir,
                   /*ephemeral=*/true, allowed_schemes)) {
    DeleteDirRecursive(profile_dir);  // no host will ever own it
    result->Error("spawn_failed", "failed to spawn cef_host");
    return;
  }

  session->texture_id = texture_bridge_->RegisterSessionTexture();
  if (session->texture_id < 0) {
    host->Terminate();  // Job close in ~HostProcess is the backstop.
    DeleteDirRecursive(profile_dir);
    result->Error("texture", "texture registration failed");
    return;
  }

  // Queue the browser create — flushed when kOpReady (protocol v3) arrives.
  // Payload: {u32 w}{u32 h}{f64 dpr}{utf8 url} (main.mm:2364-2376); frame
  // browserId = the NEW wire id.
  {
    std::vector<uint8_t> p;
    AppendU32(p, static_cast<uint32_t>(width));
    AppendU32(p, static_cast<uint32_t>(height));
    AppendF64(p, dpr);
    AppendUtf8(p, url);
    session->pending_frames.emplace_back(kOpCreateBrowser, std::move(p));
  }

  session->pipe = std::move(pipe);
  session->host = std::move(host);

  // Reader thread: frames + EOF, posted to the platform thread. The generation
  // is captured by value so a stale OLD-host event posted during the reaper
  // grace of a dispose+recreate carries the OLD id and is dropped on drain (C1).
  const std::string sid = session_id;
  const uint64_t gen = session->generation;
  session->pipe->StartReader(
      [this, sid, gen](uint32_t browser_id, uint8_t opcode,
                       std::vector<uint8_t> payload) {
        HostEvent e;
        e.kind = HostEvent::Kind::kFrame;
        e.session_id = sid;
        e.generation = gen;
        e.browser_id = browser_id;
        e.opcode = opcode;
        e.payload = std::move(payload);
        PostEvent(std::move(e));
      },
      [this, sid, gen]() {
        HostEvent e;
        e.kind = HostEvent::Kind::kDisconnect;
        e.session_id = sid;
        e.generation = gen;
        PostEvent(std::move(e));
      });

  // Process-exit watcher: catches a host that dies BEFORE ever connecting
  // the pipe (bad exe, startup crash) — the fake-host smoke path. Waits on
  // its own dup'd handle so reaper handle-closes can't race it.
  HANDLE process_dup = session->host->DuplicateProcessHandle();
  if (process_dup) {
    session->exit_watcher = std::thread([this, sid, gen, process_dup]() {
      WaitForSingleObject(process_dup, INFINITE);
      DWORD code = 0;
      GetExitCodeProcess(process_dup, &code);
      CloseHandle(process_dup);
      HostEvent e;
      e.kind = HostEvent::Kind::kExited;
      e.session_id = sid;
      e.generation = gen;
      e.exit_code = code;
      PostEvent(std::move(e));
    });
  }

  const int64_t texture_id = session->texture_id;
  sessions_[session_id] = std::move(session);
  // C1 first-present watchdog: start the first-paint clock now (armed at
  // create, like macOS armFirstPresentWatchdog).
  ArmWatchdog(sessions_[session_id].get());
  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {Ev("textureId"), flutter::EncodableValue(texture_id)},
      {Ev("width"), flutter::EncodableValue(width)},
      {Ev("height"), flutter::EncodableValue(height)},
      {Ev("cdpPort"), flutter::EncodableValue(0)},
  }));
}

void FlutterCefPlugin::HandleResize(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  Session* s = FindSession(args);
  if (!s) {
    // Contract (Swift:633-641): unknown session -> null.
    result->Success();
    return;
  }
  const int64_t width = GetInt(args, "width", 800);
  const int64_t height = GetInt(args, "height", 600);
  // Mirror the host's DoResize 1..16384 clamp/skip (cef_host_win.cc:992): an
  // out-of-range dim is dropped host-side, so if the plugin moved its size-gate
  // expectation to that dim they'd diverge and every real frame would be gated
  // out (frozen tile). Skip in lockstep — leave geometry + expectation as-is.
  if (width < 1 || width > 16384 || height < 1 || height > 16384) {
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {Ev("textureId"), flutter::EncodableValue(s->texture_id)},
    }));
    return;
  }
  double dpr = GetDouble(args, "dpr", 0.0);
  if (!(dpr > 0.0) || dpr > 8.0) dpr = s->dpr;  // 0/invalid keeps density

  s->width = static_cast<int>(width);
  s->height = static_cast<int>(height);
  s->dpr = dpr;
  // The size-gate expectation moves NOW: every WasResized discards CEF's
  // pool, and late frames at the OLD size must not promote (LAW 4).
  s->expected_pw = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(width) * dpr)));
  s->expected_ph = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(height) * dpr)));

  std::vector<uint8_t> p;
  AppendU32(p, static_cast<uint32_t>(width));
  AppendU32(p, static_cast<uint32_t>(height));
  AppendF64(p, dpr);
  SendOrQueue(s, kOpResize, std::move(p));

  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {Ev("textureId"), flutter::EncodableValue(s->texture_id)},
  }));
}

FlutterCefPlugin::Session* FlutterCefPlugin::FindSession(
    const flutter::EncodableMap& args) {
  auto it = sessions_.find(GetString(args, "sessionId"));
  return it == sessions_.end() ? nullptr : it->second.get();
}

void FlutterCefPlugin::DisposeSession(const std::string& session_id) {
  if (sessions_.find(session_id) == sessions_.end()) return;
  TeardownSession(session_id, /*send_shutdown=*/true);
}

void FlutterCefPlugin::TeardownSession(const std::string& session_id,
                                       bool send_shutdown) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) return;
  Session* s = it->second.get();
  s->closing = true;
  CancelWatchdog(s);  // C1: no timer must fire against a torn-down session
  if (send_shutdown && s->pipe && s->pipe->connected()) {
    // Single browser per host: close it, then the whole process
    // (disposeSession ordering, Swift:671-695 / PROTOCOL.md §3 dispose row).
    s->pipe->SendFrame(s->browser_id, kOpDisposeBrowser, nullptr, 0);
    s->pipe->SendFrame(0, kOpShutdown, nullptr, 0);
  }
  if (s->texture_id >= 0) {
    texture_bridge_->Unregister(s->texture_id);
    s->texture_id = -1;
  }
  // H17: prune reapers that already finished so the vector can't grow unbounded
  // across a long-lived engine (join is immediate — `done` is already set).
  for (auto rit = reapers_.begin(); rit != reapers_.end();) {
    if (rit->done->load()) {
      if (rit->thread.joinable()) rit->thread.join();
      rit = reapers_.erase(rit);
    } else {
      ++rit;
    }
  }
  // Bounded reaper: give the host time to exit cleanly, then kill. Owns the
  // pipe (reader join / deliberate leak), the process handles (job close =
  // kernel-guaranteed kill) and the exit watcher (its wait resolves once the
  // process is dead). Once the host is confirmed dead it deletes the ephemeral
  // profile dir (macOS: CefProfileHost.swift:1004-1006).
  auto done = std::make_shared<std::atomic<bool>>(false);
  std::wstring profile_dir = s->profile_dir;
  reapers_.push_back(Reaper{
      std::thread([pipe = std::move(s->pipe), host = std::move(s->host),
                   watcher = std::move(s->exit_watcher),
                   profile_dir = std::move(profile_dir), done]() mutable {
        if (host) {
          if (host->WaitForExit(3000) == HostProcess::kStillRunning) {
            host->Terminate();
            host->WaitForExit(1000);
          }
        }
        if (pipe && !pipe->Close()) {
          // Wedged reader: leak the pipe object by contract (never free state a
          // blocked reader may still touch).
          pipe.release();
        }
        if (watcher.joinable()) watcher.join();
        // ~HostProcess closes the job handle here — kill-on-close backstop.
        // The host is now dead: reclaim its throwaway profile dir.
        if (!profile_dir.empty()) DeleteDirRecursive(profile_dir);
        done->store(true);
      }),
      done});
  sessions_.erase(it);
}

void FlutterCefPlugin::SendOrQueue(Session* session, uint8_t opcode,
                                   std::vector<uint8_t> payload) {
  if (!session->ready) {
    session->pending_frames.emplace_back(opcode, std::move(payload));
    return;
  }
  session->pipe->SendFrame(session->browser_id, opcode, payload.data(),
                           static_cast<uint32_t>(payload.size()));
}

// ---- inbound host events (platform thread) ----

void FlutterCefPlugin::HandleHostGone(const std::string& session_id,
                                      uint64_t generation, bool exit_code_known,
                                      unsigned long exit_code) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) return;
  Session* s = it->second.get();
  // C1: a death event from a PRIOR host (posted during the reaper grace of a
  // dispose+recreate of this id) must not kill the freshly re-created session.
  if (s->generation != generation) return;
  if (s->closing) return;  // expected death (teardown in flight)

  unsigned long code = exit_code;
  if (!exit_code_known) {
    // Pipe EOF: the process is (about to be) gone. Do NOT block the platform
    // thread waiting for it (H18) — poll non-blocking. If it hasn't exited yet
    // this reports "crashed"; the exit-watcher's kExited carries the real code
    // but by then this session is torn down, so the common locked case (the
    // host writes kOpLog "profile-locked" then exits 2 before closing the pipe)
    // is already exited when EOF is observed and WaitForExit(0) sees code 2.
    code = s->host ? s->host->WaitForExit(0) : HostProcess::kStillRunning;
  }
  // Exit code 2 after kOpLog "profile-locked" = profile already open
  // elsewhere (main.mm:2786-2806, Swift:521).
  const std::string reason = (code == 2) ? "locked" : "crashed";
  Log("host gone for session " + session_id + " (reason=" + reason + ")");
  EmitEvent("processGone", session_id,
            {{Ev("reason"), flutter::EncodableValue(reason)}});
  TeardownSession(session_id, /*send_shutdown=*/false);
}

void FlutterCefPlugin::HandleHostFrame(const std::string& session_id,
                                       uint64_t generation, uint32_t browser_id,
                                       uint8_t opcode,
                                       const std::vector<uint8_t>& payload) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) return;
  Session* s = it->second.get();
  // C1: drop a frame from a PRIOR host of this same id (reaper-grace straggler).
  if (s->generation != generation) return;
  if (s->closing) return;
  (void)browser_id;  // single browser per host; routing is by session

  switch (opcode) {
    case kOpReady: {
      // A legacy 1-byte kOpReady (payload = {readyFlags} only, no version byte)
      // is a v0 host: treat it as host_version 0 and fall into the mismatch
      // path below — otherwise it would hang (create never flushes). PROTOCOL.md
      // §2: v>=3 always carries {readyFlags, protocolVersion}.
      const uint8_t host_version = payload.size() >= 2 ? payload[1] : 0;
      if (host_version != kCefHostProtocolVersion) {
        // Nothing has been flushed to it, so nothing mis-parsed. No
        // auto-respawn (it would re-resolve the same binary and loop) —
        // Swift:528-533.
        std::ostringstream reason;
        reason << "protocolMismatch(host=v" << static_cast<int>(host_version)
               << ")";
        EmitEvent("processGone", session_id,
                  {{Ev("reason"), flutter::EncodableValue(reason.str())}});
        TeardownSession(session_id, /*send_shutdown=*/false);
        return;
      }
      s->ready = true;
      // Flush in order — kOpCreateBrowser was queued first by create().
      auto pending = std::move(s->pending_frames);
      s->pending_frames.clear();
      for (auto& f : pending) {
        s->pipe->SendFrame(s->browser_id, f.first, f.second.data(),
                           static_cast<uint32_t>(f.second.size()));
      }
      break;
    }
    case kOpPresent:
      // C1: any present retires the first-present watchdog (macOS
      // firstPresentArrived), even a size-gated one — the browser is producing
      // frames, which is what the watchdog checks for.
      if (!s->painted) {
        s->painted = true;
        CancelWatchdog(s);
      }
      HandlePresent(s, payload);
      break;
    case kOpCursor:
      if (payload.size() >= 4) {
        EmitEvent("cursor", session_id,
                  {{Ev("cursor"), flutter::EncodableValue(static_cast<int64_t>(
                                      PayloadU32(payload, 0)))}});
      }
      break;
    case kOpLog:
      Log("[cef_host:" + session_id + "] " + PayloadString(payload));
      break;
    case kOpLoadState:
      if (payload.size() >= 3) {
        EmitEvent("loadingState", session_id,
                  {{Ev("isLoading"), flutter::EncodableValue(payload[0] != 0)},
                   {Ev("canGoBack"), flutter::EncodableValue(payload[1] != 0)},
                   {Ev("canGoForward"),
                    flutter::EncodableValue(payload[2] != 0)}});
      }
      break;
    case kOpTitle:
      EmitEvent("title", session_id,
                {{Ev("title"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpUrl:
      EmitEvent("url", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpLoadErr: {
      if (payload.size() < 4) break;
      // {u32 code}{utf8 "url\ntext"} — split at the FIRST '\n' (Swift:374-378).
      const std::string combined = PayloadString(payload, 4);
      const size_t nl = combined.find('\n');
      const std::string err_url =
          nl == std::string::npos ? combined : combined.substr(0, nl);
      const std::string text =
          nl == std::string::npos ? std::string() : combined.substr(nl + 1);
      // Emit the code bit-identically to macOS: readU32 there returns the
      // UNSIGNED 32-bit value widened to Int (CefWebSession.swift:723-726), NOT
      // sign-extended. A CEF ErrorCode (e.g. -105) rides the wire as u32
      // 0xFFFFFF97 and both platforms surface 4294967191 — so drop the
      // int32_t sign-extension the Windows path had.
      EmitEvent("loadError", session_id,
                {{Ev("code"), flutter::EncodableValue(static_cast<int64_t>(
                                  PayloadU32(payload, 0)))},
                 {Ev("url"), flutter::EncodableValue(err_url)},
                 {Ev("text"), flutter::EncodableValue(text)}});
      break;
    }
    case kOpConsole:
      if (payload.size() >= 4) {
        EmitEvent("consoleMessage", session_id,
                  {{Ev("level"), flutter::EncodableValue(static_cast<int64_t>(
                                     PayloadU32(payload, 0)))},
                   {Ev("message"),
                    flutter::EncodableValue(PayloadString(payload, 4))}});
      }
      break;
    case kOpPageStart:
      EmitEvent("pageStarted", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpPageFinish:
      EmitEvent("pageFinished", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpProgress:
      if (payload.size() >= 4) {
        EmitEvent("progress", session_id,
                  {{Ev("progress"), flutter::EncodableValue(static_cast<int64_t>(
                                        PayloadU32(payload, 0)))}});
      }
      break;
    case kOpNewWindow:
      EmitEvent("newWindow", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpFindResult:
      if (payload.size() >= 9) {
        EmitEvent(
            "findResult", session_id,
            {{Ev("count"), flutter::EncodableValue(static_cast<int64_t>(
                               PayloadU32(payload, 0)))},
             {Ev("activeMatchOrdinal"),
              flutter::EncodableValue(static_cast<int64_t>(
                  PayloadU32(payload, 4)))},
             {Ev("isFinal"), flutter::EncodableValue(payload[8] != 0)}});
      }
      break;
    case kOpJsDialog: {
      if (payload.size() < 12) break;
      const uint32_t msg_len = PayloadU32(payload, 8);
      const size_t msg_end =
          (std::min)(static_cast<size_t>(12) + msg_len, payload.size());
      const std::string msg(
          reinterpret_cast<const char*>(payload.data()) + 12, msg_end - 12);
      const std::string def = msg_end < payload.size()
                                  ? PayloadString(payload, msg_end)
                                  : std::string();
      EmitEvent("jsDialog", session_id,
                {{Ev("id"), flutter::EncodableValue(static_cast<int64_t>(
                                PayloadU32(payload, 0)))},
                 {Ev("type"), flutter::EncodableValue(static_cast<int64_t>(
                                  PayloadU32(payload, 4)))},
                 {Ev("message"), flutter::EncodableValue(msg)},
                 {Ev("defaultText"), flutter::EncodableValue(def)}});
      break;
    }
    case kOpEvalResult:
      EmitEvent("evalResult", session_id,
                {{Ev("payload"),
                  flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpChannelMsg:
      EmitEvent("channelMessage", session_id,
                {{Ev("payload"),
                  flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpDownload:
      EmitEvent("download", session_id,
                {{Ev("suggestedName"),
                  flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpImeBounds:
      if (payload.size() >= 16) {
        EmitEvent("imeCompositionBounds", session_id,
                  {{Ev("x"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 0)))},
                   {Ev("y"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 4)))},
                   {Ev("w"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 8)))},
                   {Ev("h"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 12)))}});
      }
      break;
    case kOpCookies:
      if (payload.size() >= 4) {
        EmitEvent("cookies", session_id,
                  {{Ev("id"), flutter::EncodableValue(static_cast<int64_t>(
                                  PayloadU32(payload, 0)))},
                   {Ev("json"),
                    flutter::EncodableValue(PayloadString(payload, 4))}});
      }
      break;
    case kOpCreated:
      // Browser is up (host-side create pacer signal). Nothing to emit —
      // Dart learns liveness from loadingState/present.
      break;
    case kOpCreateFailed:
      // H7: this browser's create failed; host process otherwise healthy —
      // but slice = one browser per host, so drop the whole session
      // (Swift:537-549).
      EmitEvent("processGone", session_id,
                {{Ev("reason"), flutter::EncodableValue("createFailed")}});
      TeardownSession(session_id, /*send_shutdown=*/true);
      break;
    case kOpTargetId:
      Log("kOpTargetId (agent control is post-slice) — dropped");
      break;
    default:
      // Unknown opcode: log ONCE per opcode value and drop the frame —
      // never kill the stream (main.mm:2583-2598).
      if (std::find(warned_opcodes_.begin(), warned_opcodes_.end(), opcode) ==
          warned_opcodes_.end()) {
        warned_opcodes_.push_back(opcode);
        char buf[64];
        _snprintf_s(buf, _TRUNCATE, "unknown inbound opcode 0x%02x — dropped",
                    opcode);
        Log(buf);
      }
      break;
  }
}

void FlutterCefPlugin::HandlePresent(Session* s,
                                     const std::vector<uint8_t>& payload) {
  // WINDOWS kOpPresent: {u64 bridgeHandle BE}{u32 srcW BE}{u32 srcH BE} = 16
  // bytes (PROTOCOL.md §2, LAW 10).
  if (payload.size() < 16) return;
  const uint64_t bridge_handle = ReadU64BE(payload.data());
  const uint32_t src_w = PayloadU32(payload, 8);
  const uint32_t src_h = PayloadU32(payload, 12);

  // Size-gate (LAW 4 / PROTOCOL.md §5): promote only when the frame's
  // physical dims match the CURRENT expectation (±1 px); late frames at a
  // stale size keep the previous texture serving.
  // NB: not named `near` — windef.h #defines that away.
  const auto within_one = [](uint32_t a, uint32_t b) {
    return (a > b ? a - b : b - a) <= 1;
  };
  if (!within_one(src_w, s->expected_pw) ||
      !within_one(src_h, s->expected_ph)) {
    if (++s->gate_misses <= 5 || s->gate_misses % 60 == 0) {
      char buf[128];
      _snprintf_s(buf, _TRUNCATE,
                  "present size-gated: got %ux%u expected %ux%u (miss #%u)",
                  src_w, src_h, s->expected_pw, s->expected_ph,
                  s->gate_misses);
      Log(buf);
    }
    return;
  }

  bool handle_changed = false;
  if (!texture_bridge_->Present(s->texture_id, bridge_handle, src_w, src_h,
                                &handle_changed)) {
    return;  // open failed / unknown — previous frame keeps serving
  }
  if (handle_changed) {
    s->current_handle = bridge_handle;
    // onSurface fires on each backing (re)alloc; Windows surfaceId = the
    // bridge-handle token (PROTOCOL.md §4).
    EmitEvent("onSurface", s->id,
              {{Ev("surfaceId"), flutter::EncodableValue(
                                     static_cast<int64_t>(bridge_handle))},
               {Ev("width"),
                flutter::EncodableValue(static_cast<int64_t>(src_w))},
               {Ev("height"),
                flutter::EncodableValue(static_cast<int64_t>(src_h))}});
  }
}

// ---- host exe / profile dir resolution ----

// static
std::wstring FlutterCefPlugin::ResolveCefHostPath() {
  // 1. FLUTTER_CEF_HOST env override (mirror Swift resolveCefHostPath +
  //    the macOS README contract).
  wchar_t env[MAX_PATH] = {};
  const DWORD n =
      GetEnvironmentVariableW(L"FLUTTER_CEF_HOST", env, MAX_PATH);
  if (n > 0 && n < MAX_PATH) {
    if (GetFileAttributesW(env) != INVALID_FILE_ATTRIBUTES) {
      return std::wstring(env);
    }
  }
  // 2. Bundled: cef_host.exe beside the running app exe
  //    (flutter_cef_windows_bundled_libraries lands it there).
  wchar_t exe[MAX_PATH] = {};
  if (GetModuleFileNameW(nullptr, exe, MAX_PATH) == 0) return std::wstring();
  std::wstring path(exe);
  const size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return std::wstring();
  path = path.substr(0, slash + 1) + L"cef_host.exe";
  if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return path;
  return std::wstring();
}

// static
std::wstring FlutterCefPlugin::MakeEphemeralProfileDir() {
  static std::atomic<uint32_t> counter{0};
  wchar_t tmp[MAX_PATH] = {};
  const DWORD n = GetTempPathW(MAX_PATH, tmp);
  std::wstring base = (n > 0 && n < MAX_PATH) ? std::wstring(tmp) : L".\\";
  std::wostringstream dir;
  dir << base << L"flutter_cef_ephem_" << GetCurrentProcessId() << L"_"
      << GetTickCount64() << L"_" << counter.fetch_add(1);
  CreateDirectoryW(dir.str().c_str(), nullptr);
  return dir.str();
}

// static
void FlutterCefPlugin::DeleteDirRecursive(const std::wstring& dir) {
  if (dir.empty()) return;
  const std::wstring pattern = dir + L"\\*";
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = fd.cFileName;
      if (name == L"." || name == L"..") continue;
      const std::wstring full = dir + L"\\" + name;
      if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        DeleteDirRecursive(full);
      } else {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_READONLY)
          SetFileAttributesW(full.c_str(), FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(full.c_str());
      }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
  }
  RemoveDirectoryW(dir.c_str());
}

// static
void FlutterCefPlugin::SweepStaleEphemeralProfiles() {
  wchar_t tmp[MAX_PATH] = {};
  const DWORD n = GetTempPathW(MAX_PATH, tmp);
  if (n == 0 || n >= MAX_PATH) return;
  const std::wstring base(tmp);
  const std::wstring prefix = L"flutter_cef_ephem_";
  const std::wstring pattern = base + prefix + L"*";
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
    const std::wstring name = fd.cFileName;
    if (name.rfind(prefix, 0) != 0) continue;
    // Owning pid = the token between the prefix and the next '_' in
    // flutter_cef_ephem_<pid>_<tick>_<counter> (MakeEphemeralProfileDir).
    const std::wstring rest = name.substr(prefix.size());
    const size_t us = rest.find(L'_');
    const std::wstring pid_str =
        us == std::wstring::npos ? rest : rest.substr(0, us);
    const DWORD pid =
        static_cast<DWORD>(wcstoul(pid_str.c_str(), nullptr, 10));
    bool owner_alive = false;
    if (pid != 0) {
      // Same-user temp dir => OpenProcess(SYNCHRONIZE) succeeds iff a process
      // with this pid exists; WAIT_TIMEOUT means it's still running (a signaled
      // handle is a not-yet-reaped zombie — treat as dead). Access-denied /
      // failure => not our live process => stale.
      HANDLE p = OpenProcess(SYNCHRONIZE, FALSE, pid);
      if (p) {
        owner_alive = WaitForSingleObject(p, 0) == WAIT_TIMEOUT;
        CloseHandle(p);
      }
    }
    if (!owner_alive) DeleteDirRecursive(base + name);
  } while (FindNextFileW(h, &fd));
  FindClose(h);
}

// ---- C1 first-present watchdog (platform thread) ----

void FlutterCefPlugin::ArmWatchdog(Session* session) {
  if (!session || !message_window_ || session->painted || session->closing)
    return;
  session->watchdog_phase = 0;
  session->watchdog_timer = static_cast<UINT_PTR>(session->generation);
  // Periodic WM_TIMER (id == generation) delivered to MsgWndProc on this
  // (platform) thread; fires every grace until a present arrives or teardown.
  SetTimer(message_window_, session->watchdog_timer, WatchdogGraceMs(),
           nullptr);
}

void FlutterCefPlugin::CancelWatchdog(Session* session) {
  if (!session || session->watchdog_timer == 0) return;
  if (message_window_) KillTimer(message_window_, session->watchdog_timer);
  session->watchdog_timer = 0;
}

void FlutterCefPlugin::OnWatchdogTimer(UINT_PTR timer_id) {
  // timer_id == the owning session's generation.
  Session* s = nullptr;
  for (auto& kv : sessions_) {
    if (kv.second->watchdog_timer == timer_id) {
      s = kv.second.get();
      break;
    }
  }
  if (!s) {
    if (message_window_) KillTimer(message_window_, timer_id);  // orphan
    return;
  }
  if (s->closing || s->painted || !s->visible) {
    CancelWatchdog(s);
    return;
  }
  if (s->watchdog_phase == 0) {
    // First grace elapsed with no present — cheap re-kick, then wait one more
    // grace before declaring a stall (macOS checkFirstPresent opInvalidate).
    SendOrQueue(s, kOpInvalidate, {});
    s->watchdog_phase = 1;
    return;
  }
  // Still blank after the re-kick grace: surface paintStalled to Dart (a
  // REPEATING signal — the periodic timer re-kicks + re-emits every grace until
  // a present lands or the consumer recreates the view; macOS re-arms the same
  // way, CefProfileHost.swift:756-764). Event shape = {sessionId} only
  // (Swift:558; cef_web_controller.dart:286).
  EmitEvent("paintStalled", s->id, {});
  SendOrQueue(s, kOpInvalidate, {});
}

}  // namespace flutter_cef

// ---- C API (called by generated_plugin_registrant.cc) ----
void FlutterCefPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_cef::FlutterCefPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
