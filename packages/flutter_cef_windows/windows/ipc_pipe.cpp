#include "ipc_pipe.h"

#include <bcrypt.h>
#include <sddl.h>

#include <atomic>
#include <cstring>
#include <iomanip>
#include <sstream>
#include <vector>

#include "cef_host_protocol.h"

// PLAN §4.2/§7.6 pipe hardening needs a CSPRNG (BCryptGenRandom) and the token/
// SID/SDDL APIs. Neither bcrypt.lib nor advapi32.lib is on this plugin's CMake
// link line and that file is owned elsewhere — pull them in from the TU so the
// build stays self-contained.
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")

namespace flutter_cef {

namespace {

std::atomic<uint32_t> g_pipe_counter{0};

void PipeLog(const char* msg) {
  std::string s = "[flutter_cef_windows] IpcPipe: ";
  s += msg;
  s += "\n";
  OutputDebugStringA(s.c_str());
}

// Builds a self-relative security descriptor whose DACL is PROTECTED and grants
// GENERIC_ALL to ONLY the current user's SID (PLAN §7.6). PROTECTED (SDDL "P")
// blocks inherited ACEs, so nothing a squatter controls can widen access. On
// success *out_sd is a LocalAlloc'd descriptor the caller must LocalFree.
bool BuildCurrentUserOnlySD(PSECURITY_DESCRIPTOR* out_sd) {
  *out_sd = nullptr;
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD len = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &len);  // size probe
  if (len == 0) {
    CloseHandle(token);
    return false;
  }
  std::vector<uint8_t> buf(len);
  const bool got =
      GetTokenInformation(token, TokenUser, buf.data(), len, &len) != FALSE;
  CloseHandle(token);
  if (!got) return false;
  auto* tu = reinterpret_cast<TOKEN_USER*>(buf.data());
  LPWSTR sid_str = nullptr;
  if (!ConvertSidToStringSidW(tu->User.Sid, &sid_str)) return false;
  // D:  DACL present
  // P   PROTECTED — no ACEs inherited from any parent object
  // (A;;GA;;;<SID>)  ALLOW GENERIC_ALL to the current user's SID only
  std::wstring sddl = std::wstring(L"D:P(A;;GA;;;") + sid_str + L")";
  LocalFree(sid_str);
  return ConvertStringSecurityDescriptorToSecurityDescriptorW(
             sddl.c_str(), SDDL_REVISION_1, out_sd, nullptr) != FALSE;
}

}  // namespace

IpcPipe::IpcPipe() = default;

IpcPipe::~IpcPipe() {
  // If Close() fails the reader is wedged; the OWNER was supposed to leak us
  // via release() after a false Close(). Reaching this dtor with a wedged
  // reader means that contract was ignored — Close() already left the
  // handles open in that case, so at least nothing is freed under the
  // reader here.
  Close();
}

// static
std::wstring IpcPipe::NextPipeName() {
  // 128-bit CSPRNG name (PLAN §4.2/§7.6): a predictable pid_counter name lets a
  // same-user process pre-create (squat) the pipe before cef_host connects. An
  // unguessable name closes the race window entirely.
  uint8_t rnd[16] = {};
  if (BCryptGenRandom(nullptr, rnd, sizeof(rnd),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    // BCryptGenRandom effectively never fails, but never emit a predictable
    // name: mix pid + high-res tick + a monotonic counter + a stack address as
    // a defensive backstop rather than fall back to a guessable pattern.
    const uint64_t a = (static_cast<uint64_t>(GetCurrentProcessId()) << 32) ^
                       GetTickCount64();
    const uint64_t b =
        (static_cast<uint64_t>(g_pipe_counter.fetch_add(1)) << 32) ^
        static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&rnd));
    std::memcpy(rnd, &a, sizeof(a));
    std::memcpy(rnd + 8, &b, sizeof(b));
  }
  std::wostringstream name;
  name << L"\\\\.\\pipe\\flutter_cef_" << std::hex << std::setfill(L'0');
  for (uint8_t byte : rnd) name << std::setw(2) << static_cast<unsigned>(byte);
  return name.str();
}

bool IpcPipe::Create(const std::wstring& pipe_name) {
  pipe_name_ = pipe_name;
  // Explicit protected DACL granting ONLY the current user (PLAN §7.6): the
  // default named-pipe DACL is broader than we want, and an anonymous descriptor
  // gives no guarantee. Refuse to create an unsecured pipe.
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!BuildCurrentUserOnlySD(&sd)) {
    PipeLog("failed to build current-user DACL — refusing to create pipe");
    return false;
  }
  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);
  sa.lpSecurityDescriptor = sd;
  sa.bInheritHandle = FALSE;
  // FILE_FLAG_OVERLAPPED is load-bearing: without it a reader parked in a
  // blocking ReadFile serializes (and thus blocks) every WriteFile on the
  // same handle — see the header comment.
  // FILE_FLAG_FIRST_PIPE_INSTANCE: creation FAILS (never silently attaches) if
  // any instance of this exact name already exists — the anti-squat guarantee.
  pipe_ = CreateNamedPipeW(
      pipe_name.c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
          FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      /*nMaxInstances=*/1, /*nOutBufferSize=*/64 * 1024,
      /*nInBufferSize=*/64 * 1024, /*nDefaultTimeOut=*/0,
      /*lpSecurityAttributes=*/&sa);
  const DWORD gle = GetLastError();  // capture before LocalFree resets it
  LocalFree(sd);
  if (pipe_ == INVALID_HANDLE_VALUE) {
    // ERROR_ACCESS_DENIED / ERROR_PIPE_BUSY here mean the name already exists
    // (squatter or collision) — abort, never adopt someone else's pipe.
    if (gle == ERROR_ACCESS_DENIED || gle == ERROR_PIPE_BUSY)
      PipeLog("pipe name already in use (squat/collision) — aborting");
    else
      PipeLog("CreateNamedPipeW failed");
    return false;
  }
  stop_event_ = CreateEventW(nullptr, /*bManualReset=*/TRUE, FALSE, nullptr);
  read_event_ = CreateEventW(nullptr, /*bManualReset=*/TRUE, FALSE, nullptr);
  write_event_ = CreateEventW(nullptr, /*bManualReset=*/TRUE, FALSE, nullptr);
  if (!stop_event_ || !read_event_ || !write_event_) {
    PipeLog("CreateEventW failed");
    Close();
    return false;
  }
  return true;
}

bool IpcPipe::StartReader(FrameHandler handler,
                          DisconnectHandler on_disconnect) {
  if (pipe_ == INVALID_HANDLE_VALUE || reader_.joinable()) return false;
  reader_done_.store(false);
  reader_ = std::thread([this, h = std::move(handler),
                         d = std::move(on_disconnect)]() mutable {
    ReaderMain(std::move(h), std::move(d));
    reader_done_.store(true);
  });
  return true;
}

void IpcPipe::ReaderMain(FrameHandler handler,
                         DisconnectHandler on_disconnect) {
  // Overlapped wait for cef_host's CreateFileW; Close() aborts it via the
  // stop event (+ CancelIoEx).
  {
    OVERLAPPED ov = {};
    ov.hEvent = read_event_;
    ResetEvent(read_event_);
    BOOL ok = ConnectNamedPipe(pipe_, &ov);
    DWORD err = ok ? ERROR_SUCCESS : GetLastError();
    if (!ok && err == ERROR_IO_PENDING) {
      HANDLE waits[2] = {stop_event_, read_event_};
      const DWORD which = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
      if (which == WAIT_OBJECT_0) {  // stop
        CancelIoEx(pipe_, &ov);
        DWORD n = 0;
        GetOverlappedResult(pipe_, &ov, &n, TRUE);  // drain the IRP
        return;
      }
      DWORD n = 0;
      if (!GetOverlappedResult(pipe_, &ov, &n, FALSE)) {
        if (!closing_.load() && on_disconnect) on_disconnect();
        return;
      }
    } else if (!ok && err != ERROR_PIPE_CONNECTED) {
      PipeLog("ConnectNamedPipe failed");
      if (!closing_.load() && on_disconnect) on_disconnect();
      return;
    }
  }
  connected_.store(true);

  std::vector<uint8_t> body;
  for (;;) {
    uint8_t hdr[4];
    if (!ReadFull(hdr, sizeof(hdr))) break;
    const uint32_t body_len = ReadU32BE(hdr);
    if (body_len < kMinBodyLen || body_len > kMaxBodyLen) {
      // Desynced stream: unrecoverable, tear the whole transport down
      // (main.mm:2343-2351 rule).
      PipeLog("bodyLen out of range — stream desynced, closing");
      break;
    }
    body.resize(body_len);
    if (!ReadFull(body.data(), body_len)) break;
    if (closing_.load()) break;
    const uint32_t browser_id = ReadU32BE(body.data());
    const uint8_t opcode = body[4];
    std::vector<uint8_t> payload(body.begin() + 5, body.end());
    handler(browser_id, opcode, std::move(payload));
  }
  if (!closing_.load() && on_disconnect) on_disconnect();
}

bool IpcPipe::ReadFull(void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    OVERLAPPED ov = {};
    ov.hEvent = read_event_;
    ResetEvent(read_event_);
    BOOL ok = ReadFile(pipe_, p + off, static_cast<DWORD>(len - off),
                       /*lpNumberOfBytesRead=*/nullptr, &ov);
    if (!ok) {
      const DWORD err = GetLastError();
      if (err != ERROR_IO_PENDING) return false;  // broken pipe / error
      HANDLE waits[2] = {stop_event_, read_event_};
      const DWORD which = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
      if (which == WAIT_OBJECT_0) {  // stop
        CancelIoEx(pipe_, &ov);
        DWORD n = 0;
        GetOverlappedResult(pipe_, &ov, &n, TRUE);  // drain the IRP
        return false;
      }
    }
    DWORD n = 0;
    if (!GetOverlappedResult(pipe_, &ov, &n, TRUE)) return false;
    if (n == 0) return false;  // peer closed
    off += n;
  }
  return true;
}

bool IpcPipe::SendFrame(uint32_t browser_id, uint8_t opcode,
                        const uint8_t* payload, uint32_t payload_len) {
  if (pipe_ == INVALID_HANDLE_VALUE || !connected_.load() || closing_.load())
    return false;
  if (payload_len > kMaxBodyLen - 5) return false;
  const uint32_t body_len = 5 + payload_len;
  std::vector<uint8_t> frame(static_cast<size_t>(4) + body_len);
  WriteU32BE(frame.data(), body_len);
  WriteU32BE(frame.data() + 4, browser_id);
  frame[8] = opcode;
  if (payload_len > 0) memcpy(frame.data() + 9, payload, payload_len);

  // One contiguous logical write under the mutex so a partial/interleaved
  // write can never desync the peer (main.mm:431-445). Overlapped + awaited
  // to completion — independent of the reader's parked read.
  std::lock_guard<std::mutex> lock(write_mutex_);
  size_t off = 0;
  while (off < frame.size()) {
    OVERLAPPED ov = {};
    ov.hEvent = write_event_;
    ResetEvent(write_event_);
    BOOL ok = WriteFile(pipe_, frame.data() + off,
                        static_cast<DWORD>(frame.size() - off),
                        /*lpNumberOfBytesWritten=*/nullptr, &ov);
    if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
    DWORD n = 0;
    if (!GetOverlappedResult(pipe_, &ov, &n, TRUE)) return false;
    if (n == 0) return false;
    off += n;
  }
  return true;
}

bool IpcPipe::Close() {
  closing_.store(true);
  if (reader_.joinable()) {
    // Unblock the reader: signal stop (covers the WaitForMultipleObjects
    // states) and cancel any pending IRP on the handle (covers the moment
    // between issuing the I/O and waiting). Repeat until it exits or the
    // deadline passes.
    const ULONGLONG deadline = GetTickCount64() + 2000;
    while (!reader_done_.load() && GetTickCount64() < deadline) {
      if (stop_event_) SetEvent(stop_event_);
      CancelIoEx(pipe_, nullptr);
      Sleep(20);
    }
    if (!reader_done_.load()) {
      // Wedged reader: NEVER free what it may still touch — leak the pipe +
      // events, and tell the owner to leak this whole object.
      PipeLog("reader did not stop in 2s — leaking pipe (by design)");
      reader_.detach();
      return false;
    }
    reader_.join();
  }
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
  for (HANDLE* ev : {&stop_event_, &read_event_, &write_event_}) {
    if (*ev) {
      CloseHandle(*ev);
      *ev = nullptr;
    }
  }
  return true;
}

}  // namespace flutter_cef
