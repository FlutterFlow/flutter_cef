// IpcPipe — the plugin (server) side of the cef_host named-pipe IPC.
//
// Framing/opcodes: ../native/cef_host/PROTOCOL.md §1/§2 and the shared
// constants header ../native/cef_host/cef_host_protocol.h.
//
//  - Name: \\.\pipe\flutter_cef_<128-bit CSPRNG hex> (NextPipeName()). The
//    unguessable name + FILE_FLAG_FIRST_PIPE_INSTANCE close the squat race
//    (PLAN §4.2/§7.6): a predictable pid_counter name let a same-user process
//    pre-create the pipe before cef_host connected.
//  - Server: CreateNamedPipeW(PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
//    FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE |
//    PIPE_REJECT_REMOTE_CLIENTS, 1 instance) with a PROTECTED DACL granting
//    only the current-user SID, created BEFORE spawning cef_host so the child's
//    CreateFileW connects first try. Creation aborts on ERROR_ACCESS_DENIED /
//    ERROR_PIPE_BUSY (the name already exists — squat/collision).
//  - OVERLAPPED I/O is REQUIRED, not an optimization (found empirically by
//    the harness): on a synchronous handle the I/O manager serializes ALL
//    operations on the file object, so a reader thread parked in a blocking
//    ReadFile blocks every SendFrame WriteFile on the same handle until an
//    inbound frame happens to arrive. Each operation here uses its own
//    OVERLAPPED + event and waits for completion, so reads and writes
//    overlap freely (the macOS socketpair semantics).
//  - The reader thread does the ConnectNamedPipe itself, so creating a
//    session never blocks the platform thread on child startup.
//  - Framing: [u32 bodyLen BE][u32 browserId BE][u8 op][payload], bodyLen =
//    4+1+payloadLen, guard 5..64 MiB (kMinBodyLen/kMaxBodyLen). Outbound
//    frames are assembled contiguously and written whole under a write mutex
//    (mirror main.mm SendFrame:420-446).
//  - The FrameHandler/DisconnectHandler run on the READER thread; the caller
//    must marshal to the platform thread before touching the MethodChannel.
//  - Teardown (Close): signal the stop event + CancelIoEx, bounded join. If
//    the reader will not stop, Close returns false and the caller must LEAK
//    this object (unique_ptr::release) — never free state a blocked reader
//    may still touch (CefProfileHost.swift:999-1002 rule).
//
// NOTE: deliberately flutter-free (windows.h + protocol header only) so it
// can be exercised by a standalone harness without an engine.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_IPC_PIPE_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_IPC_PIPE_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace flutter_cef {

class IpcPipe {
 public:
  // Called on the READER thread for every decoded inbound frame.
  using FrameHandler = std::function<void(uint32_t browser_id, uint8_t opcode,
                                          std::vector<uint8_t> payload)>;
  // Called ONCE on the READER thread when the stream ends for any reason
  // other than Close(): EOF (host exited), read error, desync guard, or a
  // ConnectNamedPipe failure. NOT called when Close() stops the reader.
  using DisconnectHandler = std::function<void()>;

  IpcPipe();
  ~IpcPipe();

  IpcPipe(const IpcPipe&) = delete;
  IpcPipe& operator=(const IpcPipe&) = delete;

  // Mints the next unique pipe name: \\.\pipe\flutter_cef_<pid>_<counter>.
  static std::wstring NextPipeName();

  // Creates the single-instance overlapped byte-stream pipe server (and the
  // completion/stop events). False on failure.
  bool Create(const std::wstring& pipe_name);

  // Starts the reader thread: overlapped ConnectNamedPipe (waits on
  // {stop, connect}), then the frame decode loop invoking `handler` per
  // frame until EOF/error/stop, then `on_disconnect` (unless Close()
  // initiated the stop).
  bool StartReader(FrameHandler handler, DisconnectHandler on_disconnect);

  // Frames + writes atomically (thread-safe; overlapped write awaited to
  // completion under the write mutex). False if not connected or the write
  // failed.
  bool SendFrame(uint32_t browser_id, uint8_t opcode, const uint8_t* payload,
                 uint32_t payload_len);

  // Stops the reader (stop event + CancelIoEx + bounded join) and closes the
  // pipe/events. Returns true when fully torn down; false when the reader
  // could not be stopped — the caller MUST then leak this object
  // (release()), because the wedged reader still references it.
  bool Close();

  bool connected() const { return connected_.load(); }
  const std::wstring& pipe_name() const { return pipe_name_; }

 private:
  void ReaderMain(FrameHandler handler, DisconnectHandler on_disconnect);
  // Overlapped read of exactly `len` bytes; false on EOF/error/stop.
  bool ReadFull(void* buf, size_t len);

  std::wstring pipe_name_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  HANDLE stop_event_ = nullptr;   // manual-reset: Close() -> reader unblocks
  HANDLE read_event_ = nullptr;   // reader-thread OVERLAPPED completions
  HANDLE write_event_ = nullptr;  // write OVERLAPPED completions (write mutex)
  std::thread reader_;
  std::mutex write_mutex_;
  std::atomic<bool> connected_{false};
  std::atomic<bool> closing_{false};
  std::atomic<bool> reader_done_{false};
};

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_IPC_PIPE_H_
