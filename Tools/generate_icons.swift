#!/usr/bin/env swift
import AppKit

// Regenerates Trident's icon assets from a single source shape: the system
// "trident emblem" glyph (🔱), converted to a clean silhouette. Output is baked
// into the asset catalog as PNGs, so the running app has no font/emoji runtime
// dependency. Re-run after changing colours or sizing:
//
//     swift Tools/generate_icons.swift
//
// Produces:
//   Sources/TridentApp/Assets.xcassets/AppIcon.appiconset/*.png   (ocean-blue squircle)
//   Sources/TridentApp/Assets.xcassets/MenuBarIcon.imageset/*.png (black template)

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Sources/TridentApp/Assets.xcassets")
let appIconDir = assets.appendingPathComponent("AppIcon.appiconset")
let menuDir = assets.appendingPathComponent("MenuBarIcon.imageset")
let runtimeIconDir = assets.appendingPathComponent("AppIconImage.imageset")
for dir in [appIconDir, menuDir, runtimeIconDir] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

// MARK: - Trident silhouette

/// A silhouette of the trident glyph filled with `color` on a transparent box.
/// Drawing the glyph then compositing the fill with `.sourceAtop` keeps only the
/// glyph's shape (and its interior negative space), discarding the emoji colours.
func tridentSilhouette(color: NSColor, pointSize: CGFloat, box: NSSize) -> NSImage {
    let img = NSImage(size: box)
    img.lockFocus()
    let ps = NSMutableParagraphStyle(); ps.alignment = .center
    let glyph = NSAttributedString(
        string: "\u{1F531}",
        attributes: [.font: NSFont.systemFont(ofSize: pointSize), .paragraphStyle: ps])
    let h = glyph.size().height
    glyph.draw(in: NSRect(x: 0, y: (box.height - h) / 2, width: box.width, height: h))
    NSGraphicsContext.current!.cgContext.setBlendMode(.sourceAtop)
    color.setFill()
    NSRect(origin: .zero, size: box).fill()
    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, px: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
               from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - App icon

let oceanTop = NSColor(srgbRed: 0.16, green: 0.50, blue: 0.96, alpha: 1)
let oceanBot = NSColor(srgbRed: 0.04, green: 0.17, blue: 0.58, alpha: 1)

/// One app-icon bitmap at `px`×`px`: an ocean-blue gradient squircle (macOS icon
/// grid proportions, with a soft contact shadow) and a centred white trident.
func renderAppIcon(px: Int) -> NSImage {
    let P = CGFloat(px)
    let img = NSImage(size: NSSize(width: P, height: P))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Plate: ~80% of the canvas (Apple's macOS grid), nudged up to leave room for
    // the contact shadow below.
    let side = P * 0.805
    let plate = NSRect(x: (P - side) / 2, y: (P - side) / 2 + P * 0.012,
                       width: side, height: side)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: side * 0.2237, yRadius: side * 0.2237)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -P * 0.012), blur: P * 0.03,
                  color: NSColor(white: 0, alpha: 0.28).cgColor)
    oceanBot.setFill(); squircle.fill()
    ctx.restoreGState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [oceanTop, oceanBot])!.draw(in: plate, angle: -90)
    // Gentle top sheen for depth.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2),
              angle: -90)
    let trident = tridentSilhouette(color: .white, pointSize: P * 0.50,
                                    box: NSSize(width: P, height: P))
    trident.draw(in: NSRect(x: 0, y: 0, width: P, height: P))
    NSGraphicsContext.restoreGraphicsState()

    img.unlockFocus()
    return img
}

// (filename, pixel size) for every macOS app-icon slot.
let appIconSlots: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in appIconSlots {
    writePNG(renderAppIcon(px: px), px: px, to: appIconDir.appendingPathComponent(name))
}

// A regular (non-template) copy of the icon for runtime use: an LSUIElement app's
// `applicationIconImage` doesn't reliably resolve the app-icon asset from
// LaunchServices, so alerts/notifications fall back to a blank icon. We load this
// imageset by name and set it explicitly. See AppDelegate.
for (name, px) in [("appicon.png", 256), ("appicon@2x.png", 512)] {
    writePNG(renderAppIcon(px: px), px: px, to: runtimeIconDir.appendingPathComponent(name))
}

// MARK: - Menu bar template (black silhouette; AppKit tints it for light/dark)

// The glyph is rendered at 82% of the box so transparent padding makes it sit a
// touch smaller than the menu-bar height — matching the visual weight of system
// SF Symbols, which don't fill the bar edge to edge.
for (name, px) in [("menubar.png", 18), ("menubar@2x.png", 36)] {
    let img = tridentSilhouette(color: .black, pointSize: CGFloat(px) * 0.82,
                                box: NSSize(width: px, height: px))
    writePNG(img, px: px, to: menuDir.appendingPathComponent(name))
}

print("Generated app icon (\(appIconSlots.count) slots) and menu-bar template (2 scales).")
