import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = Monitor()
    private let gateway = GatewayProbe()
    private let internet = InternetProbe()
    private let settings = Settings.shared
    private let updates = UpdateChecker(currentVersion: Bundle.main.version)

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
    /// Separate from the one-second tick: the highlight has to move far more
    /// often than the figures change, and it must stop entirely when nothing
    /// is moving so an idle Mac pays nothing for it.
    private var animation: Timer?
    private var animationPhase: Double = 0
    private var menuOpen = false
    private var menuOpenedAt: Date?
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
    private var wasOnline = true
    private var offlineSince: Date?
    private var lastRejoin = Date.distantPast
    private let message = MessageWindow()

    private let gatewayEvery: TimeInterval = 5
    private let internetEvery: TimeInterval = 10

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch claimSingleInstance() {
        case .proceed:
            break
        case .alreadyRunning(let version, let running):
            // Say so before leaving. Without a window or a Dock icon, a copy
            // that just exits is indistinguishable from one that failed to
            // start, and the running instance is a single small icon that is
            // easy to miss — which is how three of them accumulated here.
            // The app stays alive until the message is dismissed; it holds no
            // status item, so there is still only one icon in the menu bar.
            reportAlreadyRunning(version: version, running: running)
            return
        }
        Interfaces.reload()
        if let t = InternetProbe.targets.first(where: { $0.title == settings.internetTarget }) {
            internet.setTarget(t)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        buildMenu()
        rebuildAbout()
        rebuildUpdateRow()
        rebuildRejoinRow()
        rebuildDetailRow()
        rebuildTrafficRow()
        statusItem.menu = menu

        restartTimer()
        tick()
        checkForUpdates()
    }

    /// Launching an app that is already running does not start a second copy:
    /// LaunchServices sends this to the one already there instead. So a second
    /// double-click never reaches claimSingleInstance() — this is the only place
    /// it can be answered, and without an answer nothing happens at all, which
    /// is exactly how it looked.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let asked = Date()
        // Opening the menu is the good outcome: it shows where the icon is and
        // gives access in one move.
        statusItem?.button?.performClick(nil)

        // Menu tracking runs its own loop, so this lands after the menu closes.
        // Whether it opened at all is the question, not whether it is open now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, (self.menuOpenedAt ?? .distantPast) < asked else { return }
            // The click went nowhere: the icon did not fit in the menu bar.
            self.message.show(
                title: "NetSpeed is already running",
                message: "Its icon did not fit in the menu bar, so there is no way to "
                    + "reach it there. Free up room by quitting another menu bar app, or "
                    + "switch to Settings → Menu bar display → Indicator only, which takes "
                    + "a fifth of the space. You can also quit NetSpeed here.",
                action: ("Quit NetSpeed", { NSApp.terminate(nil) }))
        }
        return true
    }

    /// Runs at launch and once a day after that. The checker keeps the interval
    /// itself, so calling this on a tick costs nothing until the day is up.
    private func checkForUpdates(force: Bool = false) {
        // An explicit ask works even with the daily check switched off.
        guard force || settings.checkForUpdates else { return }
        updates.check(force: force) { [weak self] in
            self?.rebuildUpdateRow()
            self?.rebuildAbout()
            self?.refreshMenu()
        }
    }

    private enum Claim {
        case proceed
        case alreadyRunning(version: String?, running: [NSRunningApplication])
    }

    /// Decides whether this launch should carry on, and clears the way if so.
    ///
    /// Three copies had piled up here — a build, one started straight from the
    /// disk image, an installed one — each with its own status item, and once
    /// the menu bar ran out of room it silently dropped them. The symptom was
    /// not three icons but none, which reads as a crash.
    ///
    /// An older copy is superseded and shut down. A copy of the same version,
    /// or a newer one, is left alone and this launch bows out instead: its
    /// status item is already there, and replacing it would only make the icon
    /// blink and throw away the history and session totals it has collected.
    private func claimSingleInstance() -> Claim {
        guard let id = Bundle.main.bundleIdentifier else { return .proceed }
        let me = NSRunningApplication.current
        let mine = Bundle.main.version
        let started = me.launchDate ?? Date()

        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier }
        var superseded: [NSRunningApplication] = []

        for other in others {
            let theirs = other.bundleURL.flatMap(Bundle.init(url:))?.version
            switch theirs.map({ Version.compare($0, mine) }) ?? .orderedAscending {
            case .orderedDescending:
                return .alreadyRunning(version: theirs, running: [other])   // newer copy
            case .orderedSame:
                // Same version: the one that started first keeps the menu bar.
                // Without this tie-break two copies launched together would each
                // see the other and both step aside, leaving none.
                if (other.launchDate ?? .distantPast) < started {
                    return .alreadyRunning(version: theirs, running: [other])
                }
                superseded.append(other)
            case .orderedAscending:
                superseded.append(other)
            }
        }

        guard !superseded.isEmpty else { return .proceed }
        superseded.forEach { $0.terminate() }
        // A copy ignoring a polite quit still holds a status item, which is the
        // whole problem being solved here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            superseded.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
        return .proceed
    }

    private func reportAlreadyRunning(version: String?, running: [NSRunningApplication]) {
        let mine = Bundle.main.version
        var text = "Look for the signal bars in the menu bar at the top of the screen. "
        if let version, Version.compare(version, mine) == .orderedDescending {
            text = "Version \(version) is already running and this copy is \(mine), "
                + "so the newer one was left in place. " + text
        }
        // Whether the icon is actually on screen cannot be checked from here —
        // a status item appears in no window list. So the way out is offered
        // rather than diagnosed.
        text += "If it is not there, the menu bar is full and the icon did not fit; "
            + "quitting is then the only way to reach it."

        self.message.show(
            title: "NetSpeed is already running",
            message: text,
            action: ("Quit NetSpeed", { running.forEach { $0.terminate() } }),
            onClose: { NSApp.terminate(nil) })
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
        guard let iface = monitor.trackedInterface else {
            wasOnline = false
            return
        }
        let addresses = Kernel.addresses(of: iface)
        // The tunnel and the proxy settings belong to the network's identity as
        // much as the address does: switching a VPN off leaves the interface,
        // the address and the gateway untouched while changing the path — and
        // with it the external address and every latency figure.
        let id = [iface, addresses.v4.first ?? "-", currentGateway() ?? "-",
                  tunnel?.interface ?? "-", Proxies.signature()]
            .joined(separator: "|")

        // Losing a connection and getting the same one back looks identical to
        // never having moved: same interface, same address, same gateway. So the
        // link itself is watched too — otherwise the failures collected while it
        // was down went on dragging the verdict for a minute after it returned,
        // which is precisely when someone is staring at the menu asking whether
        // they are back.
        let online = !addresses.v4.isEmpty && !routes().isEmpty
        let cameBack = online && !wasOnline
        wasOnline = online

        // The SSID is tracked apart from the rest: it reads as empty now and
        // then, and a missing name must not count as "joined another network".
        var ssidChanged = false
        if let ssid = AirPort.ssidData(of: iface), !ssid.isEmpty {
            ssidChanged = lastSSID != nil && ssid != lastSSID
            lastSSID = ssid
        }

        guard id != networkID || ssidChanged || cameBack else { return }
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

    private var verdict: LinkVerdict { judgement.verdict }

    /// The verdict together with the measurement behind it, so the menu can say
    /// why rather than only what. A red icon with no stated reason sends people
    /// looking through the rows for the number that caused it — and the number
    /// is right there in the rule that fired.
    private var judgement: LinkVerdict.Judgement {
        let online = monitor.trackedInterface != nil && !routes().isEmpty
        let peak = monitor.recentPeak(seconds: 60, interval: settings.interval).down
        guard settings.latencyEnabled else {
            guard online else {
                return .init(verdict: .offline, because: "no network interface is carrying a route")
            }
            guard peak > 0 else {
                return .init(verdict: .unknown, because: "latency checks are switched off and nothing has moved yet")
            }
            return .init(verdict: .good, because: "data is moving; latency checks are switched off")
        }
        return LinkVerdict.judge(internet: internet, peakDown: peak, online: online)
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
        // A three-second peak rather than this instant: a burst should stay
        // visible long enough to be seen, and a count flickering with every
        // sample would be noise rather than information.
        let peak = monitor.recentPeak(seconds: 3, interval: settings.interval)
        let down = LinkState.chevrons(forBytesPerSecond: peak.down)
        let up = LinkState.chevrons(forBytesPerSecond: peak.up)
        guard let tether, tether.networkType != .other else {
            var state = LinkState(v)
            state.downChevrons = down
            state.upChevrons = up
            return state
        }
        return LinkState(badge: tether.networkType.label,
                         // The verdict's own glyph has to come along: it is what
                         // replaces the arrows when there is no network to move
                         // anything over. Built without it, the icon went on
                         // drawing transfer arrows while the menu right under it
                         // said Offline.
                         glyph: v.glyph,
                         tone: v.tone,
                         quality: v.quality,
                         detail: "phone: \(tether.networkType.fullName)",
                         downChevrons: down,
                         upChevrons: up)
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
            // Upload on top, download underneath, so each line sits where its
            // own arrow points. Reading order argued for download first; the
            // spatial sense is stronger and does not have to be learned.
            lines = ["↑ " + up, "↓ " + down]
        case .downOnly:
            lines = ["↓ " + down]
        case .sum:
            // No arrow of its own: the indicator beside it is already a pair of
            // them, and two sets side by side read as two different things.
            lines = [titleDown.format(s.total, unit: unit)]
        case .withPing:
            // Rates first and latency trailing the lower line. Put in front it
            // sat alone against the indicator with nothing beneath it; put on
            // its own it is a third thing competing with the pair. Here it
            // reads as a footnote to them, which is what it is.
            lines = ["↑ " + up, "↓ " + down + "  " + paddedPing()]
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
        // Two lines align left, one aligns right. Flush right looks the same
        // while the lines are equal length, which the rates are, but the moment
        // one carries latency as well the shorter line slides across and the
        // two rates stop sharing a column. Trailing spaces cannot hold it:
        // alignment ignores them. A left edge is simply fixed.
        paragraph.alignment = oneLine ? .right : .left
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
            button.image = Indicator.image(for: state, style: effective, phase: livePhase)
            syncAnimation(state: state, style: effective)
            // The same answer on the icon itself, for whoever points at it
            // before opening anything.
            let phone = tether.map { " — \($0.name): \($0.signalBars)/\(TetherDevice.maxBars) bars, battery \($0.battery)%" } ?? ""
            button.toolTip = (reason ?? state.summary) + phone
        }
    }

    // MARK: - The running highlight

    /// Three steps a second, and the crest moves exactly one mark per step.
    ///
    /// Smooth motion was the first attempt and it cost four and a half per cent
    /// of a core on top of the one per cent the whole app uses — not the
    /// drawing, which caching made free, but the assignment itself: handing the
    /// status bar a new image makes it lay the item out again, and that is
    /// roughly half a per cent per frame per second however the image was made.
    ///
    /// Discrete is not a consolation prize here. A chase light on a sign is
    /// discrete; bulbs do not slide. Stepping mark to mark is what the thing
    /// being imitated actually does, and it costs about half a per cent.
    private static let frameRate = 1.0 / 3

    private var livePhase: Double { animation == nil ? -1 : animationPhase }

    /// One full cycle, drawn once. The sequence repeats exactly, so replaying
    /// images costs an assignment per frame instead of a render.
    private var frames: [NSImage] = []
    private var frameIndex = 0

    private func syncAnimation(state: LinkState, style: IndicatorStyle) {
        // Three marks, not two. Two begins at 4 KB/s, which a Mac with every
        // window shut steps over all day — so a "only while data is moving"
        // rule written that way had the highlight running essentially always,
        // and idle cost went from one per cent of a core to two and a third.
        // From the third mark something is genuinely happening.
        let wanted = settings.animateIndicator && style != .none && state.glyph == nil
            && max(state.downChevrons, state.upChevrons) > 2
        // Any change of state invalidates the strip: a different number of lit
        // marks is a different cycle and different pictures.
        frames = []
        frameIndex = 0
        guard wanted else {
            animation?.invalidate()
            animation = nil
            animationPhase = 0
            return
        }
        guard animation == nil else { return }
        let t = Timer(timeInterval: AppDelegate.frameRate, repeats: true) { [weak self] _ in
            self?.stepAnimation()
        }
        // Common mode, or the highlight freezes the moment a menu opens.
        RunLoop.main.add(t, forMode: .common)
        animation = t
    }

    private func stepAnimation() {
        guard let button = statusItem.button, let state = lastState, let style = lastStyle else { return }
        if frames.isEmpty {
            let effective = style == .none && settings.titleMode == .hidden ? .bars : style
            // One frame per step, so the strip is the cycle itself.
            let count = Int(Indicator.cycle(for: state))
            frames = (0..<count).compactMap {
                Indicator.image(for: state, style: effective, phase: Double($0))
            }
            guard !frames.isEmpty else { return }
        }
        button.image = frames[frameIndex]
        frameIndex = (frameIndex + 1) % frames.count
    }

    @objc private func toggleAnimation() {
        settings.animateIndicator.toggle()
        if !settings.animateIndicator {
            animation?.invalidate()
            animation = nil
            animationPhase = 0
            // Redraw once without the crest, or the icon keeps whatever
            // brightness the last frame happened to leave behind.
            if let button = statusItem.button, let state = lastState, let style = lastStyle {
                button.image = Indicator.image(for: state, style: style, phase: -1)
            }
        } else if let state = lastState, let style = lastStyle {
            syncAnimation(state: state, style: style)
        }
        rebuildSettings()
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
        menuOpenedAt = Date()
        Interfaces.reload()
        rebuildSettings()
        rebuildAbout()
        rebuildUpdateRow()
        rebuildRejoinRow()
        rebuildDetailRow()
        rebuildTrafficRow()
        // Looking the address up costs an outside request, so it happens only
        // when the menu is actually opened — and only if the answer went stale.
        if settings.showExternalIP {
            externalIP.fetchIfNeeded { [weak self] in self?.refreshMenu() }
        }
        sampleTraffic()
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
        menu.addItem(detailRow)
        menu.addItem(.separator())
        menu.addItem(trafficRoot)
        menu.addItem(updateRow)
        menu.addItem(settingsRoot)
        menu.addItem(aboutRoot)
        menu.addItem(rejoinRow)
        menu.addItem(actionItem("Copy summary", symbol: "doc.on.doc", action: #selector(copySummary)))
        menu.addItem(actionItem("Quit", symbol: "power", action: #selector(quitApp), key: "q"))
    }

    private let settingsRoot = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")

    /// Switches the panel above between the summary and everything.
    private let detailRow = NSMenuItem()
    private let detailView = ToggleRowView()

    private func rebuildDetailRow() {
        let more = !settings.showAllDetails
        detailView.configure(title: more ? "Show all details" : "Show less",
                             symbol: more ? "chevron.down" : "chevron.up") { [weak self] in
            self?.toggleDetails()
        }
        if detailRow.view == nil {
            detailView.frame = NSRect(origin: .zero, size: detailView.intrinsicContentSize)
            detailRow.view = detailView
        }
    }

    private func toggleDetails() {
        settings.showAllDetails.toggle()
        rebuildDetailRow()
        refreshMenu()
    }

    // MARK: - What is using the network

    private let trafficRoot = NSMenuItem(title: "Traffic by process", action: nil, keyEquivalent: "")
    private let trafficMenu = NSMenu()
    /// Drawn, not listed as menu items. macOS paints a disabled item grey
    /// whatever colour is asked for, and every row here is disabled — there is
    /// nothing to click. The panel already solves this for the main menu.
    private let trafficPanel = PanelView()
    private var trafficSampling = false

    private func rebuildTrafficRow() {
        trafficRoot.image = symbol("list.bullet")
        trafficRoot.submenu = trafficMenu
        if trafficMenu.items.isEmpty {
            let mi = NSMenuItem()
            trafficPanel.frame = NSRect(origin: .zero, size: trafficPanel.intrinsicContentSize)
            mi.view = trafficPanel
            trafficMenu.addItem(mi)
            showTraffic(.waiting)
        }
    }

    private enum TrafficState {
        case waiting
        case ready([ProcessTraffic.Entry])
        case failed(String)
    }

    private func showTraffic(_ state: TrafficState) {
        var lines: [PanelView.Line] = []
        switch state {
        case .waiting:
            lines.append(.note("Measuring…", .neutral))
        case .failed(let why):
            lines.append(.note(why, .alert))
        case .ready(let entries) where entries.isEmpty:
            lines.append(.note("Nothing is moving enough to measure", .neutral))
        case .ready(let entries):
            let unit = settings.unit
            func row(_ e: ProcessTraffic.Entry) -> PanelView.Line {
                .kv(e.name, "↓ \(Fmt.rate(e.bytesIn, unit: unit))   ↑ \(Fmt.rate(e.bytesOut, unit: unit))")
            }
            let own = entries.filter { !ProcessTraffic.isCarrier($0.name) }
            let carriers = entries.filter { ProcessTraffic.isCarrier($0.name) }
            lines.append(contentsOf: own.prefix(8).map(row))
            if own.isEmpty { lines.append(.note("Nothing but carriers is moving", .neutral)) }
            if !carriers.isEmpty {
                // Separated rather than greyed out: these are the heaviest rows
                // on the list and the least informative, and a reader has no
                // way to tell that from the name.
                lines.append(.section("CARRIES OTHER TRAFFIC"))
                lines.append(contentsOf: carriers.prefix(4).map(row))
                lines.append(.note("A VPN tunnel or a virtual machine's network. Their bytes belong to whatever is behind them, and are counted twice here.", .neutral))
            }
        }
        trafficPanel.update(lines)
    }

    private func sampleTraffic() {
        guard !trafficSampling else { return }
        trafficSampling = true
        showTraffic(.waiting)
        ProcessTraffic.sample { [weak self] result in
            guard let self else { return }
            self.trafficSampling = false
            switch result {
            case .success(let entries): self.showTraffic(.ready(entries))
            case .failure(ProcessTraffic.Failure.unavailable):
                self.showTraffic(.failed("nettop is not available on this system"))
            case .failure: self.showTraffic(.failed("Could not read per-process traffic"))
            }
        }
    }

    /// Shown only when macOS still remembers a phone to ask.
    private let rejoinRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private func rebuildRejoinRow() {
        guard HotspotConnect.isSupported, let phone = HotspotConnect.knownPhone() else {
            rejoinRow.isHidden = true
            return
        }
        rejoinRow.isHidden = false
        rejoinRow.title = "Ask \(phone.name) to share again"
        rejoinRow.image = symbol("iphone.gen3.radiowaves.left.and.right")
        rejoinRow.action = #selector(rejoinNow)
        rejoinRow.target = self
    }

    @objc private func rejoinNow() {
        lastRejoin = Date()
        switch HotspotConnect.connect() {
        case .asked, .unsupported, .noPhoneKnown:
            break
        case .failed(let reason):
            let alert = NSAlert()
            alert.messageText = "Could not reach the phone"
            alert.informativeText = reason
            alert.runModal()
        }
    }

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
        let version = Bundle.main.version
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

        let now = NSMenuItem(title: updates.checking ? "Checking…" : "Check now",
                             action: #selector(checkNow), keyEquivalent: "")
        now.target = self
        now.isEnabled = !updates.checking
        sub.addItem(now)

        let daily = NSMenuItem(title: "Check daily", action: #selector(toggleUpdateChecks), keyEquivalent: "")
        daily.target = self
        daily.state = settings.checkForUpdates ? .on : .off
        daily.toolTip = "Asks GitHub once a day whether a newer release exists."
        sub.addItem(daily)
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

    /// Clicking a menu item closes the menu, and the answer arrives a moment
    /// later — so the result had to be hunted for by opening the menu again.
    /// An explicit ask gets an explicit answer.
    @objc private func checkNow() {
        let asked = Date()
        rebuildAbout()
        updates.check(force: true) { [weak self] in
            guard let self else { return }
            self.rebuildUpdateRow()
            self.rebuildAbout()
            self.refreshMenu()

            if let release = self.updates.newer {
                self.message.show(
                    title: "NetSpeed \(release.version) is available",
                    message: "This copy is \(Bundle.main.version).",
                    action: ("Open release page", { NSWorkspace.shared.open(release.url) }))
            } else if (self.updates.lastChecked ?? .distantPast) >= asked {
                self.message.show(
                    title: "NetSpeed is up to date",
                    message: "Version \(Bundle.main.version) is the latest release.")
            } else {
                // lastChecked only moves on a successful answer, so an unchanged
                // one means GitHub was not reached — worth saying, since the app
                // is about connections that come and go.
                self.message.show(
                    title: "Could not check for updates",
                    message: "GitHub did not answer. The connection may be down, "
                        + "or the check may have been rate-limited.")
            }
        }
    }

    /// Turning the daily check back on looks at once rather than waiting a day.
    @objc private func toggleUpdateChecks() {
        settings.checkForUpdates.toggle()
        if settings.checkForUpdates {
            checkForUpdates(force: true)
        } else {
            rebuildUpdateRow()
        }
        rebuildAbout()
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
        header.toolTip = reason
        sparkline.update(history: monitor.history, unit: unit, interval: settings.interval)
        panel.update(panelLines())
        panel.frame.size = panel.intrinsicContentSize
    }

    /// What the panel shows.
    ///
    /// Two sizes, because the panel was answering two different questions with
    /// one list. "Is my connection all right" wants six rows; "why is it
    /// behaving like this" wants the radio, the addresses and the route, and
    /// pays for them in a wall of text that buries the first answer. The short
    /// form is the default and the long one is a click away.
    private func panelLines() -> [PanelView.Line] {
        settings.showAllDetails ? detailedLines() : summaryLines()
    }

    /// Everything that answers "how is it going", and nothing that answers
    /// "how is it wired".
    private func summaryLines() -> [PanelView.Line] {
        var lines: [PanelView.Line] = []
        let unit = settings.unit
        let peak = monitor.recentPeak(seconds: 60, interval: settings.interval)

        lines.append(.kv("Peak (1 min)", "↓ \(Fmt.rate(peak.down, unit: unit))   ↑ \(Fmt.rate(peak.up, unit: unit))"))
        lines.append(.kv("Session", "↓ \(Fmt.size(monitor.sessionDown))   ↑ \(Fmt.size(monitor.sessionUp))"))

        if settings.latencyEnabled {
            let net = internet.series
            lines.append(.kv("Internet", net.last.map { Fmt.ms($0) } ?? (net.isEmpty ? "measuring…" : "no reply")))
            // Loss belongs in the short form: it is the one number that says a
            // link is failing while every other figure still looks healthy.
            lines.append(.note("   " + stats(net), .neutral))
            if gateway.host != nil {
                let gw = gateway.series
                lines.append(.kv("Access point", gw.last.map { Fmt.ms($0) } ?? (gw.isEmpty ? "measuring…" : "no reply")))
            }
        }

        // One line for the phone rather than a section: on a hotspot this is
        // the whole reason the app is open, and it compresses without loss.
        if let t = tether {
            lines.append(.kv("Phone", "\(t.networkType.fullName) · \(t.signalBars)/\(TetherDevice.maxBars) · \(t.battery)%"))
        }
        lines.append(contentsOf: networkNameLines())
        lines.append(contentsOf: externalIPLines())
        lines.append(contentsOf: warningLines())
        return lines
    }

    /// The short form plus the diagnostics: radio, addresses, route.
    private func detailedLines() -> [PanelView.Line] {
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
            if gateway.host != nil {
                let gw = gateway.series
                lines.append(.kv("Access point", gw.last.map { Fmt.ms($0) } ?? (gw.isEmpty ? "measuring…" : "no reply")))
                lines.append(.note("   over \(gateway.method.rawValue) · " + stats(gw), .neutral))
            }
        }

        if let t = tether {
            lines.append(.section("HOTSPOT PHONE"))
            lines.append(.kv("Device", t.name.isEmpty ? "—" : t.name))
            lines.append(.bars("Cellular", t.signalBars, TetherDevice.maxBars,
                               "\(t.networkType.fullName) · \(t.signalBars)/\(TetherDevice.maxBars)"))
            lines.append(.kv("Phone battery", "\(t.battery)%"))
            lines.append(.note("Reported by the phone itself — \(t.networkType.expectation)", .neutral))
        }

        lines.append(.section("CONNECTION"))
        if let iface {
            let info = Interfaces.describe(iface, counters: monitor.counters[iface])
            lines.append(.kv(info.displayName, iface))
            if let w = WiFiReader.read(interface: iface) {
                lines.append(.kv("Network", w.ssid ?? "name unavailable"))
                // Two sections, one phone: without saying so, the Wi-Fi below
                // reads as a second network that happens to be nearby, when it
                // is the hop to the phone named above.
                if let t = tether {
                    lines.append(.note("   this Wi-Fi is the hop to \(t.name), not another network",
                                       .neutral))
                }
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
        lines.append(contentsOf: externalIPLines())
        lines.append(contentsOf: warningLines())
        return lines
    }

    /// The rule that produced the colour, in the same terms as the rows below.
    ///
    /// A hint rather than a row of its own. It answers a question that is only
    /// asked when the colour is unwelcome — and a permanent line explaining a
    /// good verdict is exactly the sort of thing that made the panel a wall in
    /// the first place. It hangs on the verdict word, which is what anyone
    /// wanting the answer is already looking at.
    private var reason: String? {
        let j = judgement
        guard !j.because.isEmpty else { return nil }
        return "\(j.verdict.quality) because \(j.because)"
    }

    /// Which network this is — the one connection fact the short form keeps.
    private func networkNameLines() -> [PanelView.Line] {
        guard let iface = monitor.trackedInterface else {
            return [.note("No active interface found", .bad)]
        }
        let info = Interfaces.describe(iface, counters: monitor.counters[iface])
        let name = WiFiReader.read(interface: iface)?.ssid ?? info.displayName
        guard let t = tunnel else { return [.kv("Network", name)] }
        // A VPN changes where the traffic comes out, which is worth a line even
        // in the short form — it explains an external IP that looks wrong.
        return [.kv("Network", name), .kv("VPN", "\(t.interface) over \(iface)")]
    }

    private func externalIPLines() -> [PanelView.Line] {
        guard settings.showExternalIP else { return [] }
        if let ext = externalIP.result { return [.kv("External IP", ext.display)] }
        return [.kv("External IP", externalIP.fetching ? "looking up…" : "unavailable")]
    }

    /// Conditional and rare, so they survive into the short form: each one
    /// explains something the figures above cannot.
    private func warningLines() -> [PanelView.Line] {
        var lines: [PanelView.Line] = []
        if internet.captivePortal {
            lines.append(.note("This network requires signing in through a browser", .info))
        }
        // If "the internet" answers faster than the gateway, it is not the internet.
        if settings.latencyEnabled, gateway.host != nil,
           (internet.series.average ?? .infinity) < (gateway.series.average ?? 0) {
            lines.append(.note("Answers faster than the access point — likely a local proxy", .alert))
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
        viewMenu.addItem(.separator())
        let motion = NSMenuItem(title: "Animate the indicator",
                                action: #selector(toggleAnimation), keyEquivalent: "")
        motion.target = self
        motion.state = settings.animateIndicator ? .on : .off
        viewMenu.addItem(motion)
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
            out.append("Hotspot phone: \(t.name), \(t.networkType.fullName), \(t.signalBars)/\(TetherDevice.maxBars) bars, battery \(t.battery)%")
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
