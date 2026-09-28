// Draws the site's favicon into tools/page-assets/.
//
//   swift tools/make-favicon.swift
//
// Same mark as the app icon — the tile and the four ascending bars — but drawn
// tighter. The app icon keeps Apple's ~10% margin because macOS expects it;
// at 16 pixels in a browser tab that margin eats a third of the width and the
// bars turn to mush, so here the tile runs edge to edge.
//
// Writes three PNGs and a favicon.ico holding the two small sizes. The .ico
// exists because browsers ask for /favicon.ico on their own, whatever the page
// declares, and a 404 in the log every visit is untidy.

import AppKit
import Foundation

func drawFavicon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let tile = NSRect(x: 0, y: 0, width: size, height: size)
        let radius = size * 0.21
        let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.20, alpha: 1),
                   ending: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))?
            .draw(in: shape, angle: -90)

        let count = 4
        let barWidth = size * 0.132
        let gap = size * 0.082
        let block = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = tile.midX - block / 2
        let bottom = size * 0.235
        let shortest = size * 0.175
        let tallest = size * 0.545

        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            NSColor(srgbRed: 0.20 + 0.10 * t, green: 0.62 + 0.24 * t, blue: 0.10 + 0.25 * t, alpha: 1).setFill()
            let bar = NSRect(x: x, y: bottom, width: barWidth, height: shortest + (tallest - shortest) * t)
            // Rounding disappears below a couple of pixels and only blurs the
            // edge, so the smallest sizes get square bars.
            let corner = size >= 32 ? barWidth * 0.3 : 0
            NSBezierPath(roundedRect: bar, xRadius: corner, yRadius: corner).fill()
            x += barWidth + gap
        }
        return true
    }
}

func png(_ size: Int) -> Data {
    let image = drawFavicon(size: CGFloat(size))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// An .ico is a small directory of images. Modern browsers accept PNG payloads
/// inside it, so the same bytes serve both formats.
func ico(_ sizes: [Int]) -> Data {
    let images = sizes.map { png($0) }
    var out = Data()
    out.append(contentsOf: [0, 0, 1, 0, UInt8(sizes.count), 0])   // reserved, type 1, count

    var offset = 6 + 16 * sizes.count
    for (size, image) in zip(sizes, images) {
        var entry = Data()
        entry.append(contentsOf: [UInt8(size == 256 ? 0 : size), UInt8(size == 256 ? 0 : size), 0, 0])
        entry.append(contentsOf: [1, 0, 32, 0])                   // one plane, 32 bits
        withUnsafeBytes(of: UInt32(image.count).littleEndian) { entry.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(offset).littleEndian) { entry.append(contentsOf: $0) }
        out.append(entry)
        offset += image.count
    }
    images.forEach { out.append($0) }
    return out
}

let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("tools/page-assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

for (name, size) in [("favicon-16.png", 16), ("favicon-32.png", 32), ("apple-touch-icon.png", 180)] {
    try png(size).write(to: assets.appendingPathComponent(name))
    print("-- \(name)")
}
try ico([16, 32]).write(to: assets.appendingPathComponent("favicon.ico"))
print("-- favicon.ico")
