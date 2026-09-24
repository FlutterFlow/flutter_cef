// Pure decision helpers for the Windows cef_host and plugin: no CEF, no Win32,
// so they compile anywhere and are unit-tested standalone
// (packages/flutter_cef_windows/test/native/run_policy_tests.sh).
//
// Both cef_host_win.cc and the plugin (windows/) include this header; the
// plugin's CMake already has this directory on its include path for
// cef_host_protocol.h.

#ifndef FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_POLICY_H_
#define FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_POLICY_H_

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <set>
#include <string>
#include <vector>

#include "cef_host_protocol.h"

namespace flutter_cef {
namespace policy {

// ---- Renderer crash loop ----------------------------------------------------
//
// A renderer that dies is normally recoverable: the host reloads and a fresh
// child takes over. But when children can't start at all, the reload
// re-crashes at once and loops forever while the pipe stays up, so the
// embedder never hears about it. Past a burst the host exits instead, which
// the plugin reports as processGone and the embedder's recreate path handles.
// Same thresholds as the macOS host.
class CrashLoopDetector {
 public:
  using Clock = std::chrono::steady_clock;
  static constexpr int kBurstLimit = 4;
  static constexpr std::chrono::seconds kWindow{10};

  // Records a renderer death at `now`. True once the deaths arrive as a burst.
  bool Note(Clock::time_point now) {
    if (count_ == 0 || now - window_start_ > kWindow) {
      // The first death, or the previous burst aged out: one-off crashes over a
      // long session never add up.
      window_start_ = now;
      count_ = 1;
      return false;
    }
    return ++count_ >= kBurstLimit;
  }

 private:
  int count_ = 0;
  Clock::time_point window_start_;
};

// ---- Page-sourced payloads --------------------------------------------------
//
// The plugin treats a frame body over 64 MiB as a desynced stream and drops
// the whole host, so a page that logs or posts something that large would end
// every tile on its profile. The host caps what a page can put on the wire
// well below that.
constexpr size_t kMaxPagePayload = 8u << 20;  // 8 MiB

// The longest prefix of `s` of at most `max` bytes that doesn't end inside a
// UTF-8 sequence.
inline std::string TruncateUtf8(const std::string& s, size_t max) {
  if (s.size() <= max) return s;
  size_t end = max;
  // Back up over continuation bytes (10xxxxxx) to the lead byte, then drop the
  // lead too if its sequence doesn't fit.
  size_t lead = end;
  while (lead > 0 &&
         (static_cast<unsigned char>(s[lead - 1]) & 0xC0) == 0x80) {
    --lead;
  }
  if (lead > 0) {
    const unsigned char c = static_cast<unsigned char>(s[lead - 1]);
    size_t len = 1;
    if ((c & 0xE0) == 0xC0) len = 2;
    else if ((c & 0xF0) == 0xE0) len = 3;
    else if ((c & 0xF8) == 0xF0) len = 4;
    if (len > 1 && (lead - 1) + len > end) end = lead - 1;
  }
  return s.substr(0, end);
}

// `s` cut to `max` bytes, with a note of how much was cut. For text the page
// shows or logs (console messages, titles).
inline std::string CapText(const std::string& s,
                           size_t max = kMaxPagePayload) {
  if (s.size() <= max) return s;
  const std::string note =
      " [truncated " + std::to_string(s.size() - max) + " bytes]";
  const size_t keep = max > note.size() ? max - note.size() : 0;
  return TruncateUtf8(s, keep) + note;
}

// An eval reply ("<id>:<json>") too large for the wire becomes an error reply
// for the same id, so the caller's future fails instead of hanging.
inline std::string CapEvalResult(const std::string& reply,
                                 size_t max = kMaxPagePayload) {
  if (reply.size() <= max) return reply;
  const size_t colon = reply.find(':');
  const std::string id =
      colon == std::string::npos ? std::string() : reply.substr(0, colon);
  return id + ":{\"ok\":false,\"v\":\"result too large (" +
         std::to_string(reply.size()) + " bytes)\"}";
}

// ---- Navigation schemes -----------------------------------------------------

// A URL scheme as RFC 3986 spells it: a letter, then letters, digits, "+", "-"
// or ".". The allowlist travels on cef_host's command line, so anything else
// (a space, a quote) could smuggle in a Chromium switch.
inline bool IsValidScheme(const std::string& s) {
  if (s.empty()) return false;
  auto alpha = [](char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
  };
  if (!alpha(s[0])) return false;
  for (char c : s) {
    const bool ok = alpha(c) || (c >= '0' && c <= '9') || c == '+' ||
                    c == '-' || c == '.';
    if (!ok) return false;
  }
  return true;
}

// True when every comma-separated entry of `csv` is a valid scheme. Empty
// entries are ignored; an empty list means "allow all".
inline bool IsValidSchemeList(const std::string& csv) {
  size_t start = 0;
  while (start <= csv.size()) {
    const size_t comma = csv.find(',', start);
    const std::string item = csv.substr(
        start, comma == std::string::npos ? std::string::npos : comma - start);
    if (!item.empty() && !IsValidScheme(item)) return false;
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  return true;
}

// The lowercased schemes of `csv`, skipping empty and invalid entries.
inline std::set<std::string> ParseSchemeList(const std::string& csv) {
  std::set<std::string> out;
  size_t start = 0;
  while (start <= csv.size()) {
    const size_t comma = csv.find(',', start);
    std::string item = csv.substr(
        start, comma == std::string::npos ? std::string::npos : comma - start);
    if (IsValidScheme(item)) {
      for (char& c : item)
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
      out.insert(item);
    }
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  return out;
}

// ---- Create and present sizing ----------------------------------------------

// Rewrites a kOpCreateBrowser payload ({u32 w}{u32 h}{f64 dpr}{utf8 url}) to
// the given size. The plugin queues a create until its host is ready, which
// can take seconds; the view may be laid out again meanwhile, and a create at
// the stale size paints frames the size gate then rejects. False (payload
// untouched) if it is too short to be a create.
inline bool RewriteCreateSize(std::vector<uint8_t>& payload, uint32_t width,
                              uint32_t height, double dpr) {
  if (payload.size() < 16) return false;
  WriteU32BE(payload.data(), width);
  WriteU32BE(payload.data() + 4, height);
  WriteF64BE(payload.data() + 8, dpr);
  return true;
}

// The plugin's present size gate: a frame is shown only when its physical
// size is within 1 px of what the view expects (rounding), so a frame painted
// for a size the view has already left never reaches the texture.
inline bool SizeGatePasses(uint32_t src_w, uint32_t src_h, uint32_t expected_w,
                           uint32_t expected_h) {
  const auto within_one = [](uint32_t a, uint32_t b) {
    return (a > b ? a - b : b - a) <= 1;
  };
  return within_one(src_w, expected_w) && within_one(src_h, expected_h);
}

// ---- Frame cadence ------------------------------------------------------------

// The windowless frame rate for a begin-frame interval in ms. The interval is
// clamped to [8, 250] like the macOS pump, so the rate is 4..125 fps.
inline int FrameRateForIntervalMs(int ms) {
  if (ms < 8) ms = 8;
  if (ms > 250) ms = 250;
  return (1000 + ms / 2) / ms;
}

// ---- Downloads --------------------------------------------------------------

// A page-chosen download name (Content-Disposition) reduced to a safe file
// name: the last path component only, with characters Windows reserves
// (including ':' , which would name an alternate data stream) replaced,
// trailing dots and spaces dropped, and DOS device names neutralized.
inline std::wstring SanitizeDownloadLeaf(std::wstring name) {
  const size_t slash = name.find_last_of(L"/\\");
  if (slash != std::wstring::npos) name = name.substr(slash + 1);
  for (wchar_t& c : name) {
    if (c < 0x20 || c == L'<' || c == L'>' || c == L':' || c == L'"' ||
        c == L'|' || c == L'?' || c == L'*') {
      c = L'_';
    }
  }
  while (!name.empty() && (name.back() == L'.' || name.back() == L' '))
    name.pop_back();
  if (name.empty()) return L"download";
  std::wstring base = name.substr(0, name.find(L'.'));
  for (wchar_t& c : base)
    if (c >= L'a' && c <= L'z') c = static_cast<wchar_t>(c - 32);
  static const wchar_t* kReserved[] = {
      L"CON",  L"PRN",  L"AUX",  L"NUL",  L"COM1", L"COM2", L"COM3", L"COM4",
      L"COM5", L"COM6", L"COM7", L"COM8", L"COM9", L"LPT1", L"LPT2", L"LPT3",
      L"LPT4", L"LPT5", L"LPT6", L"LPT7", L"LPT8", L"LPT9"};
  for (const wchar_t* r : kReserved)
    if (base == r) return L"_" + name;
  return name;
}

// `dir\leaf` if `exists` says it is free, else `dir\stem (n).ext` for the
// first free n (2, 3, ...), so a download never lands on an existing file.
inline std::wstring UniqueDownloadPath(
    const std::wstring& dir, const std::wstring& leaf,
    const std::function<bool(const std::wstring&)>& exists) {
  const std::wstring first = dir + L"\\" + leaf;
  if (!exists(first)) return first;
  const size_t dot = leaf.find_last_of(L'.');
  const bool has_ext = dot != std::wstring::npos && dot > 0;
  const std::wstring stem = has_ext ? leaf.substr(0, dot) : leaf;
  const std::wstring ext = has_ext ? leaf.substr(dot) : std::wstring();
  for (int n = 2; n < 10000; ++n) {
    const std::wstring candidate =
        dir + L"\\" + stem + L" (" + std::to_wstring(n) + L")" + ext;
    if (!exists(candidate)) return candidate;
  }
  return first;  // the Save As dialog still asks before overwriting
}

}  // namespace policy
}  // namespace flutter_cef

#endif  // FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_POLICY_H_
