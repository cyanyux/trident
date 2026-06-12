#!/usr/bin/env swift
//
// Render the DMG installer background (1x + 2x PNG). Run via
// scripts/render-dmg-background.sh, which also combines the two into the
// multi-resolution TIFF that Finder uses for Retina backgrounds.
//
// Canvas: 660×400 pt, matching the --window-size in release.sh.
// Icon centers (create-dmg coords): Trident.app (165, 195), Applications (495, 195).

import AppKit

let size = NSSize(width: 660, height: 400)

func render(scale: CGFloat) -> Data {
    let pixelsWide = Int(size.width * scale)
    let pixelsHigh = Int(size.height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // AppKit's coordinate origin is bottom-left; the layout numbers in the
    // comments are top-left (Finder/create-dmg) coords. y_appkit = 400 - y_finder.

    // Pure white background.
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()

    // Drag arrow between the two icon slots (icons are 128 pt wide, centered at
    // x=165 and x=495; labels sit below, so the arrow rides at icon-center height).
    let arrowColor = NSColor(calibratedWhite: 0, alpha: 0.38)
    let y: CGFloat = 400 - 195
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 262, y: y))
    shaft.line(to: NSPoint(x: 390, y: y))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    arrowColor.setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 378, y: y + 14))
    head.line(to: NSPoint(x: 398, y: y))
    head.line(to: NSPoint(x: 378, y: y - 14))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    arrowColor.setStroke()
    head.stroke()

    // Wordmark + tagline, top center.
    func draw(_ text: String, font: NSFont, color: NSColor, centerX: CGFloat, topY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = NSAttributedString(string: text, attributes: attrs)
        let w = s.size().width
        s.draw(at: NSPoint(x: centerX - w / 2, y: 400 - topY - s.size().height))
    }
    draw("Trident", font: .systemFont(ofSize: 28, weight: .semibold),
         color: NSColor(calibratedWhite: 0.08, alpha: 1), centerX: 330, topY: 34)
    draw("Drag to Applications to install",
         font: .systemFont(ofSize: 14, weight: .medium),
         color: NSColor(calibratedWhite: 0.35, alpha: 1), centerX: 330, topY: 74)

    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try render(scale: 1).write(to: URL(fileURLWithPath: "\(outDir)/dmg-background.png"))
try render(scale: 2).write(to: URL(fileURLWithPath: "\(outDir)/dmg-background@2x.png"))
print("wrote \(outDir)/dmg-background.png and @2x")
