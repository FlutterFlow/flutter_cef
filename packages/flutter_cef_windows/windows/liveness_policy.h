// Pure decision policy for the plugin's steady-state liveness sweep: the check
// that catches a tile which painted and then stopped (a hung renderer inside a
// host whose pipe is still up, so no processGone). The first-present watchdog
// retires at the first frame, so without this such a tile froze silently.
//
// A port of the macOS LivenessProbePolicy.swift. No Win32 or Flutter, so it is
// unit-tested standalone (test/native/run_policy_tests.sh).
//
// A static page legitimately presents nothing while idle, so staleness alone
// is not a hang. The sweep first nudges a stale tile (kOpInvalidate) and pings
// its renderer with an eval the page can't see. A healthy page answers the
// ping; a renderer that leaves it unanswered for `hang_ns` is hung, and the
// plugin ends the host so the tiles are recreated.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_LIVENESS_POLICY_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_LIVENESS_POLICY_H_

#include <cstdint>

namespace flutter_cef {
namespace liveness {

// The eval id of the liveness ping. Dart's eval ids count up from 1 and never
// reach it, and its reply is consumed by the plugin, never forwarded to Dart.
constexpr uint32_t kPingId = 0xFFFFFFFFu;

enum class Action { kHealthy, kNudge, kDeclareStalled };

// What the sweep should do for one established, visible, painted tile.
// `since_last_present_ns` is now minus its last present; `nudged` says an
// invalidate is outstanding and `since_nudge_ns` how long ago it went out. The
// caller clears the nudge on every present.
inline Action Evaluate(uint64_t since_last_present_ns,
                       uint64_t staleness_threshold_ns, bool nudged,
                       uint64_t since_nudge_ns, uint64_t nudge_grace_ns) {
  if (since_last_present_ns < staleness_threshold_ns) return Action::kHealthy;
  if (!nudged) return Action::kNudge;
  // Stale and already nudged with no present since: a static page or a hung
  // renderer. The ping tells them apart; this only says the nudge is done.
  return since_nudge_ns >= nudge_grace_ns ? Action::kDeclareStalled
                                          : Action::kHealthy;
}

enum class PingAction { kWait, kPing, kHung };

// Whether to ping a stale tile's renderer. `ping_sent_ns` is when an
// unanswered ping went out (0 if none is outstanding); `ping_replied_ns` when
// the last one was answered (0 if never). A static page is re-pinged at most
// once per `ping_interval_ns`.
inline PingAction Ping(uint64_t now_ns, uint64_t ping_sent_ns,
                       uint64_t ping_replied_ns, uint64_t ping_interval_ns,
                       uint64_t hang_ns) {
  if (ping_sent_ns != 0) {
    return now_ns - ping_sent_ns >= hang_ns ? PingAction::kHung
                                            : PingAction::kWait;
  }
  if (ping_replied_ns != 0 && now_ns - ping_replied_ns < ping_interval_ns)
    return PingAction::kWait;
  return PingAction::kPing;
}

// Whether an unanswered ping would mean a hung renderer. A renderer blocked on
// a JS dialog, or paused in a debugger (DevTools, or an agent over CDP), is
// alive but can't answer, so such a tile isn't pinged.
inline bool MayPing(int dialogs_open, bool devtools_opened,
                    bool cdp_clients_can_pause) {
  return dialogs_open == 0 && !devtools_opened && !cdp_clients_can_pause;
}

}  // namespace liveness
}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_LIVENESS_POLICY_H_
