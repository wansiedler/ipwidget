import AppKit
import MapKit
import Network
import CoreWLAN
import UserNotifications

// MARK: - Model

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

    var flag: String {
        guard let countryCode, countryCode.count == 2 else { return "" }
        return countryCode.uppercased().unicodeScalars.reduce(into: "") { acc, s in
            if let scalar = UnicodeScalar(0x1F1E6 + s.value - 65) { acc.unicodeScalars.append(scalar) }
        }
    }

    var place: String {
        [city, region, countryCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
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
        return IPInfo(ip: query, city: city, region: regionName, countryCode: countryCode,
                      lat: lat, lon: lon, isp: isp)
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
            isp = String(org[org.index(after: space)...])   // "AS3320 Deutsche Telekom AG" -> "Deutsche Telekom AG"
        }
        return IPInfo(ip: ip, city: city, region: region, countryCode: country, lat: lat, lon: lon, isp: isp)
    }
}

struct HistoryEntry: Codable {
    let ip: String
    let isp: String
    let date: Date
}

// MARK: - Settings

enum WidgetSize: Int, CaseIterable {
    case compact, normal, large
    var title: String { ["Компактный", "Обычный", "Большой"][rawValue] }
    var width: CGFloat { [300, 340, 420][rawValue] }
    var mapHeight: CGFloat { [0, 150, 220][rawValue] }
    var ipFontSize: CGFloat { [20, 26, 30][rawValue] }
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
    /// Boolean flags shown in the "Показывать" submenu: (key, title, default)
    static let flags: [(key: String, title: String, def: Bool)] = [
        ("showISP", "Провайдер", true),
        ("showHost", "Hostname (reverse DNS)", true),
        ("showIPv6", "IPv6", true),
        ("showLocal", "Локальная сеть", true),
        ("showPing", "Пинг", true),
    ]

    static func flag(_ key: String) -> Bool {
        if let v = d.object(forKey: key) as? Bool { return v }
        return flags.first { $0.key == key }?.def ?? false
    }
    static func toggle(_ key: String) { d.set(!flag(key), forKey: key) }

    private static func double(_ key: String, _ def: Double) -> Double {
        d.object(forKey: key) == nil ? def : d.double(forKey: key)
    }

    static var interval: TimeInterval {
        get { double("interval", 30) }
        set { d.set(newValue, forKey: "interval") }
    }
    static var mapMeters: Double {
        get { double("mapMeters", 40_000) }
        set { d.set(newValue, forKey: "mapMeters") }
    }
    static var size: WidgetSize {
        get { WidgetSize(rawValue: Int(double("size", 1))) ?? .normal }
        set { d.set(newValue.rawValue, forKey: "size") }
    }
    static var material: Int {
        get { Int(double("material", 0)) }
        set { d.set(newValue, forKey: "material") }
    }
    static var forceDark: Bool {
        get { d.bool(forKey: "forceDark") }
        set { d.set(newValue, forKey: "forceDark") }
    }
    static var notify: Bool {
        get { d.object(forKey: "notify") == nil ? true : d.bool(forKey: "notify") }
        set { d.set(newValue, forKey: "notify") }
    }
    static var homeISP: String? {
        get { d.string(forKey: "homeISP") }
        set { d.set(newValue, forKey: "homeISP") }
    }
    static var history: [HistoryEntry] {
        get {
            guard let data = d.data(forKey: "history") else { return [] }
            return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        }
        set {
            let trimmed = Array(newValue.suffix(10))
            d.set(try? JSONEncoder().encode(trimmed), forKey: "history")
        }
    }
}

// MARK: - Views

/// Manual window drag + click detection. Reliable for a borderless, never-key window.
class DragView: NSView {
    var onClick: (() -> Void)?
    private var downAt = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var moved = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - downAt.x, dy = p.y - downAt.y
        if abs(dx) > 2 || abs(dy) > 2 { moved = true }
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if moved { window?.saveFrame(usingName: "IPWidget") } else { onClick?() }
    }
}

/// Small rounded status pill ("VPN" / "HOME").
final class Badge: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, color: NSColor) {
        label.stringValue = text
        layer?.backgroundColor = color.cgColor
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var root: DragView!
    private let blur = NSVisualEffectView()
    private let mapView = MKMapView()
    private var widthConstraint: NSLayoutConstraint!
    private var mapHeightConstraint: NSLayoutConstraint!

    private let ipLabel = NSTextField(labelWithString: "…")
    private let badge = Badge()
    private let placeLabel = NSTextField(labelWithString: "Определяю IP…")
    private let ispLabel = NSTextField(labelWithString: "")
    private let ipv6Label = NSTextField(labelWithString: "")
    private let localLabel = NSTextField(labelWithString: "")
    private let pingLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private let settingsMenu = NSMenu()
    private let pin = MKPointAnnotation()

    private let monitor = NWPathMonitor()
    private var currentPath: NWPath?
    private var timer: Timer?
    private var lastInfo: IPInfo?
    private var lastHost: String?
    private var lastIPv6: String?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        settingsMenu.delegate = self
        root.menu = settingsMenu
        applySettings()
        if Settings.notify { requestNotificationAuth() }

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.currentPath = path
                self?.renderLocal()
            }
            guard path.status == .satisfied else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "ipwidget.netmon"))

        refresh()
    }

    // MARK: UI construction

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 250),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        // Same level as macOS desktop widgets (Notification Center): above Finder's icon layer, so clicks reach us.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false

        root = DragView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.blendingMode = .behindWindow
        blur.state = .active
        root.addSubview(blur)

        // Map
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsZoomControls = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.pointOfInterestFilter = .excludingAll
        if #available(macOS 13.0, *) {
            mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        }
        // Labels
        style(ipLabel, size: 26, weight: .semibold, color: .labelColor, mono: true)
        style(placeLabel, size: 13, weight: .medium, color: .secondaryLabelColor)
        style(ispLabel, size: 11, weight: .regular, color: .tertiaryLabelColor)
        style(ipv6Label, size: 11, weight: .regular, color: .tertiaryLabelColor, mono: true)
        ipv6Label.lineBreakMode = .byTruncatingMiddle
        style(localLabel, size: 10, weight: .regular, color: .tertiaryLabelColor)
        style(pingLabel, size: 10, weight: .semibold, color: .tertiaryLabelColor, mono: true)
        style(timeLabel, size: 10, weight: .regular, color: .tertiaryLabelColor)
        timeLabel.alignment = .right

        configure(button: refreshButton, symbol: "arrow.clockwise", tip: "Обновить IP", action: #selector(refreshNow))
        configure(button: settingsButton, symbol: "gearshape", tip: "Настройки", action: #selector(showSettings(_:)))

        // Rows
        let header = NSStackView(views: [ipLabel, badge, spacer()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let bottom = NSStackView(views: [localLabel, pingLabel, spacer(), timeLabel, refreshButton, settingsButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 6
        bottom.setCustomSpacing(2, after: refreshButton)

        let info = NSStackView(views: [header, placeLabel, ispLabel, ipv6Label, bottom])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 3
        info.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 8, right: 10)
        info.setCustomSpacing(6, after: ipv6Label)
        info.translatesAutoresizingMaskIntoConstraints = false
        for row in [header, bottom] { row.widthAnchor.constraint(equalTo: info.widthAnchor, constant: -26).isActive = true }

        let column = NSStackView(views: [mapView, info])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        widthConstraint = root.widthAnchor.constraint(equalToConstant: 340)
        mapHeightConstraint = mapView.heightAnchor.constraint(equalToConstant: 150)

        NSLayoutConstraint.activate([
            widthConstraint, mapHeightConstraint,
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mapView.widthAnchor.constraint(equalTo: column.widthAnchor),
            info.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        // Transparent overlay pinned to the map: drag moves the window, click opens Maps (MKMapView eats mouse events).
        let cover = DragView()
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.onClick = { [weak self] in self?.openInMaps() }
        cover.toolTip = "Открыть в Картах"
        root.addSubview(cover, positioned: .above, relativeTo: column)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: mapView.topAnchor),
            cover.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: mapView.trailingAnchor),
        ])

        w.contentView = root

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: vf.maxX - 340 - 24, y: vf.maxY - 250 - 24))
        }
        w.setFrameAutosaveName("IPWidget")
        w.orderFrontRegardless()
        window = w
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func style(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        label.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configure(button: NSButton, symbol: String, tip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    // MARK: Apply settings / layout

    private func applySettings() {
        let size = Settings.size
        let compact = size == .compact
        let mapHidden = compact || Settings.mapMeters == 0

        widthConstraint.constant = size.width
        mapHeightConstraint.constant = mapHidden ? 0 : size.mapHeight
        mapView.isHidden = mapHidden
        ipLabel.font = .monospacedSystemFont(ofSize: size.ipFontSize, weight: .semibold)

        placeLabel.isHidden = compact
        ispLabel.isHidden = compact || !(Settings.flag("showISP") || Settings.flag("showHost"))
        ipv6Label.isHidden = compact || !Settings.flag("showIPv6")
        localLabel.isHidden = !Settings.flag("showLocal")
        pingLabel.isHidden = !Settings.flag("showPing")

        blur.material = Settings.materials[min(Settings.material, Settings.materials.count - 1)].material
        window.appearance = Settings.forceDark ? NSAppearance(named: .darkAqua) : nil

        restartTimer()
        render()
        relayout()
    }

    private func relayout() {
        root.layoutSubtreeIfNeeded()
        let fit = root.fittingSize
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: fit.width, height: fit.height)
        frame.origin.y = top - fit.height
        window.setFrame(frame, display: true, animate: false)
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = Settings.interval * 0.1
    }

    // MARK: Settings menu (gear button + right-click)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === settingsMenu else { return }
        menu.removeAllItems()

        menu.addItem(submenu("Размер", WidgetSize.allCases.map { s in
            item(s.title, #selector(pickSize(_:)), tag: s.rawValue, on: Settings.size == s)
        }))
        menu.addItem(submenu("Карта", Settings.zooms.enumerated().map { i, z in
            item(z.title, #selector(pickZoom(_:)), tag: i, on: Settings.mapMeters == z.meters)
        }))
        menu.addItem(submenu("Интервал обновления", Settings.intervals.enumerated().map { i, v in
            item(v.title, #selector(pickInterval(_:)), tag: i, on: Settings.interval == v.seconds)
        }))
        var look = Settings.materials.enumerated().map { i, m in
            item(m.title, #selector(pickMaterial(_:)), tag: i, on: Settings.material == i)
        }
        look.append(.separator())
        look.append(item("Всегда тёмная тема", #selector(toggleDark), on: Settings.forceDark))
        menu.addItem(submenu("Оформление", look))
        menu.addItem(submenu("Показывать", Settings.flags.map { f in
            item(f.title, #selector(toggleFlag(_:)), on: Settings.flag(f.key), rep: f.key)
        }))
        menu.addItem(item("Уведомлять о смене IP", #selector(toggleNotify), on: Settings.notify))

        menu.addItem(.separator())

        var home: [NSMenuItem] = []
        if let h = Settings.homeISP {
            let cur = item("Домашняя: \(h)", nil); cur.isEnabled = false; home.append(cur)
            home.append(item("Сбросить", #selector(clearHome)))
        } else {
            let cur = item("Не задана — бейдж VPN скрыт", nil); cur.isEnabled = false; home.append(cur)
        }
        home.append(item("Запомнить текущую сеть как домашнюю", #selector(setHome)))
        menu.addItem(submenu("Домашняя сеть", home))

        let df = DateFormatter(); df.dateFormat = "dd.MM HH:mm"
        var hist = Settings.history.reversed().map { e in
            item("\(df.string(from: e.date))  \(e.ip)  ·  \(e.isp)", #selector(copyFromHistory(_:)), rep: e.ip)
        }
        if hist.isEmpty { let e = item("Пусто", nil); e.isEnabled = false; hist = [e] }
        else { hist.append(.separator()); hist.append(item("Очистить историю", #selector(clearHistory))) }
        menu.addItem(submenu("История IP", hist))

        menu.addItem(.separator())
        menu.addItem(item("Обновить сейчас", #selector(refreshNow), key: "r"))
        menu.addItem(item("Скопировать IP", #selector(copyIP), key: "c"))
        menu.addItem(item("Открыть в Картах", #selector(openInMaps)))
        menu.addItem(.separator())
        menu.addItem(item("Выйти", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector?, tag: Int = 0, on: Bool = false, rep: Any? = nil, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.tag = tag
        it.state = on ? .on : .off
        it.representedObject = rep
        return it
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        it.submenu = m
        return it
    }

    @objc private func showSettings(_ sender: NSButton) {
        settingsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func pickSize(_ s: NSMenuItem) { Settings.size = WidgetSize(rawValue: s.tag) ?? .normal; applySettings() }
    @objc private func pickZoom(_ s: NSMenuItem) { Settings.mapMeters = Settings.zooms[s.tag].meters; applySettings() }
    @objc private func pickInterval(_ s: NSMenuItem) { Settings.interval = Settings.intervals[s.tag].seconds; applySettings() }
    @objc private func pickMaterial(_ s: NSMenuItem) { Settings.material = s.tag; applySettings() }
    @objc private func toggleDark() { Settings.forceDark.toggle(); applySettings() }
    @objc private func toggleFlag(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String else { return }
        Settings.toggle(key)
        applySettings()
        if key == "showIPv6" || key == "showHost" || key == "showPing" { refresh() }
    }
    @objc private func toggleNotify() {
        Settings.notify.toggle()
        if Settings.notify { requestNotificationAuth() }
    }
    @objc private func setHome() { Settings.homeISP = lastInfo?.isp ?? ""; render() }
    @objc private func clearHome() { Settings.homeISP = nil; render() }
    @objc private func clearHistory() { Settings.history = [] }
    @objc private func copyFromHistory(_ s: NSMenuItem) { if let ip = s.representedObject as? String { copy(ip) } }
    @objc private func refreshNow() { refresh() }
    @objc private func copyIP() { if let ip = lastInfo?.ip { copy(ip) } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openInMaps() {
        guard let c = lastInfo?.coordinate else { return }
        let q = lastInfo?.ip ?? "IP"
        if let url = URL(string: "maps://?ll=\(c.latitude),\(c.longitude)&q=\(q)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Data

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        setRefreshing(true)

        fetchPrimary { [weak self] info in
            if let info { self?.finish(info); return }
            self?.fetchFallback { info in self?.finish(info) }
        }
        if Settings.flag("showIPv6") { fetchIPv6() }
        if Settings.flag("showPing") { measureLatency() }
    }

    private func finish(_ info: IPInfo?) {
        isRefreshing = false
        setRefreshing(false)
        guard let info else {
            timeLabel.stringValue = "offline · " + timeString()
            if lastInfo == nil { placeLabel.stringValue = "Нет сети" }
            return
        }
        let old = lastInfo
        let changed = old != nil && old?.ip != info.ip
        lastInfo = info

        if old == nil || changed {
            if Settings.history.last?.ip != info.ip {
                Settings.history = Settings.history + [HistoryEntry(ip: info.ip, isp: info.isp ?? "", date: Date())]
            }
            lastHost = nil
            if Settings.flag("showHost") { reverseDNS(info.ip) }
        }
        if changed, let old { flashIP(); notifyChange(old: old, new: info) }

        render()
        if let coord = info.coordinate, !mapView.isHidden {
            mapView.removeAnnotation(pin)
            pin.coordinate = coord
            pin.title = info.city
            mapView.addAnnotation(pin)
            let m = Settings.mapMeters
            mapView.setRegion(MKCoordinateRegion(center: coord, latitudinalMeters: m, longitudinalMeters: m), animated: changed)
        }
    }

    private func render() {
        timeLabel.stringValue = timeString()
        renderLocal()
        guard let info = lastInfo else { return }
        ipLabel.stringValue = info.ip
        placeLabel.stringValue = [info.flag, info.place].filter { !$0.isEmpty }.joined(separator: "  ")

        var ispParts: [String] = []
        if Settings.flag("showISP"), let isp = info.isp, !isp.isEmpty { ispParts.append(isp) }
        if Settings.flag("showHost"), let h = lastHost { ispParts.append(h) }
        ispLabel.stringValue = ispParts.joined(separator: " · ")

        ipv6Label.stringValue = lastIPv6.map { "IPv6 " + $0 } ?? "IPv6 —"

        if let home = Settings.homeISP {
            badge.isHidden = false
            let isHome = (info.isp ?? "") == home
            badge.set(isHome ? "HOME" : "VPN", color: isHome ? .systemGray : .systemGreen)
        } else {
            badge.isHidden = true
        }
    }

    private func renderLocal() {
        localLabel.stringValue = localNetworkString() ?? ""
    }

    private func fetchPrimary(_ done: @escaping (IPInfo?) -> Void) {
        let url = URL(string: "http://ip-api.com/json/?fields=status,message,countryCode,regionName,city,lat,lon,isp,query")!
        get(url) { data in
            done(data.flatMap { try? JSONDecoder().decode(IPAPIResponse.self, from: $0) }?.info)
        }
    }

    private func fetchFallback(_ done: @escaping (IPInfo?) -> Void) {
        get(URL(string: "https://ipinfo.io/json")!) { data in
            done(data.flatMap { try? JSONDecoder().decode(IPInfoIOResponse.self, from: $0) }?.info)
        }
    }

    private func fetchIPv6() {
        get(URL(string: "https://api6.ipify.org?format=json")!) { [weak self] data in
            let v6 = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["ip"]
            self?.lastIPv6 = v6.flatMap { $0.contains(":") ? $0 : nil }
            self?.render()
        }
    }

    private func get(_ url: URL, _ done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    /// TCP connect time to 1.1.1.1:443 — ICMP needs privileges, this is close enough.
    private func measureLatency() {
        let q = DispatchQueue(label: "ipwidget.ping")
        let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        let start = Date()
        var finished = false
        let report: (Int?) -> Void = { [weak self] ms in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pingLabel.stringValue = ms.map { "\($0) ms" } ?? "— ms"
                self.pingLabel.textColor = ms.map { $0 < 50 ? .systemGreen : ($0 < 150 ? .systemOrange : .systemRed) } ?? .tertiaryLabelColor
            }
        }
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
                    // No PTR record: resolver may hand back the reverse zone name itself.
                    if !n.hasSuffix(".in-addr.arpa") && !n.hasSuffix(".ip6.arpa") && n != ip { name = n }
                }
                freeaddrinfo(res)
            }
            DispatchQueue.main.async {
                guard let self, self.lastInfo?.ip == ip else { return }
                self.lastHost = name
                self.render()
            }
        }
    }

    private func localNetworkString() -> String? {
        guard let path = currentPath, let iface = path.availableInterfaces.first else { return nil }
        var kind: String
        switch iface.type {
        case .wifi: kind = "Wi‑Fi"
        case .wiredEthernet: kind = "Ethernet"
        case .cellular: kind = "Cellular"
        case .loopback: kind = "lo"
        default: kind = iface.name
        }
        if iface.type == .wifi, let ssid = CWWiFiClient.shared().interface(withName: iface.name)?.ssid(), !ssid.isEmpty {
            kind += " " + ssid        // nil without Location permission on macOS 14+
        }
        var parts = [kind]
        if let ip = ipv4Address(of: iface.name) { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    private func ipv4Address(of name: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    // MARK: Notifications

    private func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyChange(old: IPInfo, new: IPInfo) {
        guard Settings.notify else { return }
        let c = UNMutableNotificationContent()
        c.title = "IP изменился"
        c.body = "\(old.ip) → \(new.ip)\n\(new.flag) \(new.place) · \(new.isp ?? "")"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Visual feedback

    private func setRefreshing(_ on: Bool) {
        refreshButton.isEnabled = !on
        guard let layer = refreshButton.layer else { return }
        if on {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.8
            spin.repeatCount = .infinity
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: refreshButton.frame.midX, y: refreshButton.frame.midY)
            layer.add(spin, forKey: "spin")
        } else {
            layer.removeAnimation(forKey: "spin")
        }
    }

    private func flashIP() {
        ipLabel.textColor = .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.ipLabel.textColor = .labelColor
        }
    }

    private func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
