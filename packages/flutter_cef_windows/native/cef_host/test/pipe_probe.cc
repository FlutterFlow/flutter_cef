// pipe_probe — standalone gate test for the Windows cef_host.
//
// Acts as the PLUGIN side of the IPC contract (PROTOCOL.md): creates the
// named pipe server, spawns cef_host.exe against it, then drives the slice
// vertical: kOpReady (v3 handshake) -> kOpCreateBrowser 1024x768@1.0 ->
// kOpCreated -> first kOpPresent within 20s -> kOpNavigate to a second URL ->
// url/title/loadState events -> kOpShutdown -> clean host exit.
//
// No CEF dependency — just Win32 + cef_host_protocol.h. Build:
//   cmake --build build --target pipe_probe
// Run (hostDir must contain cef_host.exe + cef_host.dll + the CEF runtime):
//   pipe_probe.exe <hostDir> [url1] [url2]
// Exits 0 + prints "PIPE_PROBE PASS" on success; nonzero otherwise.

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "../cef_host_protocol.h"

using namespace flutter_cef;

namespace {

HANDLE g_pipe = INVALID_HANDLE_VALUE;
ULONGLONG g_t0 = 0;

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

[[noreturn]] void Fail(const char* why) {
  Say("PIPE_PROBE FAIL: %s", why);
  ExitProcess(1);
}

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

}  // namespace

int main(int argc, char** argv) {
  g_t0 = GetTickCount64();
  if (argc < 2) {
    fprintf(stderr,
            "usage: pipe_probe.exe <hostDir with cef_host.exe> [url1] [url2]\n");
    return 2;
  }
  std::string host_dir = argv[1];
  std::string url1 = argc > 2 ? argv[2] : "https://example.com/";
  std::string url2 =
      argc > 3 ? argv[3] : "https://www.iana.org/help/example-domains";

  // Global watchdog: nothing in this probe may take 3 minutes.
  std::thread([] {
    Sleep(180000);
    printf("PIPE_PROBE FAIL: global watchdog (180s)\n");
    ExitProcess(3);
  }).detach();

  // 1. Pipe server (the plugin's role): byte-stream, single instance.
  std::string pipe_name =
      "\\\\.\\pipe\\flutter_cef_probe_" + std::to_string(GetCurrentProcessId());
  g_pipe = CreateNamedPipeA(
      pipe_name.c_str(), PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 1 << 20, 1 << 20, 0,
      nullptr);
  if (g_pipe == INVALID_HANDLE_VALUE) Fail("CreateNamedPipe failed");
  Say("pipe server up: %s", pipe_name.c_str());

  // 2. Spawn cef_host.exe --ipc=... --profile-dir=... --ephemeral.
  char tmp[MAX_PATH] = {};
  GetTempPathA(MAX_PATH, tmp);
  std::string profile = std::string(tmp) + "flutter_cef_probe_prof_" +
                        std::to_string(GetCurrentProcessId());
  std::string exe = host_dir + "\\cef_host.exe";
  std::string cmd = "\"" + exe + "\" --ipc=" + pipe_name +
                    " --profile-dir=" + profile + " --ephemeral";
  // Plain spawn, no handle inheritance needed. (The one transport gotcha
  // lives host-side: the pipe must be used with OVERLAPPED I/O — a
  // synchronous handle serializes read/write on the file object, which
  // deadlocked SendFrame against the host's blocking reader and froze the
  // CEF UI thread; see cef_host_win.cc OverlappedIo.)
  STARTUPINFOA si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (!CreateProcessA(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0,
                      nullptr, host_dir.c_str(), &si, &pi))
    Fail("CreateProcess(cef_host.exe) failed");
  CloseHandle(pi.hThread);
  Say("spawned cef_host.exe pid=%lu", pi.dwProcessId);

  // 3. Wait for the host to connect.
  if (!ConnectNamedPipe(g_pipe, nullptr) &&
      GetLastError() != ERROR_PIPE_CONNECTED)
    Fail("ConnectNamedPipe failed");
  Say("host connected to pipe");

  // ---- Event pump / assertions ----
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
      case kOpReady: {
        if (f.payload.size() < 2) Fail("kOpReady payload too short");
        uint8_t flags = f.payload[0], ver = f.payload[1];
        Say("<- kOpReady flags=%u protocolVersion=%u", flags, ver);
        if (ver != kCefHostProtocolVersion) Fail("protocol version mismatch");
        got_ready = true;
        // kOpCreateBrowser wire=1: {u32 w}{u32 h}{f64 dpr}{utf8 url}.
        std::vector<uint8_t> p(16 + url1.size());
        WriteU32BE(p.data(), 1024);
        WriteU32BE(p.data() + 4, 768);
        WriteF64BE(p.data() + 8, 1.0);
        memcpy(p.data() + 16, url1.data(), url1.size());
        SendFrame(kWire, kOpCreateBrowser, p.data(),
                  static_cast<uint32_t>(p.size()));
        t_create = Now();
        Say("-> kOpCreateBrowser wire=%u 1024x768@1.0 url=%s", kWire,
            url1.c_str());
        break;
      }
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
        if (sent_navigate && url.find(url2.substr(0, url2.find('/', 8))) !=
                                 std::string::npos)
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

  // Drain until EOF so the host's writes never block, then await exit.
  while (ReadFrame(&f)) {
    if (f.op == kOpLog) Say("<- kOpLog %s", PayloadStr(f).c_str());
  }
  Say("pipe EOF");
  DWORD wait = WaitForSingleObject(pi.hProcess, 20000);
  if (wait != WAIT_OBJECT_0) {
    TerminateProcess(pi.hProcess, 9);
    Fail("host did not exit within 20s of shutdown");
  }
  DWORD exit_code = 0;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  CloseHandle(pi.hProcess);
  Say("host exited code=%lu", exit_code);
  if (exit_code != 0) Fail("host exit code != 0");
  Say("PIPE_PROBE PASS");
  return 0;
}
