#include "host_state.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <thread>

#include <unistd.h>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "popups.h"

namespace cef_host {

bool g_debug = false;

namespace {
// When each browser's crash burst was detected, by wire id. UI-thread only.
std::map<uint32_t, std::chrono::steady_clock::time_point> g_crash_bursts;
}  // namespace

bool NoteCrashBurstAndCheckHostLoop(uint32_t wire_id,
                                    std::chrono::steady_clock::time_point now) {
  g_crash_bursts[wire_id] = now;
  for (auto it = g_crash_bursts.begin(); it != g_crash_bursts.end();) {
    if (now - it->second > kRendererCrashWindow)
      it = g_crash_bursts.erase(it);
    else
      ++it;
  }
  return g_crash_bursts.size() >= kHostCrashLoopBrowsers;
}

std::mutex g_slots_mutex;
std::map<uint32_t /*wire id*/, std::shared_ptr<Slot>>
    g_slots_by_wire_id;  // inbound IPC routing -> slot

// Look up a slot by its Swift-assigned wire id (used by the IPC reader to route
// an inbound per-browser op). Null for wire id 0 or an unknown/disposed id.
std::shared_ptr<Slot> LookupWireId(uint32_t wire_id) {
  if (wire_id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(g_slots_mutex);
  auto it = g_slots_by_wire_id.find(wire_id);
  return it == g_slots_by_wire_id.end() ? nullptr : it->second;
}

std::set<std::string> g_allowed_schemes;

namespace {
std::string LowerScheme(const std::string& url, size_t* colon_out = nullptr) {
  const size_t colon = url.find(':');
  if (colon_out) *colon_out = colon;
  std::string scheme =
      colon == std::string::npos ? std::string() : url.substr(0, colon);
  std::transform(scheme.begin(), scheme.end(), scheme.begin(),
                 [](unsigned char c) { return std::tolower(c); });
  return scheme;
}
}  // namespace

// Whether a page may take a top-level browser to `url` under g_allowed_schemes
// (true when no allowlist is set). `about:` (the blank placeholder) is always
// allowed. `view-source:` is judged by what it wraps: viewing the source of a
// page you were already allowed to LOAD grants no new reach (it renders bytes as
// text and runs nothing), whereas refusing it silently breaks Chromium's own View
// Page Source menu command. `view-source:file:///…` stays refused, because `file`
// is not in the allowlist. Nesting is not recursive in Chromium
// (`view-source:view-source:` is rejected upstream), so one unwrap is the whole
// story.
bool SchemeAllowed(const std::string& url) {
  if (g_allowed_schemes.empty()) return true;
  size_t colon = std::string::npos;
  const std::string scheme = LowerScheme(url, &colon);
  if (scheme == "view-source")
    return g_allowed_schemes.count(LowerScheme(url.substr(colon + 1))) != 0;
  return scheme == "about" || g_allowed_schemes.count(scheme) != 0;
}

bool g_shutting_down = false;
int g_open_browsers = 0;

namespace {
bool g_quit_posted = false;  // UI-thread only
constexpr int64_t kShutdownCloseGraceMs = 2000;

void QuitMessageLoopOnce() {
  if (g_quit_posted) return;
  g_quit_posted = true;
  CefQuitMessageLoop();
}
}  // namespace

void NoteBrowserClosed() {
  if (g_open_browsers > 0) --g_open_browsers;
  if (g_shutting_down && g_open_browsers == 0) QuitMessageLoopOnce();
}

// If the UI thread is wedged (a hung GPU wait, say) the shutdown posted to it
// never runs, the process lingers and keeps the profile's lock, and every
// relaunch reports "locked". Armed wherever a shutdown is requested; exits the
// process kHardExitSeconds later if its message loop hasn't quit by then. Once
// it has, CefShutdown is running, which takes a second or so and longer on a
// first launch, so the deadline moves out to kTeardownSeconds instead of
// cutting that short (see ExtendHardExitForTeardown).
namespace {
constexpr int kHardExitSeconds = 6;
constexpr int kTeardownSeconds = 30;
std::once_flag g_hard_exit_armed;
std::atomic<int64_t> g_hard_exit_at_ms{0};  // steady clock

int64_t SteadyNowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
}  // namespace

void ArmHardExit(const char* why) {
  std::call_once(g_hard_exit_armed, [why] {
    g_hard_exit_at_ms = SteadyNowMs() + kHardExitSeconds * 1000;
    std::thread([why] {
      for (int64_t left; (left = g_hard_exit_at_ms - SteadyNowMs()) > 0;)
        std::this_thread::sleep_for(std::chrono::milliseconds(left));
      fprintf(stderr, "[cef_host] still running after shutdown (%s); exiting now\n",
              why);
      _exit(0);
    }).detach();
  });
}

void ExtendHardExitForTeardown() {
  ArmHardExit("teardown");
  g_hard_exit_at_ms = SteadyNowMs() + kTeardownSeconds * 1000;
}

// Tear down the WHOLE process: close every browser, then quit the message loop
// once the last has closed (NoteBrowserClosed), or after kShutdownCloseGraceMs.
// Each browser's per-slot cleanup (maps, surface, retain-cycle break) runs in
// OnBeforeClose as CEF processes the CloseBrowser(true). Sent when the host
// disposes the last browser, on socket loss, or on parent death.
void DoShutdown() {
  CEF_REQUIRE_UI_THREAD();
  if (g_shutting_down) return;
  g_shutting_down = true;
  ArmHardExit("shutdown");
#ifdef CEF_HOST_ADHOC
  // Test hook (ad-hoc builds only): a wedged UI thread, for the hard-exit test.
  if (std::getenv("FLUTTER_CEF_TEST_WEDGE_UI_ON_SHUTDOWN"))
    for (;;) std::this_thread::sleep_for(std::chrono::hours(1));
#endif
  std::vector<std::shared_ptr<Slot>> slots;
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    slots.reserve(g_slots_by_wire_id.size());
    for (auto& kv : g_slots_by_wire_id) slots.push_back(kv.second);
  }
  for (auto& slot : slots) {
    if (slot->browser) {
      slot->browser->GetHost()->CloseBrowser(true);
    } else {
      slot->close_requested = true;  // OnAfterCreated closes it
    }
  }
  CloseWindowedBrowsers(0);
  if (g_open_browsers == 0) {
    QuitMessageLoopOnce();
    return;
  }
  CefPostDelayedTask(TID_UI, base::BindOnce(&QuitMessageLoopOnce),
                     kShutdownCloseGraceMs);
}

}  // namespace cef_host
