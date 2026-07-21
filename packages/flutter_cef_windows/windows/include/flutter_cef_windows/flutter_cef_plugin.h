// Public C entry point for the flutter_cef_windows plugin.
//
// The Flutter tool's generated_plugin_registrant.cc includes this header and
// calls FlutterCefPluginRegisterWithRegistrar() (name derived from the
// pubspec `pluginClass: FlutterCefPlugin`). Keep the symbol name stable.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void FlutterCefPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_PLUGIN_C_API_H_
