import AppKit

/// Speed history chart: download up from the midline, upload down.
///
/// Both axes are labelled, because a line without a scale says only "something
/// changed". The vertical label is the value the tallest point stands for, the
/// horizontal one is how far back the left edge reaches. Hovering replaces the
/// scale with a reading at the cursor — the chart is small, and picking a value
/// off it by eye is guesswork otherwise.
final class SparklineView: NSView {
    private var history: [Speed] = []
    private var unit: RateUnit = .bytes
    private var interval: TimeInterval = 1
    private var hover: Int?

    private let plotInset = NSEdgeInsets(top: 16, left: Layout.pad, bottom: 14, right: Layout.pad)

    override var intrinsicContentSize: NSSize { NSSize(width: Layout.width, height: 66) }

    func update(history: [Speed], unit: RateUnit, interval: TimeInterval) {
        self.history = history
        self.unit = unit
        self.interval = interval
        needsDisplay = true
    }

    // MARK: - Hovering

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A menu carries its own window, and a window does not deliver
        // mouse-moved events unless asked. Without this the tracking area is
        // installed correctly and still never hears anything.
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways because a menu runs its own event-tracking loop; without
        // it the view never hears the mouse while the menu is open.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let plot = plotRect
        guard history.count > 1, plot.contains(point) else {
            if hover != nil { hover = nil; needsDisplay = true }
            return
        }
        let step = plot.width / CGFloat(history.count - 1)
        let index = min(history.count - 1, max(0, Int(((point.x - plot.minX) / step).rounded())))
        if index != hover { hover = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        guard hover != nil else { return }
        hover = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    private var plotRect: NSRect {
        NSRect(x: plotInset.left, y: plotInset.bottom,
               width: bounds.width - plotInset.left - plotInset.right,
               height: bounds.height - plotInset.top - plotInset.bottom)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect
        let mid = plot.midY
        let maxValue = max(history.map { max($0.down, $0.up) }.max() ?? 0, 1)

        // A well with real contrast: a near-transparent fill left grey on grey,
        // and a chart hovering near zero was impossible to make out.
        let well = NSBezierPath(roundedRect: plot, xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        well.fill()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        well.lineWidth = 1
        well.stroke()

        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: plot.minX + 1, y: mid))
        axis.line(to: NSPoint(x: plot.maxX - 1, y: mid))
        axis.lineWidth = 1
        axis.stroke()

        if history.count > 1 {
            let step = plot.width / CGFloat(history.count - 1)
            let half = plot.height / 2 - 2
            func area(_ values: [Double], up: Bool, color: NSColor) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: plot.minX, y: mid))
                for (i, v) in values.enumerated() {
                    let h = CGFloat(v / maxValue) * half
                    path.line(to: NSPoint(x: plot.minX + CGFloat(i) * step, y: up ? mid + h : mid - h))
                }
                path.line(to: NSPoint(x: plot.minX + CGFloat(values.count - 1) * step, y: mid))
                path.close()
                color.withAlphaComponent(0.45).setFill()
                path.fill()
                color.setStroke()
                path.lineWidth = 1.6
                path.stroke()
            }
            area(history.map(\.down), up: true, color: Flow.down.area)
            area(history.map(\.up), up: false, color: Flow.up.area)

            if let hover, hover < history.count {
                let x = plot.minX + CGFloat(hover) * step
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                let cursor = NSBezierPath()
                cursor.move(to: NSPoint(x: x, y: plot.minY + 1))
                cursor.line(to: NSPoint(x: x, y: plot.maxY - 1))
                cursor.lineWidth = 1
                cursor.stroke()
            }
        }

        drawLabels(plot: plot, maxValue: maxValue)
    }

    private func drawLabels(plot: NSRect, maxValue: Double) {
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        if let hover, hover < history.count {
            // The reading takes the scale's place rather than adding a line:
            // the chart is 36 points tall and cannot spare another.
            let sample = history[hover]
            let ago = Int((Double(history.count - 1 - hover) * interval).rounded())
            let reading = NSMutableAttributedString()
            reading.append(NSAttributedString(string: "↓ \(Fmt.rate(sample.down, unit: unit))", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: Flow.down.ink,
            ]))
            reading.append(NSAttributedString(string: "   ↑ \(Fmt.rate(sample.up, unit: unit))", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: Flow.up.ink,
            ]))
            reading.append(NSAttributedString(string: ago == 0 ? "   now" : "   \(ago)s ago", attributes: dim))
            reading.draw(at: NSPoint(x: plot.minX, y: plot.maxY + 2))
            return
        }

        // Vertical scale: what the tallest point on the chart stands for.
        NSAttributedString(string: "scale \(Fmt.rate(maxValue, unit: unit))", attributes: dim)
            .draw(at: NSPoint(x: plot.minX, y: plot.maxY + 2))

        let legend = NSMutableAttributedString()
        legend.append(NSAttributedString(string: "↓", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                                  .foregroundColor: Flow.down.ink]))
        legend.append(NSAttributedString(string: " down  ", attributes: dim))
        legend.append(NSAttributedString(string: "↑", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                                   .foregroundColor: Flow.up.ink]))
        legend.append(NSAttributedString(string: " up", attributes: dim))
        legend.draw(at: NSPoint(x: plot.maxX - legend.size().width, y: plot.maxY + 2))

        // Horizontal scale: how far back the left edge reaches.
        let span = Int((Double(max(history.count - 1, 0)) * interval).rounded())
        NSAttributedString(string: span >= 60 ? "\(span / 60)m \(span % 60)s ago" : "\(span)s ago", attributes: dim)
            .draw(at: NSPoint(x: plot.minX, y: 0))
        let now = NSAttributedString(string: "now", attributes: dim)
        now.draw(at: NSPoint(x: plot.maxX - now.size().width, y: 0))
    }
}
