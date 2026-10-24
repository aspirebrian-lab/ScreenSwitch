import Cocoa

// Tekent het app-icoon (1024x1024) en schrijft het als PNG naar het opgegeven pad.
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// macOS-sjabloon: 824pt-vlak in een canvas van 1024 met zachte schaduw.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35).cgColor)
color(0, 0, 0).setFill()
bodyPath.fill()
ctx.restoreGState()

ctx.saveGState()
bodyPath.addClip()
NSGradient(colors: [color(94, 92, 230), color(10, 132, 255), color(100, 210, 255)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: 60)
// subtiele glans bovenaan
NSGradient(colors: [color(255, 255, 255, 0.28), color(255, 255, 255, 0)])!
    .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
ctx.restoreGState()

func window(_ rect: NSRect, alpha: CGFloat, shadow: Bool) {
    let p = NSBezierPath(roundedRect: rect, xRadius: 46, yRadius: 46)
    ctx.saveGState()
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0, 0, 40, 0.35).cgColor)
    }
    color(255, 255, 255, alpha).setFill()
    p.fill()
    ctx.restoreGState()

    // titelbalk met drie stipjes
    ctx.saveGState()
    p.addClip()
    color(0, 0, 0, 0.07).setFill()
    NSRect(x: rect.minX, y: rect.maxY - 78, width: rect.width, height: 78).fill()
    ctx.restoreGState()
    for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        c.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 30 + CGFloat(i) * 36, y: rect.maxY - 51, width: 22, height: 22)).fill()
    }
}

// Achterste (niet-actieve) venster en voorste (actieve) venster
window(NSRect(x: 168, y: 330, width: 340, height: 390), alpha: 0.55, shadow: false)
window(NSRect(x: 436, y: 260, width: 420, height: 470), alpha: 0.97, shadow: true)

// "Klik"-rimpels op het actieve venster
let center = CGPoint(x: 646, y: 470)
for (r, a) in [(120.0, 0.18), (78.0, 0.30)] as [(CGFloat, CGFloat)] {
    color(10, 132, 255, a).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    ring.lineWidth = 12
    ring.stroke()
}

// Muiscursor
let cursor = NSBezierPath()
let o = CGPoint(x: 612, y: 520)  // punt van de pijl
cursor.move(to: o)
cursor.line(to: CGPoint(x: o.x, y: o.y - 230))
cursor.line(to: CGPoint(x: o.x + 56, y: o.y - 176))
cursor.line(to: CGPoint(x: o.x + 108, y: o.y - 282))
cursor.line(to: CGPoint(x: o.x + 156, y: o.y - 260))
cursor.line(to: CGPoint(x: o.x + 106, y: o.y - 156))
cursor.line(to: CGPoint(x: o.x + 184, y: o.y - 156))
cursor.close()
cursor.lineJoinStyle = .round
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 0, 0, 0.4).cgColor)
color(20, 24, 40).setFill()
cursor.fill()
ctx.restoreGState()
color(255, 255, 255).setStroke()
cursor.lineWidth = 14
cursor.stroke()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
