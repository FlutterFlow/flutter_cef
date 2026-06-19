// Standalone unit tests for the CEF-2b per-tile CDP isolation filter — THE security
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
    fwd("Target.setAutoAttach flatten", #"{"id":1,"method":"Target.setAutoAttach","params":{"flatten":true}}"#)

    // ── C→R: page-scoped driving on OUR session is allowed; foreign session denied ──
    fwd("Page.navigate on our session", #"{"id":1,"method":"Page.navigate","sessionId":"SESS-A","params":{"url":"https://x"}}"#)
    fwd("Runtime.evaluate on our session", #"{"id":1,"method":"Runtime.evaluate","sessionId":"SESS-A","params":{}}"#)
    drop("command on foreign session", #"{"id":1,"method":"Runtime.evaluate","sessionId":"SESS-B","params":{}}"#)

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
    // header/query precedence + parsing edges (audit-driven)
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

    // ════ CEF-2b MULTIPLEX (P2-step2): N relays share ONE browser-wide pipe ════
    // Two scoped relays with distinct wire ids (browserIds 1 & 2). This is PLAN
    // Test I: feed each relay traffic for both tiles and assert ZERO cross-leak.
    let relayA = CdpRelay(sendToPipe: { _ in }, scopeTargetId: "TILE-A", relayId: 1)
    let relayB = CdpRelay(sendToPipe: { _ in }, scopeTargetId: "TILE-B", relayId: 2)

    // ── id-rewrite namespacing: pipeId = (relayId<<21)|localSeq, globally unique ──
    let aPid1 = topId(relayA.rewriteOutgoingId(#"{"id":1,"method":"Browser.getVersion"}"#))!
    let aPid2 = topId(relayA.rewriteOutgoingId(#"{"id":1,"method":"Browser.getVersion"}"#))!
    let bPid1 = topId(relayB.rewriteOutgoingId(#"{"id":1,"method":"Browser.getVersion"}"#))!
    check("mux: relayA pipeId is namespaced to relayId 1 (high bits)", aPid1 >> 21 == 1)
    check("mux: relayB pipeId is namespaced to relayId 2 (high bits)", bPid1 >> 21 == 2)
    check("mux: same client id 1 on two relays -> DIFFERENT pipe ids (no collision)", aPid1 != bPid1)
    check("mux: per-relay local seq advances", aPid2 == aPid1 + 1)
    check("mux: low 21 bits are the local sequence (first == 0)", (aPid1 & 0x1FFFFF) == 0)
    check("mux: rewrite is a no-op for a message with no top-level int id",
      relayA.rewriteOutgoingId(#"{"method":"Page.enable","sessionId":"SESS-A"}"#) == #"{"method":"Page.enable","sessionId":"SESS-A"}"#)

    // ── demux round-trip + sibling isolation: a response routes ONLY to its issuer ──
    let aReqPid = topId(relayA.rewriteOutgoingId(#"{"id":42,"method":"Page.navigate","sessionId":"SESS-A","params":{}}"#))!
    let aResp = "{\"id\":\(aReqPid),\"result\":{\"frameId\":\"F\"}}"
    check("mux: sibling relayB DROPS relayA's response (no cross-leak)", relayB.demuxPipeToClient(aResp) == nil)
    check("mux: relayA demux RESTORES its own client id (42)", topId(relayA.demuxPipeToClient(aResp)) == 42)
    check("mux: a consumed response is not re-delivered (no double-send)", relayA.demuxPipeToClient(aResp) == nil)

    // ── THE §3.2 fix: a browser-level response (NO sessionId) must not fan to siblings.
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

    print(failures == 0
      ? "\n==== CdpRelay filter: ALL PASS ===="
      : "\n==== CdpRelay filter: \(failures) FAILURE(S) ====")
    exit(failures == 0 ? 0 : 1)
  }
}
