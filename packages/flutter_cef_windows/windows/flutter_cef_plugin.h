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
  void HandleHostFrame(const std::string& session_id, uint32_t browser_id,
                       uint8_t opcode, const std::vector<uint8_t>& payload);
  void HandleHostGone(const std::string& session_id, bool exit_code_known,
                      unsigned long exit_code);
  void HandlePresent(Session* session, const std::vector<uint8_t>& payload);

  // Emit an event to Dart (platform thread only). `args` need not contain
  // sessionId — it is added here.
  void EmitEvent(const std::string& method, const std::string& session_id,
                 flutter::EncodableMap args);

  // FLUTTER_CEF_HOST env override -> cef_host.exe beside the app exe -> L"".
  static std::wstring ResolveCefHostPath();
  static std::wstring MakeEphemeralProfileDir();

  flutter::PluginRegistrarWindows* registrar_;  // owned by the engine
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<TextureBridge> texture_bridge_;

  HWND message_window_ = nullptr;
  std::mutex queue_mutex_;
  std::deque<HostEvent> queue_;

  std::map<std::string, std::unique_ptr<Session>> sessions_;
  // Per-session teardown threads (bounded: wait <=3s then kill). Joined in
  // the destructor so no thread outlives the plugin.
  std::vector<std::thread> reapers_;
  // Inbound opcodes we've already warned about (log once per opcode).
  std::vector<uint8_t> warned_opcodes_;
};

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_PLUGIN_H_
