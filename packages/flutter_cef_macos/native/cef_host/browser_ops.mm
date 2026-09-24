#include "browser_ops.h"

#import <Cocoa/Cocoa.h>

#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <vector>

#include "authored_content.h"
#include "host_client.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"
#include "ipc.h"
#include "mac_key_bindings.h"
#include "popups.h"
#include "render_handler.h"
#include "renderer_messages.h"

namespace cef_host {
namespace {

// UI-thread only. A navigate / loadTrusted that arrived before its browser's create
// frame (see DoNavigateByWireId), and the highest wire id a create has been seen for.
struct EarlyNav {
  std::string url;
  bool trusted;
};
std::map<uint32_t, EarlyNav> g_early_nav;
// Channels registered before their browser's create frame arrived. UI-thread only.
std::map<uint32_t, std::set<std::string>> g_early_channels;
uint32_t g_max_created_wire_id = 0;

}  // namespace

// Create a windowless browser for a CefWebView (kOpCreateBrowser). Runs on the
// CEF UI thread. wire_id is the Swift-assigned browser id this slot is keyed by;
// sid is the host's IOSurface for this view (0 / lookup-failure -> no surface
// until the first resize). Builds the Slot, registers it in both routing maps,
// and creates the CEF browser bound to a HostClient that holds the slot.
void DoCreateBrowser(uint32_t wire_id, int w, int h, double dpr,
                     std::string url) {
  CEF_REQUIRE_UI_THREAD();
  if (wire_id > g_max_created_wire_id) g_max_created_wire_id = wire_id;
  if (g_shutting_down) return;
  ClaimFirstBeginFrameSource();
  // A load that beat this (paced) create frame here supersedes the create URL.
  bool early_trusted = false;
  bool early_untrusted = false;
  {
    auto early = g_early_nav.find(wire_id);
    if (early != g_early_nav.end()) {
      url = early->second.url;
      early_trusted = early->second.trusted;
      early_untrusted = !early->second.trusted;
      g_early_nav.erase(early);
    }
  }
  // WIRE-ID REUSE GUARD: the Swift side allocates ids monotonically, so a collision should be
  // impossible — but if one ever happened, registering the new slot would let the OLD browser's
  // OnBeforeClose later erase the NEW slot (g_slots_by_wire_id.erase(id)), leaving an unroutable
  // browser + a leaked IOSurface/dst_mtl. Fail loudly + tell the host (kOpCreateFailed advances
  // its pacer / drops the session) instead of silently corrupting cross-tile routing.
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    if (g_slots_by_wire_id.count(wire_id)) {
      SendLog(wire_id, "createBrowser: wire id already in use — refusing (id-reuse bug)");
      SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
      return;
    }
  }
  auto slot = std::make_shared<Slot>();
  slot->browser_id = wire_id;
  slot->width = w < 1 ? 1 : w;
  slot->height = h < 1 ? 1 : h;
  slot->dpr = dpr;
  {
    auto early = g_early_channels.find(wire_id);
    if (early != g_early_channels.end()) {
      slot->channels = std::move(early->second);
      g_early_channels.erase(early);
    }
  }
  // PRODUCER-ALLOCATES: no surface is created here. slot->surface stays nullptr until the first
  // OnAcceleratedPaint, where EnsureSurfaceForPaint mints it sized to the actual painted view.
  // The consumer adopts that surface's id from the first present.
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    g_slots_by_wire_id[wire_id] = slot;
  }
  CefWindowInfo window_info;
  window_info.SetAsWindowless(0);
#ifdef CEF_HOST_MULTIPROCESS
  // Multi-process GPU OSR: the GPU/Viz process composites on the GPU and hands
  // the frame to OnAcceleratedPaint as a shared IOSurface, which we copy into
  // the host surface. This used to be gated by -67030 (process_requirement.cc
  // peer validation of this process's ad-hoc signature), but disabling the
  // MachPortRendezvous*PeerRequirements features above clears it — so the
  // GPU-accelerated path runs multi-process (crash-isolated) without
  // Developer-ID signing. (The software OnPaint path remains the fallback if a
  // build leaves shared_texture_enabled off.) All browsers in this process share
  // one GPU/Viz process; set per-create, it resolves to that same process (the
  // second+ browser attaching cleanly is the one multiplex behavior to confirm
  // at runtime under a signed build).
  window_info.shared_texture_enabled = true;
#endif
  // Own the frame clock. Without this CEF's internal scheduler decides when to paint and can
  // skip the frame after a resize (a resize is viewport-only damage on an idle page), leaving
  // the tile stuck at the old size until real input forces a tick. With external begin-frame WE
  // drive every frame via SendExternalBeginFrame (the per-slot PumpBeginFrame), so a resize —
  // and all rendering — always produces a frame. NOTE: this turns the internal timer OFF, so the
  // pump MUST run for anything to render at all (started in OnAfterCreated).
  window_info.external_begin_frame_enabled = true;
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 60;
  // RENDER FLOOR: paint an OPAQUE background. With the default (alpha 0) a windowless
  // browser paints transparent, so a DROPPED renderer frame — the shared-GPU multiplex
  // failure where the 2nd+ browser's CompositorFrame never lands — is INVISIBLE (the canvas
  // shows through) and indistinguishable from "loading". Opaque means a missing frame reads
  // as a blank white tile (correct-looking for a not-yet-painted page) instead of a ghost,
  // and makes the failure diagnosable. Pages with their own bg paint over this normally.
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  // about:blank-first: for a real http(s) URL, establish on about:blank (near-instant
  // first frame → the pacer's establishment slot frees fast) and defer the real
  // navigation to first paint. Skip for data:/file:/about: (already instant) and when the
  // env flag is off.
  std::string create_url = url;
  if (std::getenv("FLUTTER_CEF_BLANK_FIRST") &&
      (url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0)) {
    slot->pending_nav_url = url;
    create_url = "about:blank";
  }
  // create-with-html/file: a data:/file: create URL is host-trusted content
  // injection (the same schemes loadHtmlString/loadFile use via kOpLoadTrusted),
  // and can NEVER arise from an untrusted page navigation — the scheme allowlist
  // refuses data:/file: in OnBeforeBrowse. So arm the trusted-load exemption for
  // the INITIAL load here, exactly as DoNavigateTrusted does, letting a consumer
  // create the browser directly on its authored document in ONE step (no
  // about:blank + later loadHtmlString, which raced blank). Identical trust model
  // to a post-create loadTrusted; only the timing (at create) differs.
  // A plain navigate that arrived before the create replaced its URL above; it
  // is not host content, so it stays gated like any navigate.
  if (!g_allowed_schemes.empty() && !early_untrusted &&
      (create_url.rfind("data:", 0) == 0 ||
       create_url.rfind("file:", 0) == 0)) {
    slot->trusted_pending.insert(create_url);
  }
  // Same exemption for a parked trusted load, and for a create ON an authored
  // document's URL (the host chose that content). Armed for `url`, not
  // `create_url`: under blank-first the real load is the deferred one.
  if (!g_allowed_schemes.empty() && create_url.rfind("data:", 0) != 0 &&
      create_url.rfind("file:", 0) != 0 &&
      (early_trusted || LookupAuthoredDoc(wire_id, url, nullptr))) {
    slot->trusted_pending.insert(NormalizeAuthoredUrl(url));
  }
  CefRefPtr<CefClient> client = NewHostClient(slot);
  // ASYNC create. CreateBrowserSync BLOCKS this (the single CEF UI) thread until
  // the renderer + GPU/Viz accelerated-surface handshake completes — so a burst of
  // creates serialized here, contended the one shared GPU process (later browsers got
  // no surface, never painted), and one hung create wedged input/resize/dispose for
  // every sibling. CreateBrowser returns immediately; the browser is bound to its slot
  // in HostClient::OnAfterCreated, which acks kOpCreated so the host's pacer sends the
  // NEXT create — serialized by COMPLETION, not a wall-clock guess.
  // Document-start scripts + create-time JS channels ride into the renderer as
  // the browser's extra_info (see document_start.h) — the only channel that is
  // in place before the first document's scripts run.
  bool dispatched = CefBrowserHost::CreateBrowser(
      window_info, client, create_url, settings,
      TakeDocumentStartExtraInfo(wire_id, &slot->channels), nullptr);
  if (!dispatched) {
    // The create couldn't even be dispatched — OnAfterCreated/OnBeforeClose will
    // never fire, so reclaim the slot + the looked-up IOSurface (+1 ref) here (else
    // they leak and the wire id is stranded) and tell the host so it drops the session
    // (processGone) and its create-pacer advances instead of stalling on the ack.
    SendLog(wire_id, "createBrowser: CreateBrowser dispatch failed");
    SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(wire_id);
    }
    std::lock_guard<std::mutex> slock(slot->surface_mutex);
    if (slot->surface) {
      CFRelease(slot->surface);
      slot->surface = nullptr;
    }
    [slot->dst_mtl release];
    slot->dst_mtl = nil;
    slot->dst_mtl_sid = 0;
  } else {
    ++g_open_browsers;  // until its OnBeforeClose
  }
  if (g_debug)
    fprintf(stderr, "[cef_host] createBrowser wire=%u dispatched=%d\n", wire_id,
            dispatched);
}

// Close one browser (kOpDisposeBrowser). Runs on the CEF UI thread. The actual
// map-erase + surface release happen in OnBeforeClose once CEF finishes closing.
void DoDisposeBrowser(uint32_t wire_id) {
  CEF_REQUIRE_UI_THREAD();
  std::shared_ptr<Slot> slot = LookupWireId(wire_id);
  if (!slot) {
    // Never created (disposed while its create was still paced host-side), or
    // already closed: drop whatever was parked for it.
    SetAuthoredDoc(wire_id, "", "");
    SetDocumentStart(wire_id, {});
    g_early_nav.erase(wire_id);
    g_early_channels.erase(wire_id);
    return;
  }
  CloseWindowedBrowsers(wire_id);
  if (slot->browser) {
    slot->browser->GetHost()->CloseBrowser(true);
  } else {
    // The async CreateBrowser hasn't bound the browser yet — record the close so
    // OnAfterCreated closes it the instant it lands. Without this the create completes
    // into a live orphan browser the Swift side has already forgotten (browsers[id]
    // cleared), leaking a renderer + IOSurface until whole-host shutdown.
    slot->close_requested = true;
  }
}

void DoResize(const std::shared_ptr<Slot>& slot, int w, int h, double dpr) {
  if (w < 1 || w > kMaxViewDim || h < 1 || h > kMaxViewDim) {
    SendLog(slot->browser_id, "resize: out-of-range dims " + std::to_string(w) +
                                  "x" + std::to_string(h));
    return;
  }
  // PRODUCER-ALLOCATES: resize no longer touches the surface — it only updates the logical
  // geometry + dpr and kicks CEF to re-raster. CEF then paints a new-size view_src, and
  // EnsureSurfaceForPaint (in the composite path) reallocates slot->surface to match + the next
  // present hands the consumer the new id. So there is no IOSurfaceLookup/CFRelease-swap here
  // (that was the consumer-allocates handoff that could crop when src≠dst). dpr<=0 = unchanged.
  bool dpr_changed = false;
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    slot->width = w;
    slot->height = h;
    if (dpr > 0.0 && dpr != slot->dpr) {
      slot->dpr = dpr;
      dpr_changed = true;
    }
    // dst_mtl is rebuilt by EnsureSurfaceForPaint on the realloc; nil it here too so a same-size
    // relayout that doesn't realloc still drops a wrap that could be mid-rebuild (belt + suspenders).
    [slot->dst_mtl release];
    slot->dst_mtl = nil;
    slot->dst_mtl_sid = 0;
  }
  if (slot->browser) {
    if (slot->visible) {
      // A device-scale change needs the renderer told (screen info), not just a relayout.
      if (dpr_changed) slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->browser->GetHost()->WasResized();
      // Drive a frame right now at the new size. With external begin-frame this is a guaranteed
      // tick (not a coalesce-able Invalidate request), so the re-laid-out content composites into
      // the new surface immediately; PumpBeginFrame's ongoing ticks cover the heavy-page settle.
      slot->browser->GetHost()->SendExternalBeginFrame();
    } else {
      // HIDDEN — the begin-frame pump is gated off (PumpBeginFrame skips while
      // !visible), so WasResized()+SendExternalBeginFrame() here would never paint the
      // freshly-swapped (blank) surface, yet the Swift resizeWatchdog would force-promote
      // it to the live texture → permanent blank on a static page. The surface + dims are
      // already swapped above (geometry is current); defer the screen-info re-assert + the
      // repaint to DoSetVisible's hidden->visible edge. WasResized while hidden is
      // pointless (no frame can result), so it is dropped, not deferred.
      if (dpr_changed) slot->needs_screen_info_on_show = true;
    }
  }
}

void DoNavigate(const std::shared_ptr<Slot>& slot, const std::string& url) {
  if (!slot->browser) {
    // The slot exists but the browser is not yet BOUND (OnAfterCreated pending) — e.g. a
    // loadHtmlString that arrived right behind a queued createBrowser in a shared-host burst
    // (6 agent_ui tiles created at once). Defer instead of dropping: OnAfterCreated loads
    // it, and a trusted load keeps its armed exemption in trusted_pending. Dropping here is
    // exactly why such a burst stayed blank. It supersedes a blank-first deferred load.
    slot->nav_after_create = url;
    slot->pending_nav_url.clear();
    return;
  }
  CefRefPtr<CefFrame> f = slot->browser->GetMainFrame();
  if (f) f->LoadURL(url);
}

// A host content-injection load (loadHtmlString -> data:, loadFile -> file:).
// Runs on the CEF UI thread. Arm an exact-URL exemption so this specific load's
// OnBeforeBrowse (a later UI task) skips the scheme allowlist, while a page nav
// to any other URL stays gated. Only arm when an allowlist is actually set —
// g_allowed_schemes is immutable after startup, so when the feature is off this
// is a plain navigate and we don't accumulate unconsumed entries. Trusted
// because the host explicitly chose this content, not the page.
void DoNavigateTrusted(const std::shared_ptr<Slot>& slot,
                       const std::string& url) {
  // Normalized: OnBeforeBrowse matches against the CANONICAL request URL, so an
  // authored load for "https://host" must be armed as "https://host/".
  if (!g_allowed_schemes.empty())
    slot->trusted_pending.insert(NormalizeAuthoredUrl(url));
  DoNavigate(slot, url);
}

// Navigate / loadTrusted resolved by wire id ON the UI thread, not the reader thread. On a
// shared host the createBrowser for this id is queued ahead of us on TID_UI (FIFO ordering),
// so LookupWireId is null on the reader thread but registered by the time this task runs —
// dropping the op on the reader thread (the old `if (!slot) break`) is why a burst of tiles
// that loadHtmlString right after create stayed blank. Mirrors the kOpAddChannel fix. With
// trusted=true the allowlist exemption is armed and a not-yet-bound browser is tolerated via
// pending_nav_url (DoNavigate above).
void DoNavigateByWireId(uint32_t wire_id, std::string url, bool trusted) {
  auto slot = LookupWireId(wire_id);
  if (!slot) {
    // Ids are monotonic: an id ABOVE every create we've seen is a browser whose
    // create frame the host is still pacing (it sends creates one establishment at
    // a time, but every other op immediately) — park the load for DoCreateBrowser.
    // An id at or below it was genuinely disposed before the nav landed.
    if (wire_id > g_max_created_wire_id) g_early_nav[wire_id] = {url, trusted};
    return;
  }
  if (trusted)
    DoNavigateTrusted(slot, url);
  else
    DoNavigate(slot, url);
}

void DoReload(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->Reload();
}
void DoStopLoad(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->StopLoad();
}
void DoGoBack(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GoBack();
}
void DoGoForward(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GoForward();
}
void DoExecuteJs(const std::shared_ptr<Slot>& slot, const std::string& code) {
  if (!slot->browser) return;
  CefRefPtr<CefFrame> f = slot->browser->GetMainFrame();
  if (f) f->ExecuteJavaScript(code, "", 0);
}
void DoSetZoom(const std::shared_ptr<Slot>& slot, double level) {
  if (slot->browser) slot->browser->GetHost()->SetZoomLevel(level);
}
// Run a browser edit command on the FOCUSED frame. OSR has no AppKit responder
// chain, so a raw ⌘C/⌘V key event never becomes an editor action — the host
// invokes these explicitly (CefWebView wires the shortcuts). CefFrame's methods
// are no-ops when nothing is focused/selected. UI-thread only.
void DoEditCommand(const std::shared_ptr<Slot>& slot, int command) {
  CEF_REQUIRE_UI_THREAD();
  if (!slot->browser) return;
  CefRefPtr<CefFrame> frame = slot->browser->GetFocusedFrame();
  if (!frame) return;
  switch (command) {
    case 0: frame->Copy(); break;
    case 1: frame->Cut(); break;
    case 2: frame->Paste(); break;
    case 3: frame->SelectAll(); break;
    case 4: frame->Undo(); break;
    case 5: frame->Redo(); break;
    default: break;
  }
}
// Off-screen render gating. WasHidden(true) makes CEF stop producing frames
// (no OnPaint, the compositor idles) until WasHidden(false); the browser stays
// alive, so this is a cheap pause/resume — not a teardown. The host pauses a
// tile that scrolls fully out of the canvas viewport and resumes it on return.
void DoSetVisible(const std::shared_ptr<Slot>& slot, bool visible) {
  const bool was_visible = slot->visible;
  slot->visible = visible;  // PumpBeginFrame reads this to idle the begin-frame pump while hidden
  if (!slot->browser) return;
  slot->browser->GetHost()->WasHidden(!visible);
  // On the hidden->visible edge, FORCE a fresh full-viewport repaint at the
  // current geometry. WasHidden(false) alone does NOT repaint, and three things can have left
  // the live texture blank/stale while hidden: (a) a resize landed while the pump was gated off
  // (DoResize deferred its paint here); (b) a dpr/screen-info change was deferred; (c) Chromium's
  // FrameEvictionManager reclaimed the off-screen compositor frame entirely (happens past ~5
  // browsers / under memory pressure) so there is nothing to show even though geometry is
  // unchanged. Re-assert screen info (if a dpr change was deferred) + size, then drive a
  // guaranteed frame — mirrors DoResize/DoInvalidate. Unconditional on the edge because the
  // eviction case carries no resize to key off.
  if (visible && !was_visible) {
    if (slot->needs_screen_info_on_show) {
      slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->needs_screen_info_on_show = false;
    }
    slot->browser->GetHost()->WasResized();
    slot->browser->GetHost()->Invalidate(PET_VIEW);
    slot->browser->GetHost()->SendExternalBeginFrame();
  }
}
void DoSetAudioMuted(const std::shared_ptr<Slot>& slot, bool muted) {
  if (slot->browser) slot->browser->GetHost()->SetAudioMuted(muted);
}
// Write a camera+mic content setting for `origin` on this browser's context.
// This is what makes a decision STICK the way a browser's does — and what
// un-poisons an origin Chromium has already stored a BLOCK for (with a stored
// BLOCK it short-circuits getUserMedia and never consults the permission
// handler, so a site the user once denied would otherwise be permanently dead
// with no way back). UI-thread only.
namespace {
void SetMediaContentSetting(const std::shared_ptr<Slot>& slot,
                            const std::string& origin,
                            cef_content_setting_values_t value) {
  CEF_REQUIRE_UI_THREAD();
  if (!slot->browser) return;
  // Content settings are origin-keyed; only http(s) carries one worth writing
  // (about:blank et al have no meaningful origin to remember).
  if (origin.rfind("https://", 0) != 0 && origin.rfind("http://", 0) != 0) return;
  CefRefPtr<CefRequestContext> ctx =
      slot->browser->GetHost()->GetRequestContext();
  if (!ctx) return;
  ctx->SetContentSetting(origin, CefString(),
                         CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, value);
  ctx->SetContentSetting(origin, CefString(),
                         CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC, value);
}
}  // namespace

// Answer a pending prompt (kOpMediaRequest -> the host showed UI -> the user
// chose). Grants all-or-nothing because Continue must MATCH the getUserMedia
// request.
//
// `remember` MUST be set only when a human actually chose. The host also denies
// defensively — no permission UI wired up, the prompt handler threw, the tile
// was torn down or its page replaced mid-prompt — and persisting those as a
// site-wide BLOCK would permanently, silently kill camera/mic for the site with
// no request left to re-prompt on. Deny transiently instead: the page simply
// asks again next time.
// Answer a Flutter-drawn context menu. commandId 0 means dismissed: CEF requires
// the callback be answered exactly once either way, so a dismissal must Cancel
// rather than simply drop the entry — otherwise the page's menu logic hangs and
// the next right-click is ignored.
void DoContextMenuCommand(const std::shared_ptr<Slot>& slot, uint32_t id,
                          uint32_t command) {
  CEF_REQUIRE_UI_THREAD();
  CefRefPtr<CefRunContextMenuCallback> cb;
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    auto it = slot->context_menus.find(id);
    if (it == slot->context_menus.end()) return;  // already answered/dismissed
    cb = it->second;
    slot->context_menus.erase(it);
  }
  if (!cb) return;
  if (command == 0) {
    cb->Cancel();
  } else {
    cb->Continue(static_cast<int>(command), EVENTFLAG_NONE);
  }
}

void DoMediaResponse(const std::shared_ptr<Slot>& slot, uint32_t id, bool allow,
                     bool remember) {
  CEF_REQUIRE_UI_THREAD();
  auto it = slot->media_requests.find(id);
  if (it == slot->media_requests.end()) return;  // already answered/abandoned
  const uint32_t wanted = it->second.wanted;
  const std::string origin = it->second.origin;
  CefRefPtr<CefMediaAccessCallback> cb = it->second.callback;
  slot->media_requests.erase(it);
  // Remember BEFORE continuing: the page may re-ask the instant it is answered,
  // and the stored setting is what keeps that from re-prompting.
  //
  // Only an ALLOW is ever written here. A stored BLOCK is visible to the page
  // via navigator.permissions.query(), and sites check it before asking — so
  // writing one makes their own "use camera" button do nothing and leaves no
  // request to prompt on. A refusal is remembered on the Campus side instead.
  if (remember) {
    SetMediaContentSetting(slot, origin,
                           allow ? CEF_CONTENT_SETTING_VALUE_ALLOW
                                 : CEF_CONTENT_SETTING_VALUE_DEFAULT);
  }
  if (cb) cb->Continue(allow ? wanted : CEF_MEDIA_PERMISSION_NONE);
  SendMediaState(slot);  // refresh the indicator for the new decision
}

// The URL-bar "site settings" path: rewrite THIS page's camera+mic decision
// (0 = ask again / forget, 1 = allow, 2 = block).
//
// Deliberately does NOT reload. A browser never yanks the page out from under
// you to change a site permission — the new decision simply applies the next
// time the page asks. Reloading here also had a surprising side effect: the page
// re-runs its startup getUserMedia, so the permission prompt appeared by itself
// right after the reload instead of when the user pressed the site's own
// "use camera" button. An already-running stream keeps running (it belongs to
// the page), which is also what a browser does.
void DoSetMediaSetting(const std::shared_ptr<Slot>& slot, uint8_t value) {
  CEF_REQUIRE_UI_THREAD();
  if (!slot->browser) return;
  CefRefPtr<CefFrame> frame = slot->browser->GetMainFrame();
  const std::string url = frame ? frame->GetURL().ToString() : std::string();
  // 1 = allow; anything else clears the stored decision. "Block" deliberately
  // does NOT write CEF_CONTENT_SETTING_VALUE_BLOCK — see DoMediaResponse: a
  // stored block is readable by the page and stops it from ever asking.
  const cef_content_setting_values_t setting =
      value == 1 ? CEF_CONTENT_SETTING_VALUE_ALLOW
                 : CEF_CONTENT_SETTING_VALUE_DEFAULT;
  SetMediaContentSetting(slot, url, setting);
  SendMediaState(slot);  // the indicator reflects the new decision immediately
}

void DoSetPumpInterval(const std::shared_ptr<Slot>& slot, int ms) {
  // Clamp: <8ms buys nothing over 60fps begin-frames + risks pump starvation;
  // >250ms visible would read as a frozen tile.
  slot->pump_interval_ms = ms < 8 ? 8 : (ms > 250 ? 250 : ms);
}
void DoFind(const std::shared_ptr<Slot>& slot, const std::string& text,
            bool forward, bool match_case, bool find_next) {
  if (slot->browser)
    slot->browser->GetHost()->Find(text, forward, match_case, find_next);
}
void DoStopFind(const std::shared_ptr<Slot>& slot, bool clear_selection) {
  if (slot->browser) slot->browser->GetHost()->StopFinding(clear_selection);
}
void DoJsDialogResp(const std::shared_ptr<Slot>& slot, uint32_t id, bool ok,
                    const std::string& text) {
  auto it = slot->dialogs.find(id);
  if (it == slot->dialogs.end()) return;
  // Out of the map before Continue(): it can re-enter OnResetDialogState, which
  // clears the map under the iterator (answering any alert crashed the host).
  CefRefPtr<CefJSDialogCallback> callback = it->second;
  slot->dialogs.erase(it);
  callback->Continue(ok, text);
}
// ALWAYS REPLIES. Resolved by wire id on TID_UI (FIFO behind a queued create, like
// DoNavigateByWireId); with no browser/frame to run in, answer {ok:false} rather
// than return silently — a silent return left the caller's future pending forever.
// Evals in flight per browser beyond which the oldest are forgotten (their
// replies then refused). The Dart side fails a pending eval on navigation, so
// only a page that never answers leaves entries behind.
namespace {
constexpr size_t kMaxPendingEvals = 1024;
}  // namespace

void DoEvalReturning(uint32_t wire_id, uint32_t id, const std::string& code) {
  auto slot = LookupWireId(wire_id);
  CefRefPtr<CefFrame> frame =
      (slot && slot->browser) ? slot->browser->GetMainFrame() : nullptr;
  if (id == kLivenessPingId) {
    // Asked of the renderer itself, not the page. No frame: nothing is
    // answering, so no reply either.
    if (frame)
      frame->SendProcessMessage(
          PID_RENDERER, CefProcessMessage::Create(renderer_messages::kPing));
    return;
  }
  if (!frame) {
    SendUtf8(wire_id, kOpEvalResult,
             std::to_string(id) + ":{\"ok\":false,\"v\":\"no browser\"}");
    return;
  }
  // Evaluate the user expression and post its JSON result back via window.cefQuery
  // (OnQuery -> kOpEvalResult). `code` is the trusted host's JS (same trust level
  // as executeJavaScript) and must be a single expression. We splice it rather
  // than eval() it so it still works under a strict page CSP (eval would be
  // blocked); the Dart side fails any pending result on navigation so a malformed
  // expression that wedges this callback can't leak a completer forever.
  // The nonce ties the reply to this request (see Slot::pending_evals).
  const std::string nonce = RandomNonce();
  slot->pending_evals[id] = nonce;
  if (slot->pending_evals.size() > kMaxPendingEvals)
    slot->pending_evals.erase(slot->pending_evals.begin());
  std::string js =
      "window.cefQuery({request:'eval:" + std::to_string(id) + ":" + nonce +
      ":'+(function(){try{return JSON.stringify({ok:true,v:(" + code +
      "\n)});}catch(e){return JSON.stringify({ok:false,v:String(e)});}})(),"
      "persistent:false,onSuccess:function(){},onFailure:function(){}});";
  frame->ExecuteJavaScript(js, "", 0);
}
// Registers a JS channel for one browser (UI thread). Resolved by wire id here,
// not on the reader thread: on a shared host the browser's create may still be
// queued, so a channel for an id above every create seen is parked for it.
void DoAddChannel(uint32_t wire_id, const std::string& name) {
  CEF_REQUIRE_UI_THREAD();
  if (!IsValidChannelName(name)) {
    SendLog(wire_id, "addJavaScriptChannel: rejected invalid name '" + name +
                         "' (must be a JS identifier)");
    return;
  }
  auto slot = LookupWireId(wire_id);
  if (!slot) {
    if (wire_id > g_max_created_wire_id) g_early_channels[wire_id].insert(name);
    return;
  }
  slot->channels.insert(name);
  // Inject into the current page too, for a channel registered after it loaded.
  if (slot->browser) InjectChannelShim(slot->browser->GetMainFrame(), name);
}
// Cookie ops act on the GLOBAL cookie manager (= the shared profile jar), so a
// login in one browser is visible to every browser sharing this profile. They
// take `slot` only to stamp the reply browserId / route a log. Note clear/delete
// affect the WHOLE shared jar by design (the contract's kOpClearCookies semantics).
// Map the wire sameSite token to Chromium's enum (and back for getCookies).
namespace {
cef_cookie_same_site_t ParseSameSite(const std::string& s) {
  if (s == "none") return CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
  if (s == "lax") return CEF_COOKIE_SAME_SITE_LAX_MODE;
  if (s == "strict") return CEF_COOKIE_SAME_SITE_STRICT_MODE;
  return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
}
const char* SameSiteToString(cef_cookie_same_site_t v) {
  switch (v) {
    case CEF_COOKIE_SAME_SITE_NO_RESTRICTION: return "none";
    case CEF_COOKIE_SAME_SITE_LAX_MODE: return "lax";
    case CEF_COOKIE_SAME_SITE_STRICT_MODE: return "strict";
    default: return "unspecified";
  }
}
}  // namespace

// COOKIE VERBS TAKE A WIRE ID, NOT A SLOT. The jar is process-global, so nothing
// here needs the browser — the id only routes the reply/log. Requiring a live slot
// (the old `if (!slot) break` on the reader thread) silently DROPPED any cookie verb
// that raced the create: the slot is registered by a TID_UI task, and on a shared
// host the create frame itself is paced behind earlier ones. A dropped setCookie
// meant an unauthenticated first load; a dropped getCookies never replied at all,
// so the caller's future hung forever.
void DoSetCookie(uint32_t wire_id, const std::string& url,
                 const std::string& name, const std::string& value,
                 const std::string& domain, const std::string& path,
                 bool secure, bool http_only, const std::string& same_site) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (!mgr) return;
  CefCookie cookie;
  CefString(&cookie.name).FromString(name);
  CefString(&cookie.value).FromString(value);
  if (!domain.empty()) CefString(&cookie.domain).FromString(domain);
  CefString(&cookie.path).FromString(path.empty() ? "/" : path);
  cookie.has_expires = false;
  // SameSite=None without Secure is rejected by Chromium (the cookie is
  // dropped at SetCookie time), so force Secure on for that combination.
  cookie.secure = (secure || same_site == "none") ? 1 : 0;
  cookie.httponly = http_only ? 1 : 0;
  cookie.same_site = ParseSameSite(same_site);
  if (!mgr->SetCookie(url, cookie, nullptr)) {
    SendLog(wire_id,
            "setCookie rejected for " + url + " (name '" + name + "')");
  }
}
void DoClearCookies() {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(CefString(), CefString(), nullptr);
}

namespace {

std::string CookieToJson(const CefCookie& c) {
  std::string out = "{";
  out += "\"name\":\"" + JsonEscape(CefString(&c.name).ToString()) + "\",";
  out += "\"value\":\"" + JsonEscape(CefString(&c.value).ToString()) + "\",";
  out += "\"domain\":\"" + JsonEscape(CefString(&c.domain).ToString()) + "\",";
  out += "\"path\":\"" + JsonEscape(CefString(&c.path).ToString()) + "\",";
  out += "\"secure\":" + std::string(c.secure ? "true" : "false") + ",";
  out += "\"httpOnly\":" + std::string(c.httponly ? "true" : "false") + ",";
  out += "\"sameSite\":\"" + std::string(SameSiteToString(c.same_site)) + "\"";
  return out + "}";
}

// Accumulates a Visit pass and flushes the JSON array on destruction, so the
// 0-cookie case (Visit never called) still replies (godot-cef does the same).
class HostCookieVisitor : public CefCookieVisitor {
 public:
  HostCookieVisitor(uint32_t browser_id, uint32_t id)
      : browser_id_(browser_id), id_(id) {}
  bool Visit(const CefCookie& cookie, int, int, bool&) override {
    if (!json_.empty()) json_ += ",";
    json_ += CookieToJson(cookie);
    return true;
  }
  ~HostCookieVisitor() override {
    // Stamp the reply with the browser that asked, so the host routes the
    // kOpCookies result back to the right CefWebSession.
    SendCodePlusUtf8(browser_id_, kOpCookies, id_, "[" + json_ + "]");
  }

 private:
  uint32_t browser_id_;
  uint32_t id_;
  std::string json_;
  IMPLEMENT_REFCOUNTING(HostCookieVisitor);
};

}  // namespace

void DoVisitCookies(uint32_t wire_id, uint32_t id, const std::string& url) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  // The visitor replies on destruction; a null manager just yields [].
  CefRefPtr<HostCookieVisitor> visitor =
      new HostCookieVisitor(wire_id, id);
  if (!mgr) return;
  if (url.empty()) {
    mgr->VisitAllCookies(visitor);
  } else {
    mgr->VisitUrlCookies(url, true, visitor);
  }
}

void DoDeleteCookie(const std::string& url, const std::string& name) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(url, name, nullptr);
}

void DoShowDevTools(const std::shared_ptr<Slot>& slot, int inspect_x,
                    int inspect_y) {
  if (!slot->browser) return;
  // Windowed DevTools (default CefWindowInfo is windowed) — the OSR host can
  // still host a real window. null client lets CEF manage it.
  //
  // A non-negative point opens DevTools already inspecting the element there,
  // which is what "Inspect" from a right-click means. DevTools is a real window
  // (unlike the page itself), so nothing here depends on OSR having one.
  CefWindowInfo window_info;
  CefBrowserSettings settings;
  const CefPoint at = (inspect_x >= 0 && inspect_y >= 0)
                          ? CefPoint(inspect_x, inspect_y)
                          : CefPoint();
  slot->browser->GetHost()->ShowDevTools(window_info, nullptr, settings, at);
}

namespace {

// Resolve a browser's CDP targetId so the Swift relay can scope an agent's
// CDP session to exactly this tile. Extract the first quoted string value for `key`
// from a flat CDP result JSON (targetIds are GUIDs with no embedded quotes/escapes).
std::string ExtractJsonStringField(const std::string& json,
                                   const std::string& key) {
  std::string needle = "\"" + key + "\"";
  size_t k = json.find(needle);
  if (k == std::string::npos) return "";
  size_t colon = json.find(':', k + needle.size());
  if (colon == std::string::npos) return "";
  size_t q1 = json.find('"', colon + 1);
  if (q1 == std::string::npos) return "";
  size_t q2 = json.find('"', q1 + 1);
  if (q2 == std::string::npos) return "";
  return json.substr(q1 + 1, q2 - q1 - 1);
}

constexpr int kTargetInfoMsgId = 0x7e57;  // fixed id for our Target.getTargetInfo probe

// Receives the Target.getTargetInfo result for one browser and reports its targetId
// back to the plugin (kOpTargetId). UI-thread callbacks. One per browser.
class TargetIdObserver : public CefDevToolsMessageObserver {
 public:
  explicit TargetIdObserver(uint32_t wire_id) : wire_id_(wire_id) {}
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id,
                              bool success, const void* result,
                              size_t result_size) override {
    // Match this browser's CURRENT probe id (ids now increment per resolve, so a
    // fixed constant would miss every probe after the first). UI-thread, like the
    // resolve that set it.
    auto slot = LookupWireId(wire_id_);
    if (!slot || message_id != slot->target_info_msg || !success || !result ||
        result_size == 0)
      return;
    std::string json(static_cast<const char*>(result), result_size);
    // Anchor to the targetInfo object first, so a differently-named *targetId* field
    // (e.g. openerId/browserContextId) earlier in the JSON can't be mistaken for it.
    size_t ti = json.find("\"targetInfo\"");
    std::string scope = (ti != std::string::npos) ? json.substr(ti) : json;
    std::string tid = ExtractJsonStringField(scope, "targetId");
    if (!tid.empty()) SendUtf8(wire_id_, kOpTargetId, tid);
  }

 private:
  uint32_t wire_id_;
  IMPLEMENT_REFCOUNTING(TargetIdObserver);
};

// A fresh DevTools message id for this browser. The session wants increasing ids,
// and CEF silently renumbers one that isn't — which would orphan a caller that
// matches its reply by id — so every ExecuteDevToolsMethod here draws from this.
int NextDevToolsMsgId(const std::shared_ptr<Slot>& slot) {
  slot->devtools_msg = slot->devtools_msg < kTargetInfoMsgId
                           ? kTargetInfoMsgId
                           : slot->devtools_msg + 1;
  return slot->devtools_msg;
}

}  // namespace

void DoResolveTargetId(const std::shared_ptr<Slot>& slot) {
  if (!slot->browser) return;
  CefRefPtr<CefBrowserHost> host = slot->browser->GetHost();
  if (!host) return;
  if (!slot->devtools_reg) {
    slot->devtools_reg =
        host->AddDevToolsMessageObserver(new TargetIdObserver(slot->browser_id));
  }
  // Fresh, increasing id per probe (see Slot::target_info_msg) so a re-resolve on the
  // SAME browser isn't dropped by the DevTools session's monotonic-id requirement.
  slot->target_info_msg = NextDevToolsMsgId(slot);
  // Target.getTargetInfo with no params: executed on a specific browser's DevTools
  // agent (a page target), it returns THAT page's own targetInfo — so this resolves
  // exactly this browser's targetId, with no cross-tile ambiguity.
  host->ExecuteDevToolsMethod(slot->target_info_msg, "Target.getTargetInfo", nullptr);
}

void DoImeSetComposition(const std::shared_ptr<Slot>& slot,
                         const std::string& text) {
  if (!slot->browser) return;
  CefString t(text);
  uint32_t len = static_cast<uint32_t>(t.length());
  // Mark the whole composition with a single underline so the in-progress text
  // is visibly distinguished (transparent color -> Blink picks an adaptive
  // default that reads on both light and dark pages). The caret sits at the end.
  std::vector<CefCompositionUnderline> underlines;
  if (len > 0) {
    CefCompositionUnderline u;
    u.range = CefRange(0, len);
    u.color = 0;             // transparent: let Blink choose a contrasting color
    u.background_color = 0;  // transparent background
    u.thick = 0;             // thin underline
    u.style = CEF_CUS_SOLID;
    underlines.push_back(u);
  }
  slot->browser->GetHost()->ImeSetComposition(t, underlines,
                                              CefRange::InvalidRange(),
                                              CefRange(len, len));
}
void DoImeCommitText(const std::shared_ptr<Slot>& slot,
                     const std::string& text) {
  if (slot->browser)
    slot->browser->GetHost()->ImeCommitText(text, CefRange::InvalidRange(), 0);
}
void DoImeCancel(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GetHost()->ImeCancelComposition();
}

// type: 0=move 1=down 2=up 3=wheel; button: 0=left 1=middle 2=right.
void DoPointer(const std::shared_ptr<Slot>& slot, int type, int button,
               int click_count, uint32_t modifiers, double x, double y,
               double dx, double dy) {
  if (!slot->browser) return;
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;
  CefRefPtr<CefBrowserHost> host = slot->browser->GetHost();
  switch (type) {
    case 0:
      host->SendMouseMoveEvent(ev, false);
      break;
    case 1:
      // Give the browser keyboard focus on press so text fields take input and
      // show a caret (CEF won't route key events to an unfocused OSR browser).
      host->SetFocus(true);
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), false, click_count);
      break;
    case 2:
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), true, click_count);
      break;
    case 4:
      // Cursor left the view: a move with mouseLeave=true clears hover state.
      host->SendMouseMoveEvent(ev, true);
      break;
    case 3:
      host->SendMouseWheelEvent(ev, static_cast<int>(dx), static_cast<int>(dy));
      break;
    default:
      break;
  }
}

namespace {

// A keydown AppKit's key bindings give an editing meaning (⌘← = line start, ⌃K =
// kill to paragraph end, …) goes out through DevTools with those edit commands
// attached, as a windowed Chrome would send it: SendKeyEvent has no way to carry
// them. The page still sees an ordinary keydown first; the commands are only its
// default action. See mac_key_bindings.h.
bool DispatchBoundKey(const std::shared_ptr<Slot>& slot, uint32_t modifiers,
                      int32_t windows_key_code, int32_t native_key_code) {
  mac_key_bindings::Match match;
  if (!mac_key_bindings::Lookup(modifiers, windows_key_code, &match)) return false;
  int cdp_modifiers = 0;
  if (modifiers & EVENTFLAG_ALT_DOWN) cdp_modifiers |= 1;
  if (modifiers & EVENTFLAG_CONTROL_DOWN) cdp_modifiers |= 2;
  if (modifiers & EVENTFLAG_COMMAND_DOWN) cdp_modifiers |= 4;
  if (modifiers & EVENTFLAG_SHIFT_DOWN) cdp_modifiers |= 8;
  CefRefPtr<CefListValue> commands = CefListValue::Create();
  for (size_t i = 0; i < match.commands.size(); i++)
    commands->SetString(i, match.commands[i]);
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("type", "rawKeyDown");
  params->SetInt("modifiers", cdp_modifiers);
  params->SetInt("windowsVirtualKeyCode", windows_key_code);
  params->SetInt("nativeVirtualKeyCode", native_key_code);
  params->SetString("code", match.code);
  params->SetString("key", match.key);
  params->SetList("commands", commands);
  return slot->browser->GetHost()->ExecuteDevToolsMethod(
             NextDevToolsMsgId(slot), "Input.dispatchKeyEvent", params) != 0;
}

}  // namespace

// type: 0=rawkeydown 2=keyup 3=char (cef_key_event_type_t).
void DoKey(const std::shared_ptr<Slot>& slot, int type, uint32_t modifiers,
           int32_t windows_key_code, int32_t native_key_code,
           uint32_t character) {
  if (!slot->browser) return;
  if (type == KEYEVENT_RAWKEYDOWN &&
      DispatchBoundKey(slot, modifiers, windows_key_code, native_key_code))
    return;
  CefKeyEvent ev;
  ev.type = static_cast<cef_key_event_type_t>(type);
  ev.modifiers = modifiers;
  ev.windows_key_code = windows_key_code;
  ev.native_key_code = native_key_code;
  // ALWAYS set the character fields, not just for CHAR. On macOS OSR, an editing
  // or navigation key (Backspace, arrows, …) with a zero character is applied
  // TWICE inside Blink — populating it with the real NSEvent codepoint
  // de-duplicates it (CEF forum t=11650). 0 for printable keys is fine: their
  // text rides the IME ImeCommitText path, and a raw keydown inserts nothing.
  ev.character = static_cast<char16_t>(character);
  ev.unmodified_character = static_cast<char16_t>(character);
  slot->browser->GetHost()->SendKeyEvent(ev);
}

// Force a repaint. The host's first-present watchdog sends kOpInvalidate when a
// browser hasn't delivered its first frame within the deadline — re-requesting the
// frame self-heals a dropped/raced first paint instead of a permanently blank texture.
void DoInvalidate(const std::shared_ptr<Slot>& slot) {
  CEF_REQUIRE_UI_THREAD();
  if (slot && slot->browser && slot->browser->GetHost()) {
    slot->browser->GetHost()->Invalidate(PET_VIEW);
    // With external begin-frame the internal timer is off, so Invalidate alone may never paint —
    // drive a guaranteed frame so a watchdog re-kick actually delivers.
    slot->browser->GetHost()->SendExternalBeginFrame();
  }
}

}  // namespace cef_host
