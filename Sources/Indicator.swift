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
    /// Smaller than the figures beside it, a shade lighter, and raised off
    /// their line, the way a superscript sits. Level with them and at the same
    /// size it read as part of the number — a unit or a prefix — when it is a
    /// label for the icon on its other side.
    private static let font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
    private static let badgeLift: CGFloat = 2.5
    private static let glyphBox: CGFloat = 14
    private static let innerGap: CGFloat = 2.5
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
    /// A highlight runs along the lit marks from the base outwards, the way a
    /// sign chases its arrows. It only runs while something is actually moving
    /// — one lit mark is a still link and gets a still icon — so the cost is
    /// paid exactly when there is something to report.
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
    /// `phase` is where the running highlight sits, measured in chevrons from
    /// the base of each stack; negative means no animation and every lit mark
    /// burns steadily.
    private static func drawTransferArrows(in box: NSRect, color: NSColor,
                                           downChevrons: Int, upChevrons: Int,
                                           phase: Double, cycle: Double) {
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
                color.withAlphaComponent(alpha(forChevron: chevron, lit: lit,
                                               phase: phase, cycle: cycle))
                    .setStroke()
                path.stroke()
            }
        }
    }

    /// One cycle for both stacks, set by the longer of the two, plus two steps
    /// of darkness so runs do not butt against each other.
    ///
    /// Whole steps, and shared rather than per-stack, so the sequence repeats
    /// on a fixed short period — which is what lets it be a handful of pictures
    /// shown in turn instead of a render on every frame.
    static func cycle(for state: LinkState) -> Double {
        Double(max(state.downChevrons, state.upChevrons) + 2)
    }

    /// Lit marks sit a little under full while the highlight runs, so the
    /// crest has somewhere to rise to. Without that headroom the wave could
    /// only be made of dips, which reads as a fault rather than as motion.
    private static let litBase: CGFloat = 0.78

    /// Where a mark sits between "not reached" and "lit", with the moving crest
    /// folded in.
    ///
    /// The crest is deliberately small. This is a status icon that sits in the
    /// corner of the eye all day: anything that demands attention while merely
    /// reporting normal traffic would have to be switched off within the hour.
    private static func alpha(forChevron index: Int, lit: Int, phase: Double, cycle: Double) -> CGFloat {
        guard index < lit else { return dimAlpha }
        guard phase >= 0, cycle > 0 else { return 1 }
        let crest = phase.truncatingRemainder(dividingBy: cycle)
        let distance = crest - Double(index)
        let falloff = exp(-(distance * distance) / 0.5)
        return min(1, litBase + (1 - litBase) * CGFloat(falloff))
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

    /// The label takes the room it needs and no more.
    ///
    /// It used to reserve the width of the longest label there is — `GPRS` —
    /// so the item never changed size. That bought less than it cost. The item
    /// resizes anyway whenever the label appears or disappears, which is the
    /// common case; reserving only smoothed the rare step from one technology
    /// to another, and charged thirteen points of permanent gap between the
    /// icon and the figures for it.
    private static func badgeWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    /// A glyph plus an optional label, as one coloured unit.
    ///
    /// Deliberately not a template image — the system would repaint that
    /// monochrome and the colour, which is the whole state, would be lost. The
    /// contents are produced inside a drawing block, so the dynamic colours
    /// follow theme changes on their own.
    /// `cycle` overrides the length of the chase, which is otherwise set by the
    /// stack itself. A row of indicators in a strip have different stacks and
    /// so different natural cycles; given one length they step in time, and a
    /// loop over that many frames closes exactly.
    static func image(for state: LinkState, style: IndicatorStyle,
                      phase: Double = -1, cycle: Double? = nil) -> NSImage? {
        guard style != .none else { return nil }
        // An empty label reserves no room: with nothing to say, the indicator
        // shrinks to the glyph instead of leaving a gap where a word would be.
        let showBadge = style == .barsAndBadge && !state.badge.isEmpty
        let width = glyphBox + (showBadge ? innerGap + badgeWidth(state.badge) : 0)

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
                                   upChevrons: state.upChevrons,
                                   phase: phase, cycle: cycle ?? Indicator.cycle(for: state))
            }
            x += glyphBox + innerGap

            if showBadge {
                let text = state.badge as NSString
                // Full strength, and separated from the figures by weight and
                // size rather than by fading.
                //
                // Both alternatives were tried on a real menu bar and both
                // failed there. The state colour goes dark red for a bad
                // verdict, which all but disappears on a light bar — exactly
                // when it is worth reading. The system's secondary colour is
                // white at about half opacity, and the menu bar is translucent:
                // over a mid-tone desktop, measured at 0.56 luminance here,
                // half-strength white has almost no contrast left. Opacity is
                // not a reliable channel on a surface whose colour is somebody
                // else's wallpaper.
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor.labelColor,
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2 + badgeLift),
                          withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
