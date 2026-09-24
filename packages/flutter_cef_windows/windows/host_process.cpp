#include "host_process.h"

#include <cstdint>
#include <vector>

#include "cef_host_policy.h"

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
                        const std::wstring& profile_dir, bool ephemeral,
                        const std::string& allowed_schemes, bool agent_control,
                        HANDLE* out_cdp_read, HANDLE* out_cdp_write) {
  if (process_) return false;  // one-shot

  // CommandLineToArgvW-correct quoting: quote the exe and the --profile-dir
  // arg (the only ones that can contain spaces; neither ends in '\', so a
  // plain closing quote is safe). Pipe names never contain spaces.
  std::wstring cmd = L"\"" + cef_host_exe + L"\" --ipc=" + pipe_name +
                     L" \"--profile-dir=" + profile_dir + L"\"";
  if (ephemeral) cmd += L" --ephemeral";
  // Navigation scheme allowlist (csv; enforced host-side in OnBeforeBrowse).
  // Chromium parses this whole command line, so a value with a space or a
  // quote would smuggle in its own switches: only RFC 3986 scheme tokens
  // (ASCII letters, digits, "+", "-", ".") and commas get through, which also
  // makes the byte-wise widening below exact. The plugin validates first;
  // this is the last check before the command line is built.
  if (!policy::IsValidSchemeList(allowed_schemes)) {
    HostLog("refusing to spawn: allowed_schemes is not a scheme list");
    return false;
  }
  if (!allowed_schemes.empty()) {
    std::wstring w(allowed_schemes.begin(), allowed_schemes.end());
    cmd += L" --allowed-schemes=" + w;
  }

  // ---- Agent control: CDP-over-pipe plumbing ----
  // Two anonymous pipes; ONLY the child-side ends are inheritable and land in
  // the STARTUPINFOEX handle list, so this composes cleanly with the existing
  // spawn (which inherits nothing). cmd_pipe: parent writes CDP -> child reads.
  // out_pipe: child writes CDP -> parent reads.
  HANDLE cmd_read = nullptr, cmd_write = nullptr;   // cmd_read = child's read
  HANDLE out_read = nullptr, out_write = nullptr;   // out_write = child's write
  std::vector<uint8_t> attr_buf;
  LPPROC_THREAD_ATTRIBUTE_LIST attrs = nullptr;
  if (agent_control) {
    if (!CreatePipe(&cmd_read, &cmd_write, nullptr, 0) ||
        !CreatePipe(&out_read, &out_write, nullptr, 0)) {
      HostLog("CreatePipe (cdp) failed", GetLastError());
      if (cmd_read) CloseHandle(cmd_read);
      if (cmd_write) CloseHandle(cmd_write);
      if (out_read) CloseHandle(out_read);
      if (out_write) CloseHandle(out_write);
      return false;
    }
    SetHandleInformation(cmd_read, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    SetHandleInformation(out_write, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    // Child argv: --remote-debugging-io-pipes wants <read>,<write> where read is
    // the handle the browser READS commands from (cmd_read) and write is the one
    // it WRITES responses to (out_write). Decimal HANDLE values, cast to
    // unsigned 32-bit (`(unsigned)(uintptr_t)`: handle values fit in 32 bits
    // for Chromium's int-parsing of the switch).
    cmd += L" --cdp-io-pipes=" +
           std::to_wstring(static_cast<unsigned>(
               reinterpret_cast<uintptr_t>(cmd_read))) +
           L"," +
           std::to_wstring(static_cast<unsigned>(
               reinterpret_cast<uintptr_t>(out_write)));
    // Explicit inheritance list = exactly the two child-side ends.
    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
    attr_buf.resize(attr_size);
    attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attr_buf.data());
    HANDLE inherit[2] = {cmd_read, out_write};
    if (!InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size) ||
        !UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherit, sizeof(inherit), nullptr, nullptr)) {
      HostLog("ProcThreadAttributeList (cdp) failed", GetLastError());
      CloseHandle(cmd_read);
      CloseHandle(cmd_write);
      CloseHandle(out_read);
      CloseHandle(out_write);
      return false;
    }
  }

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

  // STARTUPINFOEX only when we have an attribute list (agent control); the
  // non-agent path stays byte-identical (plain STARTUPINFOW, no handle list).
  STARTUPINFOEXW six = {};
  six.StartupInfo.cb = agent_control ? sizeof(six) : sizeof(STARTUPINFOW);
  if (agent_control) six.lpAttributeList = attrs;
  DWORD flags = CREATE_SUSPENDED | CREATE_NO_WINDOW;
  if (agent_control) flags |= EXTENDED_STARTUPINFO_PRESENT;
  PROCESS_INFORMATION pi = {};
  std::vector<wchar_t> cmd_buf(cmd.begin(), cmd.end());
  cmd_buf.push_back(L'\0');
  const BOOL created = CreateProcessW(
      cef_host_exe.c_str(), cmd_buf.data(),
      /*lpProcessAttributes=*/nullptr,
      /*lpThreadAttributes=*/nullptr,
      /*bInheritHandles=*/agent_control ? TRUE : FALSE, flags,
      /*lpEnvironment=*/nullptr,
      /*lpCurrentDirectory=*/nullptr, &six.StartupInfo, &pi);
  if (agent_control) {
    if (attrs) DeleteProcThreadAttributeList(attrs);
    // Regardless of success, the parent never keeps the CHILD-side ends.
    CloseHandle(cmd_read);
    CloseHandle(out_write);
  }
  if (!created) {
    HostLog("CreateProcessW failed", GetLastError());
    if (job_) {
      CloseHandle(job_);
      job_ = nullptr;
    }
    if (agent_control) {
      CloseHandle(cmd_write);
      CloseHandle(out_read);
    }
    return false;
  }
  if (agent_control) {
    // Hand the parent-side ends to the caller (it owns + closes them).
    if (out_cdp_write) *out_cdp_write = cmd_write; else CloseHandle(cmd_write);
    if (out_cdp_read) *out_cdp_read = out_read; else CloseHandle(out_read);
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

bool HostProcess::KillTreeAndWait(unsigned long timeout_ms) {
  if (!job_) {
    // No job (assignment failed): only the host itself can be ended.
    if (!process_) return true;
    TerminateProcess(process_, 9);
    return WaitForSingleObject(process_, timeout_ms) == WAIT_OBJECT_0;
  }
  TerminateJobObject(job_, 9);
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  for (;;) {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {};
    if (!QueryInformationJobObject(job_, JobObjectBasicAccountingInformation,
                                   &info, sizeof(info), nullptr)) {
      return false;
    }
    if (info.ActiveProcesses == 0) return true;
    if (GetTickCount64() >= deadline) return false;
    Sleep(20);
  }
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
