// flutter_cef Windows plugin — channel host.
//
// The verb/event contract is ../native/cef_host/PROTOCOL.md §3/§4
// (transcribed from FlutterCefPlugin.swift). Architecture (mirrors
// CefProfileHost.swift + FlutterCefPlugin.swift):
//  - ONE cef_host.exe per PROFILE. A non-empty `profile` create arg -> a
//    shared, persistent Host (keyed by profile name) reused by every session
//    that names it; an absent/empty profile -> an ephemeral Host, shared by a
//    `hostGroup`'s sessions (keyed "~group~"+hostGroup, torn down with the
//    last) or else unique per create (keyed "~ephemeral~"+sessionId). Views
//    sharing a `profile` share one host -> one cookie jar -> one login (macOS
//    parity).
//  - A Host owns the process (Job-Object-guarded), the IpcPipe (+ reader
//    thread), the process-exit watcher, the pre-ready send queue, the
//    monotonic wire-browserId allocator, and the profile identity. It serves
//    N Sessions.
//  - A Session owns one browser (browser_id), its TextureBridge texture, the
//    size-gate expectation, and the first-present watchdog. It points at its
//    parent Host by key.
//  - Reader/watcher threads never touch the MethodChannel: they post
//    HostEvents into a mutex+deque drained on the platform thread via a
//    message-only HWND (PostMessage wakeup).
//  - Event routing: every host->plugin frame carries a wire browser_id.
//    browser_id 0 is process-level (kOpReady, kOpLog); >=1 routes to the
//    Session bound to that id on that Host. The generation guard keys on
//    the HOST's generation, so a dead host's straggler frames (posted
//    during the reaper grace after a same-profile respawn) can't reach a
//    session on the fresh host.
//  - Handshake: nothing is sent until kOpReady; protocolVersion must equal
//    kCefHostProtocolVersion (else processGone "protocolMismatch(host=vN)" for
//    every session). Verbs
//    issued before ready are queued on the Host and flushed on ready.
//  - Present size-gate: CEF still delivers late frames at the OLD size after
//    a resize, so a present is promoted only when its {srcW,srcH} matches
//    round(logical*dpr) ±1 px for the CURRENT size.
//  - Teardown is two-tier: dispose ONE browser = kOpDisposeBrowser, host
//    survives if other sessions remain; last session gone / host death = tear
//    down the whole Host (reader/watcher/Job/pipe) via a bounded reaper.
//  - Host death: pipe EOF, process-exit watcher, a pipe write that fails or
//    times out, or a renderer the liveness sweep finds hung -> processGone
//    with reason "crashed" / "locked" (the host logged "profile-locked") /
//    "createFailed" (died before kOpReady) for every session on the host.
//  - Liveness: a first-present watchdog per session until its first frame,
//    then a periodic sweep (liveness_policy.h) that nudges stale tiles and
//    pings their renderer with an eval id the page can't reach.
//  - Verbs Windows can't serve (context menus, media permissions, the auth
//    window, the emoji picker) reply Error("unsupported"); unknown verbs
//    reply NotImplemented.

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

class CdpRelay;  // windows/cdp_relay.h — winsock, pulled in only by the .cpp

// Agent-control CDP-over-pipe transport for one host. Held via a
// shared_ptr so the always-on CDP reader thread (which delivers pipe messages
// to the current relay) can safely outlive a Host erase during teardown — the
// reader captures its own shared_ptr, so the transport (and its handles) stay
// alive until the reader is joined in the reaper. `read`/`write` are the
// PARENT-side ends of the two inherited anonymous pipes (we read CDP
// responses/events on `read`, write CDP commands on `write`). `relay` is the
// token-gated WS relay, created lazily by enableAgentControl and swapped in/out
// under `relay_mutex` (mirrors macOS CefProfileHost.cdpRelays + onCdpMessage).
// SINGLE-TILE: one relay slot per host; the N-relay fan-out is deferred.
struct CdpTransport {
  HANDLE read = nullptr;
  HANDLE write = nullptr;
  std::mutex write_mutex;            // serializes WriteFile to `write`
  std::mutex relay_mutex;           // guards `relay`
  std::shared_ptr<CdpRelay> relay;  // null until enableAgentControl
};

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
    // hosts_ map key: profile name, "~group~"+hostGroup or "~ephemeral~"+sessionId
    std::string key;
    // Monotonic per-spawn identity (the analogue of the host-object identity
    // check in macOS failHost). The reader/exit-watcher
    // lambdas capture THIS value; a stale OLD-host event posted during the
    // reaper grace after a dispose+respawn of the SAME profile key carries a
    // generation that no longer matches the live host and is dropped.
    uint64_t generation = 0;
    bool ephemeral = true;
    // %LOCALAPPDATA%\flutter_cef\profiles\<name> (persistent) or
    // %TEMP%\flutter_cef_ephem_* (ephemeral). Recursively deleted by the reaper
    // ONLY when ephemeral (a persistent profile must survive teardown).
    std::wstring profile_dir;
    bool ready = false;  // kOpReady received + version checked
    // The host logged "profile-locked" before exiting: another process holds
    // this profile. Read on death so the pipe EOF, which can beat the exit
    // code, still reports "locked".
    bool profile_locked = false;
    uint32_t next_browser_id = 1;  // monotonic wire id allocator (never reused)
    // browser_id -> sessionId (inbound event routing + teardown bookkeeping).
    std::map<uint32_t, std::string> browsers;
    // Frames queued before kOpReady, flushed in order on ready (each create's
    // kOpCreateBrowser was appended before any of its follow-up verbs).
    std::vector<PendingFrame> pending_frames;
    std::unique_ptr<IpcPipe> pipe;
    std::unique_ptr<HostProcess> process;
    std::thread exit_watcher;  // waits on a dup'd process handle
    // Agent control: set when this host was spawned with the CDP-over-pipe
    // transport (create arg agentControl:true). Fixed at spawn: a later
    // agentControl create that joins this host doesn't get it. `cdp` owns the parent-side pipe
    // ends + the lazily-created relay; `cdp_reader` continuously drains the CDP
    // read pipe and delivers to cdp->relay. Both are moved into the reaper on
    // teardown. Null / not-joinable for a non-agent-control host.
    bool agent_control = false;
    std::shared_ptr<CdpTransport> cdp;
    std::thread cdp_reader;
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
    // The size-gate expectation: round(logical * dpr), in physical px.
    uint32_t expected_pw = 0;
    uint32_t expected_ph = 0;
    uint64_t current_handle = 0;  // last promoted bridge handle
    uint32_t gate_misses = 0;     // diagnostics
    // First-present watchdog (mirrors CefProfileHost.checkFirstPresent). A
    // per-session WM_TIMER (unique watchdog_id) armed at create: each grace
    // that ends with no promoted present re-kicks via kOpInvalidate and emits
    // 'paintStalled' (repeating), as macOS does. Suspended while hidden,
    // re-armed on show. Cancelled on the first promoted present / on teardown.
    // watchdog_id is a plugin-unique token (NOT the host generation, which is
    // shared across sibling sessions).
    // `painted` = a present has been PROMOTED (passed the size gate); a
    // rejected frame shows nothing, so it doesn't count.
    bool painted = false;
    bool visible = true;
    UINT_PTR watchdog_id = 0;      // stable per-session WM_TIMER token (!= 0)
    bool watchdog_active = false;  // a timer is currently set

    // Pixel liveness (sessionStats + the liveness sweep). Times are
    // GetTickCount64 ms; 0 = never.
    uint64_t present_count = 0;    // promoted presents
    uint64_t last_present_ms = 0;  // last promoted present
    uint64_t nudged_at_ms = 0;     // sweep sent kOpInvalidate, no present since
    uint64_t ping_sent_ms = 0;     // unanswered liveness ping
    uint64_t ping_replied_ms = 0;  // last answered liveness ping
    int dialogs_open = 0;          // JS dialogs awaiting an answer
    bool devtools_opened = false;  // its debugger can pause the page

    // What freeze/thaw needs to recreate the browser. The create args, plus
    // the JS channels added since (they re-register on the new browser) and
    // the last authored document.
    struct CreateSpec {
      std::string url;
      std::string allowed_schemes;
      bool agent_control = false;
      bool named_profile = false;
      std::string profile;
      std::string host_group;
      std::vector<std::string> channels;
      std::vector<std::string> document_start_scripts;
    } spec;
    std::string authored_url;   // the url the authored document is served at
    std::string authored_html;  // empty = none
    // Frozen: the browser (and, if it was the last, its host) is gone; the
    // texture keeps its last frame and host_key is empty until thaw.
    bool frozen = false;
  };

  // Cross-thread event, posted by a Host's reader/watcher threads, drained on
  // the platform thread.
  struct HostEvent {
    // kWriteFailed: a pipe write failed or timed out on the platform thread;
    // posted rather than handled inline so the sender's Session/Host
    // pointers stay valid.
    enum class Kind { kFrame, kDisconnect, kExited, kWriteFailed };
    Kind kind = Kind::kFrame;
    std::string host_key;
    // The generation of the Host that owned the poster. Dropped on drain if it
    // no longer matches the live host's generation.
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
  // are process args fixed at its spawn — the reuse arg is ignored, as in
  // macOS resolveOrSpawnHost).
  Host* ResolveOrSpawnHost(const std::string& key,
                           const std::wstring& profile_dir, bool ephemeral,
                           const std::wstring& host_exe,
                           const std::string& allowed_schemes,
                           bool agent_control);
  void DisposeSession(const std::string& session_id);
  // freezeSession / thawSession (see the .cpp).
  void FreezeSession(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  void ThawSession(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  // The live host for `key`, or a freshly spawned one for `spec`. nullptr on
  // failure, with *error_code / *error_message set for the channel reply.
  Host* AcquireHost(const std::string& key, const Session::CreateSpec& spec,
                    const std::wstring& host_exe, const char** error_code,
                    const char** error_message);
  // Send (or queue before kOpReady) the frames that create `session`'s browser
  // on `host` at `url`: document-start items, an authored document, the create
  // at the session's current size, and a hide if it is hidden.
  void SendCreateFrames(Host* host, Session* session, const std::string& url);
  // Detach browser `browser_id` from host `host_key`: drop its routing entry
  // and queued frames, close the browser, and tear the host down if it was
  // the last.
  void DetachFromHost(const std::string& host_key, uint32_t browser_id);

  // Agent control. enableAgentControl starts (idempotently) the token-gated
  // loopback CDP relay for the session's host and replies
  // `{wsUrl, token, port}` (the macOS return shape exactly); it errors if the
  // host was not created with agentControl:true. disableAgentControl tears the
  // relay down (the tile keeps running). Both platform-thread only.
  void EnableAgentControl(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  void DisableAgentControl(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  // The always-on CDP reader: drains a host's CDP read pipe (NUL-framed JSON)
  // and delivers each complete message to the current relay. Runs on its own
  // thread; touches no MethodChannel state. Static + shared_ptr-scoped so it can
  // outlive a Host erase (joined in the reaper).
  static void CdpReadLoop(std::shared_ptr<CdpTransport> transport);
  // Tear down a whole Host: optionally send kOpShutdown, sweep
  // any lingering sessions, and hand pipe/process/watcher to a reaper thread
  // (bounded wait -> kill -> close; deletes an EPHEMERAL profile dir).
  void TeardownHost(const std::string& host_key, bool send_shutdown);
  // Host death / protocol mismatch: emit processGone for every session on the
  // host, release their textures, then tear the host down.
  void FailHost(const std::string& host_key, const std::string& reason);
  // Queue until the Host's kOpReady, then send directly.
  void SendOrQueue(Session* session, uint8_t opcode,
                   std::vector<uint8_t> payload);
  // Write one frame to a ready host. A failed or timed-out write posts a
  // kWriteFailed event (never fails the host inline: callers hold pointers).
  void SendToHost(Host* host, uint32_t browser_id, uint8_t opcode,
                  const std::vector<uint8_t>& payload);

  // Cross-thread marshal.
  void PostEvent(HostEvent event);
  void DrainEvents();
  void HandleHostFrame(const std::string& host_key, uint64_t generation,
                       uint32_t browser_id, uint8_t opcode,
                       const std::vector<uint8_t>& payload);
  void HandleHostGone(const std::string& host_key, uint64_t generation,
                      bool exit_code_known, unsigned long exit_code);
  // True when the present was promoted (passed the size gate and reached the
  // texture).
  bool HandlePresent(Session* session, const std::vector<uint8_t>& payload);
  // Route a per-browser frame to its Session (the big opcode switch).
  void HandleSessionFrame(Session* session, uint8_t opcode,
                          const std::vector<uint8_t>& payload);

  // First-present watchdog (WM_TIMER on message_window_).
  void ArmWatchdog(Session* session);
  void CancelWatchdog(Session* session);
  void OnWatchdogTimer(UINT_PTR timer_id);

  // Steady-state liveness sweep (WM_TIMER kLivenessTimerId), running while
  // any session exists.
  void EnsureLivenessTimer();
  void OnLivenessTimer();

  // Emit an event to Dart (platform thread only). `args` need not contain
  // sessionId — it is added here.
  void EmitEvent(const std::string& method, const std::string& session_id,
                 flutter::EncodableMap args);

  // FLUTTER_CEF_HOST env override -> cef_host.exe beside the app exe -> L"".
  static std::wstring ResolveCefHostPath();
  static std::wstring MakeEphemeralProfileDir();
  // Persistent + shared profile dir: %LOCALAPPDATA%\flutter_cef\profiles\
  // <sanitize(name)>, created with a current-user-SID protected DACL (the
  // IPC pipe's hardening pattern). Empty string on an unusable name. See
  // the .cpp for the DPAPI-at-rest note.
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
  bool liveness_timer_active_ = false;
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
