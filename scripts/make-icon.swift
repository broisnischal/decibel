// Renders the app icon set: swift scripts/make-icon.swift Decibel/Assets.xcassets/AppIcon.appiconset
// A black speaker grille whose holes swell into rings of sound, like a halftone ripple.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
func grey(_ v: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: alpha) }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

/// Continuous-corner squircle (superellipse), closer to the macOS icon shape than a rounded rect.
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 4.3, steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c),
                        y: r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// Brightness of the grille at distance `d` from the centre (0...1): a bright core, then rings
/// one wavelength apart that fade towards the rim, like sound spreading from a speaker.
func ripple(_ d: CGFloat, field: CGFloat, wavelength: CGFloat) -> CGFloat {
    let core = exp(-pow(d / (0.32 * wavelength), 2))
    let rings = pow(0.5 + 0.5 * cos(2 * .pi * d / wavelength), 2.2) * pow(max(0, 1 - d / field), 0.3)
    return min(1, max(core, rings))
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024

    // macOS icon grid: 824 pt body centred on a 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: grey(0, 0.4))
    ctx.addPath(shape)
    ctx.setFillColor(grey(0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let c = CGPoint(x: body.midX, y: body.midY)

    // Black body, lit softly from above and from the centre.
    ctx.drawLinearGradient(gradient([grey(0.17), grey(0.08), grey(0.03)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.drawRadialGradient(gradient([white(0.11), white(0)]), startCenter: c, startRadius: 0,
                           endCenter: c, endRadius: 430 * s, options: [])

    let field = 360 * s, wavelength = 150 * s
    if px >= 128 {
        // Grille holes on concentric circles (a square or hex grid bends the rings into polygons),
        // coarser at 128 px so they don't blur away.
        let pitch = (px >= 256 ? 30 : 46) * s
        var dots: [(CGPoint, CGFloat)] = []
        for ring in 0...Int(field / pitch) {
            let r = CGFloat(ring) * pitch, count = max(1, Int((2 * .pi * r / pitch).rounded()))
            for i in 0..<count {
                let a = CGFloat(i) / CGFloat(count) * 2 * .pi + .pi / 2
                dots.append((CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r), ripple(r, field: field, wavelength: wavelength)))
            }
        }
        // Glow under the brightest holes, then the holes themselves.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 16 * s, color: white(0.6))
        for (p, k) in dots where k > 0.45 {
            ctx.setFillColor(white(k))
            ctx.fillEllipse(in: circle(p, pitch * (0.06 + 0.38 * k)))
        }
        ctx.restoreGState()
        for (p, k) in dots {
            ctx.setFillColor(white(0.14 + 0.86 * k))
            ctx.fillEllipse(in: circle(p, pitch * (0.06 + 0.38 * k)))
        }
    } else if px >= 64 {
        // At 64 px a grid would bend the rings into hexagons, so set the holes on true circles.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 20 * s, color: white(0.5))
        ctx.setFillColor(white(1))
        ctx.fillEllipse(in: circle(c, 54 * s))
        ctx.restoreGState()
        for (r, count, dot, alpha) in [(wavelength, 12, 27 * s, 1.0), (2 * wavelength, 22, 21 * s, 0.6)] as [(CGFloat, Int, CGFloat, CGFloat)] {
            ctx.setFillColor(white(alpha))
            for i in 0..<count {
                let a = CGFloat(i) / CGFloat(count) * 2 * .pi + .pi / 2
                ctx.fillEllipse(in: circle(CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r), dot))
            }
        }
    } else {
        // At 16 and 32 px the holes would blur into a grey disc, so draw the ripple itself: a core and
        // two rings, or one wider ring at 16 px where two would merge.
        let tiny = px < 32
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 24 * s, color: white(0.5))
        ctx.setFillColor(white(1))
        ctx.fillEllipse(in: circle(c, (tiny ? 96 : 66) * s))
        ctx.restoreGState()
        let rings: [(CGFloat, CGFloat, CGFloat)] = tiny ? [(250 * s, 84 * s, 1.0)] : [(wavelength, 58 * s, 1.0), (2 * wavelength, 46 * s, 0.5)]
        for (r, width, alpha) in rings {
            ctx.addEllipse(in: circle(c, r))
            ctx.setLineWidth(width)
            ctx.setStrokeColor(white(alpha))
            ctx.strokePath()
        }
    }
    ctx.restoreGState()

    // Hairline highlight on the top edge, as on Apple's own icons.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(5 * s)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([white(0.4), white(0.04), white(0.12)], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
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
