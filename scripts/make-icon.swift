// Draws Kiri's app icon (Honey style) and writes the macOS AppIcon set.
// Usage: swift scripts/make-icon.swift App/Kiri/Assets.xcassets/AppIcon.appiconset
import AppKit

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let c = ctx.cgContext
    let s = size / 1024
    c.scaleBy(x: s, y: s)

    // macOS icon grid: an 824 pt squircle centered in 1024, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x5A3A1A, 0.28))
    c.addPath(tilePath)
    c.setFillColor(rgb(0xF5EEE1))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    // Warm canvas, lighter at the top.
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFF8EC), rgb(0xF2E2C6)] as CFArray,
                        locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The page: a solid surface panel, like the editor.
    let page = CGRect(x: 230, y: 210, width: 564, height: 620)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x5A3A1A, 0.18))
    c.addPath(CGPath(roundedRect: page, cornerWidth: 70, cornerHeight: 70, transform: nil))
    c.setFillColor(rgb(0xFFFCF6))
    c.fillPath()
    c.restoreGState()

    // Lines of text in the syntax colors.
    let lines: [(x: CGFloat, w: CGFloat, color: UInt32)] = [
        (300, 220, 0x9B2C6E), (300, 330, 0x3B2A2F), (350, 250, 0x4E7A1F), (350, 180, 0x1F6F8B), (300, 140, 0x3B2A2F),
    ]
    for (i, l) in lines.enumerated() {
        let y = 720 - CGFloat(i) * 92
        c.addPath(CGPath(roundedRect: CGRect(x: l.x, y: y, width: l.w, height: 40), cornerWidth: 20, cornerHeight: 20,
                         transform: nil))
        c.setFillColor(rgb(l.color, i == 1 || i == 4 ? 0.85 : 0.9))
        c.fillPath()
    }
    // The caret, in honey.
    c.addPath(CGPath(roundedRect: CGRect(x: 456, y: 340, width: 16, height: 64), cornerWidth: 8, cornerHeight: 8,
                     transform: nil))
    c.setFillColor(rgb(0xE09A2D))
    c.fillPath()

    // A honey drop over the page's corner.
    let drop = CGMutablePath()
    let cx: CGFloat = 712, cy: CGFloat = 268, r: CGFloat = 132
    drop.move(to: CGPoint(x: cx, y: cy + r * 2.05))
    drop.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + r * 0.25, y: cy + r * 1.45),
                  control2: CGPoint(x: cx + r, y: cy + r * 0.75))
    drop.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
    drop.addCurve(to: CGPoint(x: cx, y: cy + r * 2.05), control1: CGPoint(x: cx - r, y: cy + r * 0.75),
                  control2: CGPoint(x: cx - r * 0.25, y: cy + r * 1.45))
    drop.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: rgb(0x995A05, 0.35))
    c.addPath(drop)
    c.setFillColor(rgb(0xE09A2D))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(drop)
    c.clip()
    let honey = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(0xF5B656), rgb(0xE09A2D), rgb(0xB8700E)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(honey, start: CGPoint(x: cx - r, y: cy + r * 2), end: CGPoint(x: cx + r, y: cy - r), options: [])
    c.restoreGState()
    // Highlight on the drop.
    c.addEllipse(in: CGRect(x: cx - r * 0.55, y: cy + r * 0.05, width: r * 0.34, height: r * 0.5))
    c.setFillColor(rgb(0xFFFFFF, 0.55))
    c.fillPath()

    c.restoreGState()
    ctx.flushGraphics()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "App/Kiri/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(size: CGFloat(px)).representation(using: .png, properties: [:])!
        try data.write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(out.path)")
