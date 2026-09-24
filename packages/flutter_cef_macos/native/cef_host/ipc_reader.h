// The IPC reader thread: decodes the plugin's frames and posts each one to the
// CEF UI thread.
#pragma once

namespace cef_host {

// Runs until the socket closes or kOpShutdown, then shuts the host down.
void IpcReadLoop();

}  // namespace cef_host
