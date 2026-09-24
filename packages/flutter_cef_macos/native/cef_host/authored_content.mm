#include "authored_content.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <mutex>
#include <vector>

#include "include/cef_resource_handler.h"

namespace cef_host {

// JS channels: on each main-frame load we inject a window.<name>.postMessage shim
// for each of the browser's Slot::channels, routed to the host over
// window.cefQuery (the CefMessageRouter channel — renderer half lives in
// process_helper.mm).


void InjectChannelShim(CefRefPtr<CefFrame> frame, const std::string& name) {
  if (!frame) return;
  frame->ExecuteJavaScript(document_start::ChannelShimJs(name), "", 0);
}

// Document-start config parked by kOpSetDocumentStart until its browser's
// DoCreateBrowser takes it. Keyed by wire id and set on the reader thread ahead
// of the create frame (like g_authored), read on TID_UI — hence the mutex.
namespace {
std::mutex g_doc_start_mutex;
std::map<uint32_t, document_start::Config> g_doc_start;
}  // namespace

void SetDocumentStart(uint32_t wire_id, document_start::Config config) {
  std::lock_guard<std::mutex> lock(g_doc_start_mutex);
  if (config.empty()) {
    g_doc_start.erase(wire_id);
  } else {
    g_doc_start[wire_id] = std::move(config);
  }
}


CefRefPtr<CefDictionaryValue> TakeDocumentStartExtraInfo(
    uint32_t wire_id, std::set<std::string>* channels) {
  document_start::Config config;
  {
    std::lock_guard<std::mutex> lock(g_doc_start_mutex);
    auto it = g_doc_start.find(wire_id);
    if (it == g_doc_start.end()) return nullptr;
    config = std::move(it->second);
    g_doc_start.erase(it);
  }
  channels->insert(config.channels.begin(), config.channels.end());
  auto to_list = [](const std::vector<std::string>& v) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    for (size_t i = 0; i < v.size(); ++i) list->SetString(i, v[i]);
    return list;
  };
  CefRefPtr<CefDictionaryValue> info = CefDictionaryValue::Create();
  info->SetList(document_start::kChannelsKey, to_list(config.channels));
  info->SetList(document_start::kScriptsKey, to_list(config.scripts));
  return info;
}

// ---- Authored documents at a real origin (loadHtmlString(baseUrl:)) ----
//
// A data: URL gives the document an OPAQUE origin: relative URLs don't resolve, and
// every fetch/XHR/worker it makes is cross-origin with `Origin: null`. Content that
// was written to live at a site — an editor bundle that loads its workers and
// siblings from its own origin — cannot run that way. So the host can hand us the
// HTML plus the URL it should appear to come from, and we answer the MAIN-FRAME
// request for exactly that URL with the HTML instead of the network. The document
// then has that URL's real origin; everything else it loads goes to the network
// as normal.
//
// Keyed by WIRE ID and written on the reader thread, not stored on the Slot: the
// frame is sent immediately ahead of the create / load it belongs to, and must be
// in place before that op runs — including when the slot doesn't exist yet. Read
// on the IO thread (GetResourceRequestHandler), hence the mutex. Sticky across
// reloads; replaced by the next set, cleared by a plain navigate or by dispose.
namespace {
struct AuthoredDoc {
  std::string url;  // normalized (NormalizeAuthoredUrl)
  std::string html;
};
std::mutex g_authored_mutex;
std::map<uint32_t, AuthoredDoc> g_authored;
}  // namespace

// Compare URLs the way the network stack will present them: no fragment, and a
// bare authority ("https://host") carries the implicit "/" path.
std::string NormalizeAuthoredUrl(std::string url) {
  // http(s) only: a data: URL is matched verbatim (its payload may contain "://").
  if (url.rfind("http://", 0) != 0 && url.rfind("https://", 0) != 0) return url;
  const size_t hash = url.find('#');
  if (hash != std::string::npos) url.resize(hash);
  const size_t scheme_end = url.find("://");
  if (scheme_end != std::string::npos &&
      url.find('/', scheme_end + 3) == std::string::npos) {
    const size_t q = url.find('?', scheme_end + 3);
    if (q == std::string::npos) url += '/';
    else url.insert(q, "/");
  }
  return url;
}

void SetAuthoredDoc(uint32_t wire_id, const std::string& url,
                    const std::string& html) {
  std::lock_guard<std::mutex> lock(g_authored_mutex);
  if (html.empty() || url.empty()) {
    g_authored.erase(wire_id);
  } else {
    g_authored[wire_id] = AuthoredDoc{NormalizeAuthoredUrl(url), html};
  }
}
void ClearAuthoredDocUnless(uint32_t wire_id, const std::string& keep_url) {
  std::lock_guard<std::mutex> lock(g_authored_mutex);
  auto it = g_authored.find(wire_id);
  if (it == g_authored.end()) return;
  if (keep_url.empty() || it->second.url != NormalizeAuthoredUrl(keep_url))
    g_authored.erase(it);
}
bool LookupAuthoredDoc(uint32_t wire_id, const std::string& url,
                       std::string* html) {
  std::lock_guard<std::mutex> lock(g_authored_mutex);
  auto it = g_authored.find(wire_id);
  if (it == g_authored.end()) return false;
  if (it->second.url != NormalizeAuthoredUrl(url)) return false;
  if (html) *html = it->second.html;
  return true;
}

namespace {

// Serves one authored document. Owns its bytes (CefStreamReader::CreateForData
// borrows, and the doc can be replaced mid-read).
class AuthoredResourceHandler : public CefResourceHandler {
 public:
  explicit AuthoredResourceHandler(std::string html) : html_(std::move(html)) {}
  bool Open(CefRefPtr<CefRequest>, bool& handle_request,
            CefRefPtr<CefCallback>) override {
    handle_request = true;
    return true;
  }
  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length, CefString&) override {
    response->SetStatus(200);
    response->SetStatusText("OK");
    response->SetMimeType("text/html");
    response->SetCharset("utf-8");
    response->SetHeaderByName("Cache-Control", "no-store", true);
    response_length = static_cast<int64_t>(html_.size());
  }
  bool Read(void* data_out, int bytes_to_read, int& bytes_read,
            CefRefPtr<CefResourceReadCallback>) override {
    bytes_read = 0;
    if (offset_ >= html_.size() || bytes_to_read <= 0) return false;
    const size_t n =
        std::min(static_cast<size_t>(bytes_to_read), html_.size() - offset_);
    memcpy(data_out, html_.data() + offset_, n);
    offset_ += n;
    bytes_read = static_cast<int>(n);
    return true;
  }
  void Cancel() override {}

 private:
  std::string html_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(AuthoredResourceHandler);
};

class AuthoredRequestHandler : public CefResourceRequestHandler {
 public:
  explicit AuthoredRequestHandler(std::string html) : html_(std::move(html)) {}
  CefRefPtr<CefResourceHandler> GetResourceHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
      CefRefPtr<CefRequest>) override {
    return new AuthoredResourceHandler(html_);
  }

 private:
  std::string html_;
  IMPLEMENT_REFCOUNTING(AuthoredRequestHandler);
};

}  // namespace

CefRefPtr<CefResourceRequestHandler> NewAuthoredRequestHandler(std::string html) {
  return new AuthoredRequestHandler(std::move(html));
}

}  // namespace cef_host
