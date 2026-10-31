import AppKit
import ServiceManagement

/// Builds the settings menu (gear button, right-click, menu bar item) and applies the choices.
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let model = WidgetModel.shared
    /// Called after any setting changed so windows / status item can re-apply.
    var onSettingsChanged: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
    }

    // MARK: Build

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()

        // Status line
        let st = item(statusLine(), nil); st.isEnabled = false
        menu.addItem(st)
        menu.addItem(.separator())

        menu.addItem(submenu(tr("Language"), [
            item(tr("System language"), #selector(pickLanguage(_:)), on: Settings.language.isEmpty, rep: ""),
            item("Русский", #selector(pickLanguage(_:)), on: Settings.language == "ru", rep: "ru"),
            item("English", #selector(pickLanguage(_:)), on: Settings.language == "en", rep: "en"),
        ]))
        menu.addItem(submenu(tr("Size"), WidgetSize.allCases.map { s in
            item(s.title, #selector(pickSize(_:)), tag: s.rawValue, on: Settings.size == s)
        }))
        menu.addItem(submenu(tr("Map"), Settings.zooms.enumerated().map { i, z in
            item(z.title, #selector(pickZoom(_:)), tag: i, on: Settings.mapMeters == z.meters)
        }))
        menu.addItem(submenu(tr("Refresh interval"), Settings.intervals.enumerated().map { i, v in
            item(v.title, #selector(pickInterval(_:)), tag: i, on: Settings.interval == v.seconds)
        }))

        var look = Settings.materials.enumerated().map { i, m in
            item(m.title, #selector(pickMaterial(_:)), tag: i, on: Settings.material == i)
        }
        look.append(.separator())
        look.append(item(tr("Always dark theme"), #selector(toggleDark), on: Settings.forceDark))
        menu.addItem(submenu(tr("Appearance"), look))

        menu.addItem(submenu(tr("Show"), Settings.flags.map { f in
            item(f.title, #selector(toggleFlag(_:)), on: Settings.flag(f.key), rep: f.key)
        }))

        menu.addItem(submenu(tr("Menu bar"), MenuBarStyle.allCases.map { s in
            item(s.title, #selector(pickMenuBar(_:)), tag: s.rawValue, on: Settings.menuBar == s)
        }))

        var ping = Settings.pingPresets.map { p in
            item(p.title, #selector(togglePingTarget(_:)), on: Settings.pingTargets.contains(p.target), rep: p.target)
        }
        let custom = Settings.pingTargets.filter { t in !Settings.pingPresets.contains { $0.target == t } }
        if !custom.isEmpty {
            ping.append(.separator())
            ping += custom.map { item($0, #selector(togglePingTarget(_:)), on: true, rep: $0) }
        }
        ping.append(.separator())
        ping.append(item(tr("Add address…"), #selector(addPingTarget)))
        ping.append(item(tr("Reset"), #selector(resetPingTargets)))
        menu.addItem(submenu(tr("Ping targets"), ping))

        menu.addItem(.separator())
        menu.addItem(item(tr("Mask IP (for demos)"), #selector(toggleMask), on: Settings.maskIP))
        menu.addItem(item(tr("Hide widget from desktop"), #selector(toggleHidden), on: Settings.hidden))
        menu.addItem(item(tr("On all screens"), #selector(toggleAllScreens), on: Settings.allScreens))
        menu.addItem(item(tr("Hotkey ⌃⌥I — show and copy IP"), #selector(toggleHotkey), on: Settings.hotkey))
        menu.addItem(item(tr("Notify on IP change"), #selector(toggleNotify), on: Settings.notify))
        var sounds = [item(tr("No sound"), #selector(pickSound), on: Settings.changeSound.isEmpty, rep: ""), .separator()]
        sounds += Settings.systemSounds.map { item($0, #selector(pickSound), on: Settings.changeSound == $0, rep: $0) }
        menu.addItem(submenu(tr("Sound on IP change"), sounds))
        menu.addItem(item(tr("Test notification"), #selector(testNotification)))

        menu.addItem(.separator())

        var home: [NSMenuItem] = []
        if let h = Settings.homeISP {
            let cur = item(tr("Home: ") + h, nil); cur.isEnabled = false; home.append(cur)
            home.append(item(tr("Reset"), #selector(clearHome)))
        } else {
            let cur = item(tr("Not set — VPN is detected by the tunnel"), nil); cur.isEnabled = false; home.append(cur)
        }
        home.append(item(tr("Remember current network as home"), #selector(setHome)))
        menu.addItem(submenu(tr("Home network"), home))

        let df = DateFormatter(); df.dateFormat = "dd.MM HH:mm"
        var hist = Settings.history.suffix(10).reversed().map { e in
            item("\(df.string(from: e.date))  \(Settings.maskIP ? maskIP(e.ip) : e.ip)  ·  \(e.isp)", #selector(copyFromHistory(_:)), rep: e.ip)
        }
        if hist.isEmpty { let e = item(tr("Empty"), nil); e.isEnabled = false; hist = [e] }
        hist.append(.separator())
        hist.append(item(tr("Export CSV (~/Downloads)"), #selector(exportHistory)))
        hist.append(item(tr("Clear history"), #selector(clearHistory)))
        menu.addItem(submenu(tr("IP history") + " (\(Settings.history.count))", hist))

        menu.addItem(.separator())
        menu.addItem(item(tr("Refresh now"), #selector(refreshNow), key: "r"))
        menu.addItem(item(tr("Copy IP"), #selector(copyIP), key: "c"))
        menu.addItem(item(tr("Open in Maps"), #selector(openInMaps)))
        let speed = item(model.speedTestRunning ? tr("Speed test…") : tr("Speed test (Cloudflare)"), #selector(speedTest))
        speed.isEnabled = !model.speedTestRunning
        menu.addItem(speed)
        menu.addItem(.separator())
        #if APPSTORE
        let login = item(tr("Launch at login"), #selector(toggleLoginItem), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(login)
        #else
        let rebuild = item(tr("Rebuild from source"), #selector(rebuild))
        rebuild.isEnabled = Settings.repoPath != nil
        rebuild.toolTip = Settings.repoPath
        menu.addItem(rebuild)
        #endif
        menu.addItem(item(tr("About"), #selector(about)))
        menu.addItem(item(tr("Quit"), #selector(quit), key: "q"))
    }

    private func statusLine() -> String {
        var parts: [String] = []
        if let info = model.info { parts.append("\(info.flag) \(model.ipText)") }
        if model.vpnActive { parts.append("VPN") }
        if model.dnsLeak { parts.append("DNS LEAK") }
        if let w = model.worstPing { parts.append("\(w.ms) ms") }
        if model.offline { parts.append("offline") }
        return parts.isEmpty ? "IP Widget" : parts.joined(separator: " · ")
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

    private func changed() { onSettingsChanged?() }

    // MARK: Actions

    @objc private func pickSize(_ s: NSMenuItem) { Settings.size = WidgetSize(rawValue: s.tag) ?? .normal; changed() }
    @objc private func pickZoom(_ s: NSMenuItem) { Settings.mapMeters = Settings.zooms[s.tag].meters; changed() }
    @objc private func pickInterval(_ s: NSMenuItem) { Settings.interval = Settings.intervals[s.tag].seconds; model.restartTimer(); changed() }
    @objc private func pickMaterial(_ s: NSMenuItem) { Settings.material = s.tag; changed() }
    @objc private func pickMenuBar(_ s: NSMenuItem) { Settings.menuBar = MenuBarStyle(rawValue: s.tag) ?? .ipFlag; changed() }
    @objc private func toggleDark() { Settings.forceDark.toggle(); changed() }
    @objc private func toggleMask() { Settings.maskIP.toggle(); changed() }
    @objc private func toggleHidden() { Settings.hidden.toggle(); changed() }
    @objc private func toggleAllScreens() { Settings.allScreens.toggle(); changed() }
    @objc private func toggleHotkey() { Settings.hotkey.toggle(); changed() }

    @objc private func toggleFlag(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String else { return }
        Settings.toggle(key)
        if key == "showSSID", Settings.flag(key) { model.requestLocationForSSID() }
        changed()
        if ["showIPv6", "showHost", "showPing", "showDNS"].contains(key) { model.refresh() }
    }

    @objc private func toggleNotify() {
        Settings.notify.toggle()
        if Settings.notify { model.requestNotificationAuth() }
    }
    @objc private func testNotification() { model.testNotification() }
    @objc private func pickLanguage(_ s: NSMenuItem) { Settings.language = s.representedObject as? String ?? ""; changed() }
    @objc private func pickSound(_ s: NSMenuItem) {
        let name = s.representedObject as? String ?? ""
        Settings.changeSound = name
        model.playChangeSound(name) // preview
    }

    @objc private func togglePingTarget(_ s: NSMenuItem) {
        guard let t = s.representedObject as? String else { return }
        var targets = Settings.pingTargets
        if let i = targets.firstIndex(of: t) { targets.remove(at: i) } else { targets.append(t) }
        Settings.pingTargets = targets
        model.refresh()
    }

    @objc private func addPingTarget() {
        let alert = NSAlert()
        alert.messageText = tr("Ping target")
        alert.informativeText = tr("IP or hostname. Measures TCP connect time to port 443.")
        alert.addButton(withTitle: tr("Add"))
        alert.addButton(withTitle: tr("Cancel"))
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = tr("e.g. 9.9.9.9 or my.server.com")
        alert.accessoryView = tf
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let t = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !Settings.pingTargets.contains(t) else { return }
        Settings.pingTargets = Settings.pingTargets + [t]
        model.refresh()
    }

    @objc private func resetPingTargets() { Settings.pingTargets = ["1.1.1.1", "8.8.8.8"]; model.refresh() }

    @objc private func setHome() { Settings.homeISP = model.info?.isp ?? ""; changed() }
    @objc private func clearHome() { Settings.homeISP = nil; changed() }

    @objc private func copyFromHistory(_ s: NSMenuItem) { if let ip = s.representedObject as? String { copy(ip) } }
    @objc private func clearHistory() { Settings.history = [] }
    @objc private func exportHistory() {
        if let url = model.exportHistory() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func refreshNow() { model.refresh() }
    @objc private func copyIP() { if let ip = model.info?.ip { copy(ip) } }
    @objc private func speedTest() { model.runSpeedTest() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openInMaps() {
        guard let c = model.info?.coordinate else { return }
        if let url = URL(string: "maps://?ll=\(c.latitude),\(c.longitude)&q=IP%20Widget") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(string: tr("about.credits"), attributes: [.font: NSFont.systemFont(ofSize: 11)])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "IP Widget"])
    }

    @objc private func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("login item: \(error.localizedDescription)")
        }
    }

    @objc private func rebuild() {
        if !model.rebuildFromSource() {
            let a = NSAlert()
            a.messageText = tr("Could not start the rebuild")
            a.informativeText = tr("No build.sh at %@", Settings.repoPath ?? "—")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
