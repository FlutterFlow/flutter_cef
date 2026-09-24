// Standalone unit tests for the per-tile CDP isolation filter — THE security
// boundary. CdpRelay.swift depends only on system frameworks (Foundation/CryptoKit/
// Security), so this compiles + runs without Xcode or the Flutter/pod harness:
//
//   ./test/run_filter_tests.sh        (or)   swiftc macos/Classes/CdpRelay.swift \
//        test/CdpRelayFilterTests.swift -o /tmp/cdpfilter && /tmp/cdpfilter
//
// Exercises filterClientToPipe (C→R) and filterPipeToClient (R→C) against a scoped
// relay: deny-by-default, fail-closed, flatten-only, browser-context-wide denial,
// sibling hiding, and session scoping. Pure policy — no sockets are opened (clientFd
// stays -1, so any synthesized error/reply is a harmless no-op).
import Foundation

@main
enum CdpRelayFilterTests {
  static var failures = 0
  static func check(_ name: String, _ cond: Bool) {
    print((cond ? "  PASS  " : "  FAIL  ") + name)
    if !cond { failures += 1 }
  }

  /// Extract a CDP message's top-level integer `id` (nil if absent / not JSON).
  static func topId(_ json: String?) -> Int? {
    guard let json = json, let d = json.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o["id"] as? Int
  }

  static func main() {
    let r = CdpRelay(sendToPipe: { _ in }, scopeTargetId: "TILE-A")
    func fwd(_ n: String, _ json: String) { check("forward: \(n)", r.filterClientToPipe(json) != nil) }
    func drop(_ n: String, _ json: String) { check("deny:    \(n)", r.filterClientToPipe(json) == nil) }
    func inFwd(_ n: String, _ json: String) { check("in fwd:  \(n)", r.filterPipeToClient(json) != nil) }
    func inDrop(_ n: String, _ json: String) { check("in drop: \(n)", r.filterPipeToClient(json) == nil) }

    // ── R→C: learn OUR session from the browser-level attachedToTarget for TILE-A ──
    inFwd("attachedToTarget(TILE-A) browser-level",
      #"{"method":"Target.attachedToTarget","params":{"sessionId":"SESS-A","targetInfo":{"targetId":"TILE-A","type":"page"}}}"#)
    inDrop("attachedToTarget(sibling TILE-B) hidden",
      #"{"method":"Target.attachedToTarget","params":{"sessionId":"SESS-B","targetInfo":{"targetId":"TILE-B","type":"page"}}}"#)
    inFwd("event on our session SESS-A", #"{"method":"Page.loadEventFired","sessionId":"SESS-A","params":{}}"#)
    inDrop("event on sibling session SESS-B", #"{"method":"Page.loadEventFired","sessionId":"SESS-B","params":{}}"#)
    inFwd("browser-level response (no sid)", #"{"id":1,"result":{"product":"Chrome/144"}}"#)
    inDrop("R→C malformed JSON (fail closed)", "{not json")
    inDrop("R→C stray targetInfos enumeration", #"{"id":9,"result":{"targetInfos":[{"targetId":"TILE-B"}]}}"#)

    // ── C→R: the CRITICAL — browser-context-wide CDP denied regardless of routing ──
    drop("Storage.getCookies (whole-jar read)", #"{"id":1,"method":"Storage.getCookies"}"#)
    drop("Storage.clearCookies", #"{"id":1,"method":"Storage.clearCookies"}"#)
    drop("Network.getAllCookies", #"{"id":1,"method":"Network.getAllCookies"}"#)
    drop("Network.clearBrowserCookies", #"{"id":1,"method":"Network.clearBrowserCookies"}"#)
    drop("Tracing.start (process-wide)", #"{"id":1,"method":"Tracing.start"}"#)
    drop("Memory.getDOMCounters", #"{"id":1,"method":"Memory.getDOMCounters"}"#)
    drop("Browser.getBrowserContexts", #"{"id":1,"method":"Browser.getBrowserContexts"}"#)
    drop("Storage.getCookies even ON our session (cross-tile)",
      #"{"id":1,"method":"Storage.getCookies","sessionId":"SESS-A"}"#)
    drop("Network.clearBrowserCookies on our session",
      #"{"id":1,"method":"Network.clearBrowserCookies","sessionId":"SESS-A"}"#)

    // ── C→R: Target.* deny-by-default allow-list, scoped to OUR target ──
    drop("Target.attachToBrowserTarget (escape)", #"{"id":1,"method":"Target.attachToBrowserTarget"}"#)
    drop("Target.exposeDevToolsProtocol", #"{"id":1,"method":"Target.exposeDevToolsProtocol","params":{"targetId":"x"}}"#)
    drop("Target.createTarget (no spawning)", #"{"id":1,"method":"Target.createTarget","params":{"url":"about:blank"}}"#)
    drop("Target.sendMessageToTarget (non-flatten escape)",
      #"{"id":1,"method":"Target.sendMessageToTarget","params":{"sessionId":"SESS-B","message":"{}"}}"#)
    drop("Target.attachToTarget(foreign)",
      #"{"id":1,"method":"Target.attachToTarget","params":{"targetId":"TILE-B","flatten":true}}"#)
    drop("Target.attachToTarget(ours) non-flatten",
      #"{"id":1,"method":"Target.attachToTarget","params":{"targetId":"TILE-A","flatten":false}}"#)
    fwd("Target.attachToTarget(ours, flatten)",
      #"{"id":1,"method":"Target.attachToTarget","params":{"targetId":"TILE-A","flatten":true}}"#)
    drop("Target.getTargetInfo(foreign)",
      #"{"id":1,"method":"Target.getTargetInfo","params":{"targetId":"TILE-B"}}"#)
    fwd("Target.getTargetInfo(no id)", #"{"id":1,"method":"Target.getTargetInfo"}"#)
    drop("Target.getTargets (synthesized, not forwarded)", #"{"id":1,"method":"Target.getTargets"}"#)
    drop("Target.setAutoAttach non-flatten", #"{"id":1,"method":"Target.setAutoAttach","params":{"flatten":false}}"#)
    // Browser-level setAutoAttach(flatten) is INTERCEPTED, not forwarded: the relay
    // self-attaches to our target + synthesizes attachedToTarget, so a client
    // can't change a sibling tile's auto-attach. Forwarding would be a cross-tile
    // control leak — this is the per-tile isolation boundary, so it must return nil.
    drop("Target.setAutoAttach flatten (self-attached + synthesized, not forwarded)",
      #"{"id":1,"method":"Target.setAutoAttach","params":{"flatten":true}}"#)

    // ── C→R: page-scoped driving on OUR session is allowed; foreign session denied ──
    fwd("Page.navigate on our session", #"{"id":1,"method":"Page.navigate","sessionId":"SESS-A","params":{"url":"https://x"}}"#)
    fwd("Runtime.evaluate on our session", #"{"id":1,"method":"Runtime.evaluate","sessionId":"SESS-A","params":{}}"#)
    drop("command on foreign session", #"{"id":1,"method":"Runtime.evaluate","sessionId":"SESS-B","params":{}}"#)

    // ── C→R: Target.* on OUR page session — a page session answers for the whole
    //    browser, so only what drives our own page and its sub-targets goes through ──
    drop("Target.getTargets on our session (lists siblings)",
      #"{"id":1,"method":"Target.getTargets","sessionId":"SESS-A"}"#)
    drop("Target.attachToTarget(sibling) on our session",
      #"{"id":1,"method":"Target.attachToTarget","sessionId":"SESS-A","params":{"targetId":"TILE-B","flatten":true}}"#)
    drop("Target.attachToTarget(ours) on our session",
      #"{"id":1,"method":"Target.attachToTarget","sessionId":"SESS-A","params":{"targetId":"TILE-A","flatten":true}}"#)
    drop("Target.setDiscoverTargets on our session",
      #"{"id":1,"method":"Target.setDiscoverTargets","sessionId":"SESS-A","params":{"discover":true}}"#)
    drop("Target.createTarget on our session",
      #"{"id":1,"method":"Target.createTarget","sessionId":"SESS-A","params":{"url":"about:blank"}}"#)
    drop("Target.attachToBrowserTarget on our session",
      #"{"id":1,"method":"Target.attachToBrowserTarget","sessionId":"SESS-A"}"#)
    drop("Target.sendMessageToTarget on our session",
      #"{"id":1,"method":"Target.sendMessageToTarget","sessionId":"SESS-A","params":{"sessionId":"SESS-B","message":"{}"}}"#)
    drop("Target.exposeDevToolsProtocol on our session",
      #"{"id":1,"method":"Target.exposeDevToolsProtocol","sessionId":"SESS-A","params":{"targetId":"TILE-B"}}"#)
    drop("Target.closeTarget(sibling) on our session",
      #"{"id":1,"method":"Target.closeTarget","sessionId":"SESS-A","params":{"targetId":"TILE-B"}}"#)
    drop("Target.detachFromTarget(sibling session) on our session",
      #"{"id":1,"method":"Target.detachFromTarget","sessionId":"SESS-A","params":{"sessionId":"SESS-B"}}"#)
    drop("Target.setAutoAttach non-flatten on our session",
      #"{"id":1,"method":"Target.setAutoAttach","sessionId":"SESS-A","params":{"autoAttach":true,"flatten":false}}"#)
    fwd("Target.setAutoAttach(flatten) on our session (frames, workers)",
      #"{"id":1,"method":"Target.setAutoAttach","sessionId":"SESS-A","params":{"autoAttach":true,"waitForDebuggerOnStart":true,"flatten":true}}"#)
    fwd("Target.getTargetInfo on our session", #"{"id":1,"method":"Target.getTargetInfo","sessionId":"SESS-A"}"#)
    fwd("Target.detachFromTarget(our session)",
      #"{"id":1,"method":"Target.detachFromTarget","sessionId":"SESS-A","params":{"sessionId":"SESS-A"}}"#)

    // ── C→R: browser-level allow-list + fail-closed ──
    fwd("Browser.getVersion (benign)", #"{"id":1,"method":"Browser.getVersion"}"#)
    drop("Browser.setDownloadBehavior (no-op'd, not forwarded)",
      #"{"id":1,"method":"Browser.setDownloadBehavior","params":{"behavior":"allow"}}"#)
    drop("unknown browser-level method", #"{"id":1,"method":"Fetch.enable"}"#)
    drop("C→R malformed JSON (fail closed)", "{not json")

    // ── ws-upgrade token enforcement (MANDATORY — defeats the localhost port-scan) ──
    let tok = r.token
    func tokOK(_ n: String, _ target: String, _ h: [String: String]) { check("token ok:   \(n)", r.tokenAcceptable(target, h)) }
    func tokNo(_ n: String, _ target: String, _ h: [String: String]) { check("token deny: \(n)", !r.tokenAcceptable(target, h)) }
    tokNo("absent — no header, no query (port-scanner)", "/devtools/browser", [:])
    tokOK("Authorization: Bearer <token>", "/devtools/browser", ["authorization": "Bearer \(tok)"])
    tokNo("Authorization: Bearer <wrong>", "/devtools/browser", ["authorization": "Bearer deadbeef"])
    tokNo("Authorization: Basic (not bearer)", "/devtools/browser", ["authorization": "Basic \(tok)"])
    tokNo("Authorization: Bearer (empty)", "/devtools/browser", ["authorization": "Bearer "])
    tokOK("?token=<token> query fallback", "/devtools/browser?token=\(tok)", [:])
    tokNo("?token=<wrong> query", "/devtools/browser?token=deadbeef", [:])
    // header/query precedence + parsing edges
    tokOK("non-bearer header falls through to a valid query", "/devtools/browser?token=\(tok)", ["authorization": "Basic \(tok)"])
    tokNo("wrong Bearer header does NOT consult the query", "/devtools/browser?token=\(tok)", ["authorization": "Bearer deadbeef"])
    tokOK("empty 'Bearer ' header falls through to a valid query", "/devtools/browser?token=\(tok)", ["authorization": "Bearer "])
    tokOK("valid Bearer header ignores a wrong query", "/devtools/browser?token=deadbeef", ["authorization": "Bearer \(tok)"])
    tokNo("last token= wins (good then wrong)", "/devtools/browser?token=\(tok)&token=deadbeef", [:])
    tokOK("last token= wins (wrong then good)", "/devtools/browser?token=deadbeef&token=\(tok)", [:])
    tokOK("valid token + trailing param", "/devtools/browser?token=\(tok)&x=1", [:])
    tokNo("empty ?token=", "/devtools/browser?token=", [:])
    tokNo("?token with no '='", "/devtools/browser?token", [:])
    tokNo("lookalike key ?tokenx=", "/devtools/browser?tokenx=\(tok)", [:])
    tokNo("tab (not SP) between scheme and token", "/devtools/browser", ["authorization": "Bearer\t\(tok)"])

    // ════ MULTIPLEX: N relays share ONE browser-wide pipe ════
    // Two scoped relays on one host share its pipe-id allocator. Feed each relay
    // traffic for both tiles and assert ZERO cross-leak.
    let hostIds = CdpPipeIds()
    let relayA = CdpRelay(sendToPipe: { _ in }, scopeTargetId: "TILE-A", pipeIds: hostIds)
    let relayB = CdpRelay(sendToPipe: { _ in }, scopeTargetId: "TILE-B", pipeIds: hostIds)

    // ── id rewrite: every pipe id comes from the host's one allocator ──
    let aPid1 = topId(relayA.rewriteOutgoingId(#"{"id":1,"method":"Browser.getVersion"}"#))!
    let aPid2 = topId(relayA.rewriteOutgoingId(#"{"id":1,"method":"Browser.getVersion"}"#))!
    let bPid1 = topId(relayB.rewriteOutgoingId(#"{"id":1,"method":"Browser.getVersion"}"#))!
    check("mux: same client id 1 on two relays -> DIFFERENT pipe ids (no collision)",
      Set([aPid1, aPid2, bPid1]).count == 3)
    check("mux: pipe ids start above the debug probe's small ids", aPid1 >= CdpPipeIds.first)
    check("mux: rewrite is a no-op for a message with no top-level int id",
      relayA.rewriteOutgoingId(#"{"method":"Page.enable","sessionId":"SESS-A"}"#) == #"{"method":"Page.enable","sessionId":"SESS-A"}"#)

    // ── demux round-trip + sibling isolation: a response routes ONLY to its issuer ──
    let aReqPid = topId(relayA.rewriteOutgoingId(#"{"id":42,"method":"Page.navigate","sessionId":"SESS-A","params":{}}"#))!
    let aResp = "{\"id\":\(aReqPid),\"result\":{\"frameId\":\"F\"}}"
    check("mux: sibling relayB DROPS relayA's response (no cross-leak)", relayB.demuxPipeToClient(aResp) == nil)
    check("mux: relayA demux RESTORES its own client id (42)", topId(relayA.demuxPipeToClient(aResp)) == 42)
    check("mux: a consumed response is not re-delivered (no double-send)", relayA.demuxPipeToClient(aResp) == nil)

    // ── The id-rewrite fix: a browser-level response (NO sessionId) must not fan to siblings.
    // Without the id-rewrite, filterPipeToClient forwards no-sid responses to EVERY
    // relay (see the single-relay "browser-level response (no sid)" PASS above) — i.e.
    // both clients would see both. The rewrite makes it route to exactly one. ──
    let bReqPid = topId(relayB.rewriteOutgoingId(#"{"id":99,"method":"Browser.getVersion"}"#))!
    let bResp = "{\"id\":\(bReqPid),\"result\":{\"product\":\"Chrome/144\"}}"
    check("mux: sibling relayA DROPS relayB's browser-level response", relayA.demuxPipeToClient(bResp) == nil)
    check("mux: relayB demux restores its own browser-level response (99)", topId(relayB.demuxPipeToClient(bResp)) == 99)
    check("mux: a response with an unowned pipeId is dropped", relayA.demuxPipeToClient(#"{"id":123456789,"result":{}}"#) == nil)

    // ── events (carry a method) bypass id-demux → scope filter; seed each relay's
    //    own session via its browser-level attachedToTarget, then cross-feed events ──
    _ = relayA.demuxPipeToClient(#"{"method":"Target.attachedToTarget","params":{"sessionId":"SESS-A","targetInfo":{"targetId":"TILE-A","type":"page"}}}"#)
    _ = relayB.demuxPipeToClient(#"{"method":"Target.attachedToTarget","params":{"sessionId":"SESS-B","targetInfo":{"targetId":"TILE-B","type":"page"}}}"#)
    let evtA = #"{"method":"Page.loadEventFired","sessionId":"SESS-A","params":{}}"#
    let evtB = #"{"method":"Page.loadEventFired","sessionId":"SESS-B","params":{}}"#
    check("mux: relayA forwards its own page event (SESS-A)", relayA.demuxPipeToClient(evtA) != nil)
    check("mux: relayA drops the sibling's page event (SESS-B)", relayA.demuxPipeToClient(evtB) == nil)
    check("mux: relayB forwards its own page event (SESS-B)", relayB.demuxPipeToClient(evtB) != nil)
    check("mux: relayB drops the sibling's page event (SESS-A)", relayB.demuxPipeToClient(evtA) == nil)
    check("mux: malformed pipe line fails closed (drop)", relayA.demuxPipeToClient("{not json") == nil)

    // ── pipe ids stay positive int32 however many browsers the host has made ──
    // The old scheme put the browserId in the high bits, so browser 1024 minted
    // 2147483648, which Chromium rejects. The allocator wraps inside int32 instead.
    let nearMax = CdpPipeIds(startingAt: Int(Int32.max) - 1)
    let late = CdpRelay(sendToPipe: { _ in }, scopeTargetId: "TILE-L", pipeIds: nearMax)
    let lateIds = (0..<3).map { _ in
      topId(late.rewriteOutgoingId(#"{"id":7,"method":"Browser.getVersion"}"#))!
    }
    check("pipe ids: never exceed Int32.max", lateIds.allSatisfy { $0 > 0 && $0 <= Int(Int32.max) })
    check("pipe ids: wrap back to the start of the range",
      lateIds == [Int(Int32.max) - 1, Int(Int32.max), CdpPipeIds.first])

    // ── a reconnecting client never gets its predecessor's late response ──
    // agent-browser reconnects per command, so client 2 reuses client 1's ids.
    let rc = CdpRelay(sendToPipe: { _ in }, scopeTargetId: "TILE-R")
    rc.noteClientConnected()
    let oldPid = topId(rc.rewriteOutgoingId(#"{"id":5,"method":"Runtime.evaluate","sessionId":"S"}"#))!
    rc.noteClientConnected()
    let newPid = topId(rc.rewriteOutgoingId(#"{"id":5,"method":"Runtime.evaluate","sessionId":"S"}"#))!
    check("reconnect: a departed client's late response is dropped",
      rc.demuxPipeToClient("{\"id\":\(oldPid),\"result\":{\"v\":\"old\"}}") == nil)
    check("reconnect: the new client's own response still arrives with its id",
      topId(rc.demuxPipeToClient("{\"id\":\(newPid),\"result\":{\"v\":\"new\"}}")) == 5)

    print(failures == 0
      ? "\n==== CdpRelay filter: ALL PASS ===="
      : "\n==== CdpRelay filter: \(failures) FAILURE(S) ====")
    exit(failures == 0 ? 0 : 1)
  }
}
