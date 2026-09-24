#include "host_client.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "authored_content.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_message_router.h"
#include "ipc.h"
#include "popups.h"
#include "render_handler.h"
#include "renderer_messages.h"

namespace cef_host {

// The page's COMPLETE media status: what is capturing right now, plus the
// site's remembered decision. The stored setting has to be reported explicitly
// because Chromium enforces a remembered BLOCK itself, without ever calling the
// permission handler — so the UI could otherwise never learn that a site is
// blocked (there is no request to observe). UI-thread only (GetContentSetting).
void SendMediaState(const std::shared_ptr<Slot>& slot) {
  CEF_REQUIRE_UI_THREAD();
  uint8_t setting = 0;  // 0 = ask (no stored decision)
  if (slot->browser) {
    CefRefPtr<CefRequestContext> ctx =
        slot->browser->GetHost()->GetRequestContext();
    CefRefPtr<CefFrame> frame = slot->browser->GetMainFrame();
    const std::string url = frame ? frame->GetURL().ToString() : std::string();
    if (ctx &&
        (url.rfind("https://", 0) == 0 || url.rfind("http://", 0) == 0)) {
      const cef_content_setting_values_t cam = ctx->GetContentSetting(
          url, CefString(), CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
      const cef_content_setting_values_t mic = ctx->GetContentSetting(
          url, CefString(), CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
      // Heal a stored BLOCK from an older build, at LOAD time. It cannot wait
      // for the next getUserMedia: the page reads this through
      // navigator.permissions.query() BEFORE deciding whether to ask at all, so
      // a site that sees "denied" never calls getUserMedia and the request-time
      // heal would never run — the page stays permanently dead. Clearing it
      // here puts the site back to "ask"; a refusal now lives on the Campus
      // side, invisible to the page.
      if (cam == CEF_CONTENT_SETTING_VALUE_BLOCK ||
          mic == CEF_CONTENT_SETTING_VALUE_BLOCK) {
        ctx->SetContentSetting(url, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
        ctx->SetContentSetting(url, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
        setting = 0;
      } else if (cam == CEF_CONTENT_SETTING_VALUE_ALLOW ||
                 mic == CEF_CONTENT_SETTING_VALUE_ALLOW) {
        setting = 1;
      }
    }
  }
  const uint8_t p[3] = {static_cast<uint8_t>(slot->media_video_active ? 1 : 0),
                        static_cast<uint8_t>(slot->media_audio_active ? 1 : 0),
                        setting};
  SendFrame(slot->browser_id, kOpMediaState, p, 3);
}

namespace {

// Deny-default permission gate. With NO permission handler, CEF/Chromium has no
// per-site gate, so untrusted web content (including a third-party iframe on a
// trusted page) could reach camera/mic (getUserMedia), geolocation,
// notifications, etc. We deny every permission prompt and every media-access
// request up front. This is deliberately deny-ONLY: there is no host round-trip
// and no allow path. It does NOT touch WebAuthn / caBLE — passkeys are not a
// CefPermissionHandler permission type (they go through the authenticator /
// Bluetooth stack, gated by the OS + the bluetooth entitlement), so denying
// media/geo here leaves the passkey-over-Bluetooth flow untouched.
class HostPermissionHandler : public CefPermissionHandler {
 public:
  explicit HostPermissionHandler(std::shared_ptr<Slot> slot)
      : slot_(std::move(slot)) {}

  // getUserMedia (camera/mic): the standard BROWSER model — ask once per origin,
  // then remember. Never auto-grant: with no stored decision we hold the callback
  // and ask the host to show a prompt over the tile (kOpMediaRequest), and the
  // answer is written back as a per-origin content setting so the page is never
  // asked twice. Only DEVICE capture is ever on the table; DESKTOP capture
  // (screen-share) is dropped here and stays a separate capability.
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    const uint32_t device_only =
        static_cast<uint32_t>(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) |
        static_cast<uint32_t>(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE);
    const uint32_t wanted = requested_permissions & device_only;
    // Nothing grantable (e.g. a pure getDisplayMedia/desktop request) -> deny.
    if (!slot_ || wanted == 0) {
      callback->Continue(CEF_MEDIA_PERMISSION_NONE);
      return true;
    }
    const std::string origin = requesting_origin.ToString();
    // A remembered decision answers immediately — no prompt. Chromium normally
    // short-circuits a stored setting before ever reaching this handler; we read
    // it ourselves so the behavior is identical whether or not it does, and so a
    // partially-stored decision (camera allowed, mic unset) still re-prompts.
    CefRefPtr<CefRequestContext> ctx =
        browser ? browser->GetHost()->GetRequestContext() : nullptr;
    if (ctx && !origin.empty()) {
      uint32_t remembered = 0;
      bool stored_block = false;
      const auto read = [&](uint32_t bit, cef_content_setting_types_t type) {
        if (!(wanted & bit)) return;
        const cef_content_setting_values_t v =
            ctx->GetContentSetting(origin, CefString(), type);
        if (v == CEF_CONTENT_SETTING_VALUE_ALLOW) {
          remembered |= bit;
        } else if (v == CEF_CONTENT_SETTING_VALUE_BLOCK) {
          stored_block = true;
        }
      };
      read(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE,
           CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
      read(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE,
           CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
      // A stored BLOCK is never written any more, but an older profile may
      // still carry one — heal it. It has to go: the PAGE can read it through
      // navigator.permissions.query(), and sites branch on that. Meet asks
      // first and, seeing "denied", never calls getUserMedia at all — so its
      // own "use camera" button goes dead with no request for the host to
      // observe, prompt on, or offer a way back from. "Blocked" is remembered
      // on the Campus side instead, where it can't lie to the page.
      if (stored_block) {
        ctx->SetContentSetting(origin, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
        ctx->SetContentSetting(origin, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
      }
      // All-or-nothing: Continue must MATCH the request for getUserMedia, so a
      // grant only short-circuits when EVERY requested device is remembered.
      if (!stored_block && remembered == wanted) {
        callback->Continue(remembered);
        return true;
      }
    }
    // Undecided -> hold the callback (exactly like a JS dialog) and prompt.
    const uint32_t id = slot_->media_req_next++;
    slot_->media_requests[id] = Slot::PendingMedia{callback, wanted, origin};
    std::vector<uint8_t> p(8 + origin.size());
    for (int i = 0; i < 4; ++i) {
      p[i] = (id >> (24 - 8 * i)) & 0xff;
      p[4 + i] = (wanted >> (24 - 8 * i)) & 0xff;
    }
    memcpy(p.data() + 8, origin.data(), origin.size());
    SendFrame(slot_->browser_id, kOpMediaRequest, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // answered asynchronously via DoMediaResponse
  }
  // Geolocation, notifications, clipboard, etc. all arrive as a permission
  // prompt: deny without ever showing UI.
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser>, uint64_t, const CefString&, uint32_t,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  IMPLEMENT_REFCOUNTING(HostPermissionHandler);

 private:
  std::shared_ptr<Slot> slot_;
};

// Flatten Chromium's CefMenuModel into JSON for the Flutter side to draw.
// Recurses one level for submenus (the spellcheck / "Spelling and Grammar"
// blocks are submenus). Separators are emitted so the drawn menu keeps
// Chromium's grouping instead of one undifferentiated list.
std::string SerializeMenuModel(CefRefPtr<CefMenuModel> model) {
  std::string out = "[";
  const size_t n = model->GetCount();
  for (size_t i = 0; i < n; ++i) {
    if (i) out += ",";
    const cef_menu_item_type_t type = model->GetTypeAt(i);
    const int command = model->GetCommandIdAt(i);
    out += "{";
    if (type == MENUITEMTYPE_SEPARATOR) {
      out += "\"type\":\"separator\"";
    } else {
      const char* t = type == MENUITEMTYPE_CHECK      ? "check"
                      : type == MENUITEMTYPE_RADIO    ? "radio"
                      : type == MENUITEMTYPE_SUBMENU  ? "submenu"
                                                      : "command";
      out += "\"type\":\"" + std::string(t) + "\",";
      out += "\"label\":\"" + JsonEscape(model->GetLabelAt(i).ToString()) + "\",";
      out += "\"commandId\":" + std::to_string(command) + ",";
      // Chromium owns enabled/checked — reporting them keeps the drawn menu
      // honest (e.g. Paste greyed out with an empty clipboard) without Campus
      // re-deriving state it cannot see.
      out += "\"enabled\":" +
             std::string(model->IsEnabledAt(i) ? "true" : "false") + ",";
      out += "\"checked\":" +
             std::string(model->IsCheckedAt(i) ? "true" : "false");
      if (type == MENUITEMTYPE_SUBMENU) {
        if (CefRefPtr<CefMenuModel> sub = model->GetSubMenuAt(i)) {
          out += ",\"items\":" + SerializeMenuModel(sub);
        }
      }
    }
    out += "}";
  }
  out += "]";
  return out;
}

class HostClient : public CefClient,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefFindHandler,
                   public CefJSDialogHandler,
                   public CefDownloadHandler,
                   public CefRequestHandler,
                   public CefKeyboardHandler,
                   public CefContextMenuHandler,
                   public CefMessageRouterBrowserSide::Handler {
 public:
  explicit HostClient(std::shared_ptr<Slot> slot) : slot_(std::move(slot)) {
    CefMessageRouterConfig config;  // default: window.cefQuery / cefQueryCancel
    router_ = CefMessageRouterBrowserSide::Create(config);
    router_->AddHandler(this, false);
    rh_ = NewRenderHandler(slot_);
    ph_ = new HostPermissionHandler(slot_);  // deny-default; owner opts in per tile
  }
  CefRefPtr<CefMessageRouterBrowserSide> router_;
  CefRefPtr<CefRenderHandler> rh_;
  CefRefPtr<CefPermissionHandler> ph_;
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return rh_; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return ph_; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }

  // ── CefContextMenuHandler ──────────────────────────────────────────────
  //
  // Chromium already builds a complete, correctly-stateful context menu for
  // every right-click (back/forward/reload, cut/copy/paste with the right items
  // greyed out, view-source, copy-link-address, the whole spellcheck block with
  // live dictionary suggestions). Without a handler CEF constructs it and throws
  // it away, which is why right-click did nothing in a web tile.
  //
  // We can't let CEF display it: the default display path is a native menu
  // parented to a window, and OSR has none. So RunContextMenu takes over
  // display — serialise the model Chromium built, hand it to Flutter to draw in
  // the Campus design system, and send the chosen command id back so CHROMIUM
  // executes it. That keeps every command's behaviour and enabled/checked state
  // authoritative instead of reimplementing it.
  bool RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                      CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    if (!slot_ || !params || !model || !callback) return false;
    // An empty model means Chromium had nothing to offer; let the default
    // (no-op) path handle it rather than showing an empty menu.
    if (model->GetCount() == 0) return false;

    uint32_t id;
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      id = slot_->next_context_menu_id++;
      slot_->context_menus[id] = callback;
    }

    std::string json = "{";
    json += "\"x\":" + std::to_string(params->GetXCoord()) + ",";
    json += "\"y\":" + std::to_string(params->GetYCoord()) + ",";
    json += "\"editable\":" + std::string(params->IsEditable() ? "true" : "false") + ",";
    // Page-chosen strings (a select-all on a huge page, a data: link) are cut
    // to a size the menu can show; Chromium runs the command on the real ones.
    auto text = [](const CefString& v) {
      return JsonEscape(TruncateUtf8(v.ToString(), kMaxPageText));
    };
    json += "\"linkUrl\":\"" + text(params->GetLinkUrl()) + "\",";
    json += "\"sourceUrl\":\"" + text(params->GetSourceUrl()) + "\",";
    json += "\"selectionText\":\"" + text(params->GetSelectionText()) + "\",";
    json += "\"misspelledWord\":\"" + text(params->GetMisspelledWord()) + "\",";
    json += "\"items\":" + SerializeMenuModel(model);
    json += "}";

    std::vector<uint8_t> p(4 + json.size());
    for (int i = 0; i < 4; ++i) p[i] = (id >> (8 * (3 - i))) & 0xff;
    std::memcpy(p.data() + 4, json.data(), json.size());
    SendFrame(slot_->browser_id, kOpContextMenu, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // we display it
  }

  // The menu is gone for a reason other than a pick (page navigated, browser
  // destroyed). Drop our pending entry — CEF has already invalidated the
  // callback, so answering it later would be a use-after-free.
  void OnContextMenuDismissed(CefRefPtr<CefBrowser>,
                              CefRefPtr<CefFrame>) override {
    if (!slot_) return;
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    slot_->context_menus.clear();
  }

  // CefDownloadHandler: allow downloads (CEF blocks them without a handler) and
  // notify the host. Continue with an empty path + show_dialog so the user picks
  // where to save via the native panel.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    SendUtf8(slot_->browser_id, kOpDownload, suggested_name.ToString());
    callback->Continue(CefString(), true);
    return true;
  }

  // CefFindHandler: report find-in-page results to the host.
  void OnFindResult(CefRefPtr<CefBrowser>, int /*identifier*/, int count,
                    const CefRect& /*selectionRect*/, int activeMatchOrdinal,
                    bool finalUpdate) override {
    uint32_t c = static_cast<uint32_t>(count);
    uint32_t a = static_cast<uint32_t>(activeMatchOrdinal);
    uint8_t p[9] = {static_cast<uint8_t>((c >> 24) & 0xff),
                    static_cast<uint8_t>((c >> 16) & 0xff),
                    static_cast<uint8_t>((c >> 8) & 0xff),
                    static_cast<uint8_t>(c & 0xff),
                    static_cast<uint8_t>((a >> 24) & 0xff),
                    static_cast<uint8_t>((a >> 16) & 0xff),
                    static_cast<uint8_t>((a >> 8) & 0xff),
                    static_cast<uint8_t>(a & 0xff),
                    static_cast<uint8_t>(finalUpdate ? 1 : 0)};
    SendFrame(slot_->browser_id, kOpFindResult, p, 9);
  }

  // CefJSDialogHandler: forward alert/confirm/prompt to the host, which shows a
  // native dialog and answers back over the IPC (DoJsDialogResp -> Continue).
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& /*suppress_message*/) override {
    uint32_t id = slot_->dialog_next++;
    slot_->dialogs[id] = callback;
    uint32_t type = dialog_type == JSDIALOGTYPE_ALERT
                        ? 0
                        : (dialog_type == JSDIALOGTYPE_CONFIRM ? 1 : 2);
    // Cut to a size a dialog can show: an oversized frame would be dropped,
    // leaving the page blocked on a dialog nobody sees.
    std::string msg = TruncateUtf8(message_text.ToString(), kMaxPageText);
    std::string def = TruncateUtf8(default_prompt_text.ToString(), kMaxPageText);
    std::vector<uint8_t> p(12 + msg.size() + def.size());
    uint32_t ml = static_cast<uint32_t>(msg.size());
    for (int i = 0; i < 4; ++i) {
      p[i] = (id >> (24 - 8 * i)) & 0xff;
      p[4 + i] = (type >> (24 - 8 * i)) & 0xff;
      p[8 + i] = (ml >> (24 - 8 * i)) & 0xff;
    }
    memcpy(p.data() + 12, msg.data(), msg.size());
    memcpy(p.data() + 12 + msg.size(), def.data(), def.size());
    SendFrame(slot_->browser_id, kOpJsDialog, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // we answer asynchronously via Continue()
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString&, bool,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    // Always allow navigation away (don't block on "leave this page?").
    callback->Continue(true, CefString());
    return true;
  }
  // CEF calls this when a pending dialog is dismissed by navigation / reload /
  // renderer death. Drop any held callbacks so they don't leak (the host may
  // never send a response for a dialog the page already abandoned).
  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    slot_->dialogs.clear();
  }

  // CefDisplayHandler: camera/mic capture started or stopped on this page. This
  // is the ONLY honest source for the URL bar's "in use" indicator — it reflects
  // what Chromium is actually capturing, not what was merely permitted.
  void OnMediaAccessChange(CefRefPtr<CefBrowser>, bool has_video_access,
                           bool has_audio_access) override {
    slot_->media_video_active = has_video_access;
    slot_->media_audio_active = has_audio_access;
    SendMediaState(slot_);
  }

  // Recover from a renderer crash (multi-process only): reload rather than show
  // a dead page. In single-process a renderer CHECK kills the whole process, so
  // this never fires — which is why heavy pages need multi-process.
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int /*error_code*/,
                                 const CefString& /*error_string*/) override {
    if (router_) router_->OnRenderProcessTerminated(browser);
    if (slot_->crash_looped) return;  // already reported; left alone
    const auto now = std::chrono::steady_clock::now();
    if (!slot_->crashes.NoteAndCheckBurst(now)) {
      SendLog(slot_->browser_id, "renderer terminated (status " +
                                     std::to_string(status) + ") — reloading");
      if (browser) browser->ReloadIgnoreCache();
      return;
    }
    // Reloading again would just re-crash. See the crash-loop detector.
    slot_->crash_looped = true;
    const std::string burst = std::to_string(kRendererCrashBurstLimit) +
                              " renderer crashes in " +
                              std::to_string(kRendererCrashWindow.count()) + "s";
    if (NoteCrashBurstAndCheckHostLoop(slot_->browser_id, now)) {
      SendLog(0, burst + " on several browsers — children cannot start; "
                         "exiting so the host is respawned");
      DoShutdown();
      return;
    }
    SendLog(slot_->browser_id, burst + " — giving up on this browser");
    SendUtf8(slot_->browser_id, kOpBrowserGone, "crashed");
  }

  // CefLoadHandler: spinner + back/forward enablement.
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    SendLoadState(slot_->browser_id, isLoading, canGoBack, canGoForward);
  }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   TransitionType) override {
    if (!frame) return;
    if (frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageStart, frame->GetURL().ToString());
      // A navigation abandons any camera/mic prompt the previous page raised —
      // Cancel the held callbacks so they don't leak (the page that asked is
      // gone and will never be answered). The host dismisses its prompt UI off
      // the url change, mirroring how OnResetDialogState drops JS dialogs.
      for (auto& kv : slot_->media_requests) {
        if (kv.second.callback) kv.second.callback->Cancel();
      }
      slot_->media_requests.clear();
      // Leaving the page stops its capture; don't strand a stale "in use" dot if
      // the teardown's OnMediaAccessChange(false,false) doesn't arrive.
      slot_->media_video_active = false;
      slot_->media_audio_active = false;
      // SECURITY: install the JS-channel shims ONLY into the MAIN frame. The shims expose the
      // privileged campusHost bridge (window.<name> -> window.cefQuery 'ch:'); injecting them
      // into cross-origin SUBFRAMES would hand an untrusted embedded iframe that bridge. (The
      // previous code injected into every frame.) OnQuery also refuses subframe 'ch:'/'eval:'.
      for (const auto& name : slot_->channels) InjectChannelShim(frame, name);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int /*httpStatusCode*/) override {
    if (frame && frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageFinish, frame->GetURL().ToString());
      // Report the new page's remembered camera/mic decision so the URL bar can
      // show a "blocked" indicator for a site Chromium will silently refuse.
      SendMediaState(slot_);
      // RENDER FLOOR: force a repaint when the main frame finishes. Invalidate(PET_VIEW)
      // ALONE is coalesce-able — the scheduler can drop it, which on a shared GPU/Viz process
      // under a multi-browser establishment burst is exactly when the real-content first frame
      // gets lost, leaving a permanently blank tile though the page loaded. Mirror the proven
      // DoSetVisible visibility-edge kick: re-assert size + damage + a NON-coalesce-able
      // SendExternalBeginFrame, which deterministically drives one renderer frame the scheduler
      // cannot swallow. (slot_->visible gate: a hidden tile must stay paused.)
      if (browser && browser->GetHost() && slot_->visible) {
        auto h = browser->GetHost();
        h->WasResized();
        h->Invalidate(PET_VIEW);
        h->SendExternalBeginFrame();
      }
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& text, const CefString& url) override {
    if (code == ERR_ABORTED) return;
    SendCodePlusUtf8(slot_->browser_id, kOpLoadErr, static_cast<uint32_t>(code),
                     url.ToString() + "\n" + text.ToString());
  }

  // CefDisplayHandler: title / address / console -> host.
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    SendUtf8(slot_->browser_id, kOpTitle, title.ToString());
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame && frame->IsMain())
      SendUtf8(slot_->browser_id, kOpUrl, url.ToString());
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level,
                        const CefString& message, const CefString& source,
                        int line) override {
    SendCodePlusUtf8(slot_->browser_id, kOpConsole,
                     static_cast<uint32_t>(level),
                     TruncateUtf8(source.ToString(), kMaxPageText) + ":" +
                         std::to_string(line) + "\t" +
                         TruncateUtf8(message.ToString(), kMaxPageText));
    return false;  // also keep CEF's default console logging
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    uint32_t pct = static_cast<uint32_t>(progress * 100.0 + 0.5);
    uint8_t p[4] = {static_cast<uint8_t>((pct >> 24) & 0xff),
                    static_cast<uint8_t>((pct >> 16) & 0xff),
                    static_cast<uint8_t>((pct >> 8) & 0xff),
                    static_cast<uint8_t>(pct & 0xff)};
    SendFrame(slot_->browser_id, kOpProgress, p, 4);
  }

  // Async create completes here on the CEF UI thread. Bind the browser to its slot
  // (DoCreateBrowser no longer does — it dropped the blocking CreateBrowserSync) and ack
  // the host so its create-pacer sends the NEXT create: creates serialize by COMPLETION
  // (each browser's render + GPU/Viz accelerated-surface handshake done before the next
  // contends the shared GPU process), not a wall-clock guess.
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    slot_->browser = browser;
    SendFrame(slot_->browser_id, kOpCreated, nullptr, 0);
    // A dispose arrived during the async-create window and recorded intent — honor
    // it now (OnBeforeClose then does the normal map-erase + surface release + retain-
    // cycle break) so we don't leak a live orphan browser the Swift side already forgot.
    if (slot_->close_requested || g_shutting_down) {
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    // A load that arrived while the browser was being created. Applied now, not
    // at first paint: a browser created hidden doesn't paint.
    if (!slot_->nav_after_create.empty()) {
      const std::string nav = slot_->nav_after_create;
      slot_->nav_after_create.clear();
      if (auto frame = browser->GetMainFrame()) frame->LoadURL(nav);
    }
    // Reconcile a visibility intent that arrived before the browser bound. A
    // setVisible(false) on a still-creating slot ran DoSetVisible with browser==null
    // (WasHidden skipped), so slot_->visible is already false but CEF never heard it —
    // the slot would establish VISIBLE and pump at 60fps off-screen until the next flip.
    // Honor the recorded intent now (mirrors the close_requested deferred-intent pattern).
    if (!slot_->visible) {
      browser->GetHost()->WasHidden(true);
      // Hidden, it won't paint, so blank-first's load can't wait for a paint.
      ApplyBlankFirstNav(slot_);
    }
    // Start the external begin-frame pump now that the browser is bound. We turned the internal
    // frame timer OFF (external_begin_frame_enabled), so without this nothing ever paints.
    if (!slot_->begin_frame_pump_started) {
      slot_->begin_frame_pump_started = true;
      PumpBeginFrame(slot_->browser_id);
    }
  }

  // CefLifeSpanHandler: route popups (window.open / target=_blank) to the host
  // instead of opening a native window. Returning true cancels the native popup;
  // the host decides what to do (commonly load the URL in the same view). This
  // mirrors webview_flutter, which surfaces new-window requests through its
  // navigation delegate rather than a separate window.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     WindowOpenDisposition disposition, bool user_gesture,
                     const CefPopupFeatures& features, CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    // A SIZED popup (window.open with width/height) is the shape OAuth /
    // "Sign in with Google" uses: it needs a real popup with window.opener so it
    // can postMessage the credential back to us. Give it a native window — the
    // in-tab diversion below can never complete that handshake (it would strand
    // the flow at e.g. accounts.google.com/gsi/transform with no opener).
    // Like Chrome's popup blocker, only a user gesture opens one, and only to a
    // URL the tile itself may load.
    if (g_shutting_down) return true;
    if (disposition == CEF_WOD_NEW_POPUP) {
      if (!NativePopupAllowed(target_url.ToString(), user_gesture)) {
        SendLog(slot_->browser_id, "blocked a popup (no user gesture, too many "
                                   "open, or a scheme outside the allowlist)");
        return true;
      }
      OpenNativeAuthPopup(features, slot_->browser_id, window_info, client);
      return false;  // allow CEF to create the popup browser in our native window
    }
    // target=_blank / plain new tab: keep loading it in this single-view tile.
    if (!target_url.empty())
      SendUtf8(slot_->browser_id, kOpNewWindow, target_url.ToString());
    return true;
  }

  // The page's cursor (I-beam over text, hand over links, etc.). Forward the
  // type to the host so it can drive the Flutter MouseRegion cursor.
  bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle,
                      cef_cursor_type_t type, const CefCursorInfo&) override {
    uint8_t p[4];
    uint32_t t = static_cast<uint32_t>(type);
    p[0] = (t >> 24) & 0xff;
    p[1] = (t >> 16) & 0xff;
    p[2] = (t >> 8) & 0xff;
    p[3] = t & 0xff;
    SendFrame(slot_->browser_id, kOpCursor, p, 4);
    return true;
  }

  // CefMessageRouter wiring: the renderer half (process_helper.mm) injects
  // window.cefQuery; queries land here. We forward the request string to the
  // host: "eval:<id>:<nonce>:<json>" for a runJavaScriptReturningResult result
  // (forwarded as "<id>:<json>"), "ch:<name>:<message>" for a JS-channel post.
  //
  // Both come from the page's own JS, so the page decides what they say: an eval
  // result is only as trustworthy as the page it ran in. What is enforced: only
  // the main frame (a cross-origin iframe can't post to the tile's channels or
  // answer its evals), only channels this browser registered, only evals in
  // flight with their nonce, and a size the IPC can carry.
  bool OnQuery(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int64_t,
               const CefString& request, bool,
               CefRefPtr<Callback> callback) override {
    std::string r = request.ToString();
    const bool main_frame = frame && frame->IsMain();
    if (r.rfind("eval:", 0) == 0) {
      if (!main_frame) { callback->Failure(403, "subframe"); return true; }
      // eval:<id>:<nonce>:<json>
      const size_t id_end = r.find(':', 5);
      const size_t nonce_end =
          id_end == std::string::npos ? std::string::npos : r.find(':', id_end + 1);
      if (nonce_end == std::string::npos) {
        callback->Failure(400, "malformed");
        return true;
      }
      const std::string id_str = r.substr(5, id_end - 5);
      char* parse_end = nullptr;
      const unsigned long id = std::strtoul(id_str.c_str(), &parse_end, 10);
      auto it = (id_str.empty() || *parse_end != '\0')
                    ? slot_->pending_evals.end()
                    : slot_->pending_evals.find(static_cast<uint32_t>(id));
      if (it == slot_->pending_evals.end() ||
          r.compare(id_end + 1, nonce_end - id_end - 1, it->second) != 0) {
        callback->Failure(403, "no such eval");
        return true;
      }
      slot_->pending_evals.erase(it);
      if (r.size() - nonce_end - 1 > kMaxPageMessage) {
        SendUtf8(slot_->browser_id, kOpEvalResult,
                 id_str + ":{\"ok\":false,\"v\":\"result too large\"}");
        callback->Failure(413, "too large");
        return true;
      }
      SendUtf8(slot_->browser_id, kOpEvalResult,
               id_str + ":" + r.substr(nonce_end + 1));
      callback->Success(CefString());
      return true;
    }
    if (r.rfind("ch:", 0) == 0) {
      if (!main_frame) { callback->Failure(403, "subframe"); return true; }
      // Only a channel this browser's consumer registered. The page can call
      // window.cefQuery itself, shim or not.
      const size_t name_end = r.find(':', 3);
      if (name_end == std::string::npos ||
          slot_->channels.count(r.substr(3, name_end - 3)) == 0) {
        callback->Failure(404, "no such channel");
        return true;
      }
      if (r.size() - 3 > kMaxPageMessage) {
        SendLog(slot_->browser_id, "dropped a " + std::to_string(r.size()) +
                                       "-byte channel message: too large");
        callback->Failure(413, "too large");
        return true;
      }
      SendUtf8(slot_->browser_id, kOpChannelMsg, r.substr(3));
      callback->Success(CefString());
      return true;
    }
    return false;
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    // The renderer answered the liveness ping (see DoEvalReturning); reply as
    // the plugin's ping eval would have.
    if (message->GetName().ToString() == renderer_messages::kPong) {
      if (frame && frame->IsMain())
        SendUtf8(slot_->browser_id, kOpEvalResult,
                 std::to_string(kLivenessPingId) + ":{\"ok\":true,\"v\":1}");
      return true;
    }
    return router_->OnProcessMessageReceived(browser, frame, source_process,
                                             message);
  }
  // Centralized per-browser teardown (CEF UI thread). CloseBrowser(true) — sent
  // by DoDisposeBrowser or DoShutdown — lands here. Drop the routing-map entries
  // (so no inbound op or paint can find this slot again), release the host
  // IOSurface under the slot's lock (nulling it FIRST so a GPU-thread paint
  // racing this teardown sees null and no-ops, then CFRelease the old surface),
  // and break the HostClient -> Slot -> CefBrowser -> HostClient retain cycle by
  // nulling slot_->browser. The last shared_ptr<Slot> drops once any in-flight
  // paint refs (which copied the shared_ptr) drain.
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (router_) router_->OnBeforeClose(browser);
    // Answer nothing and release everything: a tile closed with a camera/mic
    // prompt still up must not leave a held callback behind.
    for (auto& kv : slot_->media_requests) {
      if (kv.second.callback) kv.second.callback->Cancel();
    }
    slot_->media_requests.clear();
    slot_->pending_evals.clear();
    SetAuthoredDoc(slot_->browser_id, "", "");
    CloseWindowedBrowsers(slot_->browser_id);  // its sign-in popups go with it
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(slot_->browser_id);
    }
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      slot_->closing = true;  // BEFORE nulling: a paint racing this must not re-mint a surface
      IOSurfaceRef old = slot_->surface;
      slot_->surface = nullptr;
      if (old) CFRelease(old);  // drop cef_host's last +1; consumer's CVPixelBuffer keeps it alive
      [slot_->dst_mtl release];
      slot_->dst_mtl = nil;
      slot_->dst_mtl_sid = 0;
    }
    slot_->browser = nullptr;
    NoteBrowserClosed();
  }
  // ⌘-key editing shortcuts, as the FALLBACK they are in a real browser. AppKit
  // turns ⌘Z/⌘A/⌘C… into undo:/selectAll:/copy: only after the page declined the
  // keydown; windowless rendering has no responder chain to do that, so do it
  // here — OnKeyEvent is called exactly when the renderer left the key unhandled.
  // The PAGE gets first refusal: an editor that owns its own undo stack and
  // selection (Monaco, CodeMirror, Docs) handles ⌘Z/⌘A in its keydown listener,
  // and running the browser's command instead would bypass it (undo did nothing,
  // select-all selected the wrong thing).
  bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event,
                  CefEventHandle) override {
    if (event.type != KEYEVENT_RAWKEYDOWN) return false;
    const uint32_t m = event.modifiers;
    if (!(m & EVENTFLAG_COMMAND_DOWN) ||
        (m & (EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN)))
      return false;
    CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
    if (!frame) return false;
    const bool shift = (m & EVENTFLAG_SHIFT_DOWN) != 0;
    switch (event.windows_key_code) {
      case 'C': if (shift) return false; frame->Copy(); return true;
      case 'X': if (shift) return false; frame->Cut(); return true;
      case 'V': if (shift) return false; frame->Paste(); return true;
      case 'A': if (shift) return false; frame->SelectAll(); return true;
      case 'Z': if (shift) frame->Redo(); else frame->Undo(); return true;
      default: return false;
    }
  }
  // IO thread. Answer the main-frame navigation to an authored document's URL
  // with the document itself (see g_authored); everything else is untouched.
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool is_navigation, bool is_download,
      const CefString&, bool&) override {
    if (!is_navigation || is_download) return nullptr;
    if (frame && !frame->IsMain()) return nullptr;
    if (request->GetMethod().ToString() != "GET") return nullptr;
    std::string html;
    if (!LookupAuthoredDoc(slot_->browser_id, request->GetURL().ToString(),
                           &html))
      return nullptr;
    return NewAuthoredRequestHandler(std::move(html));
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool, bool) override {
    if (!g_allowed_schemes.empty()) {
      const std::string url = request->GetURL().ToString();
      // Only gate MAIN-frame navigations. A subframe can't change the view's
      // top-level origin (it's already same-policy-constrained by Chromium), and
      // gating subframes would cancel legitimate cross-scheme embeds — blob: /
      // data: iframes, PDF/video viewers, ad frames — breaking real pages.
      const bool main_frame = !frame || frame->IsMain();
      // A host content-injection load (loadHtmlString -> data:, loadFile ->
      // file:) armed an exact-URL exemption in DoNavigateTrusted. Honor it only
      // for the matching main-frame request, and consume that one entry, so a
      // page navigation to a different URL can't steal it. A redirect of a
      // trusted load carries a different URL and so remains gated.
      bool host_trusted = false;
      if (main_frame) {
        auto it = slot_->trusted_pending.find(url);
        if (it != slot_->trusted_pending.end()) {
          slot_->trusted_pending.erase(it);
          host_trusted = true;
        }
      }
      if (main_frame && !host_trusted && !SchemeAllowed(url)) {
        return true;  // cancel — the scheme is not permitted
      }
    }
    if (router_) router_->OnBeforeBrowse(browser, frame);
    return false;  // allow
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostClient);
};

}  // namespace

CefRefPtr<CefClient> NewHostClient(std::shared_ptr<Slot> slot) {
  return new HostClient(std::move(slot));
}

}  // namespace cef_host
