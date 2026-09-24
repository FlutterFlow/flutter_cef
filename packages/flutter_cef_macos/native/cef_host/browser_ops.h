// What the plugin asks of one browser (or of the host's cookie jar), run on
// the CEF UI thread: the IPC reader decodes each frame and posts one of these.
#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "host_state.h"

namespace cef_host {

void DoCreateBrowser(uint32_t wire_id, int w, int h, double dpr,
                     std::string url);
void DoDisposeBrowser(uint32_t wire_id);
void DoResize(const std::shared_ptr<Slot>& slot, int w, int h, double dpr);
void DoNavigateByWireId(uint32_t wire_id, std::string url, bool trusted);
void DoReload(const std::shared_ptr<Slot>& slot);
void DoStopLoad(const std::shared_ptr<Slot>& slot);
void DoGoBack(const std::shared_ptr<Slot>& slot);
void DoGoForward(const std::shared_ptr<Slot>& slot);
void DoExecuteJs(const std::shared_ptr<Slot>& slot, const std::string& code);
void DoSetZoom(const std::shared_ptr<Slot>& slot, double level);
void DoEditCommand(const std::shared_ptr<Slot>& slot, int command);
void DoSetVisible(const std::shared_ptr<Slot>& slot, bool visible);
void DoSetAudioMuted(const std::shared_ptr<Slot>& slot, bool muted);
void DoContextMenuCommand(const std::shared_ptr<Slot>& slot, uint32_t id,
                          uint32_t command);
void DoMediaResponse(const std::shared_ptr<Slot>& slot, uint32_t id, bool allow,
                     bool remember);
void DoSetMediaSetting(const std::shared_ptr<Slot>& slot, uint8_t value);
void DoSetPumpInterval(const std::shared_ptr<Slot>& slot, int ms);
void DoFind(const std::shared_ptr<Slot>& slot, const std::string& text,
            bool forward, bool match_case, bool find_next);
void DoStopFind(const std::shared_ptr<Slot>& slot, bool clear_selection);
void DoJsDialogResp(const std::shared_ptr<Slot>& slot, uint32_t id, bool ok,
                    const std::string& text);
void DoEvalReturning(uint32_t wire_id, uint32_t id, const std::string& code);
void DoAddChannel(uint32_t wire_id, const std::string& name);
void DoSetCookie(uint32_t wire_id, const std::string& url,
                 const std::string& name, const std::string& value,
                 const std::string& domain, const std::string& path,
                 bool secure, bool http_only, const std::string& same_site);
void DoClearCookies();
void DoVisitCookies(uint32_t wire_id, uint32_t id, const std::string& url);
void DoDeleteCookie(const std::string& url, const std::string& name);
void DoShowDevTools(const std::shared_ptr<Slot>& slot, int inspect_x,
                    int inspect_y);
void DoResolveTargetId(const std::shared_ptr<Slot>& slot);
void DoImeSetComposition(const std::shared_ptr<Slot>& slot,
                         const std::string& text);
void DoImeCommitText(const std::shared_ptr<Slot>& slot,
                     const std::string& text);
void DoImeCancel(const std::shared_ptr<Slot>& slot);
void DoPointer(const std::shared_ptr<Slot>& slot, int type, int button,
               int click_count, uint32_t modifiers, double x, double y,
               double dx, double dy);
void DoKey(const std::shared_ptr<Slot>& slot, int type, uint32_t modifiers,
           int32_t windows_key_code, int32_t native_key_code,
           uint32_t character);
void DoInvalidate(const std::shared_ptr<Slot>& slot);

}  // namespace cef_host
