// Renders Resources/AppIcon.icns — run: swift Tools/make_icon.swift
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x*s, y: y*s, width: w*s, height: h*s) }

    // Squircle tile (macOS grid: 824pt tile inside 1024 canvas)
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185*s, yRadius: 185*s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24*s; shadow.shadowOffset = NSSize(width: 0, height: -10*s); shadow.set()
    NSColor.black.setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.13, green: 0.15, blue: 0.22, alpha: 1),
                        NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)])!.draw(in: tile, angle: -90)
    // Soft glow behind the battery
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let c = NSPoint(x: 512*s, y: 500*s)
    NSGradient(colors: [NSColor(red: 0.2, green: 0.55, blue: 1, alpha: 0.4),
                        NSColor(red: 0.2, green: 0.55, blue: 1, alpha: 0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: 380*s, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Battery body (vertical)
    let body = r(352, 230, 320, 540)
    let outline = NSBezierPath(roundedRect: body, xRadius: 70*s, yRadius: 70*s)
    outline.lineWidth = 30*s
    NSColor.white.withAlphaComponent(0.92).setStroke(); outline.stroke()
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: r(452, 782, 120, 52), xRadius: 22*s, yRadius: 22*s).fill()

    // Fill up to the limit (80%)
    let inner = body.insetBy(dx: 38*s, dy: 38*s)
    let fillH = inner.height * 0.8
    let fillRect = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: fillH)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.85, blue: 0.55, alpha: 1),
                        NSColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: fillRect, xRadius: 36*s, yRadius: 36*s), angle: 90)

    // Limit marker line across the battery
    let ly = fillRect.maxY + 24*s
    let marker = NSBezierPath()
    marker.move(to: NSPoint(x: 280*s, y: ly)); marker.line(to: NSPoint(x: 744*s, y: ly))
    marker.lineWidth = 16*s; marker.lineCapStyle = .round
    marker.setLineDash([34*s, 26*s], count: 2, phase: 0)
    NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 1).setStroke(); marker.stroke()

    // Lightning bolt
    let b = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(548, 640), (420, 455), (500, 455), (470, 300), (604, 500), (520, 500), (548, 640)]
    b.move(to: NSPoint(x: pts[0].0*s, y: pts[0].1*s))
    for p in pts.dropFirst() { b.line(to: NSPoint(x: p.0*s, y: p.1*s)) }
    b.close(); b.lineJoinStyle = .round
    NSColor.white.setFill(); b.fill()
    b.lineWidth = 10*s; NSColor.white.setStroke(); b.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: set.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
