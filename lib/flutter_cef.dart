/// flutter_cef — embed a live Chromium (CEF) browser as a Flutter widget.
///
/// The page renders off-screen in a `cef_host` subprocess into a shared
/// IOSurface and is shown as a [Texture] (so it composites/transforms/clips
/// like any widget). Pointer + keyboard input is forwarded by coordinate, and
/// the page cursor drives a [MouseRegion]. macOS only, for now.
library;

export 'src/cef_events.dart'
    show
        CefCookie,
        CefConsoleMessage,
        CefFindResult,
        CefJsDialogRequest,
        CefLoadError;
export 'src/cef_web_controller.dart' show CefWebController;
export 'src/cef_web_view.dart' show CefWebView;
