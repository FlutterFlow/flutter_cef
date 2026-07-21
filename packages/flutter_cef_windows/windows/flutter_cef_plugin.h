// flutter_cef Windows plugin — channel host.
//
// The verb/event contract is ../native/cef_host/PROTOCOL.md §3/§4
// (transcribed from FlutterCefPlugin.swift). Slice architecture:
//  - ONE cef_host.exe per session/create (profile-sharing host reuse is P6;
//    the `profile` create arg is accepted but every session gets its own
//    ephemeral host for now).
//  - Per session: IpcPipe (named-pipe server + reader thread) + HostProcess
//    (Job-Object-guarded spawn) + a TextureBridge GpuSurfaceTexture.
//  - Reader/watcher threads never touch the MethodChannel: they post
//    HostEvents into a mutex+deque drained on the platform thread via a
//    message-only HWND (PostMessage wakeup) — the slice-approved marshal.
//  - Handshake: nothing is sent until kOpReady; protocolVersion must be 3
//    (else processGone "protocolMismatch(host=vN)"). Verbs issued before
//    ready are queued and flushed on ready (kOpCreateBrowser first).
//  - Present size-gate (LAW 4): a present is promoted only when its
//    {srcW,srcH} matches round(logical*dpr) ±1 px for the CURRENT size.
//  - Host death: pipe EOF or process-exit watcher -> processGone with reason
//    "crashed" / "locked" (exit code 2) / "createFailed" (kOpCreateFailed) /
//    "protocolMismatch(host=vN)".
//  - Unimplemented/unknown verbs reply success(null) + OutputDebugString —
//    never an error (slice deviation from macOS's FlutterMethodNotImplemented).

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
  // One live session: one host process + pipe + texture. Platform-thread
  // confined (the reader/watcher threads only post events).
  struct Session {
    std::string id;
    // Monotonic per-create identity (C1 host-object-identity analogue of
    // macOS failHost, FlutterCefPlugin.swift:484-511). The reader/exit-watcher
    // lambdas capture THIS value and stamp it into every HostEvent; a stale
    // OLD-host event (posted during the reaper grace after a dispose+recreate
    // of the SAME id) then carries a generation that no longer matches the
    // live session and is dropped instead of killing the new one.
    uint64_t generation = 0;
    uint32_t browser_id = 1;  // wire id (>= 1); single browser per host
    int64_t texture_id = -1;
    int width = 800;
    int height = 600;
    double dpr = 1.0;
    // The size-gate expectation: round(logical * dpr) (LAW 4).
    uint32_t expected_pw = 0;
    uint32_t expected_ph = 0;
    bool ready = false;    // kOpReady received + version checked
    bool closing = false;  // teardown started — ignore further host events
    uint64_t current_handle = 0;  // last promoted bridge handle
    uint32_t gate_misses = 0;     // diagnostics
    // C1 first-present watchdog (mirror CefProfileHost.swift:641-765). A
    // per-session WM_TIMER (id == generation) armed at create: on the first
    // grace with no kOpPresent we re-kick via kOpInvalidate; on the next grace
    // still blank we emit the 'paintStalled' event (repeating). Suspended while
    // hidden (a WasHidden browser produces no frames by design), re-armed on
    // show. Cancelled the instant any present arrives / on teardown.
    bool painted = false;           // first kOpPresent seen — watchdog retired
    bool visible = true;            // last setVisible state
    UINT_PTR watchdog_timer = 0;    // active WM_TIMER id (0 = none); == generation
    int watchdog_phase = 0;         // 0 = armed (pre re-kick), 1 = kicked
    // The ephemeral %TEMP%\flutter_cef_ephem_* profile dir this host owns;
    // recursively deleted by the reaper once the host is confirmed dead
    // (macOS: CefProfileHost.swift:1004-1006).
    std::wstring profile_dir;
    // Frames queued before kOpReady: (opcode, payload).
    std::vector<std::pair<uint8_t, std::vector<uint8_t>>> pending_frames;
    std::unique_ptr<IpcPipe> pipe;
    std::unique_ptr<HostProcess> host;
    std::thread exit_watcher;  // waits on a dup'd process handle
  };

  // Cross-thread event, posted by reader/watcher threads, drained on the
  // platform thread.
  struct HostEvent {
    enum class Kind { kFrame, kDisconnect, kExited };
    Kind kind = Kind::kFrame;
    std::string session_id;
    // The generation of the Session that owned the poster (reader/watcher).
    // Dropped on drain if it no longer matches the live session's generation
    // (C1: a stale OLD-host event must not touch a re-created same-id session).
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

  // Session helpers (platform thread).
  Session* FindSession(const flutter::EncodableMap& args);
  void DisposeSession(const std::string& session_id);
  // Tears one session down: marks closing, optionally sends
  // kOpDisposeBrowser+kOpShutdown, unregisters the texture, and hands
  // pipe/host/watcher to a reaper thread (bounded wait -> kill -> close).
  void TeardownSession(const std::string& session_id, bool send_shutdown);
  // Queue until kOpReady, then send directly.
  void SendOrQueue(Session* session, uint8_t opcode,
                   std::vector<uint8_t> payload);

  // Cross-thread marshal.
  void PostEvent(HostEvent event);
  void DrainEvents();
  void HandleHostFrame(const std::string& session_id, uint64_t generation,
                       uint32_t browser_id, uint8_t opcode,
                       const std::vector<uint8_t>& payload);
  void HandleHostGone(const std::string& session_id, uint64_t generation,
                      bool exit_code_known, unsigned long exit_code);
  void HandlePresent(Session* session, const std::vector<uint8_t>& payload);

  // C1 first-present watchdog (WM_TIMER on message_window_, id == generation).
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
  // Recursively delete a directory tree (best-effort). Used by the reaper to
  // reclaim an ephemeral profile dir once its host is dead, and by the startup
  // sweep. Safe on a missing path.
  static void DeleteDirRecursive(const std::wstring& dir);
  // Reclaim ephemeral profile dirs left behind by a previous crash/kill: any
  // %TEMP%\flutter_cef_ephem_<pid>_* whose owning pid is no longer alive
  // (macOS: FlutterCefPlugin.swift:97-109 sweepStaleEphemeralProfiles).
  static void SweepStaleEphemeralProfiles();

  flutter::PluginRegistrarWindows* registrar_;  // owned by the engine
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<TextureBridge> texture_bridge_;

  HWND message_window_ = nullptr;
  std::mutex queue_mutex_;
  std::deque<HostEvent> queue_;

  std::map<std::string, std::unique_ptr<Session>> sessions_;
  // Monotonic source for Session::generation (never 0 — 0 means "no session").
  uint64_t next_generation_ = 1;
  // Per-session teardown threads (bounded: wait <=3s then kill). Each carries a
  // `done` flag so finished reapers can be pruned/joined on the next teardown
  // (H17), and all are joined in the destructor so no thread outlives `this`.
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
