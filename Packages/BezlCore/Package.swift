// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BezlCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "BezlCore", targets: ["BezlCore", "BezlRing"]),
    ],
    targets: [
        // Lock-free single-producer/single-consumer float ring buffer, written in C so the
        // real-time audio callback can use C11 atomics on macOS 14 (Swift's Synchronization
        // atomics need macOS 15).
        .target(name: "BezlRing"),
        .target(name: "BezlCore"),
        .testTarget(name: "BezlCoreTests", dependencies: ["BezlCore", "BezlRing"]),
    ]
)
