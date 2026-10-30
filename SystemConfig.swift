import Foundation
import SystemConfiguration

/// Read-only access to the SystemConfiguration dynamic store. Works inside the App Sandbox,
/// unlike spawning `route` / `scutil`.
enum SystemConfig {
    private static func store() -> SCDynamicStore? {
        SCDynamicStoreCreate(nil, "IPWidget" as CFString, nil, nil)
    }

    private static func dict(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// Default IPv4 router and the interface it is reached through.
    static func defaultRoute() -> (router: String?, interface: String?) {
        guard let s = store(), let g = dict(s, "State:/Network/Global/IPv4") else { return (nil, nil) }
        return (g["Router"] as? String, g["PrimaryInterface"] as? String)
    }

    /// User-visible names of VPN / IPSec / PPP services that currently have an IPv4 state (= connected).
    static func connectedVPNNames() -> [String] {
        guard let s = store(),
              let keys = SCDynamicStoreCopyKeyList(s, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return [] }
        var names: [String] = []
        for key in keys {
            let parts = key.split(separator: "/")          // State:, Network, Service, <id>, IPv4
            guard parts.count >= 5 else { continue }
            let id = String(parts[3])
            guard let iface = dict(s, "Setup:/Network/Service/\(id)/Interface"),
                  let type = iface["Type"] as? String, ["VPN", "IPSec", "PPP"].contains(type) else { continue }
            let setup = dict(s, "Setup:/Network/Service/\(id)")
            names.append(setup?["UserDefinedName"] as? String ?? type)
        }
        return names.sorted()
    }
}
