// Draws the application icon and writes Resources/AppIcon.icns.
//
//   swift tools/make-icon.swift
//
// Every size is drawn from scratch rather than scaled down from one bitmap:
// at 16 points a downscaled image turns the bars into grey mush, while drawing
// them at that size keeps each one a crisp pixel column.
//
// The artwork is the same signal scale the menu bar shows, so the icon in
// Finder and the icon in the status bar are recognisably the same thing.

import AppKit
import Foundation

let canvasPadding: CGFloat = 0.098      // Apple's icon grid: ~100pt of 1024
let cornerFactor: CGFloat = 0.2237      // squircle radius of the tile

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let inset = size * canvasPadding
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = tile.width * cornerFactor

        // Tile: a dark slate so the bars read on any desktop, light or dark.
        let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        let backdrop = NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.20, alpha: 1),
                                  ending: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))
        backdrop?.draw(in: shape, angle: -90)

        // Bars: four ascending steps, the same scale the indicator draws.
        let count = 4
        let barWidth = tile.width * 0.118
        let gap = tile.width * 0.073
        let block = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = tile.midX - block / 2
        let bottom = tile.minY + tile.height * 0.26
        let shortest = tile.height * 0.16
        let tallest = tile.height * 0.50

        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let height = shortest + (tallest - shortest) * t
            // Amber at the bottom of the scale, green at the top: the same ramp
            // the app uses to say how a link behaves.
            let color = NSColor(srgbRed: 0.20 + 0.10 * t,
                                green: 0.62 + 0.24 * t,
                                blue: 0.10 + 0.25 * t,
                                alpha: 1)
            color.setFill()
            let bar = NSRect(x: x, y: bottom, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth * 0.34, yRadius: barWidth * 0.34).fill()
            x += barWidth + gap
        }
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// point size, scale — the names iconutil expects
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2),
                              (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixels = points * scale
    let image = drawIcon(size: CGFloat(pixels))
    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(points)x\(points)\(suffix).png"
    try png(image, pixels: pixels).write(to: iconset.appendingPathComponent(name))
}

let resources = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", resources.appendingPathComponent("AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }

print("-- wrote Resources/AppIcon.icns")
