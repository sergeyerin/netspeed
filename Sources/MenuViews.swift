import AppKit

/// Content width of the menu. Every view lines up on this grid.
enum Layout {
    static let width: CGFloat = 336
    static let pad: CGFloat = 14
}

/// Menu header: the link indicator and two large speed figures.
///
/// Drawn by hand rather than assembled from NSMenuItems: the system paints
/// disabled menu items grey whatever color is set on them, which makes the data
/// unreadable. Inside an own view, color and typography stay under control.
final class HeaderView: NSView {
    private var state = LinkState(.unknown)
    private var down = ""
    private var up = ""

    // Tall enough to clear the chart's top label underneath: at 58 the descenders
    // of the speed row sat on it.
    override var intrinsicContentSize: NSSize { NSSize(width: Layout.width, height: 68) }
    override var isFlipped: Bool { true }

    func update(state: LinkState, down: String, up: String) {
        guard state != self.state || down != self.down || up != self.up else { return }
        self.state = state
        self.down = down
        self.up = up
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tone = state.tone.color

        // Indicator and label
        var x = Layout.pad
        if let icon = Indicator.image(for: state, style: .bars) {
            icon.draw(in: NSRect(x: x, y: 12, width: icon.size.width * 1.25, height: icon.size.height * 1.25))
            x += icon.size.width * 1.25 + 7
        }
        // The verdict leads, in the tone color; the qualifier follows in plain
        // ink. Repeating the menu bar label here would say the same thing twice.
        let quality = NSAttributedString(string: state.quality, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: tone,
        ])
        quality.draw(at: NSPoint(x: x, y: 12))
        x += quality.size().width + 6

        if !state.detail.isEmpty {
            NSAttributedString(string: "(\(state.detail))", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ]).draw(in: NSRect(x: x, y: 13, width: Layout.width - x - Layout.pad, height: 16))
        }

        // Large speed figures
        let y: CGFloat = 34
        drawRate("↓", down, color: Flow.down.ink, at: NSPoint(x: Layout.pad, y: y))
        let upWidth = rateWidth("↑", up)
        drawRate("↑", up, color: Flow.up.ink, at: NSPoint(x: Layout.width - Layout.pad - upWidth, y: y))
    }

    private func rateAttributes(_ color: NSColor) -> ([NSAttributedString.Key: Any], [NSAttributedString.Key: Any]) {
        ([.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: color],
         [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor])
    }

    private func drawRate(_ arrow: String, _ value: String, color: NSColor, at point: NSPoint) {
        let (arrowAttrs, valueAttrs) = rateAttributes(color)
        let a = NSAttributedString(string: arrow, attributes: arrowAttrs)
        a.draw(at: point)
        NSAttributedString(string: value, attributes: valueAttrs)
            .draw(at: NSPoint(x: point.x + a.size().width + 4, y: point.y + 1))
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

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: lines.reduce(4) { $0 + $1.height } + 6)
    }

    func update(_ new: [Line]) {
        let changed = new.count != lines.count || zip(new, lines).contains { !$0.isSame(as: $1) }
        guard changed else { return }
        let resize = new.count != lines.count
        lines = new
        if resize { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
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
                _ = drawLabel(label, y: y)
                drawValue(value, y: y)
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
    private func drawValue(_ value: String, y: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingMiddle
        let available = Layout.width - Layout.pad * 2 - 90
        NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
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
