// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clippy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "clippy", targets: ["Clippy"]),
        .library(name: "ClippyCore", targets: ["ClippyCore"]),
    ],
    targets: [
        // Pure Foundation. No AppKit. Everything here is unit-testable on any
        // platform, which is deliberate: all the decisions live in this target
        // and all the untestable OS glue lives in Clippy.
        .target(name: "ClippyCore"),

        .executableTarget(
            name: "Clippy",
            dependencies: ["ClippyCore"]
        ),

        .testTarget(
            name: "ClippyCoreTests",
            dependencies: ["ClippyCore"]
        ),
    ]
)
