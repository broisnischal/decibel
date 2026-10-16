// Renders the app icon set: swift scripts/make-icon.swift Decibel/Assets.xcassets/AppIcon.appiconset
// A spun-aluminium volume knob turned up into the red, ringed by an LED level meter, on an anodised plate.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let x = a.components!, y = b.components!
    return CGColor(srgbRed: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t, blue: x[2] + (y[2] - x[2]) * t,
                   alpha: x[3] + (y[3] - x[3]) * t)
}

/// Level-meter colour from quiet (0) to loud (1).
func meter(_ t: CGFloat) -> CGColor {
    let stops: [(CGFloat, CGColor)] = [(0, rgb(0x1ED67A)), (0.4, rgb(0x8EE03A)), (0.55, rgb(0xFFD23C)),
                                       (0.68, rgb(0xFF8A22)), (0.8, rgb(0xFF3B3B)), (1, rgb(0xFF1F5A))]
    let i = stops.lastIndex { $0.0 <= t } ?? 0
    guard i < stops.count - 1 else { return stops[i].1 }
    return mix(stops[i].1, stops[i + 1].1, (t - stops[i].0) / (stops[i + 1].0 - stops[i].0))
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

/// A capsule lying along the ray at `angle` from `centre`, between radii `r0` and `r1`.
func radialCapsule(_ centre: CGPoint, _ angle: CGFloat, _ r0: CGFloat, _ r1: CGFloat, width: CGFloat) -> CGPath {
    let rect = CGRect(x: r0, y: -width / 2, width: r1 - r0, height: width)
    var t = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: angle)
    return CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: &t)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

/// Seeded so re-running the script reproduces identical PNGs.
struct Noise {
    var state: UInt64 = 0x2545F4914F6CDD1D
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
    }
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }
    var noise = Noise()

    // macOS icon grid: 824 pt body centred on a 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: rgb(0x000000, 0.4))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Anodised plate: lit from above, with a fine grain.
    ctx.drawLinearGradient(gradient([rgb(0x3A3E48), rgb(0x1E2027), rgb(0x0E0F13)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)]),
                           startCenter: CGPoint(x: body.midX, y: body.maxY), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY), endRadius: 620 * s, options: [])
    if px >= 128 {
        for _ in 0..<(px * px / 40) {
            let light = noise.next() > 0.5
            ctx.setFillColor(light ? rgb(0xFFFFFF, 0.035) : rgb(0x000000, 0.06))
            ctx.fill(CGRect(x: body.minX + noise.next() * body.width, y: body.minY + noise.next() * body.height,
                            width: max(1, s), height: max(1, s)))
        }
    }

    let centre = CGPoint(x: body.midX, y: body.midY - 14 * s)
    let start = CGFloat.pi * 1.25, sweep = CGFloat.pi * 1.5 // 7:30 round to 4:30, like a real volume knob
    let segments = 27, lit = 22
    let level = CGFloat(lit - 1) / CGFloat(segments - 1)
    let pointer = start - sweep * level

    // LED meter ring: recessed lenses, lit from quiet green into the red.
    let lenses = (0..<segments).map { i -> (CGPath, CGColor, Bool) in
        let t = CGFloat(i) / CGFloat(segments - 1)
        return (radialCapsule(centre, start - sweep * t, 304 * s, 356 * s, width: 22 * s), meter(t), i < lit)
    }
    for (path, color, on) in lenses where !on {
        ctx.addPath(path)
        ctx.setFillColor(mix(rgb(0x15161B), color, 0.14))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(0x000000, 0.5))
        ctx.setLineWidth(2 * s)
        ctx.strokePath()
    }
    for (path, color, on) in lenses where on {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 34 * s, color: color.copy(alpha: 0.95)!)
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }
    for (i, (_, color, on)) in lenses.enumerated() where on {
        let angle = start - sweep * CGFloat(i) / CGFloat(segments - 1)
        ctx.addPath(radialCapsule(centre, angle, 314 * s, 346 * s, width: 9 * s)) // hot core
        ctx.setFillColor(mix(color, rgb(0xFFFFFF), 0.55).copy(alpha: 0.85)!)
        ctx.fillPath()
    }

    // Engraved "dB" in the gap at the bottom of the scale.
    if px >= 64 {
        let font = NSFont.systemFont(ofSize: 58 * s, weight: .bold)
        func engrave(_ color: CGColor, dy: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "dB", attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: 2 * s,
            ]))
            let b = CTLineGetImageBounds(line, ctx)
            ctx.textPosition = CGPoint(x: centre.x - b.midX, y: body.minY + 74 * s - b.midY + dy)
            CTLineDraw(line, ctx)
        }
        engrave(rgb(0xFFFFFF, 0.10), dy: -2 * s)
        engrave(rgb(0x8B909B, 0.75), dy: 0)
    }

    // Knob: a long soft shadow and a tight contact shadow ground it on the plate.
    let rk = 230 * s, rf = 186 * s
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -34 * s), blur: 70 * s, color: rgb(0x000000, 0.85))
    ctx.fillEllipse(in: circle(centre, rk))
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 12 * s, color: rgb(0x000000, 0.7))
    ctx.fillEllipse(in: circle(centre, rk))
    ctx.restoreGState()

    // Knurled skirt.
    ctx.saveGState()
    ctx.addEllipse(in: circle(centre, rk))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x6A6F79), rgb(0x34373E), rgb(0x16171B)], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: centre.y + rk), end: CGPoint(x: 0, y: centre.y - rk), options: [])
    let ridges = 120
    ctx.setLineWidth(max(0.5, 3.2 * s))
    for i in 0..<ridges {
        let a = CGFloat(i) / CGFloat(ridges) * 2 * .pi
        for (offset, color) in [(0.0, rgb(0xFFFFFF, 0.16)), (0.5, rgb(0x000000, 0.35))] {
            let b = a + CGFloat(offset) * 2 * .pi / CGFloat(ridges)
            ctx.move(to: CGPoint(x: centre.x + cos(b) * rf, y: centre.y + sin(b) * rf))
            ctx.addLine(to: CGPoint(x: centre.x + cos(b) * rk, y: centre.y + sin(b) * rk))
            ctx.setStrokeColor(color)
            ctx.strokePath()
        }
    }
    ctx.restoreGState()
    ctx.addEllipse(in: circle(centre, rk - 1 * s))
    ctx.setStrokeColor(rgb(0x000000, 0.6))
    ctx.setLineWidth(2 * s)
    ctx.strokePath()

    // Bevel catching the light between skirt and face.
    ctx.saveGState()
    ctx.addEllipse(in: circle(centre, rf + 11 * s))
    ctx.addEllipse(in: circle(centre, rf))
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([rgb(0xF4F6F9), rgb(0x9A9EA7), rgb(0x2C2E34)], [0, 0.45, 1]),
                           start: CGPoint(x: centre.x, y: centre.y + rf), end: CGPoint(x: centre.x, y: centre.y - rf),
                           options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: circle(centre, rf + 11 * s))
    ctx.setStrokeColor(rgb(0x000000, 0.55))
    ctx.setLineWidth(2.5 * s)
    ctx.strokePath()

    // Spun-aluminium face: conic sheen, concentric machining marks, then a gentle dome.
    ctx.saveGState()
    ctx.addEllipse(in: circle(centre, rf))
    ctx.clip()
    let metal = [rgb(0xC9CDD4), rgb(0xFCFDFE), rgb(0xB4B9C1), rgb(0x7D828B), rgb(0xA7ACB4),
                 rgb(0xF2F4F7), rgb(0xB0B5BD), rgb(0x868B94), rgb(0xC9CDD4)]
    let wedges = 720
    for i in 0..<wedges { // Conic sheen, drawn as overlapping wedges.
        let t = CGFloat(i) / CGFloat(wedges) * CGFloat(metal.count - 1)
        let a = CGFloat(i) / CGFloat(wedges) * 2 * .pi + .pi / 5
        ctx.move(to: centre)
        ctx.addArc(center: centre, radius: rf + 2 * s, startAngle: a, endAngle: a + 2 * .pi / CGFloat(wedges) * 1.6, clockwise: false)
        ctx.closePath()
        ctx.setFillColor(mix(metal[Int(t)], metal[min(Int(t) + 1, metal.count - 1)], t - floor(t)))
        ctx.fillPath()
    }
    var r = 2 * s
    while r < rf {
        ctx.addEllipse(in: circle(centre, r))
        ctx.setStrokeColor(noise.next() > 0.5 ? rgb(0xFFFFFF, 0.02 + noise.next() * 0.06) : rgb(0x000000, 0.02 + noise.next() * 0.05))
        ctx.setLineWidth(max(0.25, 1.1 * s))
        ctx.strokePath()
        r += (1.2 + noise.next() * 1.4) * s
    }
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)]),
                           startCenter: CGPoint(x: centre.x - 70 * s, y: centre.y + 90 * s), startRadius: 0,
                           endCenter: CGPoint(x: centre.x - 70 * s, y: centre.y + 90 * s), endRadius: rf * 1.3, options: [])
    ctx.drawLinearGradient(gradient([rgb(0x000000, 0), rgb(0x000000, 0.22)]),
                           start: CGPoint(x: 0, y: centre.y + rf * 0.2), end: CGPoint(x: 0, y: centre.y - rf), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: circle(centre, rf))
    ctx.setStrokeColor(rgb(0x000000, 0.35))
    ctx.setLineWidth(2 * s)
    ctx.strokePath()

    // Pointer: an engraved slot with an LED inside, matching the loudest lit segment.
    let tip = meter(level)
    let slot = radialCapsule(centre, pointer, 104 * s, 168 * s, width: 24 * s)
    ctx.saveGState()
    ctx.addPath(slot)
    ctx.setFillColor(rgb(0x1A1B20))
    ctx.fillPath()
    ctx.addPath(slot)
    ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -4 * s), blur: 6 * s, color: rgb(0x000000, 0.9))
    ctx.addRect(circle(centre, rk))
    ctx.addPath(slot)
    ctx.fillPath(using: .evenOdd) // inner shadow
    ctx.restoreGState()
    let led = radialCapsule(centre, pointer, 112 * s, 160 * s, width: 13 * s)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22 * s, color: tip)
    ctx.addPath(led)
    ctx.setFillColor(tip)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(radialCapsule(centre, pointer, 118 * s, 154 * s, width: 5 * s))
    ctx.setFillColor(mix(tip, rgb(0xFFFFFF), 0.6))
    ctx.fillPath()

    ctx.restoreGState()

    // Hairline highlight on the plate's top edge, like light catching a machined chamfer.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(5 * s)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.32), rgb(0xFFFFFF, 0.02), rgb(0xFFFFFF, 0.08)], [0, 0.4, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
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
