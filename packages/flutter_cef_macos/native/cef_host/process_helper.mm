// cef_host helper — the CEF subprocess executable (GPU / renderer / utility /
// plugin). One tiny binary, bundled five times (base + GPU/Renderer/Plugin/
// Alerts) with distinct bundle ids under cef_host.app/Contents/Frameworks. It
// loads the CEF framework relative to its own executable and hands control to
// CEF, which dispatches on the --type= switch CEF passes it.
//
// Splitting CEF across these processes (vs --single-process) is what enables the
// GPU/Viz process — and therefore OnAcceleratedPaint shared-IOSurface rendering.
//
// The render process also hosts the renderer half of CefMessageRouter, which
// injects window.cefQuery into every frame so the page can talk to the browser
// process (powers JS channels + runJavaScriptReturningResult). The browser half
// lives in host_client.mm; both must use the same (default) CefMessageRouterConfig.
//
// It also installs each browser's document-start config (document_start.h): the
// JS channels registered before create and the consumer's document-start
// scripts, run synchronously as every main-frame JavaScript context is created —
// before the page's own scripts.

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

#include <map>

#include "document_start.h"
#include "renderer_messages.h"

namespace {

class HelperApp : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  void OnWebKitInitialized() override {
    CefMessageRouterConfig config;  // default: window.cefQuery / cefQueryCancel
    router_ = CefMessageRouterRendererSide::Create(config);
  }

  // Called in THIS renderer for every browser it hosts, with the extra_info the
  // browser process passed to CreateBrowser (again in each new renderer after a
  // cross-process navigation).
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (!extra_info) return;
    auto read = [&](const char* key, std::vector<std::string>* out) {
      CefRefPtr<CefListValue> list = extra_info->GetList(key);
      if (!list) return;
      for (size_t i = 0; i < list->GetSize(); ++i)
        out->push_back(list->GetString(i).ToString());
    };
    document_start::Config config;
    read(document_start::kChannelsKey, &config.channels);
    read(document_start::kScriptsKey, &config.scripts);
    if (!config.empty()) document_start_[browser->GetIdentifier()] = config;
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    document_start_.erase(browser->GetIdentifier());
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    // window.cefQuery first: the channel shims below post through it.
    if (router_) router_->OnContextCreated(browser, frame, context);
    if (!frame->IsMain()) return;
    auto it = document_start_.find(browser->GetIdentifier());
    if (it == document_start_.end()) return;
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    for (const std::string& name : it->second.channels) {
      if (!document_start::IsValidChannelName(name)) continue;
      context->Eval(document_start::ChannelShimJs(name), CefString(), 0, result,
                    exception);
    }
    for (const std::string& script : it->second.scripts) {
      exception = nullptr;
      if (context->Eval(script, CefString(), 0, result, exception) ||
          !exception)
        continue;
      // A broken script must not take the page down with it — report it where
      // the page's own errors go (the console, forwarded to the host).
      CefRefPtr<CefV8Exception> ignored;
      context->Eval(
          "console.error(\"[flutter_cef] document-start script failed: \" + " +
              document_start::JsStringLiteral(
                  exception->GetMessage().ToString()) +
              ")",
          CefString(), 0, result, ignored);
    }
  }

  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    if (router_) router_->OnContextReleased(browser, frame, context);
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    // The liveness ping: answered from this (the renderer's main) thread, which
    // a hung page or renderer never gets back to.
    if (message->GetName().ToString() == renderer_messages::kPing) {
      if (frame)
        frame->SendProcessMessage(
            PID_BROWSER, CefProcessMessage::Create(renderer_messages::kPong));
      return true;
    }
    return router_ && router_->OnProcessMessageReceived(browser, frame,
                                                        source_process, message);
  }

 private:
  CefRefPtr<CefMessageRouterRendererSide> router_;
  // Browser identifier -> its document-start config. Renderer main thread only.
  std::map<int, document_start::Config> document_start_;
  IMPLEMENT_REFCOUNTING(HelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
#ifndef CEF_HOST_ADHOC
  // Signed release (-DCEF_HOST_ADHOC=OFF): bring this sub-process into the
  // Chromium sandbox before anything else. CefScopedSandboxContext dlopens
  // libcef_sandbox.dylib from the framework Libraries (path resolved relative to
  // this helper executable) and calls cef_sandbox_initialize. Must run before
  // LoadInHelper and stay in scope for the process lifetime (it does — main()
  // blocks in CefExecuteProcess until the process exits). Sandbox enforcement
  // only validates under proper Developer-ID signing, so it is compiled out of
  // ad-hoc/dev builds (CEF_HOST_ADHOC), which run unsandboxed.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
#endif
  // Load the CEF framework from cef_host.app/Contents/Frameworks, resolved
  // relative to this helper's executable.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  CefRefPtr<HelperApp> app(new HelperApp());
  return CefExecuteProcess(main_args, app, nullptr);
}
