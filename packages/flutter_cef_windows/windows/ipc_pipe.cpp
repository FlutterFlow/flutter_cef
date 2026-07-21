#include "ipc_pipe.h"

#include <atomic>
#include <sstream>

#include "cef_host_protocol.h"

namespace flutter_cef {

namespace {

std::atomic<uint32_t> g_pipe_counter{0};

void PipeLog(const char* msg) {
  std::string s = "[flutter_cef_windows] IpcPipe: ";
  s += msg;
  s += "\n";
  OutputDebugStringA(s.c_str());
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
  std::wostringstream name;
  name << L"\\\\.\\pipe\\flutter_cef_" << GetCurrentProcessId() << L"_"
       << g_pipe_counter.fetch_add(1);
  return name.str();
}

bool IpcPipe::Create(const std::wstring& pipe_name) {
  pipe_name_ = pipe_name;
  // FILE_FLAG_OVERLAPPED is load-bearing: without it a reader parked in a
  // blocking ReadFile serializes (and thus blocks) every WriteFile on the
  // same handle — see the header comment.
  pipe_ = CreateNamedPipeW(
      pipe_name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      /*nMaxInstances=*/1, /*nOutBufferSize=*/64 * 1024,
      /*nInBufferSize=*/64 * 1024, /*nDefaultTimeOut=*/0,
      /*lpSecurityAttributes=*/nullptr);
  if (pipe_ == INVALID_HANDLE_VALUE) {
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
