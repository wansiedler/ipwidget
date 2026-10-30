# IPWidget

Native macOS desktop widget: external IP, flag, city/region/country, ISP and a live Apple Maps view
pinned to the IP geolocation. Sits at desktop-icon window level (below all app windows, on every Space).

- Source: `main.swift` (AppKit + MapKit + Network, single file, no dependencies)
- Data: `http://ip-api.com/json` (45 req/min, no monthly cap; ATS exception in Info.plist),
  fallback `https://ipinfo.io/json`
- Refresh: every 30 s by default (15 s … 15 min in settings) + 2 s after any network path change
- IP change: address flashes orange for 2.5 s
- Buttons: ↻ refresh (spins while loading), ⚙ settings menu — also on right-click:
  interval, map zoom (city / region / country / hidden), show ISP, copy IP, quit.
  Settings persist in UserDefaults (`com.wansiedler.ipwidget`).
- Drag anywhere to move; position is persisted (frame autosave)

## Build & install

```bash
./build.sh
```

Compiles with `swiftc`, assembles `IPWidget.app`, ad-hoc codesigns, installs to `~/Applications`,
installs a launchd agent `~/Library/LaunchAgents/com.wansiedler.ipwidget.plist` (RunAtLoad,
restart on crash, not restarted after a clean Quit) and starts it.

## Control

```bash
launchctl kickstart -k gui/$(id -u)/com.wansiedler.ipwidget   # restart
launchctl bootout   gui/$(id -u)/com.wansiedler.ipwidget      # stop + disable until next build.sh
```

Uninstall: bootout, then delete `~/Applications/IPWidget.app` and the LaunchAgents plist.
