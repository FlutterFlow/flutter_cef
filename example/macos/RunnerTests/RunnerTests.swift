import Cocoa
import FlutterMacOS
import XCTest

@testable import flutter_cef_macos

// Unit test for the macOS plugin's method-channel dispatcher. Real end-to-end
// behavior (rendering, JS channels, CDP) is covered by the example probes +
// test/run_channel_integration.sh against a real cef_host; this only checks the
// dispatcher's default path, which needs no live host.
class RunnerTests: XCTestCase {
  func testUnknownVerbReturnsNotImplemented() {
    let plugin = FlutterCefPlugin()
    let call = FlutterMethodCall(methodName: "definitelyNotARealVerb", arguments: [])
    let resultExpectation = expectation(description: "result block must be called")
    plugin.handle(call) { result in
      XCTAssertTrue(
        result is FlutterMethodNotImplemented,
        "an unknown verb must return FlutterMethodNotImplemented")
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}
