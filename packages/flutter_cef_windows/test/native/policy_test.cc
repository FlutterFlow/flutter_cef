// Unit tests for the Windows plugin's and cef_host's pure policy headers
// (native/cef_host/cef_host_policy.h, windows/liveness_policy.h). Neither
// needs Win32, CEF or Flutter, so they build and run on any host with a C++17
// compiler: see run_policy_tests.sh.

#include <chrono>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

#include "cef_host_policy.h"
#include "liveness_policy.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool ok, const char* what, int line) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("FAIL line %d: %s\n", line, what);
  }
}
#define CHECK(x) Check((x), #x, __LINE__)

using namespace flutter_cef;
using Clock = policy::CrashLoopDetector::Clock;

void TestCrashLoop() {
  policy::CrashLoopDetector d;
  const Clock::time_point t0 = Clock::now();
  // Three quick deaths are recoverable; the fourth inside 10 s is a loop.
  CHECK(!d.Note(t0));
  CHECK(!d.Note(t0 + std::chrono::seconds(1)));
  CHECK(!d.Note(t0 + std::chrono::seconds(2)));
  CHECK(d.Note(t0 + std::chrono::seconds(3)));

  // Deaths spread over a long session never add up.
  policy::CrashLoopDetector slow;
  for (int i = 0; i < 20; ++i)
    CHECK(!slow.Note(t0 + std::chrono::seconds(11 * i)));

  // A burst that ages out starts a fresh window.
  policy::CrashLoopDetector aged;
  CHECK(!aged.Note(t0));
  CHECK(!aged.Note(t0 + std::chrono::seconds(1)));
  CHECK(!aged.Note(t0 + std::chrono::seconds(2)));
  CHECK(!aged.Note(t0 + std::chrono::seconds(15)));
  CHECK(!aged.Note(t0 + std::chrono::seconds(16)));
}

void TestPayloadCaps() {
  // Under the cap: untouched.
  CHECK(policy::CapText("hello", 10) == "hello");
  CHECK(policy::CapEvalResult("7:{\"ok\":true,\"v\":1}", 100) ==
        "7:{\"ok\":true,\"v\":1}");

  // Over the cap: cut, with a note, and never longer than the cap.
  const std::string big(1000, 'x');
  const std::string capped = policy::CapText(big, 100);
  CHECK(capped.size() <= 100);
  CHECK(capped.find("[truncated 900 bytes]") != std::string::npos);

  // An eval reply too large becomes an error reply for the same id, so the
  // caller's future fails instead of the host being torn down.
  const std::string reply = "42:{\"ok\":true,\"v\":\"" + big + "\"}";
  const std::string err = policy::CapEvalResult(reply, 100);
  CHECK(err.rfind("42:{\"ok\":false,", 0) == 0);
  CHECK(err.size() < 100);

  // The default cap sits well under the plugin's 64 MiB frame limit.
  CHECK(policy::kMaxPagePayload < (64u << 20));

  // UTF-8 truncation never splits a sequence. "é" is 2 bytes, "€" 3, "😀" 4.
  CHECK(policy::TruncateUtf8("a\xC3\xA9", 2) == "a");
  CHECK(policy::TruncateUtf8("a\xC3\xA9", 3) == "a\xC3\xA9");
  CHECK(policy::TruncateUtf8("ab\xE2\x82\xAC", 4) == "ab");
  CHECK(policy::TruncateUtf8("\xF0\x9F\x98\x80z", 3) == "");
  CHECK(policy::TruncateUtf8("\xF0\x9F\x98\x80z", 4) == "\xF0\x9F\x98\x80");
  CHECK(policy::TruncateUtf8("abc", 0) == "");
}

void TestSchemes() {
  CHECK(policy::IsValidScheme("https"));
  CHECK(policy::IsValidScheme("chrome-extension"));
  CHECK(policy::IsValidScheme("web+app"));
  CHECK(policy::IsValidScheme("x.y"));
  CHECK(!policy::IsValidScheme(""));
  CHECK(!policy::IsValidScheme("1http"));
  CHECK(!policy::IsValidScheme("-x"));
  CHECK(!policy::IsValidScheme("ht tp"));
  CHECK(!policy::IsValidScheme("http\""));

  CHECK(policy::IsValidSchemeList(""));
  CHECK(policy::IsValidSchemeList("https,http,about,data"));
  CHECK(policy::IsValidSchemeList("https,,http,"));
  // The injections the check exists for: a space or quote would put a
  // Chromium switch on cef_host's command line.
  CHECK(!policy::IsValidSchemeList("https --remote-debugging-port=9222"));
  CHECK(!policy::IsValidSchemeList("https,\"x"));
  CHECK(!policy::IsValidSchemeList("https --ephemeral"));
  CHECK(!policy::IsValidSchemeList("https\t--x"));

  const std::set<std::string> parsed =
      policy::ParseSchemeList("HTTPS,about,bad scheme,,Data");
  CHECK(parsed == (std::set<std::string>{"https", "about", "data"}));
  CHECK(policy::ParseSchemeList("").empty());
}

void TestFrameRate() {
  CHECK(policy::FrameRateForIntervalMs(16) == 63);
  CHECK(policy::FrameRateForIntervalMs(33) == 30);
  CHECK(policy::FrameRateForIntervalMs(0) == 125);   // clamped to 8 ms
  CHECK(policy::FrameRateForIntervalMs(8) == 125);
  CHECK(policy::FrameRateForIntervalMs(1000) == 4);  // clamped to 250 ms
  CHECK(policy::FrameRateForIntervalMs(-5) == 125);
}

void TestDownloads() {
  CHECK(policy::SanitizeDownloadLeaf(L"report.pdf") == L"report.pdf");
  // Only the last path component survives.
  CHECK(policy::SanitizeDownloadLeaf(L"..\\..\\Windows\\evil.exe") ==
        L"evil.exe");
  CHECK(policy::SanitizeDownloadLeaf(L"a/b/c.txt") == L"c.txt");
  // ':' would name an alternate data stream.
  CHECK(policy::SanitizeDownloadLeaf(L"file.txt:stream") == L"file.txt_stream");
  CHECK(policy::SanitizeDownloadLeaf(L"a<b>c|d?e*f\"g") == L"a_b_c_d_e_f_g");
  CHECK(policy::SanitizeDownloadLeaf(L"tab\there") == L"tab_here");
  // Windows drops trailing dots and spaces.
  CHECK(policy::SanitizeDownloadLeaf(L"name. . ") == L"name");
  CHECK(policy::SanitizeDownloadLeaf(L"") == L"download");
  CHECK(policy::SanitizeDownloadLeaf(L"...") == L"download");
  CHECK(policy::SanitizeDownloadLeaf(L"dir\\") == L"download");
  // DOS device names.
  CHECK(policy::SanitizeDownloadLeaf(L"con") == L"_con");
  CHECK(policy::SanitizeDownloadLeaf(L"NUL.txt") == L"_NUL.txt");
  CHECK(policy::SanitizeDownloadLeaf(L"com1.tar.gz") == L"_com1.tar.gz");
  CHECK(policy::SanitizeDownloadLeaf(L"console.txt") == L"console.txt");

  // A download never lands on an existing file.
  std::set<std::wstring> existing;
  const auto exists = [&existing](const std::wstring& p) {
    return existing.count(p) != 0;
  };
  CHECK(policy::UniqueDownloadPath(L"C:\\D", L"a.pdf", exists) ==
        L"C:\\D\\a.pdf");
  existing.insert(L"C:\\D\\a.pdf");
  CHECK(policy::UniqueDownloadPath(L"C:\\D", L"a.pdf", exists) ==
        L"C:\\D\\a (2).pdf");
  existing.insert(L"C:\\D\\a (2).pdf");
  CHECK(policy::UniqueDownloadPath(L"C:\\D", L"a.pdf", exists) ==
        L"C:\\D\\a (3).pdf");
  existing.insert(L"C:\\D\\noext");
  CHECK(policy::UniqueDownloadPath(L"C:\\D", L"noext", exists) ==
        L"C:\\D\\noext (2)");
  existing.insert(L"C:\\D\\.bashrc");
  CHECK(policy::UniqueDownloadPath(L"C:\\D", L".bashrc", exists) ==
        L"C:\\D\\.bashrc (2)");
}

void TestCreateAndGate() {
  // A create queued at 800x600@1 is sent at the view's current size.
  std::vector<uint8_t> create(16, 0);
  WriteU32BE(create.data(), 800);
  WriteU32BE(create.data() + 4, 600);
  WriteF64BE(create.data() + 8, 1.0);
  const std::string url = "https://example.com/";
  create.insert(create.end(), url.begin(), url.end());
  CHECK(policy::RewriteCreateSize(create, 1200, 800, 2.0));
  CHECK(ReadU32BE(create.data()) == 1200);
  CHECK(ReadU32BE(create.data() + 4) == 800);
  CHECK(ReadF64BE(create.data() + 8) == 2.0);
  CHECK(std::string(create.begin() + 16, create.end()) == url);
  std::vector<uint8_t> short_payload(8, 0);
  CHECK(!policy::RewriteCreateSize(short_payload, 1, 1, 1.0));

  // The size gate the rewrite has to satisfy: +-1 px of rounding only.
  CHECK(policy::SizeGatePasses(2400, 1600, 2400, 1600));
  CHECK(policy::SizeGatePasses(2401, 1599, 2400, 1600));
  CHECK(!policy::SizeGatePasses(800, 600, 1200, 800));
  CHECK(!policy::SizeGatePasses(2402, 1600, 2400, 1600));
}

void TestLiveness() {
  using liveness::Action;
  using liveness::PingAction;
  const uint64_t s = 1000000000ull;  // 1 s in ns
  // Painted recently: healthy.
  CHECK(liveness::Evaluate(2 * s, 10 * s, false, 0, 3 * s) == Action::kHealthy);
  // Stale and not nudged: nudge.
  CHECK(liveness::Evaluate(11 * s, 10 * s, false, 0, 3 * s) == Action::kNudge);
  // Nudged, still inside the grace: wait.
  CHECK(liveness::Evaluate(12 * s, 10 * s, true, 1 * s, 3 * s) ==
        Action::kHealthy);
  // Nudged and the grace passed with no frame.
  CHECK(liveness::Evaluate(14 * s, 10 * s, true, 3 * s, 3 * s) ==
        Action::kDeclareStalled);

  const uint64_t now = 1000 * s;
  // No ping out and none answered: ping.
  CHECK(liveness::Ping(now, 0, 0, 10 * s, 15 * s) == PingAction::kPing);
  // Answered recently: a static page isn't re-pinged every sweep.
  CHECK(liveness::Ping(now, 0, now - 5 * s, 10 * s, 15 * s) ==
        PingAction::kWait);
  CHECK(liveness::Ping(now, 0, now - 11 * s, 10 * s, 15 * s) ==
        PingAction::kPing);
  // Outstanding: wait until the hang threshold, then hung.
  CHECK(liveness::Ping(now, now - 14 * s, 0, 10 * s, 15 * s) ==
        PingAction::kWait);
  CHECK(liveness::Ping(now, now - 15 * s, 0, 10 * s, 15 * s) ==
        PingAction::kHung);

  CHECK(liveness::MayPing(0, false, false));
  CHECK(!liveness::MayPing(1, false, false));  // blocked on a JS dialog
  CHECK(!liveness::MayPing(0, true, false));   // DevTools can pause it
  CHECK(!liveness::MayPing(0, false, true));   // so can an agent over CDP

  // The ping id is out of reach of Dart's eval ids, which count up from 1.
  CHECK(liveness::kPingId == 0xFFFFFFFFu);
}

}  // namespace

int main() {
  TestCrashLoop();
  TestPayloadCaps();
  TestSchemes();
  TestFrameRate();
  TestDownloads();
  TestCreateAndGate();
  TestLiveness();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
