import AppKit

/// The window shown when a launch finds another copy already holding the menu
/// bar, just before this one leaves.
///
/// Deliberately not an NSAlert. `runModal()` returns its default answer straight
/// away here: an accessory app has no Dock icon and is not frontmost, activating
/// one is asynchronous, and the modal session gives up before it lands. The
/// result was a message nobody ever saw. A plain window shows reliably — it was
/// checked on screen, which is the only way to tell the two cases apart.
final class AlreadyRunningWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var onQuit: (() -> Void)?

    /// Closes itself after a while: nobody should have to dismiss a message from
    /// an app they thought they were starting, and a window left open forever
    /// would keep a pointless process alive.
    private let lifetime: TimeInterval = 25

    func show(title: String, message: String,
              onQuit: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.onQuit = onQuit

        let padding: CGFloat = 20
        let width: CGFloat = 380

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .bold)
        heading.frame.origin = NSPoint(x: padding, y: 0)

        let body = NSTextField(wrappingLabelWithString: message)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = width - padding * 2
        body.frame.size = NSSize(width: width - padding * 2, height: body.intrinsicContentSize.height)

        let button = NSButton(title: "OK", target: self, action: #selector(dismiss))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width, 80)

        // The way out of the corner this message is most likely to find someone
        // in: the icon is running but did not fit in the menu bar, and an
        // accessory app with no icon cannot be quit by any ordinary means.
        let quit = NSButton(title: "Quit NetSpeed", target: self, action: #selector(quitOther))
        quit.bezelStyle = .rounded
        quit.sizeToFit()

        let height = padding + button.frame.height + 16 + body.frame.height + 8
            + heading.intrinsicContentSize.height + padding
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NetSpeed"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating      // an accessory app can easily end up behind everything
        window.center()

        guard let content = window.contentView else { return }
        heading.frame.origin = NSPoint(x: padding, y: height - padding - heading.intrinsicContentSize.height)
        body.frame.origin = NSPoint(x: padding, y: heading.frame.minY - 8 - body.frame.height)
        button.frame.origin = NSPoint(x: width - padding - button.frame.width, y: padding)
        quit.frame.origin = NSPoint(x: button.frame.minX - 10 - quit.frame.width, y: padding)
        [heading, body, button, quit].forEach(content.addSubview)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            self?.dismiss()
        }
    }

    @objc private func quitOther() {
        onQuit?()
        onQuit = nil
        dismiss()
    }

    @objc private func dismiss() {
        guard let onClose else { return }     // already on its way out
        self.onClose = nil
        self.onQuit = nil
        window?.close()
        window = nil
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }
}
