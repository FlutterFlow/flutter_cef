// HostProcess — spawns and owns one cef_host.exe.
//
// Slice model: ONE host per session/create (profile-sharing host reuse is
// P6). The plugin creates the IpcPipe FIRST, then spawns
//   cef_host.exe --ipc=<pipe name> --profile-dir=<%TEMP% unique> --ephemeral
// (named pipe: the child connects by NAME with CreateFileW, so no handle
// inheritance is needed — cf. S3, which inherited anonymous handles).
//
// Kill guarantees:
//  - Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, assigned before the
//    (suspended) child runs: closing the job handle (Shutdown()/dtor) is a
//    kernel-guaranteed kill — no orphaned cef_host, ever.
//  - Graceful path: the plugin sends kOpShutdown first, then a reaper thread
//    does WaitForExit(bounded) -> Terminate() -> Shutdown().
//
// NOTE: deliberately flutter-free (windows.h only) so it can be exercised by
// a standalone harness without an engine.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_HOST_PROCESS_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_HOST_PROCESS_H_

#include <windows.h>

#include <string>

namespace flutter_cef {

class HostProcess {
 public:
  // Sentinel returned by WaitForExit when the process is still running.
  static constexpr unsigned long kStillRunning = 0xFFFFFFFFul;

  HostProcess();
  ~HostProcess();

  HostProcess(const HostProcess&) = delete;
  HostProcess& operator=(const HostProcess&) = delete;

  // Spawns cef_host.exe bound to the (already created) pipe `pipe_name`.
  // `allowed_schemes` is an optional csv navigation-scheme allowlist passed as
  // --allowed-schemes=<csv> (empty = omitted = allow all; mirrors
  // CefProfileHost.spawn, CefProfileHost.swift:289-291). Returns false on
  // spawn failure.
  //
  // AGENT CONTROL (P9): when `agent_control` is true, the spawn additionally
  // sets up the CDP-over-pipe transport (the S3 recipe, mirroring macOS
  // launchViaPosixSpawn's fds 3/4): it CreatePipe()s two anonymous pipes, marks
  // ONLY the child-side ends inheritable, spawns cef_host with a
  // STARTUPINFOEX PROC_THREAD_ATTRIBUTE_HANDLE_LIST containing exactly those two
  // ends (so nothing else leaks — this composes with the existing spawn, which
  // inherits NO handles: the IPC pipe is connected by NAME and the Job Object is
  // assigned post-spawn), and passes `--cdp-io-pipes=<childRead>,<childWrite>`
  // (decimal HANDLE values) which cef_host's OnBeforeCommandLineProcessing
  // translates into Chromium's --remote-debugging-pipe +
  // --remote-debugging-io-pipes. The PARENT-side ends are returned via
  // `out_cdp_read` (we read CDP responses/events here; child writes) and
  // `out_cdp_write` (we write CDP commands here; child reads). The caller owns +
  // closes them. When `agent_control` is false the spawn is byte-identical to
  // the pre-P9 path (no handle inheritance, no extra pipes).
  bool Spawn(const std::wstring& cef_host_exe, const std::wstring& pipe_name,
             const std::wstring& profile_dir, bool ephemeral,
             const std::string& allowed_schemes = std::string(),
             bool agent_control = false, HANDLE* out_cdp_read = nullptr,
             HANDLE* out_cdp_write = nullptr);

  // Waits up to `timeout_ms` for exit; returns the exit code, or
  // kStillRunning on timeout / if never spawned.
  unsigned long WaitForExit(unsigned long timeout_ms);

  // Hard kill (TerminateProcess). The Job Object close in Shutdown() is the
  // belt-and-suspenders escalation.
  void Terminate();

  // Duplicates the process handle (SYNCHRONIZE | QUERY_LIMITED) for an
  // exit-watcher thread that must outlive this object's handles. Caller
  // closes it. nullptr if not running.
  HANDLE DuplicateProcessHandle() const;

  // Closes process + job handles. KILL_ON_JOB_CLOSE means this kills the
  // process if it is somehow still alive.
  void Shutdown();

  bool is_running() const { return process_ != nullptr; }

 private:
  HANDLE process_ = nullptr;  // held hProcess (no pid dance — a HANDLE is
                              // not a recyclable global name, PLAN §4.2)
  HANDLE job_ = nullptr;      // kill-on-close Job Object
};

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_HOST_PROCESS_H_
