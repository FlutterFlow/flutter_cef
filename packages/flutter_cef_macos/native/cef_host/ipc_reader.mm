#include "ipc_reader.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "authored_content.h"
#include "browser_ops.h"
#include "host_state.h"
#include "include/base/cef_callback.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "ipc.h"
#include "popups.h"

namespace cef_host {

// Reader thread: decode frames, marshal onto the CEF UI thread.
void IpcReadLoop() {
  for (;;) {
    uint8_t hdr[4];
    if (!ReadAll(g_ipc_fd, hdr, 4)) break;
    uint32_t body_len = ReadU32BE(hdr);
    // Minimum valid body is 5 bytes (4 browserId + 1 op + 0 payload).
    // A malformed/oversized length is a wire desync and tears down EVERY browser in
    // this process — log it first so it isn't a silent, breadcrumb-less all-tiles exit
    // (the IPC peer is trusted, so this only fires on a genuine framing bug).
    if (body_len < 5 || body_len > (64u << 20)) {
      fprintf(stderr, "[cef_host] rejecting malformed IPC frame, body_len=%u — exiting\n",
              body_len);
      break;
    }
    std::vector<uint8_t> body(body_len);
    if (!ReadAll(g_ipc_fd, body.data(), body_len)) break;
    uint32_t wire_id = ReadU32BE(body.data());
    uint8_t opcode = body[4];
    const uint8_t* p = body.data() + 5;
    uint32_t plen = body_len - 5;
    // Resolve the target browser once. null for wire id 0 (process-level) or an
    // unknown/disposed id. Per-browser ops bind this shared_ptr into their UI
    // task, so the slot stays alive even if a dispose lands while the task is
    // queued (closes the dispose/in-flight race). Control ops handle slot==null.
    std::shared_ptr<Slot> slot = LookupWireId(wire_id);
    switch (opcode) {
      case kOpCreateBrowser: {
        // Producer-allocates: no sid on the wire. {u32 w}{u32 h}{f64 dpr}{utf8 url}.
        if (plen < 16) break;
        // Clamped to the sizes a resize accepts.
        int w = static_cast<int>(std::min<uint32_t>(ReadU32BE(p), kMaxViewDim));
        int h = static_cast<int>(std::min<uint32_t>(ReadU32BE(p + 4), kMaxViewDim));
        double dpr = ReadF64BE(p + 8);
        if (!(dpr > 0.0 && dpr <= 8.0)) dpr = 1.0;  // bad/forged, NaN included
        std::string url(reinterpret_cast<const char*>(p + 16), plen - 16);
        if (url.empty()) url = "about:blank";
        CefPostTask(TID_UI,
                    base::BindOnce(&DoCreateBrowser, wire_id, w, h, dpr, url));
        break;
      }
      case kOpDisposeBrowser:
        // Resolved on TID_UI (FIFO behind a create still queued there) — requiring
        // the slot here dropped a dispose that raced its own create, leaking the
        // browser.
        CefPostTask(TID_UI, base::BindOnce(&DoDisposeBrowser, wire_id));
        break;
      case kOpShutdown:
        ArmHardExit("kOpShutdown");
        CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
        return;
      case kOpResize: {
        // Producer-allocates: no sid. {u32 w}{u32 h}{f64 dpr}. dpr 0/absent = unchanged.
        if (!slot) break;
        if (plen < 8) break;
        int w = static_cast<int>(ReadU32BE(p));
        int h = static_cast<int>(ReadU32BE(p + 4));
        double dpr = (plen >= 16) ? ReadF64BE(p + 8) : 0.0;
        if (!(dpr >= 0.0 && dpr <= 8.0)) dpr = 0.0;  // bad/forged, NaN included
        CefPostTask(TID_UI, base::BindOnce(&DoResize, slot, w, h, dpr));
        break;
      }
      case kOpSetAuthoredHtml: {
        // Stored HERE, on the reader thread, so it is in place before the create /
        // load frame right behind it is even dispatched. No slot needed.
        std::string s(reinterpret_cast<const char*>(p), plen);
        const size_t nul = s.find('\0');
        if (nul == std::string::npos) break;
        SetAuthoredDoc(wire_id, s.substr(0, nul), s.substr(nul + 1));
        break;
      }
      case kOpSetDocumentStart:
        // Parked on the reader thread, ahead of the create frame right behind it.
        SetDocumentStart(wire_id, document_start::ParsePayload(p, plen));
        break;
      case kOpNavigate: {
        // Resolve by wire id on TID_UI (see DoNavigateByWireId): do NOT require the slot
        // here, or a nav landing behind a still-queued create on a shared host is dropped.
        std::string url(reinterpret_cast<const char*>(p), plen);
        // A plain navigate means the consumer wants the real site again.
        ClearAuthoredDocUnless(wire_id, "");
        CefPostTask(TID_UI,
                    base::BindOnce(&DoNavigateByWireId, wire_id, url, false));
        break;
      }
      case kOpLoadTrusted: {
        // Same: a loadHtmlString right behind a queued create (a 6-tile agent_ui burst)
        // must not be dropped — that was the blank-tile bug. Resolved on TID_UI, FIFO-after
        // the create, and tolerant of a not-yet-bound browser via pending_nav_url.
        std::string url(reinterpret_cast<const char*>(p), plen);
        ClearAuthoredDocUnless(wire_id, url);  // keeps the doc this load is for
        CefPostTask(TID_UI,
                    base::BindOnce(&DoNavigateByWireId, wire_id, url, true));
        break;
      }
      case kOpOpenAuthWindow: {
        // Open a windowed Chrome-runtime browser at |url| for a WebAuthn / Touch
        // ID ceremony. The OSR/Alloy tile CANNOT host WebAuthn (no window for the
        // Touch ID sheet); the Chrome runtime can. nullptr request context = this
        // process's global cookie jar == the tile's named profile (profiles are
        // per-cef_host-process via root_cache_path), so a sign-in propagates back
        // to the tile. Process-level: no slot required.
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&OpenChromeAuthWindow, url));
        break;
      }
      case kOpReload:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoReload, slot));
        break;
      case kOpStop:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoStopLoad, slot));
        break;
      case kOpBack:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoGoBack, slot));
        break;
      case kOpForward:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoGoForward, slot));
        break;
      case kOpExecuteJs: {
        if (!slot) break;
        std::string code(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoExecuteJs, slot, code));
        break;
      }
      case kOpSetZoom: {
        if (!slot) break;
        if (plen < 8) break;
        const double level = ReadF64BE(p);
        if (!std::isfinite(level)) break;
        CefPostTask(TID_UI, base::BindOnce(&DoSetZoom, slot,
                                           std::clamp(level, -10.0, 10.0)));
        break;
      }
      case kOpEditCommand: {
        if (!slot) break;
        if (plen < 1) break;
        CefPostTask(TID_UI, base::BindOnce(&DoEditCommand, slot, int{p[0]}));
        break;
      }
      case kOpSetVisible: {
        if (!slot) break;
        bool vis = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoSetVisible, slot, vis));
        break;
      }
      case kOpMediaResponse: {
        // {u32 id}{u8 allow}{u8 remember} — an answer to a camera/mic prompt.
        if (!slot) break;
        if (plen < 5) break;
        uint32_t id = ReadU32BE(p);
        bool allow = p[4] != 0;
        // Absent byte = don't remember: only an explicit human choice persists.
        bool remember = plen >= 6 && p[5] != 0;
        CefPostTask(TID_UI,
                    base::BindOnce(&DoMediaResponse, slot, id, allow, remember));
        break;
      }
      case kOpContextMenuCommand: {
        // {u32 id}{u32 commandId} — the user picked an item in the Flutter-drawn
        // context menu (commandId 0 = dismissed without choosing). Chromium runs
        // the command, so behaviour matches Chrome exactly.
        if (!slot) break;
        if (plen < 8) break;
        uint32_t id = ReadU32BE(p);
        uint32_t command = ReadU32BE(p + 4);
        CefPostTask(TID_UI,
                    base::BindOnce(&DoContextMenuCommand, slot, id, command));
        break;
      }
      case kOpSetMediaSetting: {
        // {u8 value} — change this site's remembered camera/mic decision.
        if (!slot) break;
        if (plen < 1) break;
        CefPostTask(TID_UI, base::BindOnce(&DoSetMediaSetting, slot, p[0]));
        break;
      }
      case kOpSetAudioMuted: {
        if (!slot) break;
        bool muted = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoSetAudioMuted, slot, muted));
        break;
      }
      case kOpSetPumpInterval: {
        if (!slot) break;
        if (plen < 2) break;
        int ms = (int{p[0]} << 8) | int{p[1]};
        CefPostTask(TID_UI, base::BindOnce(&DoSetPumpInterval, slot, ms));
        break;
      }
      case kOpFind: {
        if (!slot) break;
        if (plen < 3) break;
        bool fwd = p[0] != 0, mc = p[1] != 0, fn = p[2] != 0;
        std::string text(reinterpret_cast<const char*>(p + 3), plen - 3);
        CefPostTask(TID_UI, base::BindOnce(&DoFind, slot, text, fwd, mc, fn));
        break;
      }
      case kOpStopFind: {
        if (!slot) break;
        bool clear = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoStopFind, slot, clear));
        break;
      }
      case kOpJsDialogResp: {
        if (!slot) break;
        if (plen < 5) break;
        uint32_t id = ReadU32BE(p);
        bool ok = p[4] != 0;
        std::string text(reinterpret_cast<const char*>(p + 5), plen - 5);
        CefPostTask(TID_UI, base::BindOnce(&DoJsDialogResp, slot, id, ok, text));
        break;
      }
      case kOpEvalReturning: {
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string code(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoEvalReturning, wire_id, id, code));
        break;
      }
      case kOpAddChannel: {
        // Do NOT require `slot`: on a shared host a session's createBrowser may
        // still be queued (pendingCreates) when this op arrives, and dropping it
        // here is exactly why a peer/secondary session's window.<name> shim was
        // never injected (campus.emit silently dead). DoAddChannel resolves the
        // browser on the UI thread and parks the channel until its create.
        std::string name(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoAddChannel, wire_id, name));
        break;
      }
      case kOpSetCookie: {
        // No slot needed — see DoSetCookie (a verb racing the create must not drop).
        std::string s(reinterpret_cast<const char*>(p), plen);
        std::vector<std::string> f;
        size_t start = 0;
        for (size_t i = 0; i <= s.size(); ++i) {
          if (i == s.size() || s[i] == '\0') {
            f.push_back(s.substr(start, i - start));
            start = i + 1;
          }
        }
        while (f.size() < 8) f.push_back("");
        CefPostTask(TID_UI,
                    base::BindOnce(&DoSetCookie, wire_id, f[0], f[1], f[2], f[3],
                                   f[4], f[5] == "1", f[6] == "1", f[7]));
        break;
      }
      case kOpClearCookies:
        CefPostTask(TID_UI, base::BindOnce(&DoClearCookies));
        break;
      case kOpVisitCookies: {
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string url(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoVisitCookies, wire_id, id, url));
        break;
      }
      case kOpDeleteCookie: {
        std::string s(reinterpret_cast<const char*>(p), plen);
        const size_t nul = s.find('\0');
        std::string url = nul == std::string::npos ? s : s.substr(0, nul);
        std::string name = nul == std::string::npos ? "" : s.substr(nul + 1);
        CefPostTask(TID_UI, base::BindOnce(&DoDeleteCookie, url, name));
        break;
      }
      case kOpImeSetComp: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoImeSetComposition, slot, text));
        break;
      }
      case kOpImeCommit: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoImeCommitText, slot, text));
        break;
      }
      case kOpShowDevTools: {
        if (!slot) break;
        // Back-compat: an empty payload still means "just open DevTools".
        int ix = -1, iy = -1;
        if (plen >= 8) {
          ix = static_cast<int>(ReadU32BE(p));
          iy = static_cast<int>(ReadU32BE(p + 4));
        }
        CefPostTask(TID_UI, base::BindOnce(&DoShowDevTools, slot, ix, iy));
        break;
      }
      case kOpResolveTargetId:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoResolveTargetId, slot));
        break;
      case kOpInvalidate:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoInvalidate, slot));
        break;
      case kOpImeCancel:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoImeCancel, slot));
        break;
      case kOpPointer: {
        if (!slot) break;
        if (plen < 40) break;
        int type = p[0], button = p[1], clicks = p[2];
        uint32_t mods = ReadU32BE(p + 4);
        double x = ReadF64BE(p + 8), y = ReadF64BE(p + 16);
        double dx = ReadF64BE(p + 24), dy = ReadF64BE(p + 32);
        // type 0-4, button 0-2 (DoPointer casts them to CEF enums); coordinates
        // are cast to int, which is undefined for NaN/inf.
        if (type > 4 || button > 2 || !std::isfinite(x) || !std::isfinite(y) ||
            !std::isfinite(dx) || !std::isfinite(dy))
          break;
        CefPostTask(TID_UI, base::BindOnce(&DoPointer, slot, type, button,
                                           clicks, mods, x, y, dx, dy));
        break;
      }
      case kOpKey: {
        if (!slot) break;
        if (plen < 20) break;
        int type = p[0];
        if (type > KEYEVENT_CHAR) break;  // cast to cef_key_event_type_t
        uint32_t mods = ReadU32BE(p + 4);
        int32_t wkc = static_cast<int32_t>(ReadU32BE(p + 8));
        int32_t nkc = static_cast<int32_t>(ReadU32BE(p + 12));
        uint32_t ch = ReadU32BE(p + 16);
        CefPostTask(TID_UI, base::BindOnce(&DoKey, slot, type, mods, wkc, nkc,
                                           ch));
        break;
      }
      default: {
        // An opcode this build doesn't know = protocol skew (a newer plugin driving an
        // older host — the kOpReady version handshake should have refused it, but an
        // in-between version or a bypassed handshake still lands here). Log ONCE per
        // opcode (this reader is a single thread, so plain statics are safe) instead of
        // silently dropping — a silent drop is a frozen tile with no breadcrumb.
        static bool logged_unknown[256] = {false};
        if (!logged_unknown[opcode]) {
          logged_unknown[opcode] = true;
          SendLog(/*browser_id=*/0,
                  "unknown opcode " + std::to_string(opcode) +
                      " (protocol skew? plugin newer than host) — dropping this "
                      "and further frames of this opcode");
        }
        break;
      }
    }
  }
  // Parent died / socket closed: quit.
  ArmHardExit("IPC closed");
  CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
}

}  // namespace cef_host
