// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockStateKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DockStateCore", targets: ["DockStateCore"]),
        .library(name: "DockStateSystem", targets: ["DockStateSystem"]),
    ],
    targets: [
        // Pure logic: models, display/window matching, restore planning, undo, persistence.
        // No AppKit, no Accessibility — everything here is unit-testable on CI.
        .target(name: "DockStateCore"),
        // Thin adapters over Accessibility, CoreGraphics and AppKit.
        .target(name: "DockStateSystem", dependencies: ["DockStateCore"]),
        .testTarget(name: "DockStateCoreTests", dependencies: ["DockStateCore"]),
    ]
)
