// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterSoundKit",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "BetterSoundKit", targets: ["BetterSoundKit"]),
    ],
    targets: [
        // Real-time DSP and the HAL IOProc. Plain C so the render thread never touches the Swift runtime.
        .target(
            name: "BSKernel",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .target(
            name: "BetterSoundKit",
            dependencies: ["BSKernel"],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .testTarget(
            name: "BetterSoundKitTests",
            dependencies: ["BetterSoundKit", "BSKernel"]
        ),
    ]
)
