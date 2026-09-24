// Document-start scripts + JS channels, shared by the browser process
// (authored_content.mm, host_client.mm) and the renderer (process_helper.mm).
//
// A consumer's document-start scripts, and the JS channels it registered before
// create, have to exist BEFORE the page's own scripts run. The browser process
// can't guarantee that: CefFrame::ExecuteJavaScript from OnLoadStart is an async
// hop into the renderer that races the document's head scripts. So the config
// rides INTO the renderer with the browser itself — CreateBrowser's extra_info,
// which CEF hands to OnBrowserCreated in every renderer process that ever hosts
// this browser (including the new process after a cross-site navigation) — and
// the renderer runs it synchronously in OnContextCreated, the moment each
// main-frame document's JavaScript context exists and before anything else can.
#pragma once

#include <cctype>
#include <cstdint>
#include <string>
#include <vector>

namespace document_start {

// CreateBrowser extra_info keys (CefListValue of strings each).
constexpr char kChannelsKey[] = "flutter_cef.channels";
constexpr char kScriptsKey[] = "flutter_cef.documentStart";

struct Config {
  std::vector<std::string> channels;
  std::vector<std::string> scripts;
  bool empty() const { return channels.empty() && scripts.empty(); }
};

// kOpSetDocumentStart payload: a sequence of {u8 kind}{u32 len BE}{utf8 bytes},
// kind 0 = a JS channel name, 1 = a script. Unknown kinds are skipped; a
// truncated item ends the parse (everything before it is kept).
inline Config ParsePayload(const uint8_t* p, size_t n) {
  Config c;
  size_t i = 0;
  while (i + 5 <= n) {
    const uint8_t kind = p[i];
    const uint32_t len = (uint32_t(p[i + 1]) << 24) | (uint32_t(p[i + 2]) << 16) |
                         (uint32_t(p[i + 3]) << 8) | uint32_t(p[i + 4]);
    i += 5;
    if (len > n - i) break;
    std::string s(reinterpret_cast<const char*>(p + i), len);
    i += len;
    if (kind == 0) c.channels.push_back(std::move(s));
    else if (kind == 1) c.scripts.push_back(std::move(s));
  }
  return c;
}

// A JS channel name is interpolated into the shim's source, so it MUST be a plain
// JS identifier — otherwise a crafted name could break out of the string literal
// and run arbitrary script on every page load.
inline bool IsValidChannelName(const std::string& n) {
  if (n.empty() || n.size() > 64) return false;
  auto is_first = [](unsigned char c) {
    return std::isalpha(c) || c == '_' || c == '$';
  };
  auto is_rest = [](unsigned char c) {
    return std::isalnum(c) || c == '_' || c == '$';
  };
  if (!is_first(static_cast<unsigned char>(n[0]))) return false;
  for (size_t i = 1; i < n.size(); ++i) {
    if (!is_rest(static_cast<unsigned char>(n[i]))) return false;
  }
  return true;
}

// window.<name>.postMessage(m) -> window.cefQuery 'ch:<name>:<m>' (the browser
// half forwards it to the host as kOpChannelMsg). The one definition of the shim,
// whether installed at document start or re-injected on load.
inline std::string ChannelShimJs(const std::string& name) {
  return "window['" + name +
         "']={postMessage:function(m){window.cefQuery({request:'ch:" + name +
         ":'+String(m),persistent:false,"
         "onSuccess:function(){},onFailure:function(){}});}};";
}

// `s` as a double-quoted JS string literal (for reporting a script's failure
// through the page console).
inline std::string JsStringLiteral(const std::string& s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '<': out += "\\x3c"; break;
      default:
        if (c < 0x20) {
          static const char kHex[] = "0123456789abcdef";
          out += "\\x";
          out += kHex[c >> 4];
          out += kHex[c & 0xf];
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out + "\"";
}

}  // namespace document_start
