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

    /// DNS servers the system actually queries: those of the primary service (the interface that owns
    /// the default route), falling back to the global list.
    static func primaryDNSServers() -> [String] {
        guard let s = store() else { return [] }
        if let id = dict(s, "State:/Network/Global/IPv4")?["PrimaryService"] as? String,
           let d = dict(s, "State:/Network/Service/\(id)/DNS"),
           let a = d["ServerAddresses"] as? [String], !a.isEmpty { return a }
        return (dict(s, "State:/Network/Global/DNS")?["ServerAddresses"] as? [String]) ?? []
    }

    /// Router of the physical (en*) interface, i.e. the LAN gateway even while a VPN owns the default route.
    static func lanRouter() -> String? {
        guard let s = store(),
              let keys = SCDynamicStoreCopyKeyList(s, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return nil }
        for key in keys {
            guard let d = dict(s, key), let name = d["InterfaceName"] as? String, name.hasPrefix("en"),
                  let r = d["Router"] as? String else { continue }
            return r
        }
        return nil
    }

    /// Connected VPN / IPSec / PPP services: user-visible name and the utun/ppp interface they own.
    /// Tunnels raised without a service record (e.g. Amnezia/AWG) are not listed here.
    static func connectedVPNs() -> [(name: String, interface: String?)] {
        guard let s = store(),
              let keys = SCDynamicStoreCopyKeyList(s, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return [] }
        var out: [(name: String, interface: String?)] = []
        for key in keys {
            let parts = key.split(separator: "/")          // State:, Network, Service, <id>, IPv4
            guard parts.count >= 5 else { continue }
            let id = String(parts[3])
            guard let iface = dict(s, "Setup:/Network/Service/\(id)/Interface"),
                  let type = iface["Type"] as? String, ["VPN", "IPSec", "PPP"].contains(type) else { continue }
            let setup = dict(s, "Setup:/Network/Service/\(id)")
            let state = dict(s, key)
            out.append((setup?["UserDefinedName"] as? String ?? type, state?["InterfaceName"] as? String))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func connectedVPNNames() -> [String] { connectedVPNs().map(\.name) }
}
