// Renders Resources/AppIcon.icns + AppIcon.png from IconArt.
// Run: swiftc Tools/make_icon/main.swift Sources/App/IconArt.swift -o build/make_icon && build/make_icon
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = size / 1024
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }

    // macOS tile: 824pt rounded square in the 1024 canvas, soft drop shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s), xRadius: 185*s, yRadius: 185*s)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.35); sh.shadowBlurRadius = 24*s; sh.shadowOffset = NSSize(width: 0, height: -10*s); sh.set()
    NSColor.black.setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.16, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.03, green: 0.06, blue: 0.11, alpha: 1)])!.draw(in: tile, angle: -90)
    // Soft glow behind the ring
    let c = P(500, 500)
    NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.95, blue: 0.80, alpha: 0.30), NSColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: 420*s, options: [])
    // Top sheen
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100*s, y: 560*s, width: 824*s, height: 364*s), angle: -90)

    // Ring with a mint → blue gradient (stroke → clip → gradient fill)
    let r = 255 * s
    let ring = IconArt.ring(center: c, radius: r, width: 92 * s)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setLineWidth(92 * s); ctx.setLineCap(.round)
    ctx.addPath(ring.cgPath); ctx.replacePathWithStrokedPath(); ctx.clip()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.96, blue: 0.78, alpha: 1), NSColor(srgbRed: 0.23, green: 0.62, blue: 1.0, alpha: 1)])!
        .draw(in: NSRect(x: c.x - r - 60*s, y: c.y - r - 60*s, width: 2*r + 120*s, height: 2*r + 120*s), angle: -45)
    NSGraphicsContext.restoreGraphicsState()

    // Inner core dot
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 62*s, y: c.y - 62*s, width: 124*s, height: 124*s)).fill()

    // Sparkle in the ring's gap, with a glow
    let sc = IconArt.sparkleCenter(center: c, radius: r)
    NSGraphicsContext.saveGraphicsState()
    let g = NSShadow(); g.shadowColor = NSColor(srgbRed: 0.5, green: 1, blue: 0.9, alpha: 0.8); g.shadowBlurRadius = 40*s; g.set()
    NSColor.white.setFill()
    IconArt.sparkle(center: sc, radius: 165*s, waist: 0.18).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setFill()
    IconArt.sparkle(center: NSPoint(x: sc.x - 150*s, y: sc.y + 95*s), radius: 48*s, waist: 0.2).fill()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let set = "build/AppIcon.iconset"
try? fm.removeItem(atPath: set); try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]; try! p.run(); p.waitUntilExit()

// Preview of the menu bar glyph on light and dark bars (for review only).
let prev = NSImage(size: NSSize(width: 240, height: 60), flipped: false) { _ in
    for (i, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.15, alpha: 1), NSColor.white)].enumerated() {
        let r = NSRect(x: CGFloat(i) * 120, y: 0, width: 120, height: 60)
        bg.setFill(); r.fill()
        let g = IconArt.menuBarGlyph()
        let tinted = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { rr in
            g.draw(in: rr); fg.set(); rr.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: NSRect(x: r.minX + 42, y: 12, width: 36, height: 36))
    }
    return true
}
let tiff = prev.tiffRepresentation!
try! NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/menubar-preview.png"))
print("icon written")
