import AppKit

/// What this copy is, and whether a newer one exists.
///
/// A window rather than a menu, because checking takes a second or two and a
/// menu cannot wait: the old arrangement started the request, closed itself
/// with the click, and left the answer to appear in a row nobody was looking
/// at any more. Here the question and its answer are in the same place, and
/// the place stays open while the answer arrives.
///
/// It also has room to say which build this is. A local build and a release
/// carry the same version number and are otherwise indistinguishable, which is
/// how an afternoon gets spent wondering why a fix is not in the app.
final class AboutWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let updates: UpdateChecker
    private var status: NSTextField?
    private var checkButton: NSButton?
    private var getButton: NSButton?

    private let settings: Settings
    private var dailyBox: NSButton?

    init(updates: UpdateChecker, settings: Settings) {
        self.updates = updates
        self.settings = settings
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            refresh()
            return
        }

        let pad: CGFloat = 22
        let width: CGFloat = 340
        var y: CGFloat = pad

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))

        // Built bottom-up, because each row's position depends on the height of
        // the one below it and AppKit's origin is at the bottom anyway.
        let links = NSStackView(views: [
            link("Download page", "https://netspeed.biplane.cc/"),
            link("Source", "https://github.com/sergeyerin/netspeed"),
            link("biplane.cc", "https://biplane.cc/"),
        ])
        links.spacing = 14
        links.frame.origin = NSPoint(x: pad, y: y)
        links.frame.size = links.fittingSize
        content.addSubview(links)
        y += links.frame.height + 18

        // The setting lives beside the button that does the same thing by
        // hand, rather than in Settings three submenus away.
        let daily = NSButton(checkboxWithTitle: "Check daily", target: self,
                             action: #selector(toggleDaily))
        daily.sizeToFit()
        daily.frame.origin = NSPoint(x: pad, y: y)
        content.addSubview(daily)
        dailyBox = daily
        y += daily.frame.height + 12

        let check = NSButton(title: "Check for updates", target: self, action: #selector(checkNow))
        check.bezelStyle = .rounded
        check.sizeToFit()
        check.frame.origin = NSPoint(x: pad, y: y)
        content.addSubview(check)
        checkButton = check

        let get = NSButton(title: "Get it", target: self, action: #selector(openRelease))
        get.bezelStyle = .rounded
        get.sizeToFit()
        get.frame.origin = NSPoint(x: check.frame.maxX + 10, y: y)
        get.isHidden = true
        content.addSubview(get)
        getButton = get
        y += check.frame.height + 10

        let line = NSTextField(wrappingLabelWithString: "")
        line.font = .systemFont(ofSize: 12)
        line.textColor = .secondaryLabelColor
        line.preferredMaxLayoutWidth = width - pad * 2
        line.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 34)
        content.addSubview(line)
        status = line
        y += line.frame.height + 14

        let version = NSTextField(labelWithString: "Version \(Bundle.main.version)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.frame.size = version.intrinsicContentSize
        version.frame.origin = NSPoint(x: pad, y: y)
        content.addSubview(version)
        y += version.frame.height + 4

        let name = NSTextField(labelWithString: "NetSpeed")
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.frame.size = name.intrinsicContentSize
        name.frame.origin = NSPoint(x: pad, y: y)
        content.addSubview(name)
        y += name.frame.height + pad

        content.frame.size.height = y
        if let icon = NSApp.applicationIconImage {
            let box = NSImageView(frame: NSRect(x: width - pad - 54, y: content.frame.height - pad - 54,
                                                width: 54, height: 54))
            box.image = icon
            content.addSubview(box)
        }

        let w = NSWindow(contentRect: content.frame,
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About NetSpeed"
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w

        refresh()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// A borderless button looks like a link and behaves like one, except for
    /// the cursor: AppKit gives a pointing hand to nothing by default, so a
    /// link that leaves the arrow alone reads as decoration.
    private final class LinkButton: NSButton {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private func link(_ title: String, _ address: String) -> NSButton {
        let b = LinkButton(title: title, target: self, action: #selector(openLink(_:)))
        b.isBordered = false
        b.contentTintColor = .linkColor
        b.identifier = NSUserInterfaceItemIdentifier(address)
        b.sizeToFit()
        return b
    }

    /// The whole state of the window in one place, called whenever any of it
    /// can have changed.
    private func refresh() {
        guard let status else { return }
        var lines: [String] = []

        // The build line comes first because it changes what the rest means:
        // there is no point comparing a local build against the releases.
        if !Bundle.main.isRelease {
            lines.append("Local build — \(Bundle.main.buildSource ?? "unknown source")")
        }

        if updates.checking {
            lines.append("Checking…")
        } else if let release = updates.newer {
            lines.append("\(release.version) is available.")
        } else if let checked = updates.lastChecked {
            lines.append("Up to date, as of \(AboutWindow.when.string(from: checked)).")
        } else {
            lines.append("Not checked yet.")
        }

        status.stringValue = lines.joined(separator: "\n")
        status.textColor = Bundle.main.isRelease ? .secondaryLabelColor : .labelColor
        checkButton?.isEnabled = !updates.checking
        dailyBox?.state = settings.checkForUpdates ? .on : .off
        getButton?.isHidden = updates.newer == nil
    }

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    @objc private func toggleDaily() {
        settings.checkForUpdates.toggle()
        if settings.checkForUpdates { checkNow() } else { refresh() }
    }

    @objc private func checkNow() {
        updates.check(force: true) { [weak self] in self?.refresh() }
        refresh()
    }

    @objc private func openRelease() {
        guard let url = updates.newer?.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let address = sender.identifier?.rawValue, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        status = nil
        checkButton = nil
        getButton = nil
        dailyBox = nil
    }
}
