// Off-screen rendering: the per-browser CefRenderHandler that copies each frame
// into the host-owned IOSurface the plugin shows, the Mach-port hand-off of
// those surfaces, and the external begin-frame pump that drives frames.
#pragma once

#include <mach/mach.h>

#include <cstdint>
#include <memory>

#include "host_state.h"
#include "include/cef_render_handler.h"

namespace cef_host {

// Where tile surfaces go: a send right to the plugin's SurfacePort, looked up by
// the bootstrap name in --surface-port. Surfaces are not global (any local
// process could look a global one up by id and read the page), so this port is
// the only way the plugin gets them. MACH_PORT_NULL without --surface-port.
extern mach_port_t g_surface_port;

// The render handler of `slot`'s browser.
CefRefPtr<CefRenderHandler> NewRenderHandler(std::shared_ptr<Slot> slot);

// about:blank-first: the browser has established (first paint on about:blank) — now
// navigate to the real URL. The establishment slot has already been released by this
// paint, so the real page loads WITHOUT holding a serial slot (concurrent with the
// other tiles' loads). Fires once (pending_nav_url cleared). UI thread.
void ApplyBlankFirstNav(const std::shared_ptr<Slot>& slot);

// Starts, then keeps re-posting, a browser's begin-frame pump. See
// render_handler.mm. UI thread.
void PumpBeginFrame(uint32_t wire_id);

// Creates and at once closes a browser so that no tile's view gets begin-frame
// source id 0, which can leave a new tile unpainted (see render_handler.mm).
// Only the first call does anything; DoCreateBrowser makes it before creating
// each tile. UI thread.
void ClaimFirstBeginFrameSource();

}  // namespace cef_host
