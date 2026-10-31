import Foundation

/// Minimal in-code localisation: English keys, Russian table, language picked from the system
/// preferred languages at launch. Works for both the swiftc build and the Xcode build without
/// .lproj resources.
enum L10n {
    /// Effective language: explicit setting ("ru"/"en") or the system's preferred language.
    static var isRussian: Bool {
        switch Settings.language {
        case "ru": return true
        case "en": return false
        default: return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("ru")
        }
    }

    static let ru: [String: String] = [
        // sizes / menu bar / tables
        "Compact": "Компактный", "Normal": "Обычный", "Large": "Большой",
        "Flag + IP": "Флаг + IP", "Flag only": "Только флаг", "Hidden": "Скрыть",
        "15 seconds": "15 секунд", "30 seconds": "30 секунд", "1 minute": "1 минута", "5 minutes": "5 минут", "15 minutes": "15 минут",
        "City (40 km)": "Город (40 км)", "Region (200 km)": "Регион (200 км)", "Country (1500 km)": "Страна (1500 км)", "Hide map": "Скрыть карту",
        "Dark glass (HUD)": "Тёмное стекло (HUD)", "Light glass (Popover)": "Светлое стекло (Popover)", "Dense (Titlebar)": "Плотное (Titlebar)",
        "ISP": "Провайдер", "DNS resolver / leak": "DNS-резолвер / утечка", "Network speed": "Скорость сети",
        "Local network": "Локальная сеть", "Wi‑Fi network name (needs Location permission)": "Имя Wi‑Fi сети (нужно разрешение «Геопозиция»)",
        "Ping": "Пинг", "Gateway (router)": "Шлюз (роутер)", "gateway": "шлюз",
        // widget texts
        "Detecting IP…": "Определяю IP…", "No network": "Нет сети", "Refresh": "Обновить", "Settings": "Настройки",
        "Open in Maps": "Открыть в Картах", "Also connected: ": "Также подключены: ",
        "Speed test…": "Тест скорости…", "Test: ↓ %@ ↑ %@ Mbps": "Тест: ↓ %@ ↑ %@ Mbps",
        "IP changed": "IP изменился", "Notifications work. Current IP: %@": "Уведомления работают. Текущий IP: %@",
        // DNS verdicts
        "home ISP resolver (%@)": "резолвер домашнего провайдера (%@)",
        "system DNS = home router %@, queries bypass the tunnel": "системный DNS = домашний роутер %@, запросы идут мимо туннеля",
        "system DNS %@ is inside the tunnel; its upstream is %@": "системный DNS %@ внутри туннеля; его upstream — %@",
        "public resolver %@; system DNS %@": "публичный резолвер %@; системный DNS %@",
        "exit ISP's resolver; system DNS %@": "резолвер провайдера выхода; системный DNS %@",
        "resolver %@ matches neither the tunnel nor a public resolver; system DNS %@": "резолвер %@ не совпадает ни с туннелем, ни с публичными; системный DNS %@",
        // menu
        "Language": "Язык", "System language": "Как в системе",
        "Size": "Размер", "Map": "Карта", "Refresh interval": "Интервал обновления", "Always dark theme": "Всегда тёмная тема",
        "Appearance": "Оформление", "Show": "Показывать", "Menu bar": "Строка меню", "Add address…": "Добавить адрес…",
        "Reset": "Сбросить", "Ping targets": "Цели пинга", "Mask IP (for demos)": "Маскировать IP (для демонстраций)",
        "Hide widget from desktop": "Скрыть виджет с рабочего стола", "On all screens": "На всех экранах",
        "Hotkey ⌃⌥I — show and copy IP": "Хоткей ⌃⌥I — показать и скопировать IP", "Notify on IP change": "Уведомлять о смене IP",
        "No sound": "Без звука", "Sound on IP change": "Звук при смене IP", "Test notification": "Тестовое уведомление",
        "Home: ": "Домашняя: ", "Not set — VPN is detected by the tunnel": "Не задана — VPN определяется по туннелю",
        "Remember current network as home": "Запомнить текущую сеть как домашнюю", "Home network": "Домашняя сеть",
        "Empty": "Пусто", "Export CSV (~/Downloads)": "Экспорт в CSV (~/Downloads)", "Clear history": "Очистить историю",
        "IP history": "История IP", "Refresh now": "Обновить сейчас", "Copy IP": "Скопировать IP",
        "Speed test (Cloudflare)": "Тест скорости (Cloudflare)", "Launch at login": "Запускать при входе",
        "Rebuild from source": "Пересобрать из исходников", "About": "О программе", "Quit": "Выйти",
        "Ping target": "Цель пинга", "IP or hostname. Measures TCP connect time to port 443.": "IP или hostname. Измеряется время TCP-соединения на порт 443.",
        "Add": "Добавить", "Cancel": "Отмена", "e.g. 9.9.9.9 or my.server.com": "например 9.9.9.9 или my.server.com",
        "Could not start the rebuild": "Не удалось запустить пересборку", "No build.sh at %@": "Нет build.sh по пути %@",
        "about.credits": """
        Внешний IP, геолокация, VPN и DNS-утечки, пинг и скорость — на рабочем столе и в строке меню.

        Данные: ipwho.is, ipinfo.io, ip-api.com (DNS), ipify.org (IPv6), Cloudflare (тест скорости).
        IP-адрес отправляется этим сервисам для определения геолокации; ничего не сохраняется на сервере разработчика.
        """,
        // tooltips: how each value is computed
        "tip.ip": "Публичный IPv4 — адрес, с которого нас видит %@ (запасной источник ipinfo.io). Обновляется каждые %@, сразу при смене сети и по кнопке ↻. Клик копирует адрес.",
        "tip.place": "Геолокация публичного IP по GeoIP-базе провайдера данных: город, регион, страна. Точность — до города; при VPN это точка выхода, а не ваше местоположение.",
        "tip.isp": "Провайдер / организация, которой принадлежит IP (из GeoIP-данных) · hostname из обратного DNS (PTR-запись адреса), если есть.",
        "tip.ipv6": "Публичный IPv6 по данным api6.ipify.org. «—» означает, что IPv6-связности нет.",
        "tip.dns": "Резолвер, который ответил на запрос уникального поддомена edns.ip-api.com (ответ не может прийти из кэша): организация, страна, IP. Вердикт об утечке — по тому, куда настроен системный DNS.",
        "tip.speed": "Трафик активного интерфейса: счётчики байт читаются раз в секунду (↓ принято, ↑ отправлено). График — последние 60 с загрузки. Тест скорости: Cloudflare, 20 МБ вниз и 8 МБ вверх.",
        "tip.local": "Интерфейс, через который идёт маршрут по умолчанию (Wi‑Fi / Ethernet / utun = туннель), его IPv4-адрес и имя Wi‑Fi сети, если разрешено. Имя VPN — у сервиса, которому принадлежит этот интерфейс.",
        "tip.ping": "Время TCP-соединения на порт 443 каждой цели (не ICMP). Показана худшая цель. Зелёный < 50 мс, оранжевый < 150 мс, красный выше.",
        "tip.time": "Время последнего успешного обновления. Интервал: %@.",
        "tip.badge.vpn.tunnel": "VPN: маршрут по умолчанию идёт через туннельный интерфейс (utun / ipsec / ppp).",
        "tip.badge.vpn.isp": "VPN: провайдер выхода отличается от запомненной домашней сети.",
        "tip.badge.home": "HOME: провайдер совпадает с запомненной домашней сетью.",
        "tip.stripe": "Полоса состояния: зелёная — всё в порядке, жёлтая — IP сменился меньше минуты назад, красная — нет сети, утечка DNS или пинг > 150 мс.",
        "tip.map": "Карта центрирована на геолокации IP. Клик открывает точку в Картах; перетаскивание двигает виджет.",
    ]

    static let en: [String: String] = [
        "about.credits": """
        Public IP, geolocation, VPN and DNS leaks, latency and throughput — on the desktop and in the menu bar.

        Data: ipwho.is, ipinfo.io, ip-api.com (DNS), ipify.org (IPv6), Cloudflare (speed test).
        Your IP address is sent to these services for geolocation; nothing is stored on the developer's side.
        """,
        "tip.ip": "Public IPv4: the address %@ sees us from (ipinfo.io as fallback). Refreshed every %@, on network changes and via ↻. Click copies it.",
        "tip.place": "Geolocation of the public IP from the data provider's GeoIP database: city, region, country. City-level accuracy; with a VPN this is the exit point, not your location.",
        "tip.isp": "ISP / organisation that owns the IP (GeoIP data) · hostname from reverse DNS (PTR record), when present.",
        "tip.ipv6": "Public IPv6 as reported by api6.ipify.org. “—” means there is no IPv6 connectivity.",
        "tip.dns": "The resolver that answered a lookup of a unique edns.ip-api.com subdomain (so the answer cannot come from a cache): organisation, country, IP. The leak verdict depends on where the system DNS points.",
        "tip.speed": "Throughput of the active interface: byte counters sampled once a second (↓ received, ↑ sent). Sparkline shows the last 60 s of download. Speed test: Cloudflare, 20 MB down and 8 MB up.",
        "tip.local": "Interface that carries the default route (Wi‑Fi / Ethernet / utun = tunnel), its IPv4 address and the Wi‑Fi name when allowed. The VPN name belongs to the service that owns this interface.",
        "tip.ping": "TCP connect time to port 443 of each target (not ICMP). The worst target is shown. Green < 50 ms, orange < 150 ms, red above.",
        "tip.time": "Time of the last successful refresh. Interval: %@.",
        "tip.badge.vpn.tunnel": "VPN: the default route goes through a tunnel interface (utun / ipsec / ppp).",
        "tip.badge.vpn.isp": "VPN: the exit ISP differs from the remembered home network.",
        "tip.badge.home": "HOME: the ISP matches the remembered home network.",
        "tip.stripe": "Status stripe: green — all good, yellow — IP changed less than a minute ago, red — offline, DNS leak or ping > 150 ms.",
        "tip.map": "Map centred on the IP geolocation. Click opens the point in Maps; dragging moves the widget.",
    ]
}

/// Translate an English key; `%@` placeholders are filled from `args`.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let s = (L10n.isRussian ? L10n.ru[key] : L10n.en[key]) ?? key
    return args.isEmpty ? s : String(format: s, arguments: args)
}
