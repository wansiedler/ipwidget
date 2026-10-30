# IPWidget

Native macOS desktop widget: external IP, flag, city/region/country, ISP and a live Apple Maps view
pinned to the IP geolocation. Sits at desktop-icon window level (below all app windows, on every Space).

- Source: `Model.swift` (data, fetching, settings), `Views.swift` (window + controls), `Menu.swift` (settings menu),
  `main.swift` (app delegate, menu bar item, hotkey). AppKit + MapKit + Network + Carbon, no dependencies.
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
| Change sound | system sound (Glass by default, any of /System/Library/Sounds or off) played via NSSound on IP change, independent of notification settings; picking a sound in "Звук при смене IP" previews it |
| Local network | active interface (Wi‑Fi / Ethernet / utunN for VPN), SSID when Location permission allows, local IPv4 |
| Latency | TCP connect time to 1.1.1.1:443, green < 50 ms, orange < 150 ms, red above |
| Appearance | blur material (HUD / Popover / Sidebar / Titlebar), force dark theme |
| Size | compact (no map, 300 px) / normal (340, map 150) / large (420, map 220) |
| Map click | opens the location in Apple Maps; drag anywhere (map included) moves the widget |
| Reverse DNS | PTR hostname of the public IP next to the ISP |
| Click to copy | every value (IP, place, ISP/host, IPv6, DNS resolver, local IP, latency) copies to the clipboard on click; label flashes green |

### Network monitor (v3)

| | |
|---|---|
| DNS leak | `edns.ip-api.com` reports the resolver that answered our lookup; with VPN on and a resolver org ≠ public ISP the row turns red **DNS LEAK** and the status stripe goes red |
| VPN detection | instant: default route via `utun*/ipsec*/ppp*` → VPN badge without waiting for the IP fetch; connected VPN names from `scutil --nc list` |
| Throughput | ↓/↑ rate from the active interface byte counters (1 s sampling, 32-bit wrap handled) + 60 s sparkline |
| Status stripe | 3 px bar on top: green ok · yellow IP changed < 60 s · red offline / DNS leak / latency > 150 ms |
| Hotkey ⌃⌥I | floats the widget above all windows for 3 s and copies the IP (Carbon hotkey, no Accessibility permission) |
| All screens | one widget per display, each remembers its own position |
| Menu bar item | `🇨🇭 89.21.64.156` (or flag only), ⚠︎ on DNS leak, red when status is bad; same settings menu |
| History export | CSV to `~/Downloads`, up to 500 entries kept |
| Ping targets | any set of 1.1.1.1 / 8.8.8.8 / 9.9.9.9 / gateway / custom hosts; shows the worst, tooltip lists all |
| Speed test | Cloudflare `__down` 20 MB + `__up` 8 MB → Mbps, on demand, shown for 60 s |
| Mask IP | `89.21.•••.•••` everywhere (widget + menu bar) for screen sharing; "hide widget" keeps only the menu bar |
| Rebuild | menu item runs `git pull --ff-only` (if a remote exists) + `build.sh` detached; repo path injected into Info.plist by build.sh |
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

Logs: `~/Library/Logs/IPWidget/` (launchd stderr, rebuild output).
