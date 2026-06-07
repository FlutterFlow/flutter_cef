// cef_host helper — the CEF subprocess executable (GPU / renderer / utility /
// plugin). One tiny binary, bundled five times (base + GPU/Renderer/Plugin/
// Alerts) with distinct bundle ids under cef_host.app/Contents/Frameworks. It
// loads the CEF framework relative to its own executable and hands control to
// CEF, which dispatches on the --type= switch CEF passes it.
//
// Splitting CEF across these processes (vs --single-process) is what enables the
// GPU/Viz process — and therefore OnAcceleratedPaint shared-IOSurface rendering.

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // Load the CEF framework from cef_host.app/Contents/Frameworks, resolved
  // relative to this helper's executable.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
