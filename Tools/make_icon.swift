// Renders Resources/AppIcon.icns and AppIcon.png — run: swift Tools/make_icon.swift
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSBezierPath(roundedRect: NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s), xRadius: 185*s, yRadius: 185*s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24*s; shadow.shadowOffset = NSSize(width: 0, height: -10*s); shadow.set()
    NSColor.black.setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.13, green: 0.15, blue: 0.22, alpha: 1), NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)])!.draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let c = NSPoint(x: 512*s, y: 512*s)
    NSGradient(colors: [NSColor(red: 0.2, green: 0.85, blue: 0.75, alpha: 0.45), NSColor(red: 0.2, green: 0.55, blue: 1, alpha: 0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: 400*s, options: [])
    NSGraphicsContext.restoreGraphicsState()
    let cfg = NSImage.SymbolConfiguration(pointSize: 470*s, weight: .medium).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let r = NSRect(x: c.x - sym.size.width/2, y: c.y - sym.size.height/2, width: sym.size.width, height: sym.size.height)
        sym.draw(in: r)
    }
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
print("icon written")
