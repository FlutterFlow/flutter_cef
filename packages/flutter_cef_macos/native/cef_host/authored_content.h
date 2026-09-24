// Content the host puts into a page rather than the network: authored documents
// served at a real origin (loadHtmlString(baseUrl:)), document-start scripts,
// and the JS-channel shims.
#pragma once

#include <cstdint>
#include <set>
#include <string>

#include "document_start.h"
#include "include/cef_frame.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_values.h"

namespace cef_host {

// A JS channel name is interpolated into the injected shim's source — see
// document_start::IsValidChannelName (DoAddChannel drops invalid names).
using document_start::IsValidChannelName;

// Injects the window.<name>.postMessage shim for one JS channel into `frame`.
void InjectChannelShim(CefRefPtr<CefFrame> frame, const std::string& name);

// Parks the document-start config for `wire_id`'s browser until its create.
// Any thread.
void SetDocumentStart(uint32_t wire_id, document_start::Config config);

// The browser's creation info carrying its document-start config to every
// renderer that hosts it, or null when it has none. Consumes the parked entry.
// Adds the config's channels to `channels`.
CefRefPtr<CefDictionaryValue> TakeDocumentStartExtraInfo(
    uint32_t wire_id, std::set<std::string>* channels);

// `url` as the network stack presents it (see authored_content.mm).
std::string NormalizeAuthoredUrl(std::string url);

// Sets (or, with an empty url or html, clears) the authored document of
// `wire_id`'s browser. Any thread.
void SetAuthoredDoc(uint32_t wire_id, const std::string& url,
                    const std::string& html);
// Drop the authored doc unless it is for `keep_url` (the load that follows a set
// targets the same URL and must keep it).
void ClearAuthoredDocUnless(uint32_t wire_id, const std::string& keep_url);
// Whether `wire_id`'s browser has an authored document for `url`, and if so
// its html (when `html` isn't null).
bool LookupAuthoredDoc(uint32_t wire_id, const std::string& url,
                       std::string* html);

// A request handler that answers with `html` (an authored document).
CefRefPtr<CefResourceRequestHandler> NewAuthoredRequestHandler(std::string html);

}  // namespace cef_host
