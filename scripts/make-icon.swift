// Draws the app icon: a patina tile with a light knob, a pointer and tick marks.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Tile with a soft shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.32))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x0B6E61))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x179482), color(0x074238)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

let c = CGPoint(x: 512, y: 512)
func at(_ deg: Double, _ r: CGFloat) -> CGPoint {
    let a = deg * .pi / 180
    return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y + r * CGFloat(cos(a)))
}

// Tick marks; the one the pointer faces is brighter and longer.
ctx.setLineCap(.round)
for i in 0..<12 {
    let deg = Double(i) * 30
    let lit = i == 2
    ctx.setStrokeColor(lit ? color(0xB4F0E3) : color(0xFFFFFF, 0.5))
    ctx.setLineWidth(lit ? 20 : 13)
    ctx.move(to: at(deg, lit ? 292 : 306))
    ctx.addLine(to: at(deg, 350))
    ctx.strokePath()
}

// Knob.
let knob = CGRect(x: c.x - 226, y: c.y - 226, width: 452, height: 452)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 44, color: color(0x02251F, 0.55))
ctx.setFillColor(color(0xEEF4F2))
ctx.fillEllipse(in: knob)
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: knob)
ctx.clip()
let face = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFDFEFE), color(0xD5E2DE)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: c.x, y: knob.maxY), end: CGPoint(x: c.x, y: knob.minY), options: [])
ctx.restoreGState()
ctx.setStrokeColor(color(0xFFFFFF, 0.7))
ctx.setLineWidth(5)
ctx.strokeEllipse(in: knob.insetBy(dx: 16, dy: 16))

// Pointer.
ctx.setStrokeColor(color(0x0B7366))
ctx.setLineWidth(40)
ctx.move(to: at(60, 52))
ctx.addLine(to: at(60, 176))
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
