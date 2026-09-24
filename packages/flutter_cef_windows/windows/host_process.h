// HostProcess — spawns and owns one cef_host.exe.
//
// One host per PROFILE, serving every session on it (see flutter_cef_plugin.h).
// The plugin creates the IpcPipe FIRST, then spawns
//   cef_host.exe --ipc=<pipe name> --profile-dir=<dir> [--ephemeral]
//                [--allowed-schemes=<csv>] [--cdp-io-pipes=<r>,<w>]
// (named pipe: the child connects by NAME with CreateFileW, so no handle
// inheritance is needed, unlike the agent-control CDP pipes below).
//
// Kill guarantees:
//  - Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, assigned before the
//    (suspended) child runs: closing the job handle (Shutdown()/dtor) is a
//    kernel-guaranteed kill — no orphaned cef_host, ever. Chromium's children
//    are spawned inside the same job.
//  - Graceful path: the plugin sends kOpShutdown first, then a reaper thread
//    does WaitForExit(bounded) -> KillTreeAndWait() -> Shutdown().
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
  // CefProfileHost.spawn). A list that isn't all valid schemes is refused.
  // Returns false on spawn failure.
  //
  // AGENT CONTROL: when `agent_control` is true, the spawn additionally
  // sets up the CDP-over-pipe transport (mirroring macOS
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
  // a plain spawn (no handle inheritance, no extra pipes).
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

  // Ends the whole process tree (the host and every Chromium child in its
  // job) and waits up to `timeout_ms` for all of them to be gone. True once
  // the job is empty. Call before deleting the profile dir: a live child
  // still holds files in it.
  bool KillTreeAndWait(unsigned long timeout_ms);

  // Closes process + job handles. KILL_ON_JOB_CLOSE means this kills the
  // process if it is somehow still alive.
  void Shutdown();

  bool is_running() const { return process_ != nullptr; }

 private:
  HANDLE process_ = nullptr;  // held hProcess (no pid dance — a HANDLE is
                              // not a recyclable global name)
  HANDLE job_ = nullptr;      // kill-on-close Job Object
};

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_HOST_PROCESS_H_
