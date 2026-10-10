// Render Tiler's app icon into an .iconset folder (then `iconutil -c icns`).
//
//   swift scripts/make-icon.swift build/AppIcon.iconset
//
// The icon follows the macOS grid: a rounded square inset on a 1024 canvas,
// a soft vertical gradient, and the three-tile layout Tiler makes.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // Drop shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.55, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.24, green: 0.27, blue: 0.86, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Tiles: one tall on the left, two stacked on the right.
    let pad = 150 * s, gap = 44 * s, r = 52 * s
    let inner = body.insetBy(dx: pad, dy: pad)
    let leftW = (inner.width - gap) * 0.5
    let left = NSRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
    let rx = left.maxX + gap, rw = inner.maxX - rx, half = (inner.height - gap) / 2
    let top = NSRect(x: rx, y: inner.minY + half + gap, width: rw, height: half)
    let bottom = NSRect(x: rx, y: inner.minY, width: rw, height: half)
    for (rect, alpha) in [(left, 0.97), (top, 0.80), (bottom, 0.80)] {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
