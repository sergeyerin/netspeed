import AppKit

/// Content width of the menu. Every view lines up on this grid.
enum Layout {
    static let width: CGFloat = 336
    static let pad: CGFloat = 14
}

/// Menu header: the verdict and two large speed figures.
///
/// Drawn by hand rather than assembled from NSMenuItems: the system paints
/// disabled menu items grey whatever color is set on them, which makes the data
/// unreadable. Inside an own view, color and typography stay under control.
final class HeaderView: NSView {
    private var state = LinkState(.unknown)
    private var down = ""
    private var up = ""

    // One row now, so a third of the former height. The figures set it: they
    // are the tallest thing in it.
    override var intrinsicContentSize: NSSize { NSSize(width: Layout.width, height: 36) }
    override var isFlipped: Bool { true }

    private static let qualityFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let detailFont = NSFont.systemFont(ofSize: 12)

    func update(state: LinkState, down: String, up: String) {
        guard state != self.state || down != self.down || up != self.up else { return }
        self.state = state
        self.down = down
        self.up = up
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // No indicator here. It sat directly below the one in the menu bar,
        // saying the same thing a few points lower and, since the chase only
        // runs on the status item, saying it worse. Its colour is on the
        // verdict word and its chevron count is in the figures beside it.
        //
        // Four type sizes meet on this row, so everything is placed from one
        // baseline rather than from the top: aligning tops would sit the small
        // words visibly above the figures.
        let baseline: CGFloat = 23

        // The verdict leads, in the tone color; the qualifier follows in plain
        // ink. Repeating the menu bar label here would say the same thing twice.
        var x = Layout.pad
        let quality = NSAttributedString(string: state.quality, attributes: [
            .font: HeaderView.qualityFont,
            .foregroundColor: state.tone.color,
        ])
        quality.draw(at: NSPoint(x: x, y: baseline - HeaderView.qualityFont.ascender))
        x += quality.size().width + 6

        // Right-aligned, as a pair, so the two of them keep a block of their own
        // and the words to their left get whatever is left.
        let downWidth = rateWidth("↓", down)
        let upWidth = rateWidth("↑", up)
        let gap: CGFloat = 14
        let ratesLeft = Layout.width - Layout.pad - upWidth - gap - downWidth
        drawRate("↓", down, color: Flow.down.ink, baseline: baseline, left: ratesLeft)
        drawRate("↑", up, color: Flow.up.ink, baseline: baseline,
                 left: Layout.width - Layout.pad - upWidth)

        // Whatever room the figures leave. It truncates rather than overlapping
        // them: "Sign-in needed" beside a pair of four-figure rates does not fit
        // on any width this menu has.
        let room = ratesLeft - 10 - x
        if !state.detail.isEmpty, room > 24 {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: "(\(state.detail))", attributes: [
                .font: HeaderView.detailFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]).draw(in: NSRect(x: x, y: baseline - HeaderView.detailFont.ascender,
                               width: room, height: 16))
        }
    }

    private func rateAttributes(_ color: NSColor) -> ([NSAttributedString.Key: Any], [NSAttributedString.Key: Any]) {
        ([.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: color],
         [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor])
    }

    private func drawRate(_ arrow: String, _ value: String, color: NSColor,
                          baseline: CGFloat, left: CGFloat) {
        let (arrowAttrs, valueAttrs) = rateAttributes(color)
        let arrowFont = arrowAttrs[.font] as! NSFont
        let valueFont = valueAttrs[.font] as! NSFont
        let a = NSAttributedString(string: arrow, attributes: arrowAttrs)
        a.draw(at: NSPoint(x: left, y: baseline - arrowFont.ascender))
        NSAttributedString(string: value, attributes: valueAttrs)
            .draw(at: NSPoint(x: left + a.size().width + 4, y: baseline - valueFont.ascender))
    }

    private func rateWidth(_ arrow: String, _ value: String) -> CGFloat {
        let (arrowAttrs, valueAttrs) = rateAttributes(.labelColor)
        return NSAttributedString(string: arrow, attributes: arrowAttrs).size().width + 4
            + NSAttributedString(string: value, attributes: valueAttrs).size().width
    }
}

/// Label-and-value table for the details: latency, Wi-Fi, addresses.
final class PanelView: NSView {
    enum Line {
        case section(String)             // group heading
        case kv(String, String)          // label left, value right
        case bars(String, Int, Int, String)   // label, filled, total, value
        case note(String, Tone)          // explanation or warning

        var height: CGFloat {
            switch self {
            case .section: return 24
            case .kv, .bars: return 19
            case .note(let text, _): return Line.noteHeight(text)
            }
        }

        static let noteFont = NSFont.systemFont(ofSize: 11)

        /// Notes wrap by word: truncating them with an ellipsis would cut away
        /// exactly the part the line exists to say.
        static func noteHeight(_ text: String) -> CGFloat {
            let width = Layout.width - Layout.pad * 2
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let rect = NSAttributedString(string: text, attributes: [.font: noteFont, .paragraphStyle: style])
                .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading])
            return ceil(rect.height) + 4
        }
    }

    private var lines: [Line] = []

    /// Labels whose row answers a click, and what to do about it.
    ///
    /// Marked by label rather than by index because the rows come and go with
    /// the state: an index would point at a different fact a second later.
    var tappable: Set<String> = []
    var onTap: ((String) -> Void)?
    private var rowFrames: [(label: String, rect: NSRect)] = []
    private var hovered: String?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: lines.reduce(4) { $0 + $1.height } + 6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    private func label(at point: NSPoint) -> String? {
        rowFrames.first { $0.rect.contains(point) }?.label
    }

    override func mouseMoved(with event: NSEvent) {
        let found = label(at: convert(event.locationInWindow, from: nil))
        guard found != hovered else { return }
        hovered = found
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let label = label(at: convert(event.locationInWindow, from: nil)) else { return }
        onTap?(label)
    }

    func update(_ new: [Line]) {
        let changed = new.count != lines.count || zip(new, lines).contains { !$0.isSame(as: $1) }
        guard changed else { return }
        let resize = new.count != lines.count
        lines = new
        if resize {
            invalidateIntrinsicContentSize()
            // A menu does not consult a hosted view's intrinsic size on its
            // own, so the frame has to be set for the menu to find room for it.
            // Without this a panel that grew or shrank while the menu was open
            // kept the old height until the menu was closed and opened again.
            setFrameSize(intrinsicContentSize)
            enclosingMenuItem?.menu?.update()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        rowFrames.removeAll(keepingCapacity: true)
        var y: CGFloat = 4
        for line in lines {
            switch line {
            case .section(let title):
                NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .kern: 0.6,
                ]).draw(at: NSPoint(x: Layout.pad, y: y + 7))
            case .kv(let label, let value):
                if tappable.contains(label) {
                    let row = NSRect(x: 0, y: y, width: Layout.width, height: line.height)
                    rowFrames.append((label, row))
                    if hovered == label {
                        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).setFill()
                        NSBezierPath(roundedRect: row.insetBy(dx: 5, dy: 0),
                                     xRadius: 4, yRadius: 4).fill()
                    }
                }
                _ = drawLabel(label, y: y)
                drawValue(value, y: y, accent: tappable.contains(label))
            case .bars(let label, let filled, let total, let value):
                let x = drawLabel(label, y: y)
                drawBars(filled: filled, total: total, at: NSPoint(x: x + 8, y: y + 5))
                drawValue(value, y: y)
            case .note(let text, let tone):
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                NSAttributedString(string: text, attributes: [
                    .font: Line.noteFont,
                    .foregroundColor: tone == .neutral ? NSColor.secondaryLabelColor : tone.color,
                    .paragraphStyle: style,
                ]).draw(with: NSRect(x: Layout.pad, y: y + 1, width: Layout.width - Layout.pad * 2, height: line.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            y += line.height
        }
    }

    // MARK: - Row drawing

    /// Returns the right edge of the label so a scale can follow it.
    private func drawLabel(_ label: String, y: CGFloat) -> CGFloat {
        let s = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        s.draw(at: NSPoint(x: Layout.pad, y: y + 2))
        return Layout.pad + s.size().width
    }

    /// Values are right-aligned and truncated in the middle when space runs out.
    private func drawValue(_ value: String, y: CGFloat, accent: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingMiddle
        let available = Layout.width - Layout.pad * 2 - 90
        NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            // A row that answers a click has to say so before it is clicked.
            .foregroundColor: accent ? NSColor.controlAccentColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]).draw(in: NSRect(x: Layout.width - Layout.pad - available, y: y + 2, width: available, height: 16))
    }

    /// Scales the same look to any number of steps, so a four-step cellular
    /// readout is not stretched onto a five-step Wi-Fi scale.
    ///
    /// Drawn in plain ink on purpose. Color in this app means one thing — how
    /// the connection actually performs — and it belongs to the indicator alone.
    /// Tinting these bars by their own fill made them contradict it: a phone
    /// holding one bar of a perfectly fast link showed red here and green in the
    /// menu bar. Here the count and the figure beside it carry the strength.
    private func drawBars(filled: Int, total: Int, at point: NSPoint) {
        guard total > 0 else { return }
        let color = NSColor.labelColor.withAlphaComponent(0.75)
        for i in 0..<total {
            (i < filled ? color : color.withAlphaComponent(0.20)).setFill()
            let h = 3 + CGFloat(i) * (total > 1 ? 8 / CGFloat(total - 1) : 0)
            let r = NSRect(x: point.x + CGFloat(i) * 4, y: point.y + (11 - h), width: 2.5, height: h)
            NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
        }
    }
}

extension PanelView.Line {
    func isSame(as other: PanelView.Line) -> Bool {
        switch (self, other) {
        case let (.section(a), .section(b)): return a == b
        case let (.kv(a1, a2), .kv(b1, b2)): return a1 == b1 && a2 == b2
        case let (.bars(a1, a2, a3, a4), .bars(b1, b2, b3, b4)): return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.note(a1, a2), .note(b1, b2)): return a1 == b1 && a2 == b2
        default: return false
        }
    }
}

/// A row that can be clicked without closing the menu.
///
/// An ordinary NSMenuItem dismisses the menu the moment it is chosen, which is
/// right for a command and wrong for a switch: toggling how much the panel
/// above shows, only to have the panel vanish, means opening the menu again to
/// see what the toggle did. A hosted view gets the click itself and the menu
/// stays up, so the change happens under the pointer.
final class ToggleRowView: NSView {
    private var title = ""
    private var symbolName = ""
    private var hovering = false
    private var action: (() -> Void)?

    // Deliberately not flipped, unlike the panel above it. An NSImage drawn
    // into a flipped context comes out upside down, which turned the "show
    // more" chevron into a "show less" one — the row pointed up while its own
    // label offered to expand.
    override var intrinsicContentSize: NSSize { NSSize(width: Layout.width, height: 24) }

    func configure(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbol
        self.action = action
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { action?() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let tint = NSColor.secondaryLabelColor
        var x = Layout.pad
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            glyph.isTemplate = true
            let box = NSRect(x: x, y: bounds.midY - glyph.size.height / 2,
                             width: glyph.size.width, height: glyph.size.height)
            tint.set()
            glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            box.fill(using: .sourceAtop)
            x += glyph.size.width + 6
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: tint,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
