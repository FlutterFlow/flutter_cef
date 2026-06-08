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
// lives in main.mm; both must use the same (default) CefMessageRouterConfig.

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

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

  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (router_) router_->OnContextCreated(browser, frame, context);
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
    return router_ && router_->OnProcessMessageReceived(browser, frame,
                                                        source_process, message);
  }

 private:
  CefRefPtr<CefMessageRouterRendererSide> router_;
  IMPLEMENT_REFCOUNTING(HelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
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
