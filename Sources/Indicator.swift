import AppKit

/// Colors that adapt to a light or dark menu bar.
///
/// The system yellow and orange are hard to read on a light menu bar, so every
/// level carries its own pair of values instead.
enum Tone {
    case good, warn, alert, bad, info, neutral

    var color: NSColor {
        switch self {
        case .good: return Tone.dynamic(light: Tone.rgb(0.11, 0.54, 0.24), dark: Tone.rgb(0.19, 0.82, 0.35))
        case .warn: return Tone.dynamic(light: Tone.rgb(0.70, 0.37, 0.00), dark: Tone.rgb(1.00, 0.62, 0.04))
        case .alert: return Tone.dynamic(light: Tone.rgb(0.69, 0.19, 0.00), dark: Tone.rgb(1.00, 0.48, 0.29))
        case .bad: return Tone.dynamic(light: Tone.rgb(0.76, 0.07, 0.12), dark: Tone.rgb(1.00, 0.27, 0.23))
        case .info: return Tone.dynamic(light: Tone.rgb(0.04, 0.36, 0.83), dark: Tone.rgb(0.39, 0.82, 1.00))
        case .neutral: return .secondaryLabelColor
        }
    }

    fileprivate static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    fileprivate static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Colors for the two directions.
///
/// The bright system blue and orange work as filled areas on a chart, but as
/// small text on a light background they wash out — the same orange that reads
/// fine as a 40-point band is barely legible at 10 points. Text gets a darker
/// pair; the areas keep the bright one.
enum Flow {
    case down, up

    var area: NSColor { self == .down ? .systemBlue : .systemOrange }

    var ink: NSColor {
        switch self {
        case .down: return Tone.dynamic(light: Tone.rgb(0.04, 0.37, 0.80), dark: Tone.rgb(0.42, 0.71, 1.00))
        case .up: return Tone.dynamic(light: Tone.rgb(0.68, 0.34, 0.02), dark: Tone.rgb(1.00, 0.62, 0.04))
        }
    }
}

extension LinkVerdict {
    /// Only states that need words get them.
    ///
    /// Quality is carried by the colour alone: labelling a measured estimate
    /// `LTE` or `E` made it look like a cellular technology the Mac had read off
    /// the modem, which it is not. The real technology appears here only when a
    /// tethering phone actually reports it.
    var marker: String {
        switch self {
        case .offline: return "OFF"
        case .portal: return "WEB"
        case .good, .medium, .slow, .awful, .unknown: return ""
        }
    }

    /// Replaces the transfer arrows where they would mislead: arrows mean data
    /// moving, and with no connection nothing is moving at all. A crossed-out
    /// network says that at a glance.
    var glyph: String? {
        switch self {
        case .offline: return "network.slash"
        case .good, .medium, .slow, .awful, .portal, .unknown: return nil
        }
    }

    var tone: Tone {
        switch self {
        case .good: return .good
        case .medium: return .warn
        case .slow: return .alert
        case .awful, .offline: return .bad
        case .portal: return .info
        case .unknown: return .neutral
        }
    }

    /// The verdict in one word — what the menu leads with.
    var quality: String {
        switch self {
        case .good: return "Good"
        case .medium: return "Fair"
        case .slow: return "Slow"
        case .awful: return "Awful"
        case .offline: return "Offline"
        case .portal: return "Sign-in needed"
        case .unknown: return "Measuring…"
        }
    }

    /// What the link behaves like, for the parenthetical after the verdict.
    /// Always a comparison, never a claim about the technology in use.
    var comparison: String {
        switch self {
        case .good: return "LTE/5G-like"
        case .medium: return "weak 4G-like"
        case .slow: return "3G-like"
        case .awful: return "EDGE-like"
        case .offline, .portal, .unknown: return ""
        }
    }

    static let all: [LinkVerdict] = [.good, .medium, .slow, .awful, .offline, .portal, .unknown]
}

/// What the indicator draws. The label is either the measured estimate or the
/// technology the tethering phone reports — the drawing code does not care which.
struct LinkState: Equatable {
    var badge: String       // menu bar label, empty unless there is a fact to state
    var glyph: String?      // overrides the transfer arrows where they would mislead
    var tone: Tone
    var quality: String     // "Awful"
    var detail: String      // "EDGE-like" or "phone: 5G"; may be empty
    var downChevrons: Int   // 1...3, by how much is moving that way
    var upChevrons: Int

    init(badge: String, glyph: String? = nil, tone: Tone, quality: String, detail: String,
         downChevrons: Int = 1, upChevrons: Int = 1) {
        self.badge = badge
        self.glyph = glyph
        self.tone = tone
        self.quality = quality
        self.detail = detail
        self.downChevrons = downChevrons
        self.upChevrons = upChevrons
    }

    init(_ verdict: LinkVerdict) {
        self.init(badge: verdict.marker, glyph: verdict.glyph, tone: verdict.tone,
                  quality: verdict.quality, detail: verdict.comparison)
    }

    /// How much is moving, as a position on a fixed scale. The colour answers a
    /// different question — how well the link carries — and the two are
    /// deliberately kept apart: a full stack in amber means plenty of data
    /// crossing a mediocre link, which is a real and common state, not a
    /// contradiction.
    ///
    /// What stops the two scales from being confused for one is that the
    /// directions move independently. A strength meter cannot read five down
    /// and one up; traffic does it constantly, and that asymmetry is what tells
    /// the eye this is flow and not level.
    ///
    /// Five steps of eight times each, which is what it takes to span the range
    /// this app actually meets: a phone on EDGE tops out around the second,
    /// a hotspot on LTE lives in the middle, wired gigabit reaches the fifth.
    /// Three steps could not do that — picking a top of 256 KB/s pinned every
    /// fast link to the ceiling, and picking a higher one left mobile users
    /// permanently at the floor.
    ///
    /// The bottom step sits at 4 KB/s because nothing below it is a decision:
    /// a Mac with every window shut still exchanges a kilobyte or two a second.
    static func chevrons(forBytesPerSecond rate: Double) -> Int {
        switch rate {
        case ..<4_000: return 1           // idle, or background chatter
        case ..<32_000: return 2
        case ..<256_000: return 3
        case ..<2_000_000: return 4
        default: return 5                 // flat out, for most links
        }
    }

    /// "Awful (phone: 5G)" — the verdict first, the qualifier in brackets.
    var summary: String {
        detail.isEmpty ? quality : "\(quality) (\(detail))"
    }
}

enum IndicatorStyle: String, CaseIterable {
    case bars
    case barsAndBadge
    case none

    var title: String {
        switch self {
        case .bars: return "Transfer arrows"
        case .barsAndBadge: return "Arrows and network type"
        case .none: return "No indicator"
        }
    }
}

enum Indicator {
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private static let glyphBox: CGFloat = 14
    private static let innerGap: CGFloat = 3.5
    private static let height: CGFloat = 16
    /// Five divisions, flatter and closer than three were. A fixed scale is
    /// read by how far the lit part reaches, not by counting segments, so the
    /// marks can be finer than they could when the stack grew and shrank.
    static let chevronsPerDirection = 5

    /// Two chevron arrows, down then up, because that is what this measures.
    ///
    /// It used to be a four-bar scale, which every phone and every Wi-Fi menu
    /// uses for signal strength — so it read as "how strong is the signal" when
    /// it has always meant "how well does the link actually carry". On a hotspot
    /// the two can disagree completely: full bars to a phone that is getting
    /// nothing from the tower. Arrows say transfer, and the colour says how well
    /// it is going.
    ///
    /// Chevrons rather than plain arrows, borrowed from road markings where a
    /// stack means speed and direction at a glance. Each direction carries its
    /// own count, set by what is actually crossing; the colour, shared by both,
    /// carries how well the link is doing. The counts repeat what the figures
    /// beside them already say — on purpose. That repetition teaches the scale
    /// without a legend, and it is the only reading left when the numbers are
    /// switched off and the arrows stand alone.
    ///
    /// All five are always drawn, the unreached ones dimmed, the way the scale
    /// on a tape deck stays visible while only the level lights up. A stack
    /// that grew and shrank gave no sense of how much room was left above, and
    /// one chevron on its own could not say whether it was the bottom of a
    /// ladder or the whole of it. A fixed scale answers both, and stops the
    /// glyph twitching in the menu bar every time traffic changes band.
    ///
    /// Drawn rather than taken from SF Symbols for a plain reason: no symbol is
    /// a five-step scale, and the lit part is the whole point of this one.
    private static func drawTransferArrows(in box: NSRect, color: NSColor,
                                           downChevrons: Int, upChevrons: Int) {
        let armWidth: CGFloat = 5.4
        let gap: CGFloat = 2.6
        let spread: CGFloat = 2.7          // half-width of a chevron
        let depth: CGFloat = 2.2           // how far its arms fall back from the point
        let step: CGFloat = 2.8            // distance between chevrons

        let left = box.midX - (armWidth * 2 + gap) / 2
        // The whole scale, always: the stack is centred once and does not move.
        let extent = depth + CGFloat(chevronsPerDirection - 1) * step

        for (index, pointingDown) in [true, false].enumerated() {
            let centre = left + armWidth / 2 + CGFloat(index) * (armWidth + gap)
            let lit = pointingDown ? downChevrons : upChevrons
            // Counted from the inside out, so lighting up runs the way the
            // arrow does: the mark nearest the middle is the first division,
            // and the scale fills outwards from there. Numbering it the other
            // way lit the far tip first and left the stack growing inwards
            // against its own direction.
            let base = pointingDown ? box.midY + extent / 2 - depth
                                    : box.midY - extent / 2 + depth

            for chevron in 0..<chevronsPerDirection {
                let offset = CGFloat(chevron) * step
                let point = pointingDown ? base - offset : base + offset
                let back = pointingDown ? point + depth : point - depth

                let path = NSBezierPath()
                path.move(to: NSPoint(x: centre - spread, y: back))
                path.line(to: NSPoint(x: centre, y: point))
                path.line(to: NSPoint(x: centre + spread, y: back))
                path.lineWidth = 1.4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                color.withAlphaComponent(chevron < lit ? 1 : dimAlpha).setStroke()
                path.stroke()
            }
        }
    }

    /// How far down the unreached part of the scale is taken.
    ///
    /// Not one number for both themes. The same alpha behaves differently at
    /// each end: over a dark bar the colour sinks into the background, over a
    /// light one it only pales, so a value dim enough to read as "off" on white
    /// disappears altogether on black.
    private static var dimAlpha: CGFloat {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? 0.28 : 0.20
    }

    /// Widest label of everything that can be shown — the measured estimates and
    /// every cellular technology name. The box is reserved up front so the image
    /// always has one size; otherwise the status item would resize whenever the
    /// state changed and shove the numbers sideways.
    private static let badgeBox: CGFloat = {
        let labels = LinkVerdict.all.map(\.marker) + CellularType.allLabels
        return labels
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
    }()

    /// A glyph plus an optional label, as one coloured unit.
    ///
    /// Deliberately not a template image — the system would repaint that
    /// monochrome and the colour, which is the whole state, would be lost. The
    /// contents are produced inside a drawing block, so the dynamic colours
    /// follow theme changes on their own.
    static func image(for state: LinkState, style: IndicatorStyle) -> NSImage? {
        guard style != .none else { return nil }
        // An empty label reserves no room: with nothing to say, the indicator
        // shrinks to the glyph instead of leaving a gap where a word would be.
        let showBadge = style == .barsAndBadge && !state.badge.isEmpty
        let width = glyphBox + (showBadge ? innerGap + badgeBox : 0)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let color = state.tone.color
            var x: CGFloat = 0

            let slot = NSRect(x: x, y: 0, width: glyphBox, height: height)
            if let glyph = state.glyph {
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                if let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let size = symbol.size
                    let box = NSRect(x: slot.midX - size.width / 2,
                                     y: slot.midY - size.height / 2,
                                     width: size.width, height: size.height)
                    color.set()
                    symbol.isTemplate = true
                    symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                    // A template image keeps its own greys unless the colour is
                    // painted over it; this does that without a second image.
                    box.fill(using: .sourceAtop)
                }
            } else {
                drawTransferArrows(in: slot, color: color,
                                   downChevrons: state.downChevrons,
                                   upChevrons: state.upChevrons)
            }
            x += glyphBox + innerGap

            if showBadge {
                let text = state.badge as NSString
                // The label takes the menu bar's own text colour rather than the
                // state colour: a dark red word on a grey bar is barely there,
                // and the glyph already carries the colour. Legibility first.
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor.labelColor,
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2 + 0.5), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
