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

    print(failures == 0
      ? "\n==== CdpRelay filter: ALL PASS ===="
      : "\n==== CdpRelay filter: \(failures) FAILURE(S) ====")
    exit(failures == 0 ? 0 : 1)
  }
}
