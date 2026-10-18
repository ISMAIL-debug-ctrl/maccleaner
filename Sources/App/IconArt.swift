import AppKit

// The MacCleaner mark: an open ring (a sweep that is almost complete) with a four-point sparkle
// sitting in its gap. Shared by the app icon (Tools/make_icon) and the menu bar template glyph.
enum IconArt {
    /// Four-point star with concave sides.
    static func sparkle(center c: NSPoint, radius r: CGFloat, waist: CGFloat = 0.22) -> NSBezierPath {
        let p = NSBezierPath()
        let w = r * waist
        p.move(to: NSPoint(x: c.x, y: c.y + r))
        p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
        p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
        p.close()
        return p
    }

    /// The ring: an arc from 70° going clockwise around to 20°, leaving a gap at the top right.
    static func ring(center c: NSPoint, radius r: CGFloat, width: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: 62, endAngle: 28, clockwise: false)
        p.lineWidth = width
        p.lineCapStyle = .round
        return p
    }

    /// Where the sparkle sits: in the ring's gap.
    static func sparkleCenter(center c: NSPoint, radius r: CGFloat) -> NSPoint {
        let a = 45 * CGFloat.pi / 180
        return NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }

    /// Monochrome menu bar glyph (template image: macOS tints it for light/dark and highlight).
    static func menuBarGlyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 8.4, y: 8.4), r: CGFloat = 6.2
            NSColor.black.setStroke()
            ring(center: c, radius: r, width: 2.1).stroke()
            NSColor.black.setFill()
            sparkle(center: sparkleCenter(center: c, radius: r), radius: 4.0, waist: 0.2).fill()
            // small inner dot: the "clean" core
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
