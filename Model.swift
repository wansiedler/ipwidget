import AppKit
import Network
import CoreLocation
import CoreWLAN
import UserNotifications

// MARK: - Data types

struct IPInfo {
    let ip: String
    let city: String?
    let region: String?
    let countryCode: String?
    let lat: Double?
    let lon: Double?
    let isp: String?

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var flag: String { flagEmoji(countryCode) }

    var place: String {
        [city, region, countryCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

func flagEmoji(_ countryCode: String?) -> String {
    guard let countryCode, countryCode.count == 2 else { return "" }
    return countryCode.uppercased().unicodeScalars.reduce(into: "") { acc, s in
        if let scalar = UnicodeScalar(0x1F1E6 + s.value - 65) { acc.unicodeScalars.append(scalar) }
    }
}

/// Primary provider: ip-api.com — 45 req/min, no monthly cap, HTTP only (ATS exception in Info.plist).
struct IPAPIResponse: Decodable {
    let status: String
    let query: String?
    let city: String?
    let regionName: String?
    let countryCode: String?
    let lat: Double?
    let lon: Double?
    let isp: String?

    var info: IPInfo? {
        guard status == "success", let query else { return nil }
        return IPInfo(ip: query, city: city, region: regionName, countryCode: countryCode, lat: lat, lon: lon, isp: isp)
    }
}

/// Fallback provider: ipinfo.io — ~50k req/month.
struct IPInfoIOResponse: Decodable {
    let ip: String
    let city: String?
    let region: String?
    let country: String?
    let loc: String?
    let org: String?

    var info: IPInfo {
        var lat: Double?, lon: Double?
        if let loc, let comma = loc.firstIndex(of: ",") {
            lat = Double(loc[..<comma]); lon = Double(loc[loc.index(after: comma)...])
        }
        var isp = org
        if let org, org.hasPrefix("AS"), let space = org.firstIndex(of: " ") {
            isp = String(org[org.index(after: space)...])
        }
        return IPInfo(ip: ip, city: city, region: region, countryCode: country, lat: lat, lon: lon, isp: isp)
    }
}

/// http://edns.ip-api.com/json — reports the resolver that answered our DNS query.
struct EDNSResponse: Decodable {
    struct Entry: Decodable { let geo: String; let ip: String }
    let dns: Entry
}

struct DNSResolver {
    let ip: String
    let geo: String            // "Germany - Deutsche Telekom AG"
    var org: String { geo.components(separatedBy: " - ").dropFirst().joined(separator: " - ") }
    var country: String { geo.components(separatedBy: " - ").first ?? "" }
}

struct HistoryEntry: Codable {
    let ip: String
    let isp: String
    let date: Date
}

struct LocalNet {
    let interface: String      // en0, utun13
    let kind: String           // Wi‑Fi, Ethernet, utun13
    let ssid: String?
    let ipv4: String?
    let isTunnel: Bool
    var gateway: String?

    var text: String {
        var parts = [ssid.map { kind + " " + $0 } ?? kind]
        if let ipv4 { parts.append(Settings.maskIP ? maskIP(ipv4) : ipv4) }
        return parts.joined(separator: " · ")
    }
}

enum StatusLevel {
    case unknown, ok, warn, bad
    var color: NSColor {
        switch self {
        case .unknown: return .systemGray
        case .ok: return .systemGreen
        case .warn: return .systemYellow
        case .bad: return .systemRed
        }
    }
}

// MARK: - Settings

enum WidgetSize: Int, CaseIterable {
    case compact, normal, large
    var title: String { ["Компактный", "Обычный", "Большой"][rawValue] }
    var width: CGFloat { [300, 340, 420][rawValue] }
    var mapHeight: CGFloat { [0, 150, 220][rawValue] }
    var ipFontSize: CGFloat { [20, 26, 30][rawValue] }
}

enum MenuBarStyle: Int, CaseIterable {
    case ipFlag, flagOnly, hidden
    var title: String { ["Флаг + IP", "Только флаг", "Скрыть"][rawValue] }
}

enum Settings {
    private static let d = UserDefaults.standard

    static let intervals: [(title: String, seconds: TimeInterval)] = [
        ("15 секунд", 15), ("30 секунд", 30), ("1 минута", 60), ("5 минут", 300), ("15 минут", 900),
    ]
    static let zooms: [(title: String, meters: Double)] = [
        ("Город (40 км)", 40_000), ("Регион (200 км)", 200_000), ("Страна (1500 км)", 1_500_000), ("Скрыть карту", 0),
    ]
    static let materials: [(title: String, material: NSVisualEffectView.Material)] = [
        ("Тёмное стекло (HUD)", .hudWindow), ("Светлое стекло (Popover)", .popover),
        ("Sidebar", .sidebar), ("Плотное (Titlebar)", .titlebar),
    ]
    static let flags: [(key: String, title: String, def: Bool)] = [
        ("showISP", "Провайдер", true),
        ("showHost", "Hostname (reverse DNS)", true),
        ("showIPv6", "IPv6", true),
        ("showDNS", "DNS-резолвер / утечка", true),
        ("showSpeed", "Скорость сети", true),
        ("showLocal", "Локальная сеть", true),
        ("showPing", "Пинг", true),
    ]
    static let pingPresets: [(title: String, target: String)] = [
        ("Cloudflare 1.1.1.1", "1.1.1.1"), ("Google 8.8.8.8", "8.8.8.8"), ("Quad9 9.9.9.9", "9.9.9.9"), ("Шлюз (роутер)", "gw"),
    ]

    static func flag(_ key: String) -> Bool {
        if let v = d.object(forKey: key) as? Bool { return v }
        return flags.first { $0.key == key }?.def ?? false
    }
    static func toggle(_ key: String) { d.set(!flag(key), forKey: key) }

    private static func double(_ key: String, _ def: Double) -> Double {
        d.object(forKey: key) == nil ? def : d.double(forKey: key)
    }
    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    static var interval: TimeInterval { get { double("interval", 30) } set { d.set(newValue, forKey: "interval") } }
    static var mapMeters: Double { get { double("mapMeters", 40_000) } set { d.set(newValue, forKey: "mapMeters") } }
    static var size: WidgetSize {
        get { WidgetSize(rawValue: Int(double("size", 1))) ?? .normal }
        set { d.set(newValue.rawValue, forKey: "size") }
    }
    static var material: Int { get { Int(double("material", 0)) } set { d.set(newValue, forKey: "material") } }
    static var forceDark: Bool { get { bool("forceDark", false) } set { d.set(newValue, forKey: "forceDark") } }
    static var notify: Bool { get { bool("notify", true) } set { d.set(newValue, forKey: "notify") } }
    static var menuBar: MenuBarStyle {
        get { MenuBarStyle(rawValue: Int(double("menuBar", 0))) ?? .ipFlag }
        set { d.set(newValue.rawValue, forKey: "menuBar") }
    }
    static var allScreens: Bool { get { bool("allScreens", false) } set { d.set(newValue, forKey: "allScreens") } }
    static var hotkey: Bool { get { bool("hotkey", true) } set { d.set(newValue, forKey: "hotkey") } }
    static var maskIP: Bool { get { bool("maskIP", false) } set { d.set(newValue, forKey: "maskIP") } }
    static var hidden: Bool { get { bool("hidden", false) } set { d.set(newValue, forKey: "hidden") } }
    static var homeISP: String? { get { d.string(forKey: "homeISP") } set { d.set(newValue, forKey: "homeISP") } }

    static var pingTargets: [String] {
        get { d.stringArray(forKey: "pingTargets") ?? ["1.1.1.1", "8.8.8.8"] }
        set { d.set(newValue, forKey: "pingTargets") }
    }

    static var history: [HistoryEntry] {
        get {
            guard let data = d.data(forKey: "history") else { return [] }
            return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(Array(newValue.suffix(500))), forKey: "history") }
    }

    /// Injected by build.sh so "Rebuild from source" knows where the repo is.
    static var repoPath: String? { Bundle.main.infoDictionary?["IPWRepoPath"] as? String }
}

// MARK: - Formatting helpers

func maskIP(_ ip: String) -> String {
    if ip.contains(":") {
        return ip.split(separator: ":", omittingEmptySubsequences: false).prefix(2).joined(separator: ":") + ":••••"
    }
    let parts = ip.split(separator: ".")
    guard parts.count == 4 else { return "•••" }
    return "\(parts[0]).\(parts[1]).•••.•••"
}

func formatRate(_ bytesPerSec: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var v = bytesPerSec, i = 0
    while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
    return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
}

func timeString(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

// MARK: - Model

final class WidgetModel {
    static let shared = WidgetModel()

    private(set) var info: IPInfo?
    private(set) var host: String?
    private(set) var ipv6: String?
    private(set) var local: LocalNet?
    private(set) var vpnNames: [String] = []
    private(set) var pings: [(target: String, ms: Int?)] = []
    private(set) var dns: DNSResolver?
    private(set) var downRate = 0.0
    private(set) var upRate = 0.0
    private(set) var rateHistory: [Double] = []          // last 60 download samples, bytes/s
    private(set) var speedTestText: String?
    private(set) var speedTestRunning = false
    private(set) var isRefreshing = false
    private(set) var offline = false
    private(set) var lastChangeAt: Date?
    private(set) var lastUpdate: Date?

    private var observers: [UUID: () -> Void] = [:]
    private let monitor = NWPathMonitor()
    private var currentPath: NWPath?
    private var refreshTimer: Timer?
    private var rateTimer: Timer?
    private var lastCounters: (iface: String, rx: UInt64, tx: UInt64, at: Date)?

    // MARK: Observation

    @discardableResult
    func addObserver(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    private func changed() { observers.values.forEach { $0() } }

    // MARK: Derived state

    /// VPN is on when the default route goes through a tunnel, or the ISP differs from the remembered home ISP.
    var vpnActive: Bool {
        if local?.isTunnel == true { return true }
        if let home = Settings.homeISP, let isp = info?.isp { return isp != home }
        return false
    }

    var badge: (text: String, color: NSColor)? {
        if vpnActive { return ("VPN", .systemGreen) }
        if Settings.homeISP != nil { return ("HOME", .systemGray) }
        return nil
    }

    var dnsLeak: Bool {
        guard vpnActive, let dns, let isp = info?.isp?.lowercased() else { return false }
        let org = dns.org.lowercased()
        return !org.isEmpty && !isp.isEmpty && !org.contains(isp) && !isp.contains(org)
    }

    var worstPing: (target: String, ms: Int)? {
        pings.compactMap { p in p.ms.map { (p.target, $0) } }.max { $0.1 < $1.1 }
    }

    var status: StatusLevel {
        if offline || dnsLeak { return .bad }
        if let w = worstPing, w.ms > 150 { return .bad }
        if let t = lastChangeAt, Date().timeIntervalSince(t) < 60 { return .warn }
        return info == nil ? .unknown : .ok
    }

    var ipText: String {
        guard let ip = info?.ip else { return "…" }
        return Settings.maskIP ? maskIP(ip) : ip
    }

    var ipv6Text: String {
        guard let v6 = ipv6 else { return "IPv6 —" }
        return "IPv6 " + (Settings.maskIP ? maskIP(v6) : v6)
    }

    var ispText: String {
        var parts: [String] = []
        if Settings.flag("showISP"), let isp = info?.isp, !isp.isEmpty { parts.append(isp) }
        if Settings.flag("showHost"), let host { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    var dnsText: String {
        guard let dns else { return "DNS …" }
        return (dnsLeak ? "DNS LEAK: " : "DNS: ") + dns.org + (dns.country.isEmpty ? "" : ", " + dns.country)
    }

    var pingText: String { worstPing.map { "\($0.ms) ms" } ?? (pings.isEmpty ? "" : "— ms") }

    var pingDetails: String {
        pings.map { "\(pingName($0.target)) \($0.ms.map { "\($0) ms" } ?? "—")" }.joined(separator: " · ")
    }

    func pingName(_ target: String) -> String { target == "gw" ? (local?.gateway ?? "шлюз") : target }

    var speedText: String {
        if let t = speedTestText { return t }
        if speedTestRunning { return "Тест скорости…" }
        return "↓ \(formatRate(downRate))   ↑ \(formatRate(upRate))"
    }

    var timeText: String {
        let t = lastUpdate.map(timeString) ?? ""
        return offline ? "offline · " + timeString() : t
    }

    var localText: String {
        var s = local?.text ?? ""
        if !vpnNames.isEmpty { s = vpnNames.joined(separator: ", ") + (s.isEmpty ? "" : " · " + s) }
        return s
    }

    // MARK: Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentPath = path
                self.updateLocal()
                self.changed()
                self.refreshGateway()
                self.refreshVPNNames()
                if path.status == .satisfied {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
                } else {
                    self.offline = true
                    self.changed()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ipwidget.netmon"))
        restartTimer()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sampleRates() }
        refresh()
    }

    func restartTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Settings.interval, repeats: true) { [weak self] _ in self?.refresh() }
        refreshTimer?.tolerance = Settings.interval * 0.1
    }

    // MARK: Refresh

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        changed()

        fetchPrimary { [weak self] info in
            if let info { self?.finish(info); return }
            self?.fetchFallback { info in self?.finish(info) }
        }
        if Settings.flag("showIPv6") { fetchIPv6() }
        if Settings.flag("showPing") { measurePings() }
        if Settings.flag("showDNS") { fetchDNS() }
    }

    private func finish(_ new: IPInfo?) {
        isRefreshing = false
        guard let new else {
            offline = true
            changed()
            return
        }
        offline = false
        lastUpdate = Date()
        let old = info
        let changedIP = old != nil && old?.ip != new.ip
        info = new

        if old == nil || changedIP {
            if Settings.history.last?.ip != new.ip {
                Settings.history = Settings.history + [HistoryEntry(ip: new.ip, isp: new.isp ?? "", date: Date())]
            }
            host = nil
            if Settings.flag("showHost") { reverseDNS(new.ip) }
        }
        if changedIP, let old {
            lastChangeAt = Date()
            notifyChange(old: old, new: new)
            DispatchQueue.main.asyncAfter(deadline: .now() + 61) { [weak self] in self?.changed() }
        }
        changed()
    }

    private func fetchPrimary(_ done: @escaping (IPInfo?) -> Void) {
        let url = URL(string: "http://ip-api.com/json/?fields=status,message,countryCode,regionName,city,lat,lon,isp,query")!
        get(url) { data in done(data.flatMap { try? JSONDecoder().decode(IPAPIResponse.self, from: $0) }?.info) }
    }

    private func fetchFallback(_ done: @escaping (IPInfo?) -> Void) {
        get(URL(string: "https://ipinfo.io/json")!) { data in
            done(data.flatMap { try? JSONDecoder().decode(IPInfoIOResponse.self, from: $0) }?.info)
        }
    }

    private func fetchIPv6() {
        get(URL(string: "https://api6.ipify.org?format=json")!) { [weak self] data in
            let v6 = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["ip"]
            self?.ipv6 = v6.flatMap { $0.contains(":") ? $0 : nil }
            self?.changed()
        }
    }

    private func fetchDNS() {
        // The endpoint 302-redirects to a unique subdomain so the active resolver has to do a fresh lookup.
        get(URL(string: "http://edns.ip-api.com/json")!) { [weak self] data in
            if let e = data.flatMap({ try? JSONDecoder().decode(EDNSResponse.self, from: $0) }) {
                self?.dns = DNSResolver(ip: e.dns.ip, geo: e.dns.geo)
                self?.changed()
            }
        }
    }

    private func get(_ url: URL, timeout: TimeInterval = 8, _ done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    // MARK: Latency (TCP connect time; ICMP needs privileges)

    private func measurePings() {
        let targets = Settings.pingTargets
        var results: [(String, Int?)] = targets.map { ($0, nil) }
        let group = DispatchGroup()
        for (i, t) in targets.enumerated() {
            let host = t == "gw" ? local?.gateway : t
            guard let host else { continue }
            group.enter()
            tcpLatency(host: host, port: t == "gw" ? 80 : 443) { ms in results[i].1 = ms; group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            self?.pings = results
            self?.changed()
        }
    }

    private func tcpLatency(host: String, port: UInt16, _ done: @escaping (Int?) -> Void) {
        let q = DispatchQueue(label: "ipwidget.ping")
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let start = Date()
        var finished = false
        let report: (Int?) -> Void = { ms in DispatchQueue.main.async { done(ms) } }
        conn.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                finished = true
                report(Int(Date().timeIntervalSince(start) * 1000))
                conn.cancel()
            case .failed, .cancelled:
                finished = true
                report(nil)
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + 3) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            report(nil)
        }
    }

    // MARK: Reverse DNS

    private func reverseDNS(_ ip: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            var res: UnsafeMutablePointer<addrinfo>?
            var name: String?
            if getaddrinfo(ip, nil, &hints, &res) == 0, let ai = res {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 {
                    let n = String(cString: host)
                    if !n.hasSuffix(".in-addr.arpa") && !n.hasSuffix(".ip6.arpa") && n != ip { name = n }
                }
                freeaddrinfo(res)
            }
            DispatchQueue.main.async {
                guard let self, self.info?.ip == ip else { return }
                self.host = name
                self.changed()
            }
        }
    }

    // MARK: Local network

    private func updateLocal() {
        guard let path = currentPath, let iface = path.availableInterfaces.first else { local = nil; return }
        var kind: String
        switch iface.type {
        case .wifi: kind = "Wi‑Fi"
        case .wiredEthernet: kind = "Ethernet"
        case .cellular: kind = "Cellular"
        case .loopback: kind = "lo"
        default: kind = iface.name
        }
        let tunnel = iface.type == .other && (iface.name.hasPrefix("utun") || iface.name.hasPrefix("ipsec") || iface.name.hasPrefix("ppp"))
        var ssid: String?
        if iface.type == .wifi, let s = CWWiFiClient.shared().interface(withName: iface.name)?.ssid(), !s.isEmpty { ssid = s }
        local = LocalNet(interface: iface.name, kind: kind, ssid: ssid, ipv4: ipv4Address(of: iface.name),
                         isTunnel: tunnel, gateway: local?.interface == iface.name ? local?.gateway : nil)
    }

    private func ipv4Address(of name: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: ifa.ifa_name) == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    private func refreshGateway() {
        run("/sbin/route", ["-n", "get", "default"]) { [weak self] out in
            let gw = out.split(separator: "\n").first { $0.contains("gateway:") }?
                .split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
            self?.local?.gateway = gw
            self?.changed()
        }
    }

    private func refreshVPNNames() {
        run("/usr/sbin/scutil", ["--nc", "list"]) { [weak self] out in
            let names = out.split(separator: "\n").filter { $0.contains("(Connected)") }.compactMap { line -> String? in
                guard let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
                return String(line[line.index(after: a)..<b])
            }
            self?.vpnNames = names
            self?.changed()
        }
    }

    private func run(_ path: String, _ args: [String], _ done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var out = ""
            if (try? p.run()) != nil {
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    // MARK: Throughput (interface byte counters, 1 s sampling)

    private func sampleRates() {
        guard let iface = local?.interface, let (rx, tx) = interfaceBytes(iface) else { return }
        let now = Date()
        defer { lastCounters = (iface, rx, tx, now) }
        guard let last = lastCounters, last.iface == iface else { return }
        let dt = now.timeIntervalSince(last.at)
        guard dt > 0 else { return }
        // if_data counters are 32-bit and wrap at 4 GiB
        let drx = rx >= last.rx ? rx - last.rx : rx &+ (UInt64(UInt32.max) - last.rx)
        let dtx = tx >= last.tx ? tx - last.tx : tx &+ (UInt64(UInt32.max) - last.tx)
        downRate = Double(drx) / dt
        upRate = Double(dtx) / dt
        rateHistory.append(downRate)
        if rateHistory.count > 60 { rateHistory.removeFirst(rateHistory.count - 60) }
        changed()
    }

    private func interfaceBytes(_ name: String) -> (UInt64, UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: ifa.ifa_name) == name, let raw = ifa.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            return (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
        }
        return nil
    }

    // MARK: Speed test (Cloudflare)

    func runSpeedTest() {
        guard !speedTestRunning else { return }
        speedTestRunning = true
        speedTestText = nil
        changed()
        let downURL = URL(string: "https://speed.cloudflare.com/__down?bytes=20000000")!
        let start = Date()
        URLSession.shared.dataTask(with: downURL) { [weak self] data, _, _ in
            let dt = Date().timeIntervalSince(start)
            let downMbps = data.map { Double($0.count) * 8 / dt / 1_000_000 }
            var up = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
            up.httpMethod = "POST"
            let payload = Data(count: 8_000_000)
            let upStart = Date()
            URLSession.shared.uploadTask(with: up, from: payload) { _, resp, _ in
                let udt = Date().timeIntervalSince(upStart)
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                let upMbps = ok ? Double(payload.count) * 8 / udt / 1_000_000 : nil
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.speedTestRunning = false
                    let d = downMbps.map { String(format: "%.0f", $0) } ?? "—"
                    let u = upMbps.map { String(format: "%.0f", $0) } ?? "—"
                    self.speedTestText = "Тест: ↓ \(d) ↑ \(u) Mbps"
                    self.changed()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                        self?.speedTestText = nil
                        self?.changed()
                    }
                }
            }.resume()
        }.resume()
    }

    // MARK: History export

    func exportHistory() -> URL? {
        let df = ISO8601DateFormatter()
        var csv = "date,ip,isp\n"
        for e in Settings.history {
            let isp = e.isp.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\(df.string(from: e.date)),\(e.ip),\"\(isp)\"\n"
        }
        let name = DateFormatter()
        name.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/ipwidget-history-\(name.string(from: Date())).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Self-update

    /// git pull (if a remote exists) + build.sh, detached so it survives our own restart.
    func rebuildFromSource() -> Bool {
        guard let repo = Settings.repoPath, FileManager.default.fileExists(atPath: repo + "/build.sh") else { return false }
        let script = "cd \(shellQuote(repo)) && { git remote | grep -q . && git pull --ff-only || true; } && ./build.sh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "nohup /bin/zsh -lc \(shellQuote(script)) >/tmp/ipwidget-update.log 2>&1 &"]
        return (try? p.run()) != nil
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Notifications

    func requestNotificationAuth() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            center.getNotificationSettings { st in
                NSLog("notifications: granted=\(granted) status=\(st.authorizationStatus.rawValue) error=\(error?.localizedDescription ?? "-")")
            }
        }
    }

    private func notifyChange(old: IPInfo, new: IPInfo) {
        guard Settings.notify else { return }
        let c = UNMutableNotificationContent()
        c.title = "IP изменился"
        c.body = "\(old.ip) → \(new.ip)\n\(new.flag) \(new.place) · \(new.isp ?? "")"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            if let err { NSLog("notification failed: \(err.localizedDescription)") }
        }
    }

    func testNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                if st.authorizationStatus == .denied {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    return
                }
                if st.authorizationStatus == .notDetermined { self.requestNotificationAuth() }
                let c = UNMutableNotificationContent()
                c.title = "IP Widget"
                c.body = "Уведомления работают. Текущий IP: \(self.info?.ip ?? "—")"
                c.sound = .default
                center.add(UNNotificationRequest(identifier: "test", content: c, trigger: nil)) { err in
                    if let err { NSLog("test notification failed: \(err.localizedDescription)") }
                }
            }
        }
    }
}
