// Process messages between the browser process and the renderer
// (process_helper.mm) that the page can't see or answer.
#pragma once

namespace renderer_messages {

// The plugin's liveness ping, answered by the renderer's main thread, so a
// renderer that is hung (or stopped) doesn't answer, and a page can't stop one
// that isn't from answering (by replacing window.cefQuery, say).
constexpr char kPing[] = "flutter_cef.ping";
constexpr char kPong[] = "flutter_cef.pong";

}  // namespace renderer_messages
