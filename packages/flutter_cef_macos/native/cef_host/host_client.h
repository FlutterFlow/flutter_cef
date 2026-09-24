// The CefClient of a tile's browser: load, display, dialog, permission,
// context-menu, popup and message-router handling, reported to the plugin.
#pragma once

#include <memory>

#include "host_state.h"
#include "include/cef_client.h"

namespace cef_host {

// The client of `slot`'s browser.
CefRefPtr<CefClient> NewHostClient(std::shared_ptr<Slot> slot);

// Send the page's COMPLETE media status: what is capturing right now, plus the
// site's remembered decision. See host_client.mm. UI thread.
void SendMediaState(const std::shared_ptr<Slot>& slot);

}  // namespace cef_host
