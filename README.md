# IPWidget

Native macOS desktop widget: external IP, flag, city/region/country, ISP and a live Apple Maps view
pinned to the IP geolocation. Sits at desktop-icon window level (below all app windows, on every Space).

- Source: `main.swift` (AppKit + MapKit + Network, single file, no dependencies)
- Data: `http://ip-api.com/json` (45 req/min, no monthly cap; ATS exception in Info.plist),
  fallback `https://ipinfo.io/json`
- Refresh: every 30 s by default (15 s … 15 min in settings) + 2 s after any network path change
- IP change: address flashes orange for 2.5 s
- Buttons: ↻ refresh (spins while loading), ⚙ settings menu — also on right-click.
  Settings persist in UserDefaults (`com.wansiedler.ipwidget`).

### Features

| | |
|---|---|
| VPN / HOME badge | "Домашняя сеть → Запомнить текущую" stores the ISP; a different ISP shows a green **VPN** pill, same ISP a grey **HOME** pill |
| IPv6 | via `api6.ipify.org`; "IPv6 —" when there is no v6 connectivity |
| IP history | last 10 addresses with ISP and time in the ⚙ menu; click copies the IP |
| Notification | macOS notification "IP изменился: old → new" (toggle in menu) |
| Local network | active interface (Wi‑Fi / Ethernet / utunN for VPN), SSID when Location permission allows, local IPv4 |
| Latency | TCP connect time to 1.1.1.1:443, green < 50 ms, orange < 150 ms, red above |
| Appearance | blur material (HUD / Popover / Sidebar / Titlebar), force dark theme |
| Size | compact (no map, 300 px) / normal (340, map 150) / large (420, map 220) |
| Map click | opens the location in Apple Maps; drag anywhere (map included) moves the widget |
| Reverse DNS | PTR hostname of the public IP next to the ISP |
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
