// Standalone unit tests for HostConfigPolicy: which sessions may join a running
// cef_host whose process-wide config came from an earlier session.
//
//   ./test/run_host_config_tests.sh
import Foundation

@main
enum HostConfigPolicyTests {
  static var failures = 0
  static func check(_ name: String, _ cond: Bool) {
    print((cond ? "  PASS  " : "  FAIL  ") + name)
    if !cond { failures += 1 }
  }

  static func main() {
    func joins(_ want: String, cdp: Bool = false, host: String, hostCdp: Bool = false) -> Bool {
      HostConfigPolicy.joinRefusal(requestedSchemes: want, requestedTcpCdp: cdp,
                                   hostSchemes: host, hostHasTcpCdp: hostCdp) == nil
    }
    check("same config joins", joins("https,data", host: "https,data"))
    check("scheme lists compare as sets, case-insensitively", joins("HTTPS,data", host: "data,https"))
    check("a session with no allowlist joins any host", joins("", host: "https"))
    check("a host stricter than asked for is accepted", joins("https,http", host: "https"))
    check("an allowlisted session can't join an allow-everything host", !joins("https", host: ""))
    check("an allowlisted session can't join a broader host", !joins("https", host: "https,file"))
    check("a session that didn't ask for CDP can't join a host with a CDP port",
          !joins("", host: "", hostCdp: true))
    check("a session that asked for CDP joins a host with a CDP port",
          joins("", cdp: true, host: "", hostCdp: true))
    check("a session that asked for CDP joins a host without one", joins("", cdp: true, host: ""))
    check("the refusal names what the host allows",
          HostConfigPolicy.joinRefusal(requestedSchemes: "https", requestedTcpCdp: false,
                                       hostSchemes: "file,https", hostHasTcpCdp: false)?
            .contains("file,https") == true)

    check("an ordinary profile name is valid", HostConfigPolicy.isValidProfileName("work"))
    check("a reserved group key is not", !HostConfigPolicy.isValidProfileName("~group~x"))
    check("a reserved ephemeral key is not", !HostConfigPolicy.isValidProfileName("~ephemeral~s1"))

    print(failures == 0
      ? "\nALL HostConfigPolicy TESTS PASSED"
      : "\n\(failures) HostConfigPolicy TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
  }
}
