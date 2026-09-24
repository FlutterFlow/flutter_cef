// Process-wide state of cef_host: the per-browser Slot and the registry that
// routes wire ids to it, the scheme allowlist, the renderer crash-loop
// bookkeeping, and shutdown. See main.mm for the process overview.
#pragma once

#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_registration.h"

namespace cef_host {

// FLUTTER_CEF_DEBUG, read once in main() before anything runs: the per-frame
// and per-tick diagnostics check it on hot paths.
extern bool g_debug;

// The eval id of the plugin's liveness ping (CefProfileHost.livenessPingId).
// Answered natively by the renderer, not by page JS: see renderer_messages.h.
constexpr uint32_t kLivenessPingId = 0xFFFFFFFFu;

// The largest view side (DIP) a create or resize accepts.
constexpr int kMaxViewDim = 16384;

// ── Renderer crash-loop detector ─────────────────────────────────────────────
// A renderer that dies is normally recoverable: OnRenderProcessTerminated
// reloads and the fresh child takes over. But a page that crashes its renderer
// on every load, or a child that can no longer be SPAWNED at all, re-crashes
// instantly and loops forever with no signal to the embedder.
//
// Counted per browser: one page crash-looping ends only its own browser
// (kOpBrowserGone, and it is not reloaded again). When bursts span several
// browsers at once the children themselves can't start (the observed trigger is
// the app bundle being replaced under a running host), so the host exits: the
// pipe EOFs, the plugin reports processGone, and the embedder's recreate path
// spawns a fresh host from the new bundle.
// Tuned to be unreachable by ordinary flakiness: an isolated renderer crash (or
// a few across unrelated tabs) reloads normally and never trips this.
constexpr int kRendererCrashBurstLimit = 4;
constexpr std::chrono::seconds kRendererCrashWindow{10};
// Browsers whose bursts overlap within kRendererCrashWindow before the host
// gives up on its children.
constexpr size_t kHostCrashLoopBrowsers = 2;

/// One browser's renderer crash history. UI-thread only.
struct CrashCounter {
  int count = 0;
  std::chrono::steady_clock::time_point window_start;

  /// Records a renderer death; true when they arrive as a burst, i.e. the
  /// reload is re-crashing rather than recovering.
  bool NoteAndCheckBurst(std::chrono::steady_clock::time_point now) {
    if (count == 0 || now - window_start > kRendererCrashWindow) {
      // First death, or the previous burst aged out: unrelated one-off crashes
      // over a long session never accumulate.
      window_start = now;
      count = 1;
      return false;
    }
    return ++count >= kRendererCrashBurstLimit;
  }
};

/// A browser's renderer crash-looped. True when bursts on other browsers
/// overlap it, which means the host can't start children at all.
bool NoteCrashBurstAndCheckHostLoop(uint32_t wire_id,
                                    std::chrono::steady_clock::time_point now);

// Per-browser state. One cef_host process now multiplexes N browsers (one per
// CefWebView sharing this profile), so the state that used to be process-global
// (surface/geometry/dpr, the browser, pending JS dialogs, the trusted-load
// allowlist exemptions, popup compositing buffers) moves into a per-browser
// Slot. HostClient / HostRenderHandler each hold a shared_ptr to their slot, and
// per-op UI tasks bind a shared_ptr copy so the slot outlives the
// dispose/in-flight race. Slots are created in DoCreateBrowser and torn down in
// OnBeforeClose (both on the CEF UI thread).
struct Slot {
  uint32_t browser_id = 0;  // Swift-assigned wire id (>=1); NOT GetIdentifier().
  CefRefPtr<CefBrowser> browser;
  // H3 async-create dispose-loss guard: a dispose arriving while the async
  // CreateBrowser is still in flight (browser == null) can't CloseBrowser yet, so it
  // records intent here and OnAfterCreated honors it the instant the browser binds —
  // otherwise that browser is a live orphan (renderer + IOSurface) nothing reclaims
  // until whole-host shutdown. UI-thread-confined (DoDisposeBrowser + OnAfterCreated
  // both run on the CEF UI thread), so no lock.
  bool close_requested = false;

  // Pending getUserMedia permission callbacks, keyed by request id — the browser
  // permission model: a page asks, the host shows a prompt, the answer comes back
  // over the IPC (kOpMediaResponse -> DoMediaResponse -> Continue). Held exactly
  // like `dialogs` below: UI-thread-only (OnRequestMediaAccessPermission and the
  // response both run on the CEF UI thread), per-slot so one browser's request id
  // can never Continue() another's. A held callback that is never answered is
  // dropped (Cancel) in OnBeforeClose / on navigation, matching a page whose
  // permission prompt is dismissed by leaving it.
  // The requested mask is held with the callback because CefMediaAccessCallback
  // requires that, for a getUserMedia request, the allowed permissions MATCH the
  // requested ones — so a grant is all-or-nothing and the host enforces that
  // itself rather than trusting whatever mask the response carries.
  struct PendingMedia {
    CefRefPtr<CefMediaAccessCallback> callback;
    uint32_t wanted = 0;
    // The ORIGIN that asked — the decision is remembered against this, not the
    // address bar, so a cross-origin iframe's grant can't be recorded for (or
    // silently inherited from) the top-level page.
    std::string origin;
  };
  std::map<uint32_t, PendingMedia> media_requests;

  // Right-click menus awaiting a choice from the Flutter side. Same shape as
  // media_requests and for the same reason: OSR has no window, so the menu is
  // drawn by the host and the callback has to survive until the user picks.
  // CEF requires the callback be answered (Continue or Cancel) exactly once, so
  // a dropped entry would leave the page's menu logic hanging.
  std::map<uint32_t, CefRefPtr<CefRunContextMenuCallback>> context_menus;
  uint32_t next_context_menu_id = 1;
  uint32_t media_req_next = 1;
  // Last capture state reported by OnMediaAccessChange, so the complete media
  // status can be re-sent (on load, or on demand) without waiting for a change.
  bool media_video_active = false;
  bool media_audio_active = false;

  // Guards surface / width / height / dpr / popup_* for THIS browser. Per-slot
  // (not a single global) so paints on independent browsers don't contend.
  std::mutex surface_mutex;
  IOSurfaceRef surface = nullptr;  // host-OWNED IOSurface we paint into (producer-allocates;
                                   // minted lazily in EnsureSurfaceForPaint on the first paint)
  // Set under surface_mutex in OnBeforeClose BEFORE nulling `surface`, so a paint racing teardown
  // (EnsureSurfaceForPaint) doesn't re-mint a surface for a closing browser (which would leak —
  // OnBeforeClose already released the last one). Producer-allocates lifetime guard.
  bool closing = false;
  // Cached Metal wrap of `surface` for the GPU-blit DEST. Wrapping it fresh every
  // frame is pure churn (the surface is stable except on resize), so cache it and
  // recreate only when the wrapped IOSurface id changes. Released wherever `surface`
  // is. Guarded by surface_mutex. MRC: holds the +1 from newTextureWithDescriptor.
  id<MTLTexture> dst_mtl = nil;
  uint32_t dst_mtl_sid = 0;
  int width = 800;   // logical (DIP) — GetViewRect; CEF scales by dpr.
  int height = 600;
  double dpr = 1.0;  // device pixel ratio; the IOSurface is logical*dpr px.

  // Popup widgets (<select> dropdowns, autofill) paint into a separate PET_POPUP
  // buffer that we composite over the view at the popup rect. Guarded by
  // surface_mutex. Per-slot so two browsers' open dropdowns don't clobber.
  bool popup_visible = false;
  CefRect popup_rect;
  std::vector<uint8_t> popup_buf;
  int popup_w = 0;
  int popup_h = 0;

  // Exact URLs armed for a host-trusted content load (kOpLoadTrusted). The
  // exemption is bound to the specific URL, NOT to a moment in time: LoadURL does
  // not deliver OnBeforeBrowse synchronously (it enqueues the nav; the callback
  // arrives as a later UI task), so a global one-shot flag could be consumed by a
  // page-initiated navigation queued in the gap — an allowlist bypass. Matching
  // on the exact URL (and main frame) in OnBeforeBrowse means a page nav to a
  // different URL can never steal another load's exemption. A multiset tolerates
  // identical concurrent trusted loads. UI-thread only, so no lock. Per-slot so a
  // trusted load on one browser can't exempt a navigation on another.
  // (A page racing the host to the EXACT same data:/file: URL could consume one
  // armed entry, but that is benign — it loads the same content the host chose —
  // so it is not defended beyond exact-URL matching.)
  std::multiset<std::string> trusted_pending;

  // Pending JS dialog callbacks, keyed by id. UI-thread-only (OnJSDialog and the
  // host's response both run on the CEF UI thread), so no lock is needed.
  // Per-slot so dialog ids on one browser can't Continue() another's callback.
  std::map<uint32_t, CefRefPtr<CefJSDialogCallback>> dialogs;
  uint32_t dialog_next = 1;

  // CEF-2b: registration for the DevTools message observer used to resolve this
  // browser's CDP targetId (Target.getTargetInfo). Kept alive for the slot's life;
  // UI-thread only. Lazily set on the first kOpResolveTargetId.
  CefRefPtr<CefRegistration> devtools_reg;
  // CEF-2b: the DevTools message id of the LAST Target.getTargetInfo probe on this
  // browser. A FRESH, monotonically-increasing id per probe (seeded to
  // kTargetInfoMsgId) — Chromium's DevTools session requires increasing command ids,
  // so reusing a fixed id silently drops the 2nd+ probe, which hung a re-enable of
  // agent-control (disable then enable again). UI-thread only, like dialog_next.
  int target_info_msg = 0;
  // The last DevTools message id issued on this browser, shared by every caller
  // (see NextDevToolsMsgId) so their ids stay increasing. UI-thread only.
  int devtools_msg = 0;

  // External begin-frame pump (see PumpBeginFrame). With external_begin_frame_enabled, CEF's
  // internal frame timer is OFF — frames are produced ONLY when we drive them — so a per-slot
  // pump calls SendExternalBeginFrame on a cadence. `visible` gates it (UI-thread only, set by
  // DoSetVisible); `begin_frame_pump_started` guards a double-start. UI-thread only.
  bool visible = true;
  bool begin_frame_pump_started = false;
  // Visible begin-frame cadence (ms) for this slot — the OSR frame clock.
  // 16 ≈ 60fps (default); the host clamps kOpSetPumpInterval to [8, 250] so a
  // consumer can drop an unengaged tile to ~30fps without touching hidden
  // gating. UI-thread only, like `visible`.
  int pump_interval_ms = 16;
  // F-1/F-2: a dpr/screen-info change that lands while the slot is HIDDEN is deferred —
  // the begin-frame pump is gated off while hidden, so notifying + painting now would
  // composite into a surface nothing displays and mislead the Swift resize watchdog into
  // promoting a never-painted buffer. DoResize sets this while hidden; DoSetVisible's
  // hidden->visible edge re-asserts screen info before forcing a full repaint. UI-thread only.
  bool needs_screen_info_on_show = false;
  // Per-slot pump-tick + accelerated-paint counters, logged from PumpBeginFrame when
  // FLUTTER_CEF_DEBUG is set — diagnostics for paint-stall investigation at scale.
  uint64_t diag_pump_ticks = 0;
  uint64_t diag_paint_count = 0;
  // about:blank-first (FLUTTER_CEF_BLANK_FIRST): the real URL to navigate to AFTER the
  // browser establishes on about:blank. Establishing on blank makes the first-frame GPU
  // handshake near-instant (so the create-pacer releases its slot fast), decoupling
  // establishment from the real page's load time. Navigated + cleared on first paint,
  // or when the browser binds hidden (a hidden browser doesn't paint). UI-thread only.
  std::string pending_nav_url;
  // A load that arrived after the create but before the browser bound
  // (OnAfterCreated). Applied there. UI-thread only.
  std::string nav_after_create;
  // This browser's renderer crash history (see CrashCounter), and whether it
  // crash-looped: it is then left alone, not reloaded again. UI-thread only.
  CrashCounter crashes;
  bool crash_looped = false;
  // Nonce of each runJavaScriptReturningResult in flight, by eval id. Only a
  // reply carrying its eval's nonce is passed on, so the page can't answer an
  // eval it wasn't asked (though, running in the page, it can still alter the
  // result of one it was). UI-thread only.
  std::map<uint32_t, std::string> pending_evals;
  // The JS channels this browser's consumer registered, before create (they also
  // ride in extra_info) or after. Only these are injected into its pages and
  // honored from them: channels are per browser, not per host. UI-thread only.
  std::set<std::string> channels;
};

// Routing map from a wire browser id to its Slot. MUTATED ONLY ON THE CEF UI
// THREAD (insert in DoCreateBrowser, erase in OnBeforeClose). The IPC reader
// thread takes g_slots_mutex, copies the shared_ptr, releases the lock, then
// operates — so a slot stays alive for the duration of an in-flight op even if
// it's disposed. Paint/display handlers don't consult this map: each HostClient
// / HostRenderHandler holds its slot_ shared_ptr directly (no hot-path lookup).
extern std::mutex g_slots_mutex;
extern std::map<uint32_t /*wire id*/, std::shared_ptr<Slot>>
    g_slots_by_wire_id;  // inbound IPC routing -> slot

// Look up a slot by its Swift-assigned wire id (used by the IPC reader to route
// an inbound per-browser op). Null for wire id 0 or an unknown/disposed id.
std::shared_ptr<Slot> LookupWireId(uint32_t wire_id);

// Host-set navigation scheme allowlist (lowercased; `--allowed-schemes=a,b`).
// Empty = allow all. `about` is always allowed (the blank placeholder).
// Enforced in HostClient::OnBeforeBrowse so it covers the initial load,
// programmatic navigation (navigate), in-page clicks, and redirects. The host's
// explicit content-injection APIs (loadHtmlString -> data:, loadFile -> file:)
// are NOT subject to it — they arrive as kOpLoadTrusted and arm an exact-URL
// exemption in the browser's Slot::trusted_pending so their load isn't refused.
extern std::set<std::string> g_allowed_schemes;

// Whether a page may take a top-level browser to `url` under g_allowed_schemes
// (true when no allowlist is set). See host_state.mm.
bool SchemeAllowed(const std::string& url);

// ── Shutdown ────────────────────────────────────────────────────────────────
// CEF must not be shut down with browsers still open, so DoShutdown closes
// every browser and quits the message loop only once the last one is gone
// (OnBeforeClose), or after kShutdownCloseGrace if one never closes.
extern bool g_shutting_down;  // UI-thread only
extern int g_open_browsers;   // tiles dispatched + windowed browsers; UI thread

/// A browser counted in g_open_browsers closed. UI-thread only.
void NoteBrowserClosed();

// Exits the process if it is still running a while after a shutdown was
// requested (see host_state.mm). Any thread.
void ArmHardExit(const char* why);
void ExtendHardExitForTeardown();

// Tear down the WHOLE process: close every browser, then quit the message loop.
// See host_state.mm. UI thread.
void DoShutdown();

}  // namespace cef_host
