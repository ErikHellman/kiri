// swift-tools-version:6.2
// KiriKit: the Honey + Liquid Glass style kit (docs/DESIGN.md) and, later,
// the editor's document model. The token layer (Honey.swift) is plain
// Foundation so it also builds and tests on Linux; the SwiftUI layer is
// behind `canImport(SwiftUI)`.
import PackageDescription

let package = Package(
    name: "KiriKit",
    // Liquid Glass (`glassEffect`, `GlassEffectContainer`) needs macOS 26.
    platforms: [.macOS(.v26)],
    products: [.library(name: "KiriKit", targets: ["KiriKit"])],
    targets: [
        .target(name: "KiriKit", resources: [
            // Nunito (SIL OFL 1.1), the Honey UI typeface (docs/DESIGN.md §4).
            .copy("Fonts"),
        ]),
        .testTarget(name: "KiriKitTests", dependencies: ["KiriKit"]),
    ]
)
