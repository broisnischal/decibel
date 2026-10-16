// Generates the Icon Composer icon: swift scripts/make-icon.swift Decibel/AppIcon.icon [docs/icon.png]
// A black speaker grille whose holes swell into a bright core and rings of sound, like a ripple.
// The artwork is vector (SVG) on a full-bleed 1024 pt canvas: macOS applies the icon shape, lighting and
// Liquid Glass itself, renders it sharp at every size, and builds the legacy .icns for older systems.
// With a second argument, also renders a 512 px PNG preview (for the README) with Icon Composer's ictool.
import Foundation

let args = CommandLine.arguments.dropFirst()
let bundle = URL(fileURLWithPath: args.first ?? "AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

/// Brightness of the grille at distance `d` from the centre (0...1): a bright core, then rings one
/// wavelength apart that fade towards the rim, like sound spreading from a speaker.
func ripple(_ d: Double, field: Double, wavelength: Double) -> Double {
    let core = exp(-pow(d / (0.36 * wavelength), 2))
    let rings = pow(0.5 + 0.5 * cos(2 * .pi * d / wavelength), 2.2) * pow(max(0, 1 - d / field), 0.3)
    return min(1, max(core, rings))
}

// Holes on concentric circles (a square or hex grid bends the rings into polygons).
let centre = 512.0, pitch = 50.0, wavelength = 4 * pitch, field = 560.0 // rings land on every 4th circle of holes
var rings = "", grille = ""
for ring in 0...8 {
    let r = Double(ring) * pitch, count = max(1, Int((2 * .pi * r / pitch).rounded()))
    let k = ripple(r, field: field, wavelength: wavelength)
    let radius = pitch * (0.08 + 0.36 * k)
    for i in 0..<count {
        let a = Double(i) / Double(count) * 2 * .pi + .pi / 2
        let x = centre + cos(a) * r, y = centre - sin(a) * r
        let dot = String(format: "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"%.2f\"", x, y, radius)
        if k > 0.55 {
            rings += dot + String(format: " fill-opacity=\"%.3f\"/>\n", 0.55 + 0.45 * k)
        } else {
            grille += dot + String(format: " fill-opacity=\"%.3f\"/>\n", 0.16 + 0.6 * k)
        }
    }
}
func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n<g fill=\"#ffffff\">\n\(body)</g>\n</svg>\n"
}
try svg(rings).write(to: assets.appendingPathComponent("rings.svg"), atomically: true, encoding: .utf8)
try svg(grille).write(to: assets.appendingPathComponent("grille.svg"), atomically: true, encoding: .utf8)

// Front to back: the bright rings in Liquid Glass, then the faint grille texture, on a black fill.
let manifest = """
{
  "fill" : {
    "linear-gradient" : [
      "display-p3:0.17000,0.17000,0.18000,1.00000",
      "display-p3:0.02000,0.02000,0.02500,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "rings.svg",
          "name" : "rings"
        }
      ],
      "name" : "Rings",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "specular" : true,
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    },
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "grille.svg",
          "name" : "grille"
        }
      ],
      "name" : "Grille",
      "opacity" : 0.38,
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0
      },
      "specular" : false,
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""
try manifest.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Wrote \(bundle.path)")

if let preview = args.dropFirst().first {
    let ictool = Process()
    ictool.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")
    ictool.arguments = [bundle.path, "--export-image", "--output-file", preview, "--platform", "macOS",
                        "--rendition", "Default", "--width", "512", "--height", "512", "--scale", "1"]
    try ictool.run()
    ictool.waitUntilExit()
    print(ictool.terminationStatus == 0 ? "Wrote \(preview)" : "ictool failed (\(ictool.terminationStatus))")
}
