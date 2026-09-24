// pipe_probe — standalone gate test for the Windows cef_host.
//
// Acts as the PLUGIN side of the IPC contract (PROTOCOL.md): creates the
// named pipe server, spawns cef_host.exe against it, then drives one browser
// end to end: kOpReady (version handshake) -> kOpCreateBrowser 1024x768@1.0 ->
// kOpCreated -> first kOpPresent within 20s -> kOpNavigate to a second URL ->
// url/title/loadState events -> kOpShutdown -> clean host exit.
//
// Then a wedged host: a second cef_host loads a page, the probe suspends its
// UI thread and sends kOpShutdown, which that thread never runs. The host's
// hard-exit watchdog has to end it about 6 s later, exit code 0, with its
// "still running after shutdown" line on stderr.
//
// The pages come from a server the probe runs on 127.0.0.1, so a slow network
// can't slow a load or a shutdown down. Each host's stdout and stderr are
// printed after it exits.
//
// No CEF dependency — just Win32, Winsock and cef_host_protocol.h. Build:
//   cmake --build build --target pipe_probe
// Run (hostDir must contain cef_host.exe + cef_host.dll + the CEF runtime):
//   pipe_probe.exe <hostDir> [url1] [url2]
// Exits 0 + prints "PIPE_PROBE PASS" on success; nonzero otherwise.

#include <winsock2.h>
#include <windows.h>

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../cef_host_protocol.h"

#pragma comment(lib, "ws2_32.lib")

using namespace flutter_cef;

namespace {

HANDLE g_pipe = INVALID_HANDLE_VALUE;
ULONGLONG g_t0 = 0;

// The running host's stdout and stderr, collected by a reader thread; printed
// by Fail and after each host.
std::mutex g_host_out_mutex;
std::string g_host_out;
HANDLE g_host_out_done = nullptr;  // set when the host's output pipe closes

double Now() { return (GetTickCount64() - g_t0) / 1000.0; }

void Say(const char* fmt, ...) {
  printf("[%7.3f] ", Now());
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  printf("\n");
  fflush(stdout);
}

// Everything the host has written to stdout and stderr so far.
std::string HostOutput() {
  std::lock_guard<std::mutex> lock(g_host_out_mutex);
  return g_host_out;
}

void PrintHostOutput() {
  const std::string out = HostOutput();
  Say("host stdout+stderr (%zu bytes)%s", out.size(), out.empty() ? "" : ":");
  size_t start = 0;
  while (start < out.size()) {
    size_t end = out.find('\n', start);
    if (end == std::string::npos) end = out.size();
    std::string line = out.substr(start, end - start);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    printf("  [host] %s\n", line.c_str());
    start = end + 1;
  }
  fflush(stdout);
}

[[noreturn]] void Fail(const char* why) {
  PrintHostOutput();
  Say("PIPE_PROBE FAIL: %s", why);
  ExitProcess(1);
}

// ---- The probe's pages, served on 127.0.0.1 ----

std::string PageBody(const std::string& path) {
  if (path == "/one")
    return "<!doctype html><title>pipe_probe one</title>"
           "<body style=\"background:#1f6f5c;color:#fff\">page one</body>";
  if (path == "/two")
    return "<!doctype html><title>pipe_probe two</title>"
           "<body style=\"background:#3b3f8f;color:#fff\">page two</body>";
  return std::string();
}

// One connection: read the request head, answer it, close. Its own thread, so
// a connection Chromium opens ahead of time and never uses can't hold up the
// next.
void ServeConnection(SOCKET c) {
  std::string req;
  char buf[4096];
  while (req.find("\r\n\r\n") == std::string::npos && req.size() < 65536) {
    const int n = recv(c, buf, sizeof(buf), 0);
    if (n <= 0) break;
    req.append(buf, static_cast<size_t>(n));
  }
  // "GET /path HTTP/1.1"
  std::string path;
  const size_t sp1 = req.find(' ');
  const size_t sp2 =
      sp1 == std::string::npos ? std::string::npos : req.find(' ', sp1 + 1);
  if (sp2 != std::string::npos) path = req.substr(sp1 + 1, sp2 - sp1 - 1);
  std::string body = PageBody(path);
  const char* status = "200 OK";
  if (body.empty()) {
    status = "404 Not Found";
    body = "not found";
  }
  const std::string resp =
      std::string("HTTP/1.1 ") + status +
      "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " +
      std::to_string(body.size()) +
      "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body;
  send(c, resp.data(), static_cast<int>(resp.size()), 0);
  shutdown(c, SD_SEND);
  closesocket(c);
}

// Starts the page server on an ephemeral loopback port; returns the port.
int StartPageServer() {
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) Fail("WSAStartup failed");
  SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (listener == INVALID_SOCKET) Fail("socket failed");
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      listen(listener, SOMAXCONN) != 0)
    Fail("bind/listen on 127.0.0.1 failed");
  int len = sizeof(addr);
  if (getsockname(listener, reinterpret_cast<sockaddr*>(&addr), &len) != 0)
    Fail("getsockname failed");
  std::thread([listener] {
    for (;;) {
      SOCKET c = accept(listener, nullptr, nullptr);
      if (c == INVALID_SOCKET) return;
      std::thread(ServeConnection, c).detach();
    }
  }).detach();
  return ntohs(addr.sin_port);
}

// ---- The pipe ----

bool ReadAllPipe(void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    DWORD n = 0;
    if (!ReadFile(g_pipe, p + off, static_cast<DWORD>(len - off), &n, nullptr))
      return false;
    if (n == 0) return false;
    off += n;
  }
  return true;
}

void SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload,
               uint32_t payload_len) {
  uint32_t body_len = 4 + 1 + payload_len;
  std::vector<uint8_t> frame(4 + body_len);
  WriteU32BE(frame.data(), body_len);
  WriteU32BE(frame.data() + 4, browser_id);
  frame[8] = opcode;
  if (payload_len) memcpy(frame.data() + 9, payload, payload_len);
  DWORD written = 0;
  if (!WriteFile(g_pipe, frame.data(), static_cast<DWORD>(frame.size()),
                 &written, nullptr) ||
      written != frame.size())
    Fail("pipe write failed");
}

struct Frame {
  uint32_t wire_id = 0;
  uint8_t op = 0;
  std::vector<uint8_t> payload;
};

bool ReadFrame(Frame* f) {
  uint8_t hdr[4];
  if (!ReadAllPipe(hdr, 4)) return false;
  uint32_t body_len = ReadU32BE(hdr);
  if (body_len < kMinBodyLen || body_len > kMaxBodyLen) Fail("bad bodyLen");
  std::vector<uint8_t> body(body_len);
  if (!ReadAllPipe(body.data(), body_len)) return false;
  f->wire_id = ReadU32BE(body.data());
  f->op = body[4];
  f->payload.assign(body.begin() + 5, body.end());
  return true;
}

std::string PayloadStr(const Frame& f, size_t off = 0) {
  if (f.payload.size() <= off) return std::string();
  return std::string(reinterpret_cast<const char*>(f.payload.data() + off),
                     f.payload.size() - off);
}

const char* OpName(uint8_t op) {
  switch (op) {
    case kOpPresent: return "kOpPresent";
    case kOpReady: return "kOpReady";
    case kOpCursor: return "kOpCursor";
    case kOpLog: return "kOpLog";
    case kOpLoadState: return "kOpLoadState";
    case kOpTitle: return "kOpTitle";
    case kOpUrl: return "kOpUrl";
    case kOpLoadErr: return "kOpLoadErr";
    case kOpConsole: return "kOpConsole";
    case kOpPageStart: return "kOpPageStart";
    case kOpPageFinish: return "kOpPageFinish";
    case kOpProgress: return "kOpProgress";
    case kOpNewWindow: return "kOpNewWindow";
    case kOpCreated: return "kOpCreated";
    case kOpCreateFailed: return "kOpCreateFailed";
    default: return "op?";
  }
}

// ---- A host ----

struct Host {
  HANDLE process = nullptr;
  HANDLE main_thread = nullptr;  // runs CefRunMessageLoop: the UI thread
};

// Creates this run's pipe server, spawns cef_host.exe against it with its
// stdout and stderr on a pipe the probe reads, and waits for it to connect.
Host SpawnHost(const std::string& host_dir, const char* tag) {
  const std::string suffix =
      std::to_string(GetCurrentProcessId()) + "_" + tag;
  std::string pipe_name = "\\\\.\\pipe\\flutter_cef_probe_" + suffix;
  g_pipe = CreateNamedPipeA(
      pipe_name.c_str(), PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 1 << 20, 1 << 20, 0,
      nullptr);
  if (g_pipe == INVALID_HANDLE_VALUE) Fail("CreateNamedPipe failed");
  Say("pipe server up: %s", pipe_name.c_str());

  char tmp[MAX_PATH] = {};
  GetTempPathA(MAX_PATH, tmp);
  const std::string profile =
      std::string(tmp) + "flutter_cef_probe_prof_" + suffix;

  // The host's output pipe. Only its write end is inherited, and only by the
  // host.
  SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};
  HANDLE out_read = nullptr, out_write = nullptr;
  if (!CreatePipe(&out_read, &out_write, &sa, 0) ||
      !SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0))
    Fail("CreatePipe for the host's output failed");
  SIZE_T attr_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
  std::vector<uint8_t> attr_buf(attr_size);
  auto* attrs =
      reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attr_buf.data());
  if (!InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size) ||
      !UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                 &out_write, sizeof(out_write), nullptr,
                                 nullptr))
    Fail("ProcThreadAttributeList failed");
  STARTUPINFOEXA six = {};
  six.StartupInfo.cb = sizeof(six);
  six.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  six.StartupInfo.hStdInput = nullptr;
  six.StartupInfo.hStdOutput = out_write;
  six.StartupInfo.hStdError = out_write;
  six.lpAttributeList = attrs;

  const std::string exe = host_dir + "\\cef_host.exe";
  std::string cmd = "\"" + exe + "\" --ipc=" + pipe_name +
                    " --profile-dir=" + profile + " --ephemeral";
  // (The one transport gotcha lives host-side: the pipe must be used with
  // OVERLAPPED I/O — a synchronous handle serializes read/write on the file
  // object, which deadlocked SendFrame against the host's blocking reader and
  // froze the CEF UI thread; see cef_host_win.cc OverlappedIo.)
  PROCESS_INFORMATION pi = {};
  const BOOL created = CreateProcessA(
      exe.c_str(), &cmd[0], nullptr, nullptr, TRUE,
      EXTENDED_STARTUPINFO_PRESENT, nullptr, host_dir.c_str(),
      &six.StartupInfo, &pi);
  DeleteProcThreadAttributeList(attrs);
  CloseHandle(out_write);
  if (!created) Fail("CreateProcess(cef_host.exe) failed");
  Say("spawned cef_host.exe pid=%lu", pi.dwProcessId);

  {
    std::lock_guard<std::mutex> lock(g_host_out_mutex);
    g_host_out.clear();
  }
  g_host_out_done = CreateEventA(nullptr, TRUE, FALSE, nullptr);
  std::thread([out_read, done = g_host_out_done] {
    char buf[4096];
    DWORD n = 0;
    while (ReadFile(out_read, buf, sizeof(buf), &n, nullptr) && n > 0) {
      std::lock_guard<std::mutex> lock(g_host_out_mutex);
      g_host_out.append(buf, n);
    }
    CloseHandle(out_read);
    SetEvent(done);
  }).detach();

  if (!ConnectNamedPipe(g_pipe, nullptr) &&
      GetLastError() != ERROR_PIPE_CONNECTED)
    Fail("ConnectNamedPipe failed");
  Say("host connected to pipe");
  return Host{pi.hProcess, pi.hThread};
}

// After the host has exited: waits (briefly) for the last of its output, then
// prints it.
void FinishHostOutput() {
  if (WaitForSingleObject(g_host_out_done, 5000) != WAIT_OBJECT_0)
    Say("the host's output pipe is still open 5s after it exited");
  PrintHostOutput();
}

void SendCreate(uint32_t wire, const std::string& url) {
  // kOpCreateBrowser: {u32 w}{u32 h}{f64 dpr}{utf8 url}.
  std::vector<uint8_t> p(16 + url.size());
  WriteU32BE(p.data(), 1024);
  WriteU32BE(p.data() + 4, 768);
  WriteF64BE(p.data() + 8, 1.0);
  memcpy(p.data() + 16, url.data(), url.size());
  SendFrame(wire, kOpCreateBrowser, p.data(), static_cast<uint32_t>(p.size()));
  Say("-> kOpCreateBrowser wire=%u 1024x768@1.0 url=%s", wire, url.c_str());
}

void CheckReady(const Frame& f) {
  if (f.payload.size() < 2) Fail("kOpReady payload too short");
  uint8_t flags = f.payload[0], ver = f.payload[1];
  Say("<- kOpReady flags=%u protocolVersion=%u", flags, ver);
  if (ver != kCefHostProtocolVersion) Fail("protocol version mismatch");
}

// Reads frames until the host closes the pipe, so its writes never block.
void DrainToEof() {
  Frame f;
  while (ReadFrame(&f)) {
    if (f.op == kOpLog) Say("<- kOpLog %s", PayloadStr(f).c_str());
  }
  Say("pipe EOF");
  CloseHandle(g_pipe);
  g_pipe = INVALID_HANDLE_VALUE;
}

// Waits up to `timeout_ms` for the host to exit; its exit code.
DWORD AwaitExit(const Host& host, DWORD timeout_ms, const char* what) {
  if (WaitForSingleObject(host.process, timeout_ms) != WAIT_OBJECT_0) {
    TerminateProcess(host.process, 9);
    Fail(what);
  }
  DWORD exit_code = 0;
  GetExitCodeProcess(host.process, &exit_code);
  return exit_code;
}

constexpr char kHardExitLine[] = "still running after shutdown";

// The gate: create, first frame, a navigation, a clean shutdown.
void RunGate(const std::string& host_dir, const std::string& url1,
             const std::string& url2) {
  Host host = SpawnHost(host_dir, "gate");
  const uint32_t kWire = 1;
  bool got_ready = false, got_created = false, got_present = false;
  bool page1_settled = false, sent_navigate = false;
  bool nav_url_seen = false, nav_title_seen = false, nav_loaded = false;
  bool loadstate_seen = false;
  double t_create = 0;
  int presents = 0;

  Frame f;
  while (ReadFrame(&f)) {
    switch (f.op) {
      case kOpReady:
        CheckReady(f);
        got_ready = true;
        SendCreate(kWire, url1);
        t_create = Now();
        break;
      case kOpCreated:
        Say("<- kOpCreated wire=%u", f.wire_id);
        got_created = true;
        break;
      case kOpCreateFailed:
        Fail("kOpCreateFailed");
        break;
      case kOpPresent: {
        if (f.payload.size() < 16) Fail("kOpPresent payload != 16 bytes");
        uint64_t handle = ReadU64BE(f.payload.data());
        uint32_t sw = ReadU32BE(f.payload.data() + 8);
        uint32_t sh = ReadU32BE(f.payload.data() + 12);
        presents++;
        if (!got_present) {
          got_present = true;
          double dt = Now() - t_create;
          Say("<- kOpPresent #1 wire=%u bridgeHandle=0x%llx src=%ux%u "
              "(%.3fs after create)",
              f.wire_id, static_cast<unsigned long long>(handle), sw, sh, dt);
          if (!got_created) Fail("present before created");
          if (dt > 20.0) Fail("first present later than 20s");
          // Page settled before the first frame landed: drive the navigate
          // leg now (the other ordering triggers it from kOpLoadState).
          if (page1_settled && !sent_navigate) {
            sent_navigate = true;
            SendFrame(kWire, kOpNavigate, url2.data(),
                      static_cast<uint32_t>(url2.size()));
            Say("-> kOpNavigate wire=%u url=%s", kWire, url2.c_str());
          }
        } else if (presents <= 5 || presents % 60 == 0) {
          Say("<- kOpPresent #%d bridgeHandle=0x%llx src=%ux%u", presents,
              static_cast<unsigned long long>(handle), sw, sh);
        }
        break;
      }
      case kOpLoadState: {
        if (f.payload.size() < 3) break;
        bool loading = f.payload[0] != 0;
        Say("<- kOpLoadState loading=%d canGoBack=%d canGoForward=%d",
            f.payload[0], f.payload[1], f.payload[2]);
        loadstate_seen = true;
        if (!loading) page1_settled = true;
        // First page settled + first frame present -> drive the navigate leg.
        if (!loading && got_present && !sent_navigate) {
          sent_navigate = true;
          SendFrame(kWire, kOpNavigate, url2.data(),
                    static_cast<uint32_t>(url2.size()));
          Say("-> kOpNavigate wire=%u url=%s", kWire, url2.c_str());
        }
        if (!loading && sent_navigate && nav_url_seen) nav_loaded = true;
        break;
      }
      case kOpUrl: {
        std::string url = PayloadStr(f);
        Say("<- kOpUrl %s", url.c_str());
        if (sent_navigate && url.compare(0, url2.size(), url2) == 0)
          nav_url_seen = true;
        break;
      }
      case kOpTitle: {
        std::string title = PayloadStr(f);
        Say("<- kOpTitle \"%s\"", title.c_str());
        if (sent_navigate && !title.empty()) nav_title_seen = true;
        break;
      }
      case kOpPageStart:
        Say("<- kOpPageStart %s", PayloadStr(f).c_str());
        break;
      case kOpPageFinish:
        Say("<- kOpPageFinish %s", PayloadStr(f).c_str());
        break;
      case kOpProgress:
        if (f.payload.size() >= 4)
          Say("<- kOpProgress %u%%", ReadU32BE(f.payload.data()));
        break;
      case kOpCursor:
        if (f.payload.size() >= 4)
          Say("<- kOpCursor %u", ReadU32BE(f.payload.data()));
        break;
      case kOpLog:
        Say("<- kOpLog(wire=%u) %s", f.wire_id, PayloadStr(f).c_str());
        break;
      case kOpLoadErr:
        Say("<- kOpLoadErr code=%u %s",
            f.payload.size() >= 4 ? ReadU32BE(f.payload.data()) : 0,
            PayloadStr(f, 4).c_str());
        break;
      case kOpConsole:
        Say("<- kOpConsole %s", PayloadStr(f, 4).c_str());
        break;
      default:
        Say("<- %s (0x%02x) wire=%u plen=%zu", OpName(f.op), f.op, f.wire_id,
            f.payload.size());
        break;
    }
    // Success condition: navigate leg fully observed.
    if (nav_url_seen && nav_title_seen && nav_loaded) break;
  }

  if (!(got_ready && got_created && got_present && nav_url_seen &&
        nav_title_seen && nav_loaded && loadstate_seen))
    Fail("pipe closed before all gate conditions were met");

  Say("all gate conditions met (ready/created/present/url/title/loadState); "
      "presents so far=%d",
      presents);
  SendFrame(0, kOpShutdown, nullptr, 0);
  Say("-> kOpShutdown");
  DrainToEof();
  // Longer than the host's own teardown allowance (30 s), so a slow
  // CefShutdown is reported as the watchdog's exit, not as a hang here.
  const DWORD exit_code =
      AwaitExit(host, 40000, "host did not exit within 40s of shutdown");
  Say("host exited code=%lu", exit_code);
  FinishHostOutput();
  if (exit_code != 0) Fail("host exit code != 0");
  if (HostOutput().find(kHardExitLine) != std::string::npos)
    Fail("the host's hard-exit watchdog ended it: shutdown didn't finish");
  CloseHandle(host.main_thread);
  CloseHandle(host.process);
}

// A host whose UI thread is wedged when kOpShutdown arrives exits on its own.
void RunWedgedShutdown(const std::string& host_dir, const std::string& url) {
  Say("== a host whose UI thread is wedged at shutdown");
  Host host = SpawnHost(host_dir, "wedge");
  const uint32_t kWire = 1;
  bool presented = false, settled = false;
  Frame f;
  while (!(presented && settled)) {
    if (!ReadFrame(&f)) Fail("pipe closed before the page loaded");
    switch (f.op) {
      case kOpReady:
        CheckReady(f);
        SendCreate(kWire, url);
        break;
      case kOpCreateFailed:
        Fail("kOpCreateFailed");
        break;
      case kOpPresent:
        presented = true;
        break;
      case kOpLoadState:
        if (f.payload.size() >= 1 && f.payload[0] == 0) settled = true;
        break;
      case kOpLog:
        Say("<- kOpLog(wire=%u) %s", f.wire_id, PayloadStr(f).c_str());
        break;
      default:
        break;
    }
  }
  Say("page loaded and painted");
  // Let the load's last tasks run, so the UI thread is suspended idle rather
  // than inside something the watchdog thread might need.
  Sleep(500);
  if (SuspendThread(host.main_thread) == static_cast<DWORD>(-1))
    Fail("SuspendThread failed");
  Say("suspended the host's UI thread");
  SendFrame(0, kOpShutdown, nullptr, 0);
  const double t_shutdown = Now();
  Say("-> kOpShutdown");
  DrainToEof();
  const DWORD exit_code = AwaitExit(
      host, 20000, "a host with a wedged UI thread did not exit within 20s");
  const double took = Now() - t_shutdown;
  Say("host exited code=%lu, %.3fs after kOpShutdown", exit_code, took);
  FinishHostOutput();
  const std::string want =
      std::string("[cef_host] ") + kHardExitLine + " (kOpShutdown); exiting now";
  if (HostOutput().find(want) == std::string::npos)
    Fail("no hard-exit line from the host");
  if (exit_code != 0) Fail("host exit code != 0");
  // 6 s after the host read kOpShutdown, give or take the clocks' ticks.
  if (took < 5.0 || took > 15.0) Fail("the hard exit wasn't about 6s late");
  CloseHandle(host.main_thread);
  CloseHandle(host.process);
}

}  // namespace

int main(int argc, char** argv) {
  g_t0 = GetTickCount64();
  if (argc < 2) {
    fprintf(stderr,
            "usage: pipe_probe.exe <hostDir with cef_host.exe> [url1] [url2]\n");
    return 2;
  }
  std::string host_dir = argv[1];

  // Global watchdog: nothing in this probe may take 3 minutes.
  std::thread([] {
    Sleep(180000);
    printf("PIPE_PROBE FAIL: global watchdog (180s)\n");
    ExitProcess(3);
  }).detach();

  const std::string origin =
      "http://127.0.0.1:" + std::to_string(StartPageServer());
  Say("serving the probe's pages at %s", origin.c_str());
  const std::string url1 = argc > 2 ? argv[2] : origin + "/one";
  const std::string url2 = argc > 3 ? argv[3] : origin + "/two";

  RunGate(host_dir, url1, url2);
  RunWedgedShutdown(host_dir, url1);
  Say("PIPE_PROBE PASS");
  return 0;
}
