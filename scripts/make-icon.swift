// Renders the app icon set: swift scripts/make-icon.swift Decibel/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Continuous-corner squircle (superellipse), closer to the macOS icon shape than a rounded rect.
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 4.3, steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c)
        let y = r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// Loudness ramp, like a level meter: green, amber, then red at the loud end.
let meter = [rgb(0x2EE6A6), rgb(0xB8F05A), rgb(0xFFC94D), rgb(0xFF7A45), rgb(0xFF3D6E)]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: 824 pt body centred on a 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Deep indigo body with a warm bloom rising behind the loud end of the waveform.
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2A2F5C), rgb(0x161937), rgb(0x0A0B1C)] as CFArray,
                        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    let bloom = CGGradient(colorsSpace: space, colors: [rgb(0xFF5A6E, 0.30), rgb(0x7A5CFF, 0.12), rgb(0x7A5CFF, 0)] as CFArray,
                           locations: [0, 0.5, 1])!
    let bloomCentre = CGPoint(x: body.midX + 120 * s, y: body.midY)
    ctx.drawRadialGradient(bloom, startCenter: bloomCentre, startRadius: 0, endCenter: bloomCentre, endRadius: 520 * s, options: [])

    // A crescendo: five capsules growing louder left to right, centred like a waveform.
    let heights: [CGFloat] = [0.30, 0.50, 0.40, 0.74, 1.0]
    let barWidth = 84 * s, gap = 34 * s, maxHeight = 560 * s
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let bars = heights.enumerated().map { i, h in
        let rect = CGRect(x: body.midX - total / 2 + CGFloat(i) * (barWidth + gap), y: body.midY - maxHeight * h / 2,
                          width: barWidth, height: maxHeight * h)
        return CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    }
    let span = (start: CGPoint(x: body.midX - total / 2, y: 0), end: CGPoint(x: body.midX + total / 2, y: 0))
    let ramp = CGGradient(colorsSpace: space, colors: meter as CFArray, locations: [0, 0.25, 0.5, 0.75, 1])!

    // Glow: each bar casts light in its own colour.
    for (i, bar) in bars.enumerated() {
        let color = meter[i * (meter.count - 1) / (bars.count - 1)]
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 70 * s, color: color.copy(alpha: 0.75))
        ctx.addPath(bar)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Fill with the continuous ramp, then a soft top sheen.
    let allBars = CGMutablePath()
    bars.forEach { allBars.addPath($0) }
    ctx.saveGState()
    ctx.addPath(allBars)
    ctx.clip()
    ctx.drawLinearGradient(ramp, start: span.start, end: span.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0), rgb(0x000000, 0.12)] as CFArray,
                           locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.midY + maxHeight / 2), end: CGPoint(x: 0, y: body.midY - maxHeight / 2), options: [])
    ctx.restoreGState()

    // Hairline highlight on the top edge, like light catching glass.
    let rim = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 0.35])!
    ctx.addPath(shape)
    ctx.setLineWidth(6 * s)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(rim, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
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
