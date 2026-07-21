#include "host_process.h"

#include <vector>

namespace flutter_cef {

namespace {

void HostLog(const char* msg, unsigned long err = 0) {
  char buf[256];
  if (err) {
    _snprintf_s(buf, _TRUNCATE, "[flutter_cef_windows] HostProcess: %s (err=%lu)\n",
                msg, err);
  } else {
    _snprintf_s(buf, _TRUNCATE, "[flutter_cef_windows] HostProcess: %s\n", msg);
  }
  OutputDebugStringA(buf);
}

}  // namespace

HostProcess::HostProcess() = default;

HostProcess::~HostProcess() { Shutdown(); }

bool HostProcess::Spawn(const std::wstring& cef_host_exe,
                        const std::wstring& pipe_name,
                        const std::wstring& profile_dir, bool ephemeral) {
  if (process_) return false;  // one-shot

  // CommandLineToArgvW-correct quoting: quote the exe and the --profile-dir
  // arg (the only ones that can contain spaces; neither ends in '\', so a
  // plain closing quote is safe). Pipe names never contain spaces.
  std::wstring cmd = L"\"" + cef_host_exe + L"\" --ipc=" + pipe_name +
                     L" \"--profile-dir=" + profile_dir + L"\"";
  if (ephemeral) cmd += L" --ephemeral";

  // Kill-on-close Job Object, assigned while the child is suspended, so the
  // guarantee covers the child's entire lifetime (its own subprocesses run
  // under CEF's job management; Chromium children die with the browser).
  job_ = CreateJobObjectW(nullptr, nullptr);
  if (job_) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job_, JobObjectExtendedLimitInformation,
                                 &info, sizeof(info))) {
      CloseHandle(job_);
      job_ = nullptr;
    }
  }

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  std::vector<wchar_t> cmd_buf(cmd.begin(), cmd.end());
  cmd_buf.push_back(L'\0');
  if (!CreateProcessW(cef_host_exe.c_str(), cmd_buf.data(),
                      /*lpProcessAttributes=*/nullptr,
                      /*lpThreadAttributes=*/nullptr,
                      /*bInheritHandles=*/FALSE,
                      CREATE_SUSPENDED | CREATE_NO_WINDOW,
                      /*lpEnvironment=*/nullptr,
                      /*lpCurrentDirectory=*/nullptr, &si, &pi)) {
    HostLog("CreateProcessW failed", GetLastError());
    if (job_) {
      CloseHandle(job_);
      job_ = nullptr;
    }
    return false;
  }
  if (job_ && !AssignProcessToJobObject(job_, pi.hProcess)) {
    // Best-effort (nested-job support exists since Win8): proceed without the
    // kernel guarantee rather than failing the spawn.
    HostLog("AssignProcessToJobObject failed", GetLastError());
    CloseHandle(job_);
    job_ = nullptr;
  }
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  process_ = pi.hProcess;
  return true;
}

unsigned long HostProcess::WaitForExit(unsigned long timeout_ms) {
  if (!process_) return kStillRunning;
  if (WaitForSingleObject(process_, timeout_ms) != WAIT_OBJECT_0)
    return kStillRunning;
  DWORD code = 0;
  if (!GetExitCodeProcess(process_, &code)) return kStillRunning;
  return code;
}

void HostProcess::Terminate() {
  if (process_) TerminateProcess(process_, 9);
}

HANDLE HostProcess::DuplicateProcessHandle() const {
  if (!process_) return nullptr;
  HANDLE dup = nullptr;
  if (!DuplicateHandle(GetCurrentProcess(), process_, GetCurrentProcess(),
                       &dup, SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                       FALSE, 0)) {
    return nullptr;
  }
  return dup;
}

void HostProcess::Shutdown() {
  if (process_) {
    CloseHandle(process_);
    process_ = nullptr;
  }
  if (job_) {
    // KILL_ON_JOB_CLOSE: this is the kernel-guaranteed no-orphan escalation.
    CloseHandle(job_);
    job_ = nullptr;
  }
}

}  // namespace flutter_cef
