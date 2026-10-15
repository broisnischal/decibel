// Renders the app icon set: swift scripts/make-icon.swift Forte/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024

    // macOS icon grid: 824 pt body centred on a 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 1.0, green: 0.66, blue: 0.22, alpha: 1).cgColor,
        NSColor(red: 0.96, green: 0.36, blue: 0.18, alpha: 1).cgColor,
        NSColor(red: 0.78, green: 0.16, blue: 0.28, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // The forte marking from sheet music: a bold italic f.
    let font = NSFont(name: "Baskerville-BoldItalic", size: 660 * s) ?? NSFont.systemFont(ofSize: 660 * s, weight: .heavy)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "f", attributes: [
        .font: font, .foregroundColor: NSColor.white,
    ]))
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.textPosition = CGPoint(x: body.midX - bounds.midX, y: body.midY - bounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
