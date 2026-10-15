// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForteKit",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "ForteKit", targets: ["ForteKit"]),
    ],
    targets: [
        // Real-time DSP and the HAL IOProc. Plain C so the render thread never touches the Swift runtime.
        .target(
            name: "BSKernel",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .target(
            name: "ForteKit",
            dependencies: ["BSKernel"],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .testTarget(
            name: "ForteKitTests",
            dependencies: ["ForteKit", "BSKernel"]
        ),
    ]
)
