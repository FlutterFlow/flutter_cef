// When a session may join a cef_host that is already running. Some settings are
// fixed per process when the host is spawned (the navigation scheme allowlist and
// the TCP CDP port), so every browser on a shared host (a named profile or a
// hostGroup) gets the ones the first session asked for. Joining is refused when
// that would give the new session LESS protection than it asked for; a host that
// is stricter than the session wanted is left alone.
//
// Dependency-light (Foundation only) → unit-testable standalone with `swiftc`:
//   ./test/run_host_config_tests.sh
import Foundation

enum HostConfigPolicy {
  /// The schemes in an `allowedSchemes` list, parsed the way cef_host parses
  /// `--allowed-schemes`: comma-separated, lowercased, empties dropped. Empty
  /// means every scheme is allowed.
  static func schemes(_ list: String) -> Set<String> {
    Set(list.split(separator: ",", omittingEmptySubsequences: true).map { $0.lowercased() })
  }

  /// Why a session asking for `requestedSchemes` (and TCP CDP when
  /// `requestedTcpCdp`) can't join a host spawned with `hostSchemes` and a TCP CDP
  /// port when `hostHasTcpCdp`, or nil when it can.
  static func joinRefusal(requestedSchemes: String, requestedTcpCdp: Bool,
                          hostSchemes: String, hostHasTcpCdp: Bool) -> String? {
    let want = schemes(requestedSchemes)
    let have = schemes(hostSchemes)
    if !want.isEmpty && (have.isEmpty || !have.isSubset(of: want)) {
      let allowed = have.isEmpty ? "every scheme" : have.sorted().joined(separator: ",")
      return "the running cef_host for this profile allows \(allowed), "
        + "more than this session's allowedSchemes (\(want.sorted().joined(separator: ",")))"
    }
    if hostHasTcpCdp && !requestedTcpCdp {
      return "the running cef_host for this profile has an open CDP port, "
        + "which this session didn't ask for (enableCdp)"
    }
    return nil
  }

  /// Whether `profile` is a name a consumer may use. Names starting with "~" are
  /// reserved for the plugin's own keys ("~ephemeral~…", "~group~…"), and a named
  /// profile using one would join another session's throwaway host.
  static func isValidProfileName(_ profile: String) -> Bool {
    !profile.hasPrefix("~")
  }
}
