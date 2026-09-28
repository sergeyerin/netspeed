import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = Monitor()
    private let gateway = GatewayProbe()
    private let internet = InternetProbe()
    private let settings = Settings.shared
    private let updates = UpdateChecker(
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")

    private let menu = NSMenu()
    private let header = HeaderView()
    private let sparkline = SparklineView()
    private let panel = PanelView()

    /// One formatter per slot: each keeps its own unit, so the download line
    /// does not change scale just because the upload line did.
    private let titleDown = RateFormatter()
    private let titleUp = RateFormatter()
    private let headerDown = RateFormatter()
    private let headerUp = RateFormatter()

    private var timer: Timer?
    private var menuOpen = false
    private var lastGatewayProbe = Date.distantPast
    private var lastInternetProbe = Date.distantPast
    private let externalIP = ExternalIP()

    private var lastTitle: String?
    private var lastStyle: IndicatorStyle?
    private var cachedRoutes: [DefaultRoute]?
    private var tether: TetherDevice?
    private var lastState: LinkState?
    private var networkID: String?
    private var lastSSID: Data?

    private let gatewayEvery: TimeInterval = 5
    private let internetEvery: TimeInterval = 10

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Interfaces.reload()
        if let t = InternetProbe.targets.first(where: { $0.title == settings.internetTarget }) {
            internet.setTarget(t)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        buildMenu()
        rebuildAbout()
        rebuildUpdateRow()
        statusItem.menu = menu

        restartTimer()
        tick()
        checkForUpdates()
    }

    /// Runs at launch and once a day after that. The checker keeps the interval
    /// itself, so calling this on a tick costs nothing until the day is up.
    private func checkForUpdates(force: Bool = false) {
        guard settings.checkForUpdates else { return }
        updates.check(force: force) { [weak self] in
            self?.rebuildUpdateRow()
            self?.refreshMenu()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: settings.interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = settings.interval * 0.2
        // .common keeps the data flowing while the menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Polling tick

    private func tick() {
        monitor.tick(pinned: settings.pinnedInterface)
        cachedRoutes = nil
        gateway.setHost(currentGateway())
        tether = readTether()
        noticeNetworkChange()

        if settings.latencyEnabled {
            let now = Date()
            if now.timeIntervalSince(lastGatewayProbe) >= gatewayEvery {
                lastGatewayProbe = now
                gateway.probe { [weak self] in self?.refreshMenu() }
            }
            if now.timeIntervalSince(lastInternetProbe) >= internetEvery {
                lastInternetProbe = now
                internet.probe { [weak self] in
                    self?.refreshTitle()
                    self?.refreshMenu()
                }
            }
        }

        refreshTitle()
        refreshMenu()
    }

    /// Identity of the network in use. Joining a different Wi-Fi keeps the same
    /// interface, so without this the measurements from the previous network
    /// would live on: a burst of failures during the switch kept the indicator
    /// red long after the new link was fine.
    private func noticeNetworkChange() {
        guard let iface = monitor.trackedInterface else { return }
        let id = [iface, Kernel.addresses(of: iface).v4.first ?? "-", currentGateway() ?? "-"]
            .joined(separator: "|")

        // The SSID is tracked apart from the rest: it reads as empty now and
        // then, and a missing name must not count as "joined another network".
        var ssidChanged = false
        if let ssid = AirPort.ssidData(of: iface), !ssid.isEmpty {
            ssidChanged = lastSSID != nil && ssid != lastSSID
            lastSSID = ssid
        }

        guard id != networkID || ssidChanged else { return }
        let firstRun = networkID == nil
        networkID = id
        guard !firstRun else { return }

        internet.reset()
        gateway.series.reset()
        externalIP.invalidate()
        lastInternetProbe = .distantPast
        lastGatewayProbe = .distantPast
        lastState = nil
    }

    /// Dumping the routing table is not free and a tick asks for it several
    /// times, so the result is cached for the tick and dropped at the next one.
    private func routes() -> [DefaultRoute] {
        if let cachedRoutes { return cachedRoutes }
        let r = Kernel.defaultRoutes()
        cachedRoutes = r
        return r
    }

    private func currentGateway() -> String? {
        guard let iface = monitor.trackedInterface else { return nil }
        return routes().first(where: { $0.interface == iface })?.gateway
    }

    private var verdict: LinkVerdict {
        let online = monitor.trackedInterface != nil && !routes().isEmpty
        guard settings.latencyEnabled else {
            guard online else { return .offline }
            return monitor.recentPeak(seconds: 60, interval: settings.interval).down > 0 ? .good : .unknown
        }
        return LinkVerdict.evaluate(internet: internet,
                                    peakDown: monitor.recentPeak(seconds: 60, interval: settings.interval).down,
                                    online: online)
    }

    /// macOS keeps the last tethering device in the dynamic store even after the
    /// phone is gone, so the data is only used while actually on its hotspot.
    private func readTether() -> TetherDevice? {
        guard let iface = monitor.trackedInterface,
              let v4 = Kernel.addresses(of: iface).v4.first,
              isPersonalHotspot(v4: v4, kind: Interfaces.describe(iface, counters: monitor.counters[iface]).kind),
              let device = HotspotReader.read(interface: iface) else { return nil }
        return device
    }

    /// What the indicator shows: the phone's own cellular readout when tethered,
    /// the measured estimate otherwise. The color always comes from the measured
    /// side, so "5G" in orange reads as "says 5G, behaves like weak 4G".
    private var linkState: LinkState {
        let v = verdict
        guard let tether, tether.networkType != .other else { return LinkState(v) }
        return LinkState(badge: tether.networkType.label,
                         level: tether.signalBars,
                         tone: v.tone,
                         quality: v.quality,
                         detail: "phone: \(tether.networkType.label)")
    }

    private var tunnel: DefaultRoute? {
        routes().first {
            Interfaces.describe($0.interface, counters: monitor.counters[$0.interface]).kind == .tunnel
        }
    }

    // MARK: - Menu bar title

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        let unit = settings.unit
        let s = monitor.speed
        let down = titleDown.format(s.down, unit: unit)
        let up = titleUp.format(s.up, unit: unit)

        var lines: [String]
        switch settings.titleMode {
        case .both:
            lines = ["↓ " + down, "↑ " + up]
        case .downOnly:
            lines = ["↓ " + down]
        case .sum:
            lines = ["⇅ " + titleDown.format(s.total, unit: unit)]
        case .withPing:
            lines = ["↓ " + down, "↑ " + up + "  " + paddedPing()]
        case .hidden:
            lines = []
        }

        let oneLine = lines.count <= 1
        let text = lines.joined(separator: "\n")
        let state = linkState
        let style = settings.indicatorStyle

        // Redrawing the status bar is the costly part of a tick, so it only
        // happens when the text or the state actually changed.
        guard text != lastTitle || state != lastState || style != lastStyle else { return }
        lastTitle = text

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        if !oneLine {
            paragraph.maximumLineHeight = 10
            paragraph.minimumLineHeight = 10
        }
        // A fully monospaced face, not merely monospaced digits: the padding that
        // holds the width constant is made of spaces, and those must align too.
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: oneLine ? 11 : 9, weight: .regular),
            .paragraphStyle: paragraph,
        ])

        if state != lastState || style != lastStyle {
            lastState = state
            lastStyle = style
            let effective = style == .none && settings.titleMode == .hidden ? .bars : style
            button.image = Indicator.image(for: state, style: effective)
            button.toolTip = tether.map { "\(state.summary) — \($0.name): \($0.signalBars)/\(TetherDevice.maxBars) bars, battery \($0.battery)%" }
                ?? state.summary
        }
    }

    /// Latency padded to a constant width, for the same reason as the rates.
    private func paddedPing() -> String {
        let text = settings.latencyEnabled
            ? (internet.series.last.map { Fmt.ms($0) } ?? "—")
            : "off"
        return String(repeating: " ", count: max(0, 6 - text.count)) + text
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        Interfaces.reload()
        rebuildSettings()
        rebuildAbout()
        rebuildUpdateRow()
        // Looking the address up costs an outside request, so it happens only
        // when the menu is actually opened — and only if the answer went stale.
        if settings.showExternalIP {
            externalIP.fetchIfNeeded { [weak self] in self?.refreshMenu() }
        }
        refreshMenu()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    /// The menu structure is fixed: everything that changes lives inside the three
    /// views, so a tick rebuilds nothing and open submenus stay open.
    private func buildMenu() {
        menu.delegate = self
        menu.removeAllItems()
        for view in [header, sparkline, panel] as [NSView] {
            let mi = NSMenuItem()
            view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
            mi.view = view
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(updateRow)
        menu.addItem(settingsRoot)
        menu.addItem(aboutRoot)
        menu.addItem(actionItem("Copy summary", symbol: "doc.on.doc", action: #selector(copySummary)))
        menu.addItem(actionItem("Quit", symbol: "power", action: #selector(quitApp), key: "q"))
    }

    private let settingsRoot = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")

    /// Sits in the main menu rather than inside About: an update nobody finds is
    /// the same as no update. Hidden entirely while there is nothing to say.
    private let updateRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private func rebuildUpdateRow() {
        guard let release = updates.newer else {
            updateRow.isHidden = true
            return
        }
        updateRow.isHidden = false
        updateRow.title = "Update available — \(release.version)"
        updateRow.image = symbol("arrow.down.circle.fill")
        updateRow.action = #selector(openLink(_:))
        updateRow.target = self
        updateRow.representedObject = release.url.absoluteString
    }

    private let aboutRoot = NSMenuItem(title: "About NetSpeed", action: nil, keyEquivalent: "")

    /// Rebuilt whenever the menu opens, like the settings: it reports the state
    /// of the update check, which changes while the app runs.
    private func rebuildAbout() {
        let root = aboutRoot
        root.image = symbol("info.circle")
        let sub = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // Greyed out on purpose: a version is a caption, not something to click.
        let state: String
        if !settings.checkForUpdates {
            state = ""
        } else if updates.checking {
            state = " — checking…"
        } else if let release = updates.newer {
            state = " — \(release.version) available"
        } else if updates.lastChecked != nil {
            state = " — up to date"
        } else {
            state = ""
        }
        let label = NSMenuItem(title: "Version \(version)\(state)", action: nil, keyEquivalent: "")
        label.isEnabled = false
        sub.addItem(label)

        let check = NSMenuItem(title: "Check for updates", action: #selector(checkNow), keyEquivalent: "")
        check.target = self
        check.state = settings.checkForUpdates ? .on : .off
        check.toolTip = "Asks GitHub once a day whether a newer release exists."
        sub.addItem(check)
        sub.addItem(.separator())
        for (title, url) in [("Download page — netspeed.biplane.cc", "https://netspeed.biplane.cc/"),
                             ("Other projects — biplane.cc", "https://biplane.cc/"),
                             ("Source on GitHub", "https://github.com/sergeyerin/netspeed")] {
            let mi = NSMenuItem(title: title, action: #selector(openLink(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = url
            sub.addItem(mi)
        }
        root.submenu = sub
    }

    /// The checkbox turns the daily check on and off; turning it on looks at
    /// once rather than waiting for tomorrow.
    @objc private func checkNow() {
        settings.checkForUpdates.toggle()
        if settings.checkForUpdates {
            checkForUpdates(force: true)
        } else {
            rebuildUpdateRow()
        }
        refreshMenu()
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshMenu() {
        guard menuOpen else { return }
        let unit = settings.unit
        let s = monitor.speed

        header.update(state: linkState,
                      down: headerDown.format(s.down, unit: unit, padded: false),
                      up: headerUp.format(s.up, unit: unit, padded: false))
        sparkline.update(history: monitor.history, unit: unit)
        panel.update(panelLines())
        panel.frame.size = panel.intrinsicContentSize
    }

    private func panelLines() -> [PanelView.Line] {
        var lines: [PanelView.Line] = []
        let unit = settings.unit
        let iface = monitor.trackedInterface
        let peak = monitor.recentPeak(seconds: 60, interval: settings.interval)

        lines.append(.kv("Peak (1 min)", "↓ \(Fmt.rate(peak.down, unit: unit))   ↑ \(Fmt.rate(peak.up, unit: unit))"))
        lines.append(.kv("Session", "↓ \(Fmt.size(monitor.sessionDown))   ↑ \(Fmt.size(monitor.sessionUp))"))
        lines.append(.kv("Uptime", Fmt.duration(monitor.uptime)))

        if settings.latencyEnabled {
            lines.append(.section("LATENCY"))
            let net = internet.series
            lines.append(.kv("Internet (\(internet.target.title))",
                             net.last.map { Fmt.ms($0) } ?? (net.isEmpty ? "measuring…" : "no reply")))
            lines.append(.note("   " + stats(net), .neutral))
            if internet.captivePortal {
                lines.append(.note("This network requires signing in through a browser", .info))
            }
            if gateway.host != nil {
                let gw = gateway.series
                lines.append(.kv("Access point", gw.last.map { Fmt.ms($0) } ?? (gw.isEmpty ? "measuring…" : "no reply")))
                lines.append(.note("   over \(gateway.method.rawValue) · " + stats(gw), .neutral))
                // If "the internet" answers faster than the gateway, it is not the internet.
                if (net.average ?? .infinity) < (gw.average ?? 0) {
                    lines.append(.note("Answers faster than the access point — likely a local proxy", .alert))
                }
            }
        }

        if let t = tether {
            lines.append(.section("HOTSPOT PHONE"))
            lines.append(.kv("Device", t.name.isEmpty ? "—" : t.name))
            lines.append(.bars("Cellular", t.signalBars, TetherDevice.maxBars,
                               "\(t.networkType.label) · \(t.signalBars)/\(TetherDevice.maxBars)"))
            lines.append(.kv("Phone battery", "\(t.battery)%"))
            lines.append(.note("Reported by the phone itself — \(t.networkType.expectation)", .neutral))
        }

        lines.append(.section("CONNECTION"))
        if let iface {
            let info = Interfaces.describe(iface, counters: monitor.counters[iface])
            lines.append(.kv(info.displayName, iface))
            if let w = WiFiReader.read(interface: iface) {
                lines.append(.kv("Network", w.ssid ?? "name unavailable"))
                lines.append(.bars("Wi-Fi signal", w.quality.bars, 5, "\(w.rssi) dBm · SNR \(w.snr) dB"))
                lines.append(.kv("Link rate", "\(Int(w.txRate)) Mbit/s"))
                lines.append(.kv("Channel", "\(w.channel) · \(w.band) · \(w.width)"))
                lines.append(.note("   \(w.phy) · \(w.security) · noise \(w.noise) dBm", .neutral))
            }
            let addrs = Kernel.addresses(of: iface)
            if let v4 = addrs.v4.first {
                lines.append(.kv("IP", v4))
                if isPersonalHotspot(v4: v4, kind: info.kind), tether == nil {
                    lines.append(.note("Personal Hotspot: the cellular type is only visible on the phone", .neutral))
                }
            }
            if let gw = currentGateway() { lines.append(.kv("Gateway", gw)) }
            if let v6 = addrs.v6.first { lines.append(.kv("IPv6", v6)) }
        } else {
            lines.append(.note("No active interface found", .bad))
        }
        if let t = tunnel {
            lines.append(.kv("VPN", "\(t.interface) over \(iface ?? "?")"))
        }
        if settings.showExternalIP {
            if let ext = externalIP.result {
                lines.append(.kv("External IP", ext.display))
            } else {
                lines.append(.kv("External IP", externalIP.fetching ? "looking up…" : "unavailable"))
            }
        }

        return lines
    }

    /// Short form for the menu panel, full form for the copied summary.
    private func stats(_ s: RTTSeries, full: Bool = false) -> String {
        var parts: [String] = []
        if let a = s.average { parts.append("avg \(Fmt.ms(a))") }
        if full, let b = s.best { parts.append("best \(Fmt.ms(b))") }
        if let j = s.jitter { parts.append("jitter \(Fmt.ms(j))") }
        parts.append("loss \(s.lossPercent)%")
        return parts.joined(separator: " · ")
    }

    private func isPersonalHotspot(v4: String, kind: LinkKind?) -> Bool {
        if kind == .hotspotUSB { return true }
        // iOS always hands out 172.20.10.0/28 — the most reliable hotspot marker.
        return v4.hasPrefix("172.20.10.")
    }

    // MARK: - Settings

    private func rebuildSettings() {
        let sub = NSMenu()

        let ifaceMenu = NSMenu()
        ifaceMenu.addItem(choice("Auto" + (settings.pinnedInterface == nil ? " (\(monitor.trackedInterface ?? "—"))" : ""),
                                 value: "", selected: settings.pinnedInterface == nil,
                                 action: #selector(pickInterface(_:))))
        ifaceMenu.addItem(.separator())
        for c in Interfaces.candidates(counters: monitor.counters) {
            let mi = choice("\(c.displayName) · \(c.bsd)", value: c.bsd,
                            selected: settings.pinnedInterface == c.bsd, action: #selector(pickInterface(_:)))
            mi.image = symbol(c.kind.symbol)
            ifaceMenu.addItem(mi)
        }
        sub.addItem(submenu("Interface", ifaceMenu))

        let viewMenu = NSMenu()
        for m in TitleMode.allCases {
            viewMenu.addItem(choice(m.title, value: m.rawValue, selected: settings.titleMode == m,
                                    action: #selector(pickTitleMode(_:))))
        }
        viewMenu.addItem(.separator())
        for st in IndicatorStyle.allCases {
            viewMenu.addItem(choice(st.title, value: st.rawValue, selected: settings.indicatorStyle == st,
                                    action: #selector(pickIndicator(_:))))
        }
        viewMenu.addItem(.separator())
        for u in [RateUnit.bytes, .bits] {
            viewMenu.addItem(choice(u.title, value: u.rawValue, selected: settings.unit == u,
                                    action: #selector(pickUnit(_:))))
        }
        sub.addItem(submenu("Menu bar display", viewMenu))

        let rateMenu = NSMenu()
        for v in [0.5, 1.0, 2.0, 5.0] {
            rateMenu.addItem(choice(v < 1 ? "\(Int(v * 1000)) ms" : "\(Int(v))s", value: v,
                                    selected: abs(settings.interval - v) < 0.01,
                                    action: #selector(pickInterval(_:))))
        }
        sub.addItem(submenu("Update interval", rateMenu))

        let latMenu = NSMenu()
        let toggle = NSMenuItem(title: "Measure latency", action: #selector(toggleLatency), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.latencyEnabled ? .on : .off
        latMenu.addItem(toggle)
        latMenu.addItem(.separator())
        for t in InternetProbe.targets {
            latMenu.addItem(choice("Check via \(t.title)", value: t.title,
                                   selected: internet.target.title == t.title, action: #selector(pickTarget(_:))))
        }
        sub.addItem(submenu("Latency", latMenu))

        sub.addItem(.separator())
        let extIP = NSMenuItem(title: "Show external IP", action: #selector(toggleExternalIP), keyEquivalent: "")
        extIP.target = self
        extIP.state = settings.showExternalIP ? .on : .off
        sub.addItem(extIP)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sub.addItem(login)

        settingsRoot.image = symbol("gearshape")
        settingsRoot.submenu = sub
    }

    // MARK: - Actions

    @objc private func pickInterface(_ sender: NSMenuItem) {
        let bsd = sender.representedObject as? String ?? ""
        settings.pinnedInterface = bsd.isEmpty ? nil : bsd
        tick()
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        settings.interval = v
        restartTimer()
    }

    @objc private func pickUnit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let u = RateUnit(rawValue: raw) else { return }
        settings.unit = u
        lastTitle = nil
        refreshTitle()
        refreshMenu()
    }

    @objc private func pickTitleMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = TitleMode(rawValue: raw) else { return }
        settings.titleMode = m
        lastTitle = nil
        refreshTitle()
    }

    @objc private func pickIndicator(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = IndicatorStyle(rawValue: raw) else { return }
        settings.indicatorStyle = st
        statusItem.button?.image = nil
        lastStyle = nil
        lastState = nil
        refreshTitle()
    }

    @objc private func toggleLatency() {
        settings.latencyEnabled.toggle()
        if settings.latencyEnabled {
            lastGatewayProbe = .distantPast
            lastInternetProbe = .distantPast
        } else {
            internet.reset()
            gateway.series.reset()
        }
        tick()
    }

    @objc private func pickTarget(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let t = InternetProbe.targets.first(where: { $0.title == title }) else { return }
        internet.setTarget(t)
        settings.internetTarget = title
        lastInternetProbe = .distantPast
        tick()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change the launch-at-login setting"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc private func toggleExternalIP() {
        settings.showExternalIP.toggle()
        if settings.showExternalIP {
            externalIP.fetchIfNeeded { [weak self] in self?.refreshMenu() }
        } else {
            externalIP.invalidate()
        }
        refreshMenu()
    }

    @objc private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText(), forType: .string)
    }

    private func summaryText() -> String {
        var out: [String] = ["NetSpeed summary", "Link: \(linkState.summary)"]
        if let iface = monitor.trackedInterface {
            let info = Interfaces.describe(iface, counters: monitor.counters[iface])
            out.append("Interface: \(info.displayName) (\(iface))")
            let addrs = Kernel.addresses(of: iface)
            if let v4 = addrs.v4.first { out.append("IP: \(v4)") }
            if let gw = currentGateway() { out.append("Gateway: \(gw)") }
            if let w = WiFiReader.read(interface: iface) {
                out.append("Wi-Fi: \(w.ssid ?? "—"), \(w.rssi) dBm, noise \(w.noise), SNR \(w.snr) dB, link \(Int(w.txRate)) Mbit/s, channel \(w.channel) (\(w.band), \(w.width)), \(w.phy)")
            }
        }
        if let t = tether {
            out.append("Hotspot phone: \(t.name), \(t.networkType.label), \(t.signalBars)/\(TetherDevice.maxBars) bars, battery \(t.battery)%")
        }
        if let t = tunnel { out.append("VPN: \(t.interface)") }
        out.append("Speed: ↓ \(Fmt.rateBoth(monitor.speed.down)) / ↑ \(Fmt.rateBoth(monitor.speed.up))")
        let peak = monitor.recentPeak(seconds: 60, interval: settings.interval)
        out.append("Peak (1 min): ↓ \(Fmt.rateBoth(peak.down)) / ↑ \(Fmt.rateBoth(peak.up))")
        if settings.latencyEnabled {
            out.append("To the internet (\(internet.target.title)): " + stats(internet.series, full: true))
            if let host = gateway.host {
                out.append("To the access point \(host) over \(gateway.method.rawValue): " + stats(gateway.series, full: true))
            }
        }
        if let ext = externalIP.result { out.append("External IP: \(ext.display)") }
        out.append("Session: ↓ \(Fmt.size(monitor.sessionDown)) / ↑ \(Fmt.size(monitor.sessionUp)) over \(Fmt.duration(monitor.uptime))")
        return out.joined(separator: "\n")
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Helpers

    private func actionItem(_ title: String, symbol name: String? = nil, action: Selector?, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let name { mi.image = symbol(name) }
        mi.target = self
        mi.isEnabled = action != nil
        return mi
    }

    private func choice(_ title: String, value: Any, selected: Bool, action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = value
        mi.state = selected ? .on : .off
        return mi
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        return mi
    }

    private var symbolCache: [String: NSImage] = [:]

    private func symbol(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        img.isTemplate = true
        symbolCache[name] = img
        return img
    }
}
