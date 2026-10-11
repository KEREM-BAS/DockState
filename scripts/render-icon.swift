// Renders the DockState app icon into the asset catalog.
//   swift scripts/render-icon.swift
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1) // top-left origin

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset * 0.9, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(srgbRed: 0.27, green: 0.56, blue: 0.98, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.09, green: 0.33, blue: 0.84, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    ctx.restoreGState()

    // Two windows: a large one and a smaller one docked against it.
    let u = body.width
    let line = u * 0.055
    func window(_ r: CGRect, fill: CGColor?) {
        let p = CGPath(roundedRect: r, cornerWidth: u * 0.05, cornerHeight: u * 0.05, transform: nil)
        if let fill { ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath() }
        ctx.addPath(p); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(line); ctx.strokePath()
        // title bar line
        ctx.move(to: CGPoint(x: r.minX + line / 2, y: r.minY + r.height * 0.24))
        ctx.addLine(to: CGPoint(x: r.maxX - line / 2, y: r.minY + r.height * 0.24))
        ctx.setLineWidth(line * 0.6); ctx.strokePath()
    }
    let big = CGRect(x: body.minX + u * 0.15, y: body.minY + u * 0.25, width: u * 0.48, height: u * 0.36)
    window(big, fill: nil)
    let small = CGRect(x: body.minX + u * 0.52, y: body.minY + u * 0.43, width: u * 0.33, height: u * 0.27)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: u * 0.03, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    window(small, fill: NSColor(srgbRed: 0.16, green: 0.44, blue: 0.92, alpha: 1).cgColor)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "DockState/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(size: px).write(to: dir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("Contents.json"))
print("Rendered \(images.count) icon images")
