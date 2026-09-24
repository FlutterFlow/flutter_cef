// cef_host — a standalone CEF off-screen-rendering subprocess.
//
// The Flutter host (the flutter_cef macOS plugin) spawns one cef_host per
// PROFILE (persistent or ephemeral) and drives N browsers in it over a
// Unix-socket IPC. For each browser the host allocates an IOSurface-backed
// CVPixelBuffer, registers a FlutterTexture on it, and sends kOpCreateBrowser
// (carrying url/width/height/dpr/iosurface-id). cef_host runs CEF windowless
// (OSR), paints each page into its shared IOSurface, and notifies the host so
// it calls textureFrameAvailable. Because the page renders to an offscreen
// buffer (no NSWindow), it keeps rendering live even when the view is off-screen
// — the whole point of the CEF path. No browser is created at startup; the host
// waits for kOpReady, then issues kOpCreateBrowser per view.
//
// Multi-process is the default (CMake option CEF_MULTI_PROCESS, ON by default,
// defines CEF_HOST_MULTIPROCESS): the CEF helper subprocesses
// (GPU/Renderer/Plugin/Alerts) spawn from Contents/Frameworks, the GPU/Viz
// process composites the page, and OnAcceleratedPaint delivers it as a
// shared-texture IOSurface — crash-isolated, so heavy SPAs survive. Chromium
// 144's Mach-port peer validation (process_requirement.cc -67030) is cleared
// WITHOUT Developer-ID signing: the MACH_PORT_RENDEZVOUS_PEER_VALDATION=0 env
// var (inherited by children) plus
// --disable-features=MachPortRendezvousValidatePeerRequirements,
// MachPortRendezvousEnforcePeerRequirements in the browser process. Build with
// -DCEF_MULTI_PROCESS=OFF for the simpler single-process fallback (software
// OnPaint, no helpers, no peer validation at all).
//
// Those Mach-port shortcuts plus a mock keychain are gated behind the
// CEF_HOST_ADHOC compile flag (ON by default). A signed release builds with
// -DCEF_HOST_ADHOC=OFF, which enforces peer validation and uses the real
// Keychain (OSCrypt) — and so requires correct inside-out Developer-ID signing.
//
// Args (all per-PROCESS / per-profile): --ipc=<path> --cdp-port=<port>
//       --allowed-schemes=<csv> --profile-dir=<abs path>
//       --surface-port=<bootstrap name of the plugin's SurfacePort>
// --profile-dir maps to settings.root_cache_path (empty/omitted -> a per-pid
// ephemeral temp dir; Swift always supplies it, so the fallback is defensive).
// The per-view args (url/width/height/dpr/iosurface-id) moved into the
// kOpCreateBrowser payload. --cdp-port is rejected upstream when a named profile
// is in use, so persistent profiles never expose the unauthenticated debug port.
//
// IPC wire format: 4-byte big-endian length prefix (bodyLen), then a 4-byte
// big-endian browserId, then [opcode][payload]. bodyLen = 4 + 1 + payloadLen.
// browserId is the Swift-assigned wire id (>=1); browserId 0 = process/profile
// level (kOpReady, process-level kOpLog, inbound kOpShutdown). The opcodes, each
// with its payload layout, are in cef_host_opcodes.h, generated from
// tool/protocol/spec.dart.
//
// Source layout:
//   main.mm              startup, the CEF app (command-line switches, kOpReady)
//   host_state.*         Slot + wire-id registry, scheme allowlist, crash-loop
//                        bookkeeping, shutdown and the hard-exit watchdog
//   ipc.*                frame writing, size limits, wire helpers
//   ipc_reader.*         the reader thread: frame decode -> UI-thread tasks
//   browser_ops.*        the per-browser operations those tasks run
//   host_client.*        a tile browser's CefClient (load/display/dialog/menu/
//                        permission/message-router handlers)
//   render_handler.*     OSR paint -> host IOSurface, surface hand-off, pump
//   popups.*             native sign-in popups and auth windows
//   authored_content.*   authored documents, document-start scripts, channels
//   process_helper.mm    the helper (renderer/GPU/...) processes

#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <libgen.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "host_state.h"
#include "ipc.h"
#include "ipc_reader.h"
#include "render_handler.h"

@interface CefHostApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end
@implementation CefHostApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}
- (void)setHandlingSendEvent:(BOOL)h {
  handlingSendEvent_ = h;
}
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

namespace cef_host {
namespace {

// Agent-control opt-in: when true (set from main() via --cdp-pipe BEFORE
// CefInitialize, read back in OnBeforeCommandLineProcessing), cef_host exposes
// CDP over inherited fds (3=read / 4=write, Chromium's DevToolsPipeHandler)
// instead of a TCP port. The argv-scrub below hands CEF only argv[0], so the
// "remote-debugging-pipe" Chromium switch can ONLY be injected through the
// OnBeforeCommandLineProcessing hook — hence this file-scope flag. Off by
// default; when off, behavior is byte-identical to the pre-pipe path.
bool g_cdp_pipe = false;

class HostApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString&, CefRefPtr<CefCommandLine> command_line) override {
    // Chromium parses --disable-features ONCE: a second occurrence of the
    // switch REPLACES the first rather than unioning with it, so appending our
    // own would silently re-enable whatever an earlier block turned off (most
    // dangerously the ad-hoc MachPortRendezvous bypass below, whose loss
    // -67030s the multi-process GPU→browser handoff and blanks every tile).
    // Every disable therefore accumulates here and is emitted as ONE
    // comma-joined value at the bottom of this hook. Do not call
    // AppendSwitchWithValue("disable-features", …) anywhere else.
    std::vector<std::string> disabled_features;
    // Effective memory-lever configuration, captured for the one-line startup
    // log at the bottom (see there for why it is unconditional).
    bool no_spare_renderer = false;

    // OSR establishment-latency: OSR views have no real OS window, so Chromium's scheduler
    // treats every renderer as backgrounded/occluded and LOWERS its process priority during
    // the critical first load — delaying the first frame of a tile that's actually visible
    // in our canvas. Keeping the renderer at full priority ~halved time-to-first-paint for a
    // 20-real-site board (measured), with no race/security change. Default ON; opt out with
    // FLUTTER_CEF_KEEP_BG_THROTTLE for debugging. NOTE: we deliberately do NOT add
    // --disable-background-timer-throttling — that would keep HIDDEN (off-screen, WasHidden)
    // tiles' JS timers running hot, fighting the off-screen-is-cheap property; the priority
    // flags below are what speed establishment without that cost.
    if (!std::getenv("FLUTTER_CEF_KEEP_BG_THROTTLE")) {
      command_line->AppendSwitch("disable-renderer-backgrounding");
      command_line->AppendSwitch("disable-backgrounding-occluded-windows");
    }

    // ---- Memory levers (both opt-in; unset == today's behaviour) -----------
    // Measured shape of this process tree on macOS (phys_footprint, not summed
    // RSS — the 307 MB Chromium framework is mapped into every process, so
    // summed RSS overstates by ~3.4x): 158 MB fixed + 33-42 MB per live
    // webview, r²=0.9997, with processes = N+5 and renderers = N+1 for N views.
    // The renderers are the whole per-view slope: at N=16 that is 17 x ~28 MB
    // = ~476 MB of a 689 MB total. Each lever below trades a specific,
    // user-visible property for part of that slope, so each is env-gated and
    // OFF by default — they can be A/B'd on one binary without a rebuild.

    // NOT A LEVER: --renderer-process-limit. Recorded because it is the obvious
    // next idea and it does NOT work here, so the next person should not spend
    // the day we spent. The intent would be that above the cap Chromium reuses
    // renderers instead of spawning, trading isolation for memory. MEASURED on
    // this build (CEF 144 / chromium-144.0.7559.254): Chromium treats it as a
    // SOFT limit and still gives every CEF windowless browser a DEDICATED
    // renderer. At N=8 browsers the renderer count was 8 for caps of 1, 2, 4
    // and 8 alike — never the cap; at N=16 under a cap of 8 there were 16.
    // The value does reach Chromium — cap=99 kept the spare (9 renderers),
    // cap<=8 dropped it (8) — so its ONLY enforced effect is declining to warm
    // the spare, which is a strictly weaker version of the lever below. It
    // recovers none of the per-view slope, so there is nothing here to ship.

    // THE LEVER — drop Chromium's SPARE renderer. The browser process keeps one
    // extra pre-warmed renderer per profile so the next navigation can skip
    // process startup; it is why renderers measure N+1 at EVERY N, including
    // N=1, and it costs ~23-24 MB permanently and PER PROFILE (so it compounds
    // with profile count, and we spawn one cef_host per profile). THE COST IS
    // FIRST-PAINT LATENCY on the NEXT tile created: that navigation now pays a
    // cold renderer launch instead of adopting a warm one. Nothing already
    // rendering is affected.
    //
    // Feature name verified against THIS build's vendored Chromium
    // (CEF 144.0.27 / chromium-144.0.7559.254, see native/build_cef_host.sh):
    // "SpareRendererForSitePerProcess" appears verbatim in the shipped
    // "Chromium Embedded Framework" binary, next to the source path
    // content/browser/renderer_host/spare_render_process_host_manager_impl.cc
    // that gates on it — i.e. it is this framework's own feature string, not a
    // name carried over from an older branch.
    // DEFAULT ON. Measured on the always-live bench (phys_footprint, shared
    // profile, N in {1,2,4,8,16}): renderer count drops from N+1 to exactly N at
    // every N, and the fitted fixed term falls 149.5 -> 126.2 MB — ~23 MB back
    // per CEF PROFILE, so it compounds with however many profiles a host app
    // declares. The cost is one cold renderer launch for the NEXT browser
    // created: first paint 38 -> 69 ms (~+31 ms). Nothing already rendering is
    // touched, and no browser shares a process with another, so there is no
    // neighbour-jank trade here.
    //
    // Opt BACK IN with FLUTTER_CEF_SPARE_RENDERER=1 when first-paint latency of
    // a newly created browser matters more than ~23 MB.
    const char* spare_env = std::getenv("FLUTTER_CEF_SPARE_RENDERER");
    const bool keep_spare =
        spare_env != nullptr && spare_env[0] != '\0' &&
        std::strcmp(spare_env, "0") != 0;
    if (!keep_spare) {
      no_spare_renderer = true;
      disabled_features.push_back("SpareRendererForSitePerProcess");
    }
    // ------------------------------------------------------------------------

#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc-only (CEF_HOST_ADHOC is ON by default; a signed release sets
    // -DCEF_HOST_ADHOC=OFF). Mock keychain + basic password store so a launch
    // doesn't raise the macOS Keychain access prompt every time. A signed
    // release omits these and uses the real Keychain via OSCrypt.
    command_line->AppendSwitch("use-mock-keychain");
    command_line->AppendSwitchWithValue("password-store", "basic");
#endif
#ifndef CEF_HOST_MULTIPROCESS
    // Single-process (-DCEF_MULTI_PROCESS=OFF; NOT the default): renderer + GPU
    // + utility all share this process, so there are no Mach-port peers to
    // validate (Chromium 144's -67030). The catch: heavy pages whose work lands
    // on the in-process utility thread (e.g. Google sign-in probing WebAuthn/HID
    // security keys) can CHECK-crash the whole process. It's best for
    // simpler/first-party content; the default multi-process build isolates
    // those crashes.
    command_line->AppendSwitch("single-process");
#endif
#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc-only: disable Chromium 144's Mach-port peer-requirement
    // validation, which otherwise -67030s the multi-process GPU→browser handoff
    // (OnAcceleratedPaint) under an ad-hoc signature. (Harmless in
    // single-process, where there are no peers to validate.) Together with the
    // shared-texture GPU OSR path this lets the accelerated path run
    // multi-process (crash-isolated) WITHOUT Developer-ID signing. A signed
    // release omits this and enforces validation, which then requires correct
    // inside-out Developer-ID signing of the cef_host tree. Accumulated (not
    // appended) so a later --disable-features can't clobber it — see the
    // disabled_features declaration at the top of this hook.
    disabled_features.push_back("MachPortRendezvousValidatePeerRequirements");
    disabled_features.push_back("MachPortRendezvousEnforcePeerRequirements");
#endif
    // Verbose Chromium logging only when explicitly debugging; off by default so
    // a shipped build doesn't write logs behind the user's back. The log is full
    // of URLs, so it goes to the per-user temp dir under a per-process name, not
    // a fixed shared path another user could pre-create or read.
    if (g_debug) {
      const std::string log_file =
          std::string([NSTemporaryDirectory() UTF8String]) +
          "cef_host_chromium_" + std::to_string(getpid()) + ".log";
      command_line->AppendSwitch("enable-logging");
      command_line->AppendSwitchWithValue("log-file", log_file);
      command_line->AppendSwitchWithValue("v", "1");
    }
    // CDP WebSocket origin allow-list: Chromium M113+ rejects DevTools WS
    // connections whose Origin isn't allow-listed (anti-CSRF on the local debug
    // port). We do NOT widen it with "*": the wildcard would disable that only
    // origin/CSRF guard on the unauthenticated localhost debugger. CDP stays
    // 127.0.0.1-bound and ephemeral-only (rejected on a persistent profile), and
    // clients that need WS access pass their own --remote-allow-origins out of
    // band; the default (no Origin / same-origin) still connects.

    // Agent-control / pipe mode (opt-in via --cdp-pipe, gated by g_cdp_pipe).
    // This hook only runs for the browser process (process_type empty), so no
    // explicit process_type check is needed. Inject "remote-debugging-pipe" so
    // Chromium's DevToolsPipeHandler speaks CDP over inherited fds (3=read /
    // 4=write) instead of a TCP port — there is no listening socket, so the
    // ONLY CDP client is the process that launched cef_host with those fds (the
    // Swift plugin). Default (ASCIIZ) framing: each CDP message is UTF-8 JSON
    // followed by a single 0x00 NUL byte, both directions (Puppeteer
    // PipeTransport). Deliberately NOT "remote-debugging-pipe=cbor". This MUST
    // go through this hook: the argv-scrub in main() hands CEF only argv[0], so
    // the switch can't ride in via clean_argv.
    if (g_cdp_pipe) {
      command_line->AppendSwitch("remote-debugging-pipe");
      // Chromium turns on the "AutomationControlled" blink feature whenever
      // remote debugging is active, which exposes `navigator.webdriver === true`.
      // Sites that gate on it (Google's OAuth — "this browser or app may not be
      // secure") then refuse human sign-in. We drive the page over CDP, never
      // WebDriver, so suppressing that one signal costs us nothing and lets a
      // user log in to a tile that's simultaneously agent-controllable. Does NOT
      // affect the DevTools pipe / CDP itself — only the JS-visible flag.
      command_line->AppendSwitchWithValue("disable-blink-features",
                                          "AutomationControlled");
    }

    // The ONE --disable-features emission (see the top of this hook: a second
    // occurrence would replace, not extend, this one).
    std::string disabled_features_value;
    for (const std::string& feature : disabled_features) {
      if (!disabled_features_value.empty()) disabled_features_value += ',';
      disabled_features_value += feature;
    }
    if (!disabled_features_value.empty()) {
      command_line->AppendSwitchWithValue("disable-features",
                                          disabled_features_value);
    }

    // Unconditional, one line, once per browser process (CEF calls this hook
    // only for process_type == "", see the CDP note above). Deliberately NOT
    // behind FLUTTER_CEF_DEBUG: an A/B memory sweep needs positive in-band
    // proof of which configuration the process ACTUALLY started with —
    // including the control arm, where "no levers" is itself the claim being
    // measured. Silently measuring the wrong build is the recurring failure
    // mode, and one stderr write per process launch is the cheapest cure.
    // Unlike --enable-logging this writes no file and leaks nothing about the
    // user's browsing — it names only our own switch configuration.
    fprintf(stderr,
            "[cef_host] mem-levers spare-renderer=%s disable-features=%s\n",
            no_spare_renderer ? "disabled" : "kept",
            disabled_features_value.empty() ? "(none)"
                                            : disabled_features_value.c_str());
  }
  // No browser is created here. We only announce readiness; the host then drives
  // browser creation on demand via kOpCreateBrowser (one per CefWebView sharing
  // this profile). Nothing loads — and nothing is written to the profile cache —
  // until the first kOpCreateBrowser, which is the safety window the host uses to
  // refuse a persistent profile under a mock-keychain (ad-hoc) build (F.5). The
  // payload is [readyFlags (bit0 = ad-hoc build), protocolVersion] — the version
  // byte lets the host refuse a protocol-skewed binary at the handshake instead of
  // silently mis-parsing every later frame.
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (g_debug) fprintf(stderr, "[cef_host] OnContextInitialized\n");
    uint8_t ready_flags = 0;
#ifdef CEF_HOST_ADHOC
    ready_flags |= 0x01;  // bit0 = ad-hoc / mock-keychain build
#endif
    const uint8_t ready_payload[2] = {ready_flags, kCefHostProtocolVersion};
    SendFrame(/*browser_id=*/0, kOpReady, ready_payload, sizeof(ready_payload));
  }
  IMPLEMENT_REFCOUNTING(HostApp);
};

// Belt-and-suspenders: if the host process dies without closing the socket
// cleanly, kqueue NOTE_EXIT still tears us down so no cef_host orphans.
void WatchParentDeath(pid_t parent) {
  int kq = kqueue();
  if (kq < 0) return;
  struct kevent change;
  EV_SET(&change, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0,
         nullptr);
  if (kevent(kq, &change, 1, nullptr, 0, nullptr) < 0) {
    close(kq);  // parent already gone (ESRCH) — socket EOF will catch it
    return;
  }
  struct kevent out;
  const int n = kevent(kq, nullptr, 0, &out, 1, nullptr);  // blocks until exit
  close(kq);
  if (n > 0) {
    ArmHardExit("parent exited");
    CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
  }
}

// ---- Arg parsing ----
std::string ArgValue(int argc, char** argv, const char* key) {
  std::string prefix = std::string("--") + key + "=";
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], prefix.c_str(), prefix.size()) == 0) {
      return std::string(argv[i] + prefix.size());
    }
  }
  return std::string();
}

// Presence-only flag (no value), e.g. bare "--cdp-pipe". ArgValue only matches
// "--key=value", so a value-less flag needs this. Accepts both "--key" and
// "--key=..." forms so the caller can pass either.
bool HasFlag(int argc, char** argv, const char* key) {
  const std::string bare = std::string("--") + key;
  const std::string prefix = bare + "=";
  for (int i = 1; i < argc; ++i) {
    if (argv[i] == bare ||
        strncmp(argv[i], prefix.c_str(), prefix.size()) == 0) {
      return true;
    }
  }
  return false;
}

std::string ExecutableDir() {
  char buf[4096];
  uint32_t sz = sizeof(buf);
  if (_NSGetExecutablePath(buf, &sz) != 0) return std::string();
  char real[4096];
  const char* resolved = realpath(buf, real) ? real : buf;
  return std::string(dirname(const_cast<char*>(resolved)));
}

int ConnectUnixSocket(const std::string& path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
  if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

}  // namespace
}  // namespace cef_host

int main(int argc, char* argv[]) {
  using namespace cef_host;
  g_debug = std::getenv("FLUTTER_CEF_DEBUG") != nullptr;
  // Raise the open-file limit early. A busy shared host runs many OSR browsers, each holding
  // sockets/pipes plus IOSurfaces, against macOS's low default soft limit (256) — and an
  // fd-heavy campus reaches the documented non-fatal WebRTC select() fd>=1024 fault. Lift the
  // soft limit toward the hard limit so fd headroom isn't the reachable ceiling.
  {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
      const rlim_t kCap = 10240;  // macOS caps RLIMIT_NOFILE at OPEN_MAX (10240)
      rlim_t target =
          (rl.rlim_max == RLIM_INFINITY || rl.rlim_max > kCap) ? kCap : rl.rlim_max;
      if (rl.rlim_cur < target) {
        rl.rlim_cur = target;
        setrlimit(RLIMIT_NOFILE, &rl);
      }
    }
  }
#if defined(CEF_HOST_MULTIPROCESS) && defined(CEF_HOST_ADHOC)
  // Disable Chromium 144's Mach-port peer-requirement validation for the whole
  // process tree. The child processes read this policy from an env var (NOT the
  // FeatureList, which isn't up yet when the rendezvous runs), and the browser
  // injects it; pre-setting it here makes children inherit kNoValidation (0).
  // (Note Chromium's misspelling "VALDATION".) On macOS 26 a failed validation
  // TERMINATES children, so without this no paint callback ever fires. This is a
  // dev/CI unblock (ad-hoc only — compiled out of a signed -DCEF_HOST_ADHOC=OFF
  // release); the production fix is correct inside-out Developer-ID signing.
  setenv("MACH_PORT_RENDEZVOUS_PEER_VALDATION", "0", 1);
#endif
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    fprintf(stderr, "[cef_host] failed to load CEF framework\n");
    return 1;
  }

  // All args are now per-PROCESS / per-profile; the per-view geometry/url moved
  // into the kOpCreateBrowser payload.
  std::string ipc_path = ArgValue(argc, argv, "ipc");
  std::string allowed = ArgValue(argc, argv, "allowed-schemes");
  std::string cdp = ArgValue(argc, argv, "cdp-port");
  // Agent-control / pipe mode opt-in (presence = true, no value). When set, CDP
  // goes over inherited fds 3/4 instead of the TCP --cdp-port; stashed in the
  // file-scope g_cdp_pipe so OnBeforeCommandLineProcessing can inject the
  // Chromium switch (set BEFORE CefInitialize, below). Mutually independent of
  // --cdp-port; the pipe path never touches the TCP `cdp` string above, so the
  // persistent-profile guard below (which strips only the TCP port) doesn't
  // fire for it — a pipe on a named profile is naturally allowed.
  const bool want_pipe = HasFlag(argc, argv, "cdp-pipe");
  std::string profile_dir = ArgValue(argc, argv, "profile-dir");
  // Swift always passes --profile-dir (even for an ephemeral host, whose dir is a
  // throwaway temp dir), so profile_dir alone can't tell "persistent" from
  // "ephemeral". --ephemeral marks the throwaway case so the CDP / mock-keychain
  // guards below fire only for a real (named, persistent) profile.
  const bool is_ephemeral = !ArgValue(argc, argv, "ephemeral").empty();
  for (size_t start = 0; start < allowed.size();) {
    const size_t comma = allowed.find(',', start);
    const size_t len =
        comma == std::string::npos ? std::string::npos : comma - start;
    std::string s = allowed.substr(start, len);
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (!s.empty()) g_allowed_schemes.insert(s);
    if (comma == std::string::npos) break;
    start = comma + 1;
  }

  const std::string surface_port = ArgValue(argc, argv, "surface-port");
  if (!surface_port.empty() &&
      bootstrap_look_up(bootstrap_port, surface_port.c_str(),
                        &g_surface_port) != KERN_SUCCESS) {
    fprintf(stderr, "[cef_host] no surface port %s\n", surface_port.c_str());
    return 1;
  }

  // Without its IPC connection the host could never be driven or told to stop
  // (and would still take the profile's lock below), so it doesn't start.
  if (ipc_path.empty()) {
    fprintf(stderr, "[cef_host] --ipc=<socket path> is required\n");
    return 1;
  }
  g_ipc_fd = ConnectUnixSocket(ipc_path);
  if (g_ipc_fd < 0) {
    fprintf(stderr, "[cef_host] failed to connect IPC socket %s: %s\n",
            ipc_path.c_str(), strerror(errno));
    return 1;
  }

  // Defense-in-depth (Swift is the real gate): CDP is an unauthenticated
  // localhost port that could read the shared cookie jar, so a *persistent*
  // profile must never expose it. CDP IS allowed on an ephemeral host, so gate
  // on !is_ephemeral — not on profile_dir alone, which is always set. Swift
  // already rejects CDP+named before spawn; this is belt-and-suspenders.
  // NOTE: this gates the TCP --cdp-port (`cdp`) ONLY. The agent-control pipe
  // path (--cdp-pipe / g_cdp_pipe) never sets `cdp`, so this guard does not fire
  // for it — a pipe on a named profile is allowed by construction (no listening
  // socket means the cookie-exfil rationale above doesn't apply).
  if (!cdp.empty() && !profile_dir.empty() && !is_ephemeral) {
    SendLog(0,
            "ignoring --cdp-port: refusing CDP on a persistent --profile-dir");
    cdp.clear();
  }
#ifdef CEF_HOST_ADHOC
  // Ad-hoc / mock-keychain build: secrets at rest aren't really encrypted, so a
  // persistent (named) profile here is insecure. Swift downgrades named profiles
  // to ephemeral on an ad-hoc host (F.5); this is an advisory log only, and only
  // for a real persistent profile (an ephemeral throwaway dir is never at risk).
  if (!profile_dir.empty() && !is_ephemeral &&
      !std::getenv("FLUTTER_CEF_ALLOW_INSECURE_PROFILE")) {
    SendLog(0, "warning: persistent profile under mock keychain (ad-hoc build)");
  }
#endif

  // Cross-process single-writer lock on a PERSISTENT profile dir (C2). Swift's
  // in-memory dedup only covers one plugin instance; two app instances (or two
  // FlutterEngines in one process) would resolve the same root_cache_path and
  // spawn two cef_host on it. Chromium's own profile singleton then fails the
  // SECOND CefInitialize (-> EOF, silent dead profile) with possible cache
  // corruption if the lock races. Take an advisory exclusive flock on
  // <profile_dir>/.flutter_cef.lock FIRST; on contention report a distinct,
  // machine-parseable signal and exit with code 2 so Swift surfaces a real
  // "profile already in use" error instead of the generic crash/EOF path. A lock
  // file that can't be opened at all (a missing or unwritable dir) is not
  // contention: exit 3, which the plugin reports as a failed start. Only for a real persistent profile — an
  // ephemeral throwaway dir is per-pid, so it can never contend. The fd is held
  // open (never closed) for the process lifetime: the lock releases when the
  // process exits (closing it early, or letting an RAII guard close it, would
  // drop the lock while the profile is still live). Intentionally leaked.
  if (!profile_dir.empty() && !is_ephemeral) {
    const std::string lock_path = profile_dir + "/.flutter_cef.lock";
    int lock_fd = open(lock_path.c_str(), O_CREAT | O_RDWR, 0600);
    if (lock_fd < 0) {
      const std::string why = strerror(errno);
      SendLog(0, "profile-lock-failed: cannot open " + lock_path + ": " + why);
      fprintf(stderr, "[cef_host] cannot open profile lock %s: %s\n",
              lock_path.c_str(), why.c_str());
      return 3;
    }
    if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
      SendLog(0, "profile-locked");
      fprintf(stderr,
              "[cef_host] profile already in use by another process (%s): %s\n",
              lock_path.c_str(), strerror(errno));
      close(lock_fd);
      return 2;
    }
    // Held for the process lifetime — never closed (the OS drops the lock on
    // exit). Suppress the unused-variable warning without releasing the lock.
    (void)lock_fd;
  }

  // Stash the agent-control / pipe opt-in for OnBeforeCommandLineProcessing,
  // which runs during CefInitialize below. That hook is the ONLY place the
  // "remote-debugging-pipe" Chromium switch can be injected (the argv-scrub just
  // below hands CEF argv[0] only, so it can't ride in via clean_argv). When
  // false, nothing is injected and behavior is byte-identical to the pre-pipe
  // path. Note: --cdp-pipe is independent of the TCP --cdp-port and is NOT
  // subject to the persistent-profile guard above (which strips only the TCP
  // `cdp` string); a pipe has no listening socket, so a pipe on a named profile
  // is allowed by construction.
  g_cdp_pipe = want_pipe;

  // Hand Chromium ONLY the program name. Our custom switches (--ipc,
  // --cdp-port, --allowed-schemes, --profile-dir, --cdp-pipe) are parsed by us
  // above; if they reach Chromium's CommandLine, cef_initialize CHECK-crashes
  // on them.
  char* clean_argv[] = {argv[0]};
  CefMainArgs main_args(1, clean_argv);
  @autoreleasepool {
    [CefHostApplication sharedApplication];
    CefSettings settings;
#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc: the Chromium renderer/GPU sandbox is OFF. It only *validates*
    // under proper Developer-ID signing, so an ad-hoc build must run unsandboxed.
    settings.no_sandbox = true;
#else
    // Signed release (-DCEF_HOST_ADHOC=OFF): enable the Chromium renderer/GPU
    // sandbox. The browser process itself is never sandboxed on macOS — only the
    // helper subprocesses, which call CefScopedSandboxContext (process_helper.mm)
    // before loading the framework. Requires correct inside-out Developer-ID
    // signing of the cef_host tree (the libcef_sandbox.dylib + helpers + host).
    settings.no_sandbox = false;
#endif
    settings.windowless_rendering_enabled = true;
    settings.log_severity = LOGSEVERITY_INFO;
    // Chrome DevTools Protocol (CDP): the host picks a free port and passes it
    // via --cdp-port; CEF stands up the DevTools HTTP/WebSocket server on
    // 127.0.0.1:<port> (M113+ forces localhost-only). UNAUTHENTICATED — any local
    // client that reaches the port fully drives the page — so this is opt-in,
    // never set by default. CEF treats 0 as "disabled" (no auto-assign), so the
    // host must choose a real port (1024-65535).
    if (!cdp.empty()) {
      int port = atoi(cdp.c_str());
      if (port >= 1024 && port <= 65535) {
        settings.remote_debugging_port = port;
      }
    }
    // Per-profile cache. The host supplies --profile-dir: a stable 0700 dir
    // under Application Support for a named (persistent, shared-login) profile,
    // or a unique throwaway temp dir for an ephemeral session. One root_cache_path
    // is shared by every browser in this process, which is what makes login
    // shared. The per-pid temp fallback is defensive — Swift always passes
    // --profile-dir, so it normally never fires. persist_session_cookies keeps
    // session cookies across relaunch (harmless for ephemeral; required for
    // "stay signed in").
    std::string cef_cache =
        !profile_dir.empty()
            ? profile_dir
            : std::string([NSTemporaryDirectory() UTF8String]) +
                  "flutter_cef_cache_" +
                  std::to_string([[NSProcessInfo processInfo] processIdentifier]);
    CefString(&settings.root_cache_path) = cef_cache;
    settings.persist_session_cookies = true;
    // A plain (non-.app) executable can't auto-locate the framework Resources
    // (icudtl.dat, *.pak, locale .lproj), so point CEF at them explicitly via a
    // normalized (no "..") framework dir.
    std::string exe_dir = ExecutableDir();
    std::string fw_raw =
        exe_dir + "/../Frameworks/Chromium Embedded Framework.framework";
    char fw_real[4096];
    std::string fw =
        realpath(fw_raw.c_str(), fw_real) ? std::string(fw_real) : fw_raw;
    CefString(&settings.framework_dir_path) = fw;
    CefString(&settings.resources_dir_path) = fw + "/Resources";
    CefString(&settings.locales_dir_path) = fw + "/Resources";
#ifdef CEF_HOST_MULTIPROCESS
    // Multi-process: point CEF at the base helper subprocess + the cef_host
    // bundle. CEF derives the (GPU)/(Renderer)/(Plugin)/(Alerts) variants from
    // the base helper name.
    auto normalize = [](const std::string& p) {
      char buf[4096];
      return realpath(p.c_str(), buf) ? std::string(buf) : p;
    };
    CefString(&settings.browser_subprocess_path) = normalize(
        exe_dir + "/../Frameworks/cef_host Helper.app/Contents/MacOS/cef_host Helper");
    CefString(&settings.main_bundle_path) = normalize(exe_dir + "/../..");
#endif
    CefRefPtr<HostApp> app(new HostApp);
    if (!CefInitialize(main_args, settings, app, nullptr)) {
      fprintf(stderr, "[cef_host] CefInitialize failed\n");
      return 1;
    }
    if (g_debug)
      fprintf(stderr, "[cef_host] CefInitialize OK (fd=%d)\n", g_ipc_fd.load());
    std::thread reader(&IpcReadLoop);
    std::thread(&WatchParentDeath, getppid()).detach();
    CefRunMessageLoop();
    ExtendHardExitForTeardown();
    if (reader.joinable()) {
      shutdown(g_ipc_fd, SHUT_RDWR);  // unblock the reader's blocking read
      reader.join();
    }
    // Reader is joined (no more reads); close the socket under the write mutex
    // (no concurrent SendFrame) and clear the fd so any late write is a no-op.
    {
      std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
      // C3: store -1 FIRST (atomic exchange), THEN close — so a SendFrame that snapshots
      // the fd under this lock never holds a value that's already closed/recycled. The
      // GPU/compositor threads that call SendFrame aren't joined until CefShutdown below,
      // so this ordering (not close-then-clear) is what makes a late paint write a safe
      // no-op instead of a write into an unrelated recycled fd.
      int fd = g_ipc_fd.exchange(-1);
      if (fd >= 0) close(fd);
    }
    CefShutdown();
  }
  return 0;
}
