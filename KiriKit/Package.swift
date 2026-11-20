// swift-tools-version:6.2
// KiriKit: the Honey + Liquid Glass style kit (docs/DESIGN.md), the editor's
// document model and, in KiriSyntax, Tree-sitter syntax highlighting.
//
// The token layer and the document model (KiriKit) are plain Foundation so
// they build and test on Linux; the SwiftUI layer is behind
// `canImport(SwiftUI)`. KiriSyntax links Tree-sitter only on macOS.
import PackageDescription

let macOS = TargetDependencyCondition.when(platforms: [Platform.macOS])

/// Tree-sitter grammars, pinned to exact releases. (Newer JavaScript, Python,
/// CSS and YAML releases decide on `scanner.c` with a relative-path
/// `fileExists` in their manifests, which drops the scanner under SwiftPM.)
let grammars: [(url: String, version: Version, package: String, product: String)] = [
    ("https://github.com/tree-sitter/tree-sitter-json", "0.24.8", "tree-sitter-json", "TreeSitterJSON"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-yaml", "0.7.0", "tree-sitter-yaml", "TreeSitterYAML"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-markdown", "0.5.4", "tree-sitter-markdown",
     "TreeSitterMarkdown"),
    ("https://github.com/tree-sitter/tree-sitter-javascript", "0.23.1", "tree-sitter-javascript",
     "TreeSitterJavaScript"),
    ("https://github.com/tree-sitter/tree-sitter-typescript", "0.23.2", "tree-sitter-typescript",
     "TreeSitterTypeScript"),
    ("https://github.com/tree-sitter/tree-sitter-python", "0.23.6", "tree-sitter-python", "TreeSitterPython"),
    ("https://github.com/tree-sitter/tree-sitter-bash", "0.25.1", "tree-sitter-bash", "TreeSitterBash"),
    ("https://github.com/tree-sitter/tree-sitter-html", "0.23.2", "tree-sitter-html", "TreeSitterHTML"),
    ("https://github.com/tree-sitter/tree-sitter-css", "0.23.2", "tree-sitter-css", "TreeSitterCSS"),
    // Upstream keeps generated parsers on this tag only.
    ("https://github.com/alex-pinkus/tree-sitter-swift", "0.7.4-with-generated-files", "tree-sitter-swift",
     "TreeSitterSwift"),
]

let package = Package(
    name: "KiriKit",
    // Liquid Glass (`glassEffect`, `GlassEffectContainer`) needs macOS 26.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KiriKit", targets: ["KiriKit"]),
        .library(name: "KiriSyntax", targets: ["KiriSyntax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.10.0"),
    ] + grammars.map { .package(url: $0.url, exact: $0.version) },
    targets: [
        .target(name: "KiriKit", resources: [
            // Nunito (SIL OFL 1.1), the Honey UI typeface (docs/DESIGN.md §4).
            .copy("Fonts"),
        ]),
        .target(
            name: "KiriSyntax",
            dependencies: ["KiriKit", .product(name: "SwiftTreeSitter", package: "swift-tree-sitter", condition: macOS)]
                + grammars.map { .product(name: $0.product, package: $0.package, condition: macOS) },
            resources: [
                // Highlight queries copied from the pinned grammars (LICENSES.txt).
                .copy("Queries"),
            ]
        ),
        .testTarget(name: "KiriKitTests", dependencies: ["KiriKit"]),
        .testTarget(name: "KiriSyntaxTests", dependencies: ["KiriSyntax"]),
    ]
)
