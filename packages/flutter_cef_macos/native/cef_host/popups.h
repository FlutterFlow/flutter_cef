// Windows the host opens besides the tiles: native sign-in popups (a page's
// sized window.open) and Chrome-runtime auth windows (kOpOpenAuthWindow). Both
// are held to the scheme allowlist and closed with their tile or the host.
#pragma once

#include <cstdint>
#include <string>

#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"

namespace cef_host {

// Whether a page may open a native popup to `url` now: a user gesture, a URL
// the tile may load, and fewer than the maximum open. UI thread.
bool NativePopupAllowed(const std::string& url, bool user_gesture);

// Sets up the native window a sized popup opened by `owner_wire_id`'s page is
// created in: fills `window_info` and `client`. UI thread.
void OpenNativeAuthPopup(const CefPopupFeatures& f, uint32_t owner_wire_id,
                         CefWindowInfo& window_info,
                         CefRefPtr<CefClient>& client);

// Opens a Chrome-runtime auth window at `url` (kOpOpenAuthWindow). UI thread.
void OpenChromeAuthWindow(const std::string& url);

// Closes the windowed browsers `owner_wire_id` opened, or all of them when
// owner_wire_id is 0. UI thread.
void CloseWindowedBrowsers(uint32_t owner_wire_id);

}  // namespace cef_host
