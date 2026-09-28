import AppKit

/// Speed history chart: download up from the midline, upload down.
final class SparklineView: NSView {
    private var history: [Speed] = []
    private var unit: RateUnit = .bytes

    override var intrinsicContentSize: NSSize { NSSize(width: Layout.width, height: 62) }

    func update(history: [Speed], unit: RateUnit) {
        self.history = history
        self.unit = unit
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: Layout.pad, y: 14, width: Layout.width - Layout.pad * 2, height: 36)
        let mid = plot.midY
        let maxValue = max(history.map { max($0.down, $0.up) }.max() ?? 0, 1)

        // A well with real contrast: the old near-transparent fill left grey on
        // grey, and a chart hovering near zero was impossible to make out.
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
            let step = plot.width / CGFloat(max(1, history.count - 1))
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
            area(history.map(\.down), up: true, color: .systemBlue)
            area(history.map(\.up), up: false, color: .systemOrange)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let scale = NSAttributedString(string: "peak \(Fmt.rate(maxValue, unit: unit))", attributes: attrs)
        scale.draw(at: NSPoint(x: plot.minX, y: plot.maxY + 1))
        let span = NSAttributedString(string: "\(history.count)s", attributes: attrs)
        span.draw(at: NSPoint(x: plot.maxX - span.size().width, y: 0))
    }
}
