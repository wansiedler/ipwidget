import AppKit
import Carbon
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = WidgetModel.shared
    private let menuController = MenuController()
    private var windows: [WidgetWindow] = []
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        if Settings.notify { model.requestNotificationAuth() }

        menuController.onSettingsChanged = { [weak self] in self?.settingsChanged() }
        rebuildWindows()
        updateStatusItem()
        updateHotkey()

        model.addObserver { [weak self] in self?.renderStatusItem() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.start()
    }

    // MARK: Windows (one per screen when enabled)

    private func rebuildWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()
        let screens = Settings.allScreens ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens[0]]
        for (i, screen) in screens.enumerated() {
            let name = i == 0 ? "IPWidget" : "IPWidget-\(i)"
            windows.append(WidgetWindow(screen: screen, autosaveName: name, menu: menuController.menu))
        }
    }

    @objc private func screensChanged() { rebuildWindows() }

    private func settingsChanged() {
        let want = Settings.allScreens ? NSScreen.screens.count : 1
        if want != windows.count { rebuildWindows() } else { windows.forEach { $0.applySettings() } }
        updateStatusItem()
        updateHotkey()
    }

    // MARK: Menu bar item

    private func updateStatusItem() {
        if Settings.menuBar == .hidden {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }
            return
        }
        if statusItem == nil {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            s.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            s.menu = menuController.menu
            statusItem = s
        }
        renderStatusItem()
    }

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let flag = model.info?.flag ?? ""
        var title: String
        switch Settings.menuBar {
        case .flagOnly: title = flag.isEmpty ? "IP" : flag
        default: title = [flag, model.ipText].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if model.dnsLeak { title += " ⚠︎" }
        button.title = title
        button.toolTip = [model.info?.place, model.info?.isp, model.pingDetails].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        button.contentTintColor = model.status == .bad ? .systemRed : nil
    }

    // MARK: Global hotkey ⌃⌥I (Carbon — no Accessibility permission needed)

    private func updateHotkey() {
        if Settings.hotkey, hotKeyRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.hotKeyPressed() }
                return noErr
            }, 1, &spec, nil, nil)
            let id = EventHotKeyID(signature: 0x4950_5744, id: 1) // "IPWD"
            RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        } else if !Settings.hotkey, let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func hotKeyPressed() {
        if let ip = model.info?.ip {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
        }
        windows.forEach { $0.raise(for: 3); $0.flashIP() }
    }

    // MARK: Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
