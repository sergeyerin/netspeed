import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = Monitor()
    private let gateway = GatewayProbe()
    private let internet = InternetProbe()
    private let settings = Settings.shared
    private let updates = UpdateChecker(currentVersion: Bundle.main.version)
    private lazy var about = AboutWindow(updates: updates, settings: settings)

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
        // Both the "nothing reported" and "unrecognised" cases leave the badge
        // empty: a dash in the menu bar states nothing and costs room.
        guard let tether, tether.networkType.label != "—" else {
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
        let down = titleDown.format(s.down, unit: unit, pinned: settings.pinnedKiloScale)
        let up = titleUp.format(s.up, unit: unit, pinned: settings.pinnedKiloScale)

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
            lines = [titleDown.format(s.total, unit: unit, pinned: settings.pinnedKiloScale)]
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
        // Two points taller on one line, where the status item has the room:
        // the figures are the whole message and 11 point left them smaller
        // than the clock beside them. The two-line mode stays at 9 — two lines
        // of 10 would come to the full height of the menu bar.
        button.attributedTitle = AppDelegate.title(text, size: oneLine ? 13 : 9,
                                                   paragraph: paragraph)

        // Indicator to the right of the figures.
        //
        // The rates are padded to a constant width, so a short one carries
        // leading spaces. With the icon on the left those spaces sat between
        // the two as a hole that opened and closed with the traffic; on the
        // right they fall at the outer edge of the item, where they are
        // indistinguishable from the gap to the next thing in the menu bar.
        // Same padding, no hole.
        button.imagePosition = .imageTrailing

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

    /// The figures full size, their units a size down.
    ///
    /// The unit is the least of what this row says — it changes about once a
    /// minute and it is the same four characters either way — yet set in the
    /// same type as the number it was reading as part of it. Smaller, it steps
    /// back and the digits come forward, which is the order anyone glancing at
    /// a menu bar wants them in.
    ///
    /// Smaller and not fainter: the menu bar is translucent, its colour is
    /// whatever the desktop behind it happens to be, and over a mid-tone
    /// wallpaper half-strength text has almost no contrast left. Size is the
    /// one axis that survives any backdrop.
    ///
    /// It also sits a shade below the figures — half a point of ink, not the
    /// point and a half tried first. Reaching even that takes a small lift
    /// rather than a drop: set on a shared baseline the smaller type already
    /// hangs a full point lower, partly its metrics, partly the slash in
    /// "KB/s", which descends.
    ///
    /// A deliberate drop was tried first, after a speedometer, where km/h sits
    /// well under the number. It does not carry: there the number is forty
    /// points tall, and at twelve the same proportion detaches the unit and
    /// sets it on the floor of the menu bar.
    ///
    /// Both the step down and the lift are fractions of the type size, so the
    /// two-line mode at 9 point gets the same proportions as the single line
    /// at 13. The numbers behind them were measured on the rendered strip, not
    /// read off the font's metrics, which say nothing about the slash.
    private static let units = ["B/s", "KB/s", "MB/s", "GB/s",
                                "b/s", "Kb/s", "Mb/s", "Gb/s", "ms"]

    private static func title(_ text: String, size: CGFloat,
                              paragraph: NSParagraphStyle) -> NSAttributedString {
        let full = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .paragraphStyle: paragraph,
        ])
        let small = NSFont.monospacedSystemFont(ofSize: size * 0.77, weight: .regular)
        let drop = size * 0.023
        // The space before a unit belongs to the unit: left in the figures'
        // size it opened a monospaced gap as wide as a digit, which read as a
        // missing character rather than as spacing.
        let tighten = -size * 0.06
        let ns = text as NSString

        // The tenth is part of the figure, so it keeps the figures' baseline —
        // only the size steps down. The unit is a different thing and sits
        // slightly lower; this does not.
        var at = 0
        while at + 1 < ns.length {
            let here = ns.character(at: at)
            let next = ns.character(at: at + 1)
            let isDot = here == 46 || here == 44
            let digitBefore = at > 0 && (48...57).contains(Int(ns.character(at: at - 1)))
            if isDot, digitBefore, (48...57).contains(Int(next)) {
                full.addAttribute(.font, value: small, range: NSRange(location: at, length: 2))
                at += 2
                continue
            }
            at += 1
        }

        // Longest first, or "B/s" would claim the tail of "KB/s" and leave its
        // first letter at full size.
        for unit in units.sorted(by: { $0.count > $1.count }) {
            var from = 0
            while from < ns.length {
                let found = ns.range(of: unit, options: [],
                                     range: NSRange(location: from, length: ns.length - from))
                guard found.location != NSNotFound else { break }
                from = found.location + found.length
                // Only where the whole token is the unit: "ms" inside a word is
                // not a unit, and a longer suffix has already been styled.
                guard full.attribute(.font, at: found.location, effectiveRange: nil) as? NSFont != small,
                      found.location == 0 || ns.character(at: found.location - 1) == 32
                else { continue }
                full.addAttributes([.font: small, .baselineOffset: drop], range: found)
                // Every space before the unit, not just the one touching it:
                // the suffix is padded so "B/s" lines up with "KB/s", and a
                // padding space left at the figures' size put the width back.
                var start = found.location
                while start > 0, ns.character(at: start - 1) == 32 { start -= 1 }
                if start < found.location {
                    full.addAttribute(.font, value: small,
                                      range: NSRange(location: start,
                                                     length: found.location - start))
                    // Tightened once, on the space that actually touches the
                    // unit. Applied to each of them, the pair of padding
                    // spaces before "B/s" pulled a kern further than the
                    // single one before "KB/s", and the width drifted again.
                    full.addAttribute(.kern, value: tighten,
                                      range: NSRange(location: found.location - 1, length: 1))
                }
            }
        }
        return full
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

    @objc private func togglePinnedScale() {
        settings.pinnedKiloScale.toggle()
        // The formatters carry the current scale between ticks; left alone,
        // the old one would persist until the rate crossed a boundary.
        [titleDown, titleUp, headerDown, headerUp].forEach { $0.reset() }
        rebuildSettings()
        tick()
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

        // Four groups, because the tail of this menu had none and read as a
        // heap. What decides the grouping is who the item is about.
        //
        // First, things that happened and want an answer — a new release, a
        // phone that could be asked to share again. Both come and go, and both
        // used to appear wherever they happened to be inserted: the update row
        // between two unrelated submenus, the hotspot offer between "About"
        // and "Copy summary".
        menu.addItem(newsSeparator)
        menu.addItem(updateRow)
        menu.addItem(rejoinRow)

        // Then the two things that act on what the panel above is showing.
        menu.addItem(.separator())
        menu.addItem(trafficRoot)
        menu.addItem(actionItem("Copy summary", symbol: "doc.on.doc", action: #selector(copySummary)))

        // Then the app itself.
        menu.addItem(.separator())
        menu.addItem(settingsRoot)
        menu.addItem(aboutRoot)

        // And Quit alone, where every Mac menu keeps it.
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", symbol: "power", action: #selector(quitApp), key: "q"))
    }

    /// Hidden along with the pair it introduces: a separator with nothing
    /// under it is a line across the menu for no reason, and both rows above
    /// it are often absent at once.
    private let newsSeparator = NSMenuItem.separator()

    private func syncNewsSeparator() {
        newsSeparator.isHidden = updateRow.isHidden && rejoinRow.isHidden
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

    /// Offered only while there is nothing to connect to.
    ///
    /// The row asks the phone to switch its hotspot back on, which is a thing
    /// to want when the phone lost cell service and shut the hotspot down —
    /// the network is gone, so there is nothing on this side to rejoin. Sitting
    /// on that hotspot already, the request has no subject: it is the state
    /// the button exists to reach. It was offered anyway, and pressing it
    /// there is how the crash in 1.16 was found.
    private func rebuildRejoinRow() {
        guard HotspotConnect.isSupported, !onHotspot, let phone = HotspotConnect.knownPhone() else {
            rejoinRow.isHidden = true
            syncNewsSeparator()
            return
        }
        rejoinRow.isHidden = false
        syncNewsSeparator()
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
            syncNewsSeparator()
            return
        }
        updateRow.isHidden = false
        syncNewsSeparator()
        updateRow.title = "Update available — \(release.version)"
        updateRow.image = symbol("arrow.down.circle.fill")
        updateRow.action = #selector(openLink(_:))
        updateRow.target = self
        updateRow.representedObject = release.url.absoluteString
    }

    private let aboutRoot = NSMenuItem(title: "About NetSpeed", action: nil, keyEquivalent: "")

    /// Rebuilt whenever the menu opens, like the settings: it reports the state
    /// of the update check, which changes while the app runs.
    /// "About NetSpeed" opens a window rather than a submenu.
    ///
    /// Checking for updates takes a second or two, and a menu cannot wait: the
    /// click that started the request also closed the menu, and the answer
    /// arrived in a row nobody was looking at. A window keeps the question and
    /// the answer in one place, and has room for the thing a menu had none
    /// for — which build this actually is.
    private func rebuildAbout() {
        aboutRoot.image = symbol("info.circle")
        aboutRoot.title = Bundle.main.isRelease ? "About NetSpeed" : "About NetSpeed — local build"
        aboutRoot.action = #selector(showAbout)
        aboutRoot.target = self
        aboutRoot.submenu = nil
    }

    @objc private func showAbout() {
        about.show()
    }

    /// Turning the daily check back on looks at once rather than waiting a day.
    @objc private func openLink(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshMenu() {
        guard menuOpen else { return }
        let unit = settings.unit
        let s = monitor.speed

        header.update(state: linkState,
                      down: headerDown.format(s.down, unit: unit, padded: false,
                                              pinned: settings.pinnedKiloScale),
                      up: headerUp.format(s.up, unit: unit, padded: false,
                                            pinned: settings.pinnedKiloScale))
        // On the verdict word, where anyone wanting the answer is already
        // looking. It was briefly moved into the panel on the theory that the
        // tooltip was the pale box appearing over the chart's reading;
        // measuring the screenshot showed that box to be the desktop coming
        // through a translucent menu, which no amount of our drawing explains.
        header.toolTip = reason
        sparkline.update(history: monitor.history, unit: unit, interval: settings.interval)
        let facts = menuFacts()
        // Only a row that can actually do something answers a click.
        panel.tappable = facts.nameHidden ? [MenuContent.networkRow] : []
        panel.onTap = { [weak self] label in
            guard label == MenuContent.networkRow else { return }
            self?.handleNetworkNameTap()
        }
        panel.update(MenuContent.lines(facts, detailed: settings.showAllDetails))
        panel.frame.size = panel.intrinsicContentSize
    }

    /// What the panel shows.
    ///
    /// Gathers what the panel needs from the live monitors. The rows
    /// themselves are built in MenuContent, which the screenshot generator
    /// calls too — so a picture of the menu cannot show a layout the menu no
    /// longer has.
    private func menuFacts() -> MenuFacts {
        var f = MenuFacts()
        f.unit = settings.unit
        f.peak = monitor.recentPeak(seconds: 60, interval: settings.interval)
        f.sessionDown = monitor.sessionDown
        f.sessionUp = monitor.sessionUp
        f.uptime = monitor.uptime

        f.latencyEnabled = settings.latencyEnabled
        f.internetTarget = internet.target.title
        f.internet = internet.series
        f.captivePortal = internet.captivePortal
        f.gatewayHost = gateway.host
        f.gateway = gateway.series
        f.gatewayMethod = gateway.method.rawValue

        f.tether = tether

        if let iface = monitor.trackedInterface {
            let info = Interfaces.describe(iface, counters: monitor.counters[iface])
            f.interfaceBSD = iface
            f.interfaceName = info.displayName
            f.wifi = WiFiReader.read(interface: iface)
            f.nameHidden = Interfaces.isWiFi(iface) && f.wifi?.ssid == nil
            f.nameAccess = NetworkName.shared.state
            let addrs = Kernel.addresses(of: iface)
            f.ipv4 = addrs.v4.first
            f.ipv6 = addrs.v6.first
            f.gatewayAddress = currentGateway()
            if let v4 = f.ipv4 {
                f.hotspotWithoutType = isPersonalHotspot(v4: v4, kind: info.kind) && tether == nil
            }
            if let t = tunnel { f.tunnel = "\(t.interface) over \(iface)" }
        }

        f.showExternalIP = settings.showExternalIP
        f.externalIP = externalIP.result?.display
        f.externalPlace = externalIP.result?.place
        f.externalIPLookingUp = externalIP.fetching
        return f
    }

    private func panelLines() -> [PanelView.Line] {
        MenuContent.lines(menuFacts(), detailed: settings.showAllDetails)
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

    private func stats(_ s: RTTSeries, full: Bool = false) -> String {
        MenuContent.stats(s, full: full)
    }

    /// Whether this Mac is on a Personal Hotspot right now, over Wi-Fi or USB.
    private var onHotspot: Bool {
        if tether != nil { return true }
        guard let iface = monitor.trackedInterface else { return false }
        let kind = Interfaces.describe(iface, counters: monitor.counters[iface]).kind
        guard let v4 = Kernel.addresses(of: iface).v4.first else { return kind == .hotspotUSB }
        return isPersonalHotspot(v4: v4, kind: kind)
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
        let pinned = NSMenuItem(title: "Always kilobytes", action: #selector(togglePinnedScale),
                                keyEquivalent: "")
        pinned.target = self
        pinned.state = settings.pinnedKiloScale ? .on : .off
        pinned.toolTip = "Never switches to MB/s. Wider, but the figure keeps one meaning."
        viewMenu.addItem(pinned)

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

        // Asked for here and nowhere else: the app starts with no permissions
        // at all, and this one buys exactly one row of text.
        let names = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        switch NetworkName.shared.state {
        case .granted:
            names.title = "Network names shown"
            names.state = .on
        case .refused:
            names.title = "Network names blocked — see Location Services"
            names.action = #selector(openLocationSettings)
            names.target = self
        case .available:
            names.title = "Show network names…"
            names.action = #selector(askForNetworkNames)
            names.target = self
        }
        sub.addItem(names)
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

    /// Clicking the row does whatever is left to do: ask, or say where to go
    /// once asking is no longer possible.
    private func handleNetworkNameTap() {
        switch NetworkName.shared.state {
        case .available: askForNetworkNames()
        case .refused: openLocationSettings()
        case .granted: break
        }
    }

    @objc private func askForNetworkNames() {
        NetworkName.shared.request { [weak self] in
            // The name is cached for the length of a tick, and the cached value
            // is the placeholder macOS handed back before permission existed.
            WiFiReader.forget()
            self?.rebuildSettings()
            self?.refreshMenu()
        }
    }

    @objc private func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
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
