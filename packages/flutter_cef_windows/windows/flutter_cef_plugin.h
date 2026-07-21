// flutter_cef Windows plugin — channel host.
//
// The verb/event contract is ../native/cef_host/PROTOCOL.md §3/§4
// (transcribed from FlutterCefPlugin.swift). Architecture (P6 foundation +
// the profile slice of P11 — mirrors CefProfileHost.swift + FlutterCefPlugin
// .swift):
//  - ONE cef_host.exe per PROFILE. A non-empty `profile` create arg -> a
//    shared, persistent Host (keyed by profile name) reused by every session
//    that names it; an absent/empty profile -> a unique ephemeral Host per
//    create (keyed "~ephemeral~"+sessionId). Views sharing a `profile` share
//    one host -> one cookie jar -> one login (macOS parity).
//  - A Host owns the process (Job-Object-guarded), the IpcPipe (+ reader
//    thread), the process-exit watcher, the pre-ready send queue, the
//    monotonic wire-browserId allocator, and the profile identity. It serves
//    N Sessions.
//  - A Session owns one browser (browser_id), its TextureBridge texture, the
//    size-gate expectation, and the first-present watchdog. It points at its
//    parent Host by key.
//  - Reader/watcher threads never touch the MethodChannel: they post
//    HostEvents into a mutex+deque drained on the platform thread via a
//    message-only HWND (PostMessage wakeup) — the slice-approved marshal.
//  - Event routing: every host->plugin frame carries a wire browser_id.
//    browser_id 0 is process-level (kOpReady, kOpLog); >=1 routes to the
//    Session bound to that id on that Host. The #1 generation guard now keys
//    on the HOST's generation, so a dead host's straggler frames (posted
//    during the reaper grace after a same-profile respawn) can't reach a
//    session on the fresh host.
//  - Handshake: nothing is sent until kOpReady; protocolVersion must be 3
//    (else processGone "protocolMismatch(host=vN)" for every session). Verbs
//    issued before ready are queued on the Host and flushed on ready.
//  - Present size-gate (LAW 4): a present is promoted only when its
//    {srcW,srcH} matches round(logical*dpr) ±1 px for the CURRENT size.
//  - Teardown is two-tier: dispose ONE browser = kOpDisposeBrowser, host
//    survives if other sessions remain; last session gone / host death = tear
//    down the whole Host (reader/watcher/Job/pipe) via a bounded reaper.
//  - Host death: pipe EOF or process-exit watcher -> processGone with reason
//    "crashed" / "locked" (exit code 2) for every session on the host.
//  - Unimplemented/unknown verbs reply success(null) + OutputDebugString.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "host_process.h"
#include "ipc_pipe.h"
#include "texture_bridge.h"

namespace flutter_cef {

class FlutterCefPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit FlutterCefPlugin(flutter::PluginRegistrarWindows* registrar);
  ~FlutterCefPlugin() override;

  FlutterCefPlugin(const FlutterCefPlugin&) = delete;
  FlutterCefPlugin& operator=(const FlutterCefPlugin&) = delete;

 private:
  // A frame queued before kOpReady: (browser_id, opcode, payload). Held on the
  // Host (not the Session) so a burst of pre-ready creates on a fresh shared
  // host all flush in order.
  struct PendingFrame {
    uint32_t browser_id = 0;
    uint8_t opcode = 0;
    std::vector<uint8_t> payload;
  };

  // One cef_host.exe process serving N Sessions. Platform-thread confined (the
  // reader/watcher threads only post events). Mirrors CefProfileHost.swift.
  struct Host {
    std::string key;  // hosts_ map key: profile name OR "~ephemeral~"+sessionId
    // Monotonic per-spawn identity (C1 host-object-identity analogue of macOS
    // failHost, FlutterCefPlugin.swift:484-511). The reader/exit-watcher
    // lambdas capture THIS value; a stale OLD-host event posted during the
    // reaper grace after a dispose+respawn of the SAME profile key carries a
    // generation that no longer matches the live host and is dropped.
    uint64_t generation = 0;
    bool ephemeral = true;
    // %LOCALAPPDATA%\flutter_cef\profiles\<name> (persistent) or
    // %TEMP%\flutter_cef_ephem_* (ephemeral). Recursively deleted by the reaper
    // ONLY when ephemeral (a persistent profile must survive teardown).
    std::wstring profile_dir;
    bool ready = false;    // kOpReady received + version checked
    bool closing = false;  // whole-host teardown started
    uint32_t next_browser_id = 1;  // monotonic wire id allocator (never reused)
    // browser_id -> sessionId (inbound event routing + teardown bookkeeping).
    std::map<uint32_t, std::string> browsers;
    // Frames queued before kOpReady, flushed in order on ready (each create's
    // kOpCreateBrowser was appended before any of its follow-up verbs).
    std::vector<PendingFrame> pending_frames;
    std::unique_ptr<IpcPipe> pipe;
    std::unique_ptr<HostProcess> process;
    std::thread exit_watcher;  // waits on a dup'd process handle
  };

  // One browser/view. Platform-thread confined.
  struct Session {
    std::string id;
    std::string host_key;     // parent Host (look up in hosts_)
    uint32_t browser_id = 0;  // wire id on the parent host (>= 1)
    int64_t texture_id = -1;
    int width = 800;
    int height = 600;
    double dpr = 1.0;
    // The size-gate expectation: round(logical * dpr) (LAW 4).
    uint32_t expected_pw = 0;
    uint32_t expected_ph = 0;
    uint64_t current_handle = 0;  // last promoted bridge handle
    uint32_t gate_misses = 0;     // diagnostics
    // C1 first-present watchdog (mirror CefProfileHost.swift:641-765). A
    // per-session WM_TIMER (unique watchdog_id) armed at create: on the first
    // grace with no kOpPresent we re-kick via kOpInvalidate; on the next grace
    // still blank we emit 'paintStalled' (repeating). Suspended while hidden,
    // re-armed on show. Cancelled the instant any present arrives / on
    // teardown. watchdog_id is a plugin-unique token (NOT the host generation,
    // which is now shared across sibling sessions).
    bool painted = false;
    bool visible = true;
    UINT_PTR watchdog_id = 0;      // stable per-session WM_TIMER token (!= 0)
    bool watchdog_active = false;  // a timer is currently set
    int watchdog_phase = 0;        // 0 = armed (pre re-kick), 1 = kicked
  };

  // Cross-thread event, posted by a Host's reader/watcher threads, drained on
  // the platform thread.
  struct HostEvent {
    enum class Kind { kFrame, kDisconnect, kExited };
    Kind kind = Kind::kFrame;
    std::string host_key;
    // The generation of the Host that owned the poster. Dropped on drain if it
    // no longer matches the live host's generation (C1).
    uint64_t generation = 0;
    uint32_t browser_id = 0;
    uint8_t opcode = 0;
    std::vector<uint8_t> payload;
    unsigned long exit_code = 0;  // kExited only
  };

  static LRESULT CALLBACK MsgWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                     LPARAM lparam);

  // Channel verb dispatch (platform thread). Verb names/args: PROTOCOL.md §3.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void HandleCreate(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  void HandleResize(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);

  // Session / host helpers (platform thread).
  Session* FindSession(const flutter::EncodableMap& args);
  Host* HostForSession(const Session* session);
  // Resolve the live Host for `key`, or spawn a fresh one. nullptr on spawn
  // failure. An EXISTING host is reused verbatim (its --allowed-schemes etc.
  // are process args fixed at its spawn — the reuse arg is ignored, macOS
  // parity, FlutterCefPlugin.swift:456-471).
  Host* ResolveOrSpawnHost(const std::string& key,
                           const std::wstring& profile_dir, bool ephemeral,
                           const std::wstring& host_exe,
                           const std::string& allowed_schemes);
  void DisposeSession(const std::string& session_id);
  // Tear down a whole Host: mark closing, optionally send kOpShutdown, sweep
  // any lingering sessions, and hand pipe/process/watcher to a reaper thread
  // (bounded wait -> kill -> close; deletes an EPHEMERAL profile dir).
  void TeardownHost(const std::string& host_key, bool send_shutdown);
  // Host death / protocol mismatch: emit processGone for every session on the
  // host, release their textures, then tear the host down.
  void FailHost(const std::string& host_key, const std::string& reason);
  // Queue until the Host's kOpReady, then send directly.
  void SendOrQueue(Session* session, uint8_t opcode,
                   std::vector<uint8_t> payload);

  // Cross-thread marshal.
  void PostEvent(HostEvent event);
  void DrainEvents();
  void HandleHostFrame(const std::string& host_key, uint64_t generation,
                       uint32_t browser_id, uint8_t opcode,
                       const std::vector<uint8_t>& payload);
  void HandleHostGone(const std::string& host_key, uint64_t generation,
                      bool exit_code_known, unsigned long exit_code);
  void HandlePresent(Session* session, const std::vector<uint8_t>& payload);
  // Route a per-browser frame to its Session (the big opcode switch).
  void HandleSessionFrame(Session* session, uint8_t opcode,
                          const std::vector<uint8_t>& payload);

  // C1 first-present watchdog (WM_TIMER on message_window_).
  void ArmWatchdog(Session* session);
  void CancelWatchdog(Session* session);
  void OnWatchdogTimer(UINT_PTR timer_id);

  // Emit an event to Dart (platform thread only). `args` need not contain
  // sessionId — it is added here.
  void EmitEvent(const std::string& method, const std::string& session_id,
                 flutter::EncodableMap args);

  // FLUTTER_CEF_HOST env override -> cef_host.exe beside the app exe -> L"".
  static std::wstring ResolveCefHostPath();
  static std::wstring MakeEphemeralProfileDir();
  // Persistent + shared profile dir: %LOCALAPPDATA%\flutter_cef\profiles\
  // <sanitize(name)>, created with a current-user-SID protected DACL (the #3
  // pipe-hardening pattern). Empty string on an unusable name. See the .cpp
  // for the DPAPI-at-rest note (SPIKES.md S2 / §7).
  static std::wstring MakePersistentProfileDir(const std::string& profile);
  // Recursively delete a directory tree (best-effort). Safe on a missing path.
  static void DeleteDirRecursive(const std::wstring& dir);
  // Reclaim ephemeral profile dirs left behind by a previous crash/kill.
  static void SweepStaleEphemeralProfiles();

  flutter::PluginRegistrarWindows* registrar_;  // owned by the engine
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<TextureBridge> texture_bridge_;

  HWND message_window_ = nullptr;
  std::mutex queue_mutex_;
  std::deque<HostEvent> queue_;

  // Two-level registry: one Host per profile key, many Sessions per host.
  std::map<std::string, std::unique_ptr<Host>> hosts_;
  std::map<std::string, std::unique_ptr<Session>> sessions_;
  // Monotonic source for Host::generation (never 0 — 0 means "no host").
  uint64_t next_generation_ = 1;
  // Monotonic source for Session::watchdog_id (never 0). Distinct from the host
  // generation so sibling sessions on one shared host get distinct WM_TIMER ids.
  UINT_PTR next_timer_id_ = 1;
  // Per-host teardown threads (bounded: wait <=3s then kill). Each carries a
  // `done` flag so finished reapers can be pruned/joined on the next teardown,
  // and all are joined in the destructor so no thread outlives `this`.
  struct Reaper {
    std::thread thread;
    std::shared_ptr<std::atomic<bool>> done;
  };
  std::vector<Reaper> reapers_;
  // Inbound opcodes we've already warned about (log once per opcode).
  std::vector<uint8_t> warned_opcodes_;
};

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_PLUGIN_H_
