import AppKit
import MapKit
import Network

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

// MARK: - Settings

enum Settings {
    private static let d = UserDefaults.standard

    static let intervals: [(title: String, seconds: TimeInterval)] = [
        ("15 секунд", 15), ("30 секунд", 30), ("1 минута", 60), ("5 минут", 300), ("15 минут", 900),
    ]
    static let zooms: [(title: String, meters: Double)] = [
        ("Город (40 км)", 40_000), ("Регион (200 км)", 200_000), ("Страна (1500 км)", 1_500_000), ("Скрыть карту", 0),
    ]

    static var interval: TimeInterval {
        get { let v = d.double(forKey: "interval"); return v > 0 ? v : 30 }
        set { d.set(newValue, forKey: "interval") }
    }
    static var mapMeters: Double {
        get { d.object(forKey: "mapMeters") == nil ? 40_000 : d.double(forKey: "mapMeters") }
        set { d.set(newValue, forKey: "mapMeters") }
    }
    static var showISP: Bool {
        get { d.object(forKey: "showISP") == nil ? true : d.bool(forKey: "showISP") }
        set { d.set(newValue, forKey: "showISP") }
    }
}

// MARK: - Views

/// Root blur view: any left-drag on it moves the window (works even when the window is not key).
final class RootView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Transparent overlay on top of the map so drags there move the window instead of being eaten by MKMapView.
final class DragOverlay: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private let mapView = MKMapView()
    private var mapHeightConstraint: NSLayoutConstraint!
    private let ipLabel = NSTextField(labelWithString: "…")
    private let placeLabel = NSTextField(labelWithString: "Определяю IP…")
    private let ispLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private let settingsMenu = NSMenu()
    private let pin = MKPointAnnotation()
    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private var lastInfo: IPInfo?
    private var isRefreshing = false

    private let width: CGFloat = 340
    private let infoHeight: CGFloat = 100
    private let fullMapHeight: CGFloat = 150

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        buildMenu()
        applyMapSetting()

        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "ipwidget.netmon"))

        restartTimer()
        refresh()
    }

    // MARK: UI

    private func buildWindow() {
        let size = NSSize(width: width, height: fullMapHeight + infoHeight)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        // Same level as macOS desktop widgets (Notification Center): above Finder's icon layer, so clicks reach us.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false

        let root = RootView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

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
        root.addSubview(mapView)

        let dragOverlay = DragOverlay()
        dragOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dragOverlay)

        // Labels
        ipLabel.font = .monospacedSystemFont(ofSize: 26, weight: .semibold)
        ipLabel.textColor = .labelColor
        ipLabel.lineBreakMode = .byTruncatingTail

        placeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        placeLabel.textColor = .secondaryLabelColor
        placeLabel.lineBreakMode = .byTruncatingTail

        ispLabel.font = .systemFont(ofSize: 11)
        ispLabel.textColor = .tertiaryLabelColor
        ispLabel.lineBreakMode = .byTruncatingTail

        timeLabel.font = .systemFont(ofSize: 10)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right

        let left = NSStackView(views: [ipLabel, placeLabel, ispLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 3
        left.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(left)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(timeLabel)

        configure(button: refreshButton, symbol: "arrow.clockwise", tip: "Обновить IP", action: #selector(refreshNow))
        configure(button: settingsButton, symbol: "gearshape", tip: "Настройки", action: #selector(showSettings(_:)))
        root.addSubview(refreshButton)
        root.addSubview(settingsButton)

        mapHeightConstraint = mapView.heightAnchor.constraint(equalToConstant: fullMapHeight)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: root.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mapHeightConstraint,

            dragOverlay.topAnchor.constraint(equalTo: mapView.topAnchor),
            dragOverlay.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            dragOverlay.trailingAnchor.constraint(equalTo: mapView.trailingAnchor),
            dragOverlay.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),

            left.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 12),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            left.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            settingsButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            settingsButton.widthAnchor.constraint(equalToConstant: 22),
            settingsButton.heightAnchor.constraint(equalToConstant: 22),

            refreshButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -2),
            refreshButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),

            timeLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -4),
            timeLabel.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
        ])

        w.contentView = root

        // Default position: top-right of main screen; autosave restores last dragged spot.
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24))
        }
        w.setFrameAutosaveName("IPWidget")
        w.orderFrontRegardless()
        window = w
    }

    private func configure(button: NSButton, symbol: String, tip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
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
    }

    // MARK: Settings menu (also shown on right-click)

    private func buildMenu() {
        settingsMenu.delegate = self

        let intervalItem = NSMenuItem(title: "Интервал обновления", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for (i, opt) in Settings.intervals.enumerated() {
            let item = NSMenuItem(title: opt.title, action: #selector(pickInterval(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        settingsMenu.addItem(intervalItem)

        let zoomItem = NSMenuItem(title: "Карта", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        for (i, opt) in Settings.zooms.enumerated() {
            let item = NSMenuItem(title: opt.title, action: #selector(pickZoom(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            zoomMenu.addItem(item)
        }
        zoomItem.submenu = zoomMenu
        settingsMenu.addItem(zoomItem)

        let ispItem = NSMenuItem(title: "Показывать провайдера", action: #selector(toggleISP), keyEquivalent: "")
        ispItem.target = self; ispItem.tag = 100
        settingsMenu.addItem(ispItem)

        settingsMenu.addItem(.separator())
        settingsMenu.addItem(withTitle: "Обновить сейчас", action: #selector(refreshNow), keyEquivalent: "r").target = self
        settingsMenu.addItem(withTitle: "Скопировать IP", action: #selector(copyIP), keyEquivalent: "c").target = self
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q").target = self

        window.contentView?.menu = settingsMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === settingsMenu else { return }
        for item in menu.item(withTitle: "Интервал обновления")?.submenu?.items ?? [] {
            item.state = Settings.intervals[item.tag].seconds == Settings.interval ? .on : .off
        }
        for item in menu.item(withTitle: "Карта")?.submenu?.items ?? [] {
            item.state = Settings.zooms[item.tag].meters == Settings.mapMeters ? .on : .off
        }
        menu.item(withTag: 100)?.state = Settings.showISP ? .on : .off
    }

    @objc private func showSettings(_ sender: NSButton) {
        let point = NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4)
        settingsMenu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        Settings.interval = Settings.intervals[sender.tag].seconds
        restartTimer()
    }

    @objc private func pickZoom(_ sender: NSMenuItem) {
        Settings.mapMeters = Settings.zooms[sender.tag].meters
        applyMapSetting()
        if let info = lastInfo { apply(info, changed: false) }
    }

    @objc private func toggleISP() {
        Settings.showISP.toggle()
        ispLabel.isHidden = !Settings.showISP
    }

    private func applyMapSetting() {
        let hidden = Settings.mapMeters == 0
        mapView.isHidden = hidden
        mapHeightConstraint.constant = hidden ? 0 : fullMapHeight
        ispLabel.isHidden = !Settings.showISP

        let newHeight = (hidden ? 0 : fullMapHeight) + infoHeight
        var frame = window.frame
        let delta = newHeight - frame.height
        frame.origin.y -= delta       // keep top edge in place
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: false)
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = Settings.interval * 0.1
    }

    // MARK: Actions

    @objc private func refreshNow() { refresh() }

    @objc private func copyIP() {
        guard let ip = lastInfo?.ip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Data

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        setRefreshing(true)

        fetchPrimary { [weak self] info in
            if let info { self?.finish(info); return }
            self?.fetchFallback { info in self?.finish(info) }
        }
    }

    private func finish(_ info: IPInfo?) {
        isRefreshing = false
        setRefreshing(false)
        guard let info else {
            timeLabel.stringValue = "offline · " + timeString()
            if lastInfo == nil { placeLabel.stringValue = "Нет сети" }
            return
        }
        let changed = lastInfo != nil && lastInfo?.ip != info.ip
        lastInfo = info
        apply(info, changed: changed)
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

    private func get(_ url: URL, _ done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    private func apply(_ info: IPInfo, changed: Bool) {
        ipLabel.stringValue = info.ip
        placeLabel.stringValue = [info.flag, info.place].filter { !$0.isEmpty }.joined(separator: "  ")
        ispLabel.stringValue = info.isp ?? ""
        timeLabel.stringValue = timeString()

        if let coord = info.coordinate, Settings.mapMeters > 0 {
            mapView.removeAnnotation(pin)
            pin.coordinate = coord
            pin.title = info.city
            mapView.addAnnotation(pin)
            let m = Settings.mapMeters
            mapView.setRegion(MKCoordinateRegion(center: coord, latitudinalMeters: m, longitudinalMeters: m), animated: changed)
        }

        if changed { flashIP() }
    }

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
