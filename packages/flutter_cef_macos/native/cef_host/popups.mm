#include "popups.h"

#import <Cocoa/Cocoa.h>

#include <map>
#include <vector>

#include "host_state.h"
#include "include/cef_browser.h"
#include "include/cef_display_handler.h"
#include "include/cef_request_handler.h"

// NSWindowDelegate for the native OAuth popup window (see PopupClient below).
// ObjC declarations must be at global scope, not inside a C++ namespace.
@interface FCPopupWindowDelegate : NSObject <NSWindowDelegate> {
 @public
  // Raw CefBrowser*, only safe to deref while `alive` is YES — i.e. between
  // OnAfterCreated and DoClose. Once a close is underway (JS window.close() or a
  // user click) CEF may synthesize a close-button press and fire this delegate
  // AFTER it has begun destroying the browser, leaving `browser` dangling; the
  // `alive` gate keeps us from touching it then (EXC_BAD_ACCESS otherwise).
  CefBrowser* browser;
  BOOL alive;
}
@end

@implementation FCPopupWindowDelegate
- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (alive && browser) {
    browser->GetHost()->CloseBrowser(false);  // -> DoClose -> OnBeforeClose closes the window
    return NO;  // don't close yet; CEF drives teardown, then we close the window
  }
  return YES;  // a close is already underway (browser gone/going) — let it close
}
@end

namespace cef_host {
namespace {

// Windowed browsers the host opened besides the tiles: sign-in popups (keyed to
// the tile that opened them, so disposing the tile closes them) and auth windows
// (owner 0). By CefBrowser identifier. UI-thread only.
struct WindowedBrowser {
  CefRefPtr<CefBrowser> browser;
  uint32_t owner_wire_id = 0;
};
std::map<int, WindowedBrowser> g_windowed_browsers;

// Native popup windows open now (UI thread). A page gets one only from a user
// gesture, and only this many at once, so it can't flood the screen with
// focus-stealing windows.
int g_native_popups = 0;
constexpr int kMaxNativePopups = 4;

}  // namespace

bool NativePopupAllowed(const std::string& url, bool user_gesture) {
  return user_gesture && g_native_popups < kMaxNativePopups &&
         SchemeAllowed(url);
}

void CloseWindowedBrowsers(uint32_t owner_wire_id) {
  std::vector<CefRefPtr<CefBrowser>> doomed;
  for (auto& kv : g_windowed_browsers) {
    if (owner_wire_id == 0 || kv.second.owner_wire_id == owner_wire_id)
      doomed.push_back(kv.second.browser);
  }
  for (auto& b : doomed) b->GetHost()->CloseBrowser(true);
}

namespace {

// ───── Native windowed popup for OAuth (window.open with features) ──────────
//
// The main tile is OSR (windowless) and cancels ordinary popups, loading their
// URL in-place. That works for target=_blank links but BREAKS popup-based sign-in
// (Google / Firebase signInWithPopup): those open a real popup, authenticate,
// then postMessage the credential back to window.opener and close. An in-place
// navigation has no opener and destroys the page waiting for the message, so the
// flow hangs (e.g. stuck at accounts.google.com/gsi/transform).
//
// For a SIZED popup (WOD_NEW_POPUP) we instead let CEF create a REAL popup
// browser hosted in a native NSWindow (SetAsChild). window.opener / postMessage /
// window.close all work natively — exactly like a normal browser's sign-in popup.
// The popup is windowed (no OSR render handler), fixed-size, and owns its window's
// lifecycle. It uses the parent's request context (shared cookie jar), so an
// already-signed-in Google session is recognized.
// FCPopupWindowDelegate (the NSWindowDelegate) is declared at global scope
// above (ObjC decls can't live in a C++ namespace).

class PopupClient : public CefClient,
                    public CefLifeSpanHandler,
                    public CefDisplayHandler,
                    public CefRequestHandler {
 public:
  PopupClient(NSWindow* window, FCPopupWindowDelegate* delegate,
              uint32_t owner_wire_id)
      : window_([window retain]),
        delegate_([delegate retain]),
        owner_wire_id_(owner_wire_id) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // The popup runs the page's code in a window of its own, so it is held to the
  // tile's scheme allowlist too.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool, bool) override {
    const bool main_frame = !frame || frame->IsMain();
    return main_frame && !SchemeAllowed(request->GetURL().ToString());
  }

  // Nested windows opened from within the auth popup (consent screens, IdP hops,
  // a target=_blank link) are part of the same flow — each gets its own native
  // window and client so opener/postMessage keeps working all the way down.
  // Without a client of its own a new window would share this one, and closing
  // either would tear down the other's window.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     WindowOpenDisposition, bool user_gesture,
                     const CefPopupFeatures& features, CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (g_shutting_down ||
        !NativePopupAllowed(target_url.ToString(), user_gesture))
      return true;
    OpenNativeAuthPopup(features, owner_wire_id_, window_info, client);
    return false;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    ++g_native_popups;
    ++g_open_browsers;
    g_windowed_browsers[browser->GetIdentifier()] =
        WindowedBrowser{browser, owner_wire_id_};
    if (delegate_) {
      delegate_->browser = browser.get();
      delegate_->alive = YES;
    }
    // Its tile went away (or the host is shutting down) while it was created.
    if (g_shutting_down || (owner_wire_id_ != 0 && !LookupWireId(owner_wire_id_)))
      browser->GetHost()->CloseBrowser(true);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // Close underway (JS window.close(), a user click, or its tile going away).
    // Flip the gate BEFORE CEF destroys the browser so any close-button press
    // can't deref a dangling browser in windowShouldClose:.
    if (delegate_) delegate_->alive = NO;
    // The browser is destroyed with its view, and the view lives in a window
    // this client keeps until OnBeforeClose, so CEF's default (asking the
    // window to close) would never finish it. Take the view out of the window
    // instead, on the next turn, out of CEF's close stack; OnBeforeClose then
    // closes the window.
    NSView* view = [CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(
        browser->GetHost()->GetWindowHandle()) retain];
    dispatch_async(dispatch_get_main_queue(), ^{
      [view removeFromSuperview];
      [view release];
    });
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    // Runs inside CEF's teardown of the child NSView. Closing/releasing the
    // window synchronously here re-enters -[NSWindow __close] and can fire the
    // delegate against a half-destroyed browser (EXC_BAD_ACCESS). So: sever the
    // browser pointer NOW (any stray windowShouldClose: then sees nil and no-ops),
    // detach the delegate, and defer the window close + releases to the next
    // main-loop turn, out of the teardown stack.
    --g_native_popups;
    g_windowed_browsers.erase(browser->GetIdentifier());
    NoteBrowserClosed();
    NSWindow* win = window_;
    FCPopupWindowDelegate* del = delegate_;
    window_ = nil;
    delegate_ = nil;
    if (del) del->browser = nullptr;
    if (win) [win setDelegate:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (win) {
        [win orderOut:nil];
        [win close];
        [win release];
      }
      if (del) [del release];
    });
  }

  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    if (window_)
      [window_ setTitle:[NSString stringWithUTF8String:title.ToString().c_str()]];
  }

 private:
  NSWindow* window_;                 // MRC: retained in ctor, released in OnBeforeClose
  FCPopupWindowDelegate* delegate_;  // MRC: retained in ctor, released in OnBeforeClose
  const uint32_t owner_wire_id_;     // the tile whose page opened it
  IMPLEMENT_REFCOUNTING(PopupClient);
};

// The client of an auth window (kOpOpenAuthWindow): a windowed, CHROME-runtime
// browser. The Chrome runtime manages its own native window, toolbar, and —
// crucially — the full WebAuthn stack (Touch ID sheet, account picker, hybrid
// QR), none of which exist in the Alloy/OSR runtime the tiles are forced into.
// It is held to the host's scheme allowlist like a tile, and closed with the
// host.
class AuthWindowClient : public CefClient,
                         public CefLifeSpanHandler,
                         public CefRequestHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool, bool) override {
    const bool main_frame = !frame || frame->IsMain();
    return main_frame && !SchemeAllowed(request->GetURL().ToString());
  }

  // Windows it opens stay inside the Chrome runtime's own window management;
  // only ones the allowlist permits, from a user gesture.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     WindowOpenDisposition, bool user_gesture,
                     const CefPopupFeatures&, CefWindowInfo&,
                     CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    return g_shutting_down || !user_gesture ||
           !SchemeAllowed(target_url.ToString());
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    ++g_open_browsers;
    g_windowed_browsers[browser->GetIdentifier()] =
        WindowedBrowser{browser, 0};
    if (g_shutting_down) browser->GetHost()->CloseBrowser(true);
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    g_windowed_browsers.erase(browser->GetIdentifier());
    NoteBrowserClosed();
  }

 private:
  IMPLEMENT_REFCOUNTING(AuthWindowClient);
};

}  // namespace

// Open a real windowed Chrome-runtime browser at |url| (kOpOpenAuthWindow),
// sharing THIS process's cookie jar (global request context == the tile's named
// profile, since profiles are per-cef_host-process via root_cache_path).
// Windowed + Chrome style = the WebAuthn UI can actually draw.
void OpenChromeAuthWindow(const std::string& url) {
  if (g_shutting_down) return;
  CefWindowInfo wi;                             // default → windowed, CEF owns the NSWindow
  wi.runtime_style = CEF_RUNTIME_STYLE_CHROME;  // full Chrome UI + WebAuthn stack
  wi.bounds = CefRect(120, 100, 520, 760);      // a plausible sign-in window
  CefBrowserSettings settings;
  CefBrowserHost::CreateBrowser(wi, new AuthWindowClient(), url, settings,
                                nullptr, nullptr);  // nullptr ctx = shared cookies
}

void OpenNativeAuthPopup(const CefPopupFeatures& f, uint32_t owner_wire_id,
                         CefWindowInfo& window_info,
                         CefRefPtr<CefClient>& client) {
  // Runs on the CEF UI thread, which on macOS (CefRunMessageLoop) is the main
  // thread — safe to build AppKit objects here.
  int w = (f.widthSet && f.width > 0) ? f.width : 480;
  int h = (f.heightSet && f.height > 0) ? f.height : 640;
  if (w < 320) w = 320;
  if (w > 1200) w = 1200;
  if (h < 400) h = 400;
  if (h > 1000) h = 1000;
  NSRect frame = NSMakeRect(0, 0, w, h);
  NSWindow* win = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [win setReleasedWhenClosed:NO];  // MRC: PopupClient releases it explicitly
  [win setTitle:@"Sign in"];
  [win center];
  FCPopupWindowDelegate* del = [[[FCPopupWindowDelegate alloc] init] autorelease];
  [win setDelegate:del];
  // Host the popup browser windowed inside our content view: CEF renders + routes
  // native input for it, and keeps the window.opener relationship intact.
  window_info.SetAsChild((CefWindowHandle)[win contentView], CefRect(0, 0, w, h));
  client = new PopupClient(win, del, owner_wire_id);  // retains win + del
  [win makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [win release];  // drop our alloc +1; PopupClient's retain keeps it alive
}

}  // namespace cef_host
