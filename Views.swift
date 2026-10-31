import AppKit
import MapKit

// MARK: - Mouse handling

/// Manual window drag + click detection. Reliable for a borderless, never-key window.
struct DragTracker {
    private var downAt = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private(set) var moved = false

    mutating func begin(_ window: NSWindow?) {
        downAt = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        moved = false
    }

    mutating func drag(_ window: NSWindow?) {
        let p = NSEvent.mouseLocation
        let dx = p.x - downAt.x, dy = p.y - downAt.y
        if abs(dx) > 2 || abs(dy) > 2 { moved = true }
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    /// Returns true when the gesture was a click (no movement).
    func end(_ window: NSWindow?) -> Bool {
        if moved, let w = window, !w.frameAutosaveName.isEmpty { w.saveFrame(usingName: w.frameAutosaveName) }
        return !moved
    }
}

class DragView: NSView {
    var onClick: (() -> Void)?
    private var tracker = DragTracker()
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { tracker.begin(window) }
    override func mouseDragged(with event: NSEvent) { tracker.drag(window) }
    override func mouseUp(with event: NSEvent) { if tracker.end(window) { onClick?() } }
}

/// Label that copies its value to the clipboard on click (drag still moves the window).
final class CopyLabel: NSTextField {
    var copyValue: (() -> String?)?
    private var tracker = DragTracker()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) { tracker.begin(window) }
    override func mouseDragged(with event: NSEvent) { tracker.drag(window) }
    override func mouseUp(with event: NSEvent) { if tracker.end(window) { copyNow() } }

    private func copyNow() {
        let value = (copyValue?() ?? stringValue).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "—", !value.hasPrefix("…") else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        let original = textColor
        textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.textColor = original }
    }
}

// MARK: - Small widgets

/// Rounded status pill ("VPN" / "HOME").
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

/// 60-sample download-rate sparkline.
final class SparklineView: NSView {
    var samples: [Double] = [] { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 70, height: 12) }

    override func draw(_ dirtyRect: NSRect) {
        guard samples.count > 1, let maxV = samples.max(), maxV > 0 else { return }
        let path = NSBezierPath()
        let w = bounds.width, h = bounds.height
        let step = w / CGFloat(max(59, samples.count - 1))
        let x0 = w - step * CGFloat(samples.count - 1)
        path.move(to: NSPoint(x: x0, y: 0))
        for (i, v) in samples.enumerated() {
            path.line(to: NSPoint(x: x0 + step * CGFloat(i), y: CGFloat(v / maxV) * (h - 1) + 0.5))
        }
        path.line(to: NSPoint(x: w, y: 0))
        path.close()
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        path.fill()
    }
}

// MARK: - Widget window

/// One desktop widget window. Several can exist (one per screen); all render the shared model.
final class WidgetWindow {
    let window: NSWindow
    private let model = WidgetModel.shared
    private let menu: NSMenu
    private var observer: UUID?

    private let root = DragView()
    private let blur = NSVisualEffectView()
    private let stripe = NSView()
    private let mapView = MKMapView()
    private let cover = DragView()
    private var widthConstraint: NSLayoutConstraint!
    private var mapHeightConstraint: NSLayoutConstraint!

    private let ipLabel = CopyLabel(labelWithString: "…")
    private let badge = Badge()
    private let placeLabel = CopyLabel(labelWithString: "Определяю IP…")
    private let ispLabel = CopyLabel(labelWithString: "")
    private let ipv6Label = CopyLabel(labelWithString: "")
    private let dnsLabel = CopyLabel(labelWithString: "")
    private let speedLabel = CopyLabel(labelWithString: "")
    private let spark = SparklineView()
    private let localLabel = CopyLabel(labelWithString: "")
    private let pingLabel = CopyLabel(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private var speedRow: NSStackView!
    private let pin = MKPointAnnotation()
    private var renderedMap: (ip: String, meters: Double)?

    init(screen: NSScreen, autosaveName: String, menu: NSMenu) {
        self.menu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 250),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        build()
        window.contentView = root
        root.menu = menu

        let vf = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: vf.maxX - 340 - 24, y: vf.maxY - 250 - 24))
        window.setFrameAutosaveName(autosaveName)
        applySettings()
        if !Settings.hidden { window.orderFrontRegardless() }

        observer = model.addObserver { [weak self] in self?.render() }
        render()
    }

    deinit {
        if let observer { model.removeObserver(observer) }
    }

    func close() {
        if let observer { model.removeObserver(observer) }
        observer = nil
        window.orderOut(nil)
    }

    // MARK: Build

    private func build() {
        let w = window
        // Same level as macOS desktop widgets (Notification Center): above Finder's icon layer, so clicks reach us.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false

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

        stripe.wantsLayer = true
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.heightAnchor.constraint(equalToConstant: 3).isActive = true

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

        style(ipLabel, size: 26, weight: .semibold, color: .labelColor, mono: true)
        style(placeLabel, size: 13, weight: .medium, color: .secondaryLabelColor)
        style(ispLabel, size: 11, weight: .regular, color: .tertiaryLabelColor)
        style(ipv6Label, size: 11, weight: .regular, color: .tertiaryLabelColor, mono: true)
        ipv6Label.lineBreakMode = .byTruncatingMiddle
        style(dnsLabel, size: 11, weight: .regular, color: .tertiaryLabelColor)
        style(speedLabel, size: 10, weight: .regular, color: .tertiaryLabelColor, mono: true)
        style(localLabel, size: 10, weight: .regular, color: .tertiaryLabelColor)
        style(pingLabel, size: 10, weight: .semibold, color: .tertiaryLabelColor, mono: true)
        style(timeLabel, size: 10, weight: .regular, color: .tertiaryLabelColor)
        timeLabel.alignment = .right

        ipLabel.copyValue = { [weak self] in self?.model.info?.ip }
        placeLabel.copyValue = { [weak self] in self?.model.info?.place }
        ipv6Label.copyValue = { [weak self] in self?.model.ipv6 }
        // dnsLabel copies its whole line (resolver, country, IP)
        localLabel.copyValue = { [weak self] in self?.model.local?.ipv4 }
        pingLabel.copyValue = { [weak self] in self?.model.pingDetails }
        for l in [ipLabel, placeLabel, ispLabel, ipv6Label, dnsLabel, speedLabel, localLabel] { l.toolTip = "Клик — скопировать" }

        configure(button: refreshButton, symbol: "arrow.clockwise", tip: "Обновить", action: #selector(refreshNow))
        configure(button: settingsButton, symbol: "gearshape", tip: "Настройки", action: #selector(showSettings(_:)))

        let header = hstack([ipLabel, badge, spacer()], spacing: 8)
        speedRow = hstack([speedLabel, spacer(), spark], spacing: 6)
        let bottom = hstack([localLabel, pingLabel, spacer(), timeLabel, refreshButton, settingsButton], spacing: 6)
        bottom.setCustomSpacing(2, after: refreshButton)
        // Long VPN/interface text truncates first; latency and time stay intact.
        localLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        pingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pingLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let info = NSStackView(views: [header, placeLabel, ispLabel, ipv6Label, dnsLabel, speedRow, bottom])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 3
        info.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 8, right: 10)
        info.setCustomSpacing(6, after: dnsLabel)
        info.setCustomSpacing(6, after: speedRow)
        info.translatesAutoresizingMaskIntoConstraints = false
        for row in [header, speedRow!, bottom] {
            row.widthAnchor.constraint(equalTo: info.widthAnchor, constant: -26).isActive = true
        }

        let column = NSStackView(views: [stripe, mapView, info])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        // Transparent overlay pinned to the map: drag moves the window, click opens Maps (MKMapView eats mouse events).
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.onClick = { [weak self] in self?.openInMaps() }
        cover.toolTip = "Открыть в Картах"
        root.addSubview(cover, positioned: .above, relativeTo: column)

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
            stripe.widthAnchor.constraint(equalTo: column.widthAnchor),
            mapView.widthAnchor.constraint(equalTo: column.widthAnchor),
            info.widthAnchor.constraint(equalTo: column.widthAnchor),
            cover.topAnchor.constraint(equalTo: mapView.topAnchor),
            cover.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: mapView.trailingAnchor),
        ])
    }

    private func hstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
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

    // MARK: Settings → layout

    func applySettings() {
        let size = Settings.size
        let compact = size == .compact
        let mapHidden = compact || Settings.mapMeters == 0

        widthConstraint.constant = size.width
        mapHeightConstraint.constant = mapHidden ? 0 : size.mapHeight
        mapView.isHidden = mapHidden
        cover.isHidden = mapHidden
        ipLabel.font = .monospacedSystemFont(ofSize: size.ipFontSize, weight: .semibold)

        placeLabel.isHidden = compact
        ispLabel.isHidden = compact || !(Settings.flag("showISP") || Settings.flag("showHost"))
        ipv6Label.isHidden = compact || !Settings.flag("showIPv6")
        dnsLabel.isHidden = compact || !Settings.flag("showDNS")
        speedRow.isHidden = compact || !Settings.flag("showSpeed")
        localLabel.isHidden = !Settings.flag("showLocal")
        pingLabel.isHidden = !Settings.flag("showPing")

        blur.material = Settings.materials[min(Settings.material, Settings.materials.count - 1)].material
        window.appearance = Settings.forceDark ? NSAppearance(named: .darkAqua) : nil

        if Settings.hidden { window.orderOut(nil) } else { window.orderFrontRegardless() }

        renderedMap = nil
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

    /// Temporarily float above everything (hotkey), then sink back to the desktop.
    func raise(for seconds: TimeInterval) {
        window.level = .floating
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
            if Settings.hidden { self.window.orderOut(nil) }
        }
    }

    // MARK: Render

    private func render() {
        let m = model
        stripe.layer?.backgroundColor = m.status.color.cgColor

        ipLabel.stringValue = m.ipText
        if let info = m.info {
            placeLabel.stringValue = [info.flag, info.place].filter { !$0.isEmpty }.joined(separator: "  ")
        } else if m.offline {
            placeLabel.stringValue = "Нет сети"
        }
        ispLabel.stringValue = m.ispText
        ipv6Label.stringValue = m.ipv6Text

        dnsLabel.stringValue = m.dnsText
        dnsLabel.textColor = m.dnsLeak ? .systemRed : .tertiaryLabelColor
        dnsLabel.font = .systemFont(ofSize: 11, weight: m.dnsLeak ? .bold : .regular)
        let verdict = m.dnsVerdict.reason
        dnsLabel.toolTip = (verdict.isEmpty ? "" : verdict + "\n") + "Клик — скопировать строку"

        speedLabel.stringValue = m.speedText
        spark.samples = m.rateHistory
        spark.isHidden = m.speedTestText != nil || m.speedTestRunning

        localLabel.stringValue = m.localText
        pingLabel.stringValue = m.pingText
        pingLabel.toolTip = m.pingDetails.isEmpty ? nil : m.pingDetails
        if let w = m.worstPing {
            pingLabel.textColor = w.ms < 50 ? .systemGreen : (w.ms < 150 ? .systemOrange : .systemRed)
        } else {
            pingLabel.textColor = .tertiaryLabelColor
        }
        timeLabel.stringValue = m.timeText

        if let b = m.badge {
            badge.isHidden = false
            badge.set(b.text, color: b.color)
        } else {
            badge.isHidden = true
        }
        badge.toolTip = m.vpnNames.isEmpty ? (m.local?.interface) : m.vpnNames.joined(separator: ", ")

        setRefreshing(m.isRefreshing)

        if let info = m.info, let coord = info.coordinate, !mapView.isHidden {
            let key = (info.ip, Settings.mapMeters)
            if renderedMap == nil || renderedMap! != key {
                let animated = renderedMap != nil
                renderedMap = key
                mapView.removeAnnotation(pin)
                pin.coordinate = coord
                pin.title = info.city
                mapView.addAnnotation(pin)
                let meters = Settings.mapMeters
                mapView.setRegion(MKCoordinateRegion(center: coord, latitudinalMeters: meters, longitudinalMeters: meters), animated: animated)
                if animated { flashIP() }
            }
        }
    }

    private var spinning = false
    private func setRefreshing(_ on: Bool) {
        refreshButton.isEnabled = !on
        guard on != spinning, let layer = refreshButton.layer else { return }
        spinning = on
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

    func flashIP() {
        ipLabel.textColor = .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.ipLabel.textColor = .labelColor }
    }

    // MARK: Actions

    @objc private func refreshNow() { model.refresh() }

    @objc private func showSettings(_ sender: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func openInMaps() {
        guard let c = model.info?.coordinate else { return }
        if let url = URL(string: "maps://?ll=\(c.latitude),\(c.longitude)&q=IP%20Widget") {
            NSWorkspace.shared.open(url)
        }
    }
}
