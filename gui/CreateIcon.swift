import AppKit

// App icon: a black power symbol with misregistered cyan/magenta print ghosts on a
// neon yellow-green tile, crossed by magenta caution tape, with a halftone corner.
// Coordinates are top-down on a 1024 canvas, following the macOS icon grid.

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let acid = rgb(0xD4FF2A), hot = rgb(0xFF3D7F), cyan = rgb(0x27E3FF), ink = rgb(0x0A0A0C)

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}
func polygon(_ points: [(CGFloat, CGFloat)], closed: Bool = true) -> NSBezierPath {
    let path = NSBezierPath()
    for (index, point) in points.enumerated() {
        let p = NSPoint(x: point.0, y: point.1)
        if index == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    if closed { path.close() }
    return path
}

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let flip = NSAffineTransform()
flip.translateX(by: 0, yBy: CGFloat(size))
flip.scaleX(by: 1, yBy: -1)
flip.concat()

// Tile with a soft drop shadow (shadow offsets ignore the flip, so negative is down).
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = NSColor.black.withAlphaComponent(0.45)
drop.shadowBlurRadius = 28
drop.shadowOffset = NSSize(width: 0, height: -14)
drop.set()
acid.setFill(); tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
tile.addClip()
// Halftone dots growing toward the bottom-right corner.
ink.withAlphaComponent(0.16).setFill()
for i in 0...16 {
    for j in 0...16 where i + j > 18 {
        circle(CGFloat(100 + i * 52), CGFloat(100 + j * 52), CGFloat(min((i + j - 18) * 2, 22))).fill()
    }
}
// Caution tape crossing the tile at -24°.
NSGraphicsContext.saveGraphicsState()
let tilt = NSAffineTransform()
tilt.translateX(by: 512, yBy: 512)
tilt.rotate(byDegrees: -24)
tilt.translateX(by: -512, yBy: -512)
tilt.concat()
ink.setFill()
NSBezierPath(rect: NSRect(x: -100, y: 640, width: 1300, height: 96)).fill()
hot.setFill()
for i in 0...22 {
    let x = CGFloat(-120 + i * 64)
    polygon([(x, 724), (x + 32, 724), (x + 64, 652), (x + 32, 652)]).fill()
}
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

// Power symbol: the long arc around the bottom from (380, 330) to (644, 330), plus the stem.
let power = NSBezierPath()
let center = NSPoint(x: 512, y: 330 + CGFloat(210 * 210 - 132 * 132).squareRoot())
let startAngle = atan2(330 - center.y, 380 - center.x)
let sweep = 2 * CGFloat.pi - (atan2(330 - center.y, 644 - center.x) - startAngle).magnitude
for step in 0...240 {
    // Top-down coordinates: decreasing angles run left, down, and around to the right.
    let angle = startAngle - sweep * CGFloat(step) / 240
    let point = NSPoint(x: center.x + 210 * cos(angle), y: center.y + 210 * sin(angle))
    if step == 0 { power.move(to: point) } else { power.line(to: point) }
}
power.move(to: NSPoint(x: 512, y: 230))
power.line(to: NSPoint(x: 512, y: 480))
power.lineWidth = 78; power.lineCapStyle = .round; power.lineJoinStyle = .round
for (dx, dy, color) in [(CGFloat(-20), CGFloat(-14), cyan), (22, 18, hot), (0, 0, ink)] {
    NSGraphicsContext.saveGraphicsState()
    let shift = NSAffineTransform()
    shift.translateX(by: dx, yBy: dy)
    shift.concat()
    color.setStroke(); power.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

// A white sparkle in the top-right corner.
let sparkle = polygon([(800, 190), (814, 228), (852, 242), (814, 256), (800, 294), (786, 256), (748, 242), (786, 228)])
NSColor.white.setFill(); sparkle.fill()
sparkle.lineWidth = 7; ink.setStroke(); sparkle.stroke()

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
