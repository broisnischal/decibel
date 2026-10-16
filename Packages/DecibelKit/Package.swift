// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DecibelKit",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "DecibelKit", targets: ["DecibelKit"]),
    ],
    targets: [
        // Real-time DSP and the HAL IOProc. Plain C so the render thread never touches the Swift runtime.
        .target(
            name: "BSKernel",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .target(
            name: "DecibelKit",
            dependencies: ["BSKernel"],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .testTarget(
            name: "DecibelKitTests",
            dependencies: ["DecibelKit", "BSKernel"]
        ),
    ]
)
