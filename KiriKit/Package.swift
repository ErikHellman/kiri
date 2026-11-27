// swift-tools-version:6.2
// KiriKit: the Honey + Liquid Glass style kit (docs/DESIGN.md), the editor's
// document model and, in KiriSyntax, Tree-sitter syntax highlighting.
//
// The token layer and the document model (KiriKit) are plain Foundation so
// they build and test on Linux; the SwiftUI layer is behind
// `canImport(SwiftUI)`. KiriSyntax links Tree-sitter only on macOS.
import PackageDescription

let macOS = TargetDependencyCondition.when(platforms: [Platform.macOS])

/// CI sets KIRI_WARNINGS_AS_ERRORS=YES, so a warning in KiriKit fails the
/// build there (only this package's targets: dependencies still just warn).
/// Local builds only warn.
let swiftSettings: [SwiftSetting] = Context.environment["KIRI_WARNINGS_AS_ERRORS"] == "YES"
    ? [.treatAllWarnings(as: .error)] : []

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
    ("https://github.com/tree-sitter/tree-sitter-go", "0.25.0", "tree-sitter-go", "TreeSitterGo"),
    ("https://github.com/tree-sitter/tree-sitter-rust", "0.24.2", "tree-sitter-rust", "TreeSitterRust"),
    ("https://github.com/tree-sitter/tree-sitter-java", "0.23.5", "tree-sitter-java", "TreeSitterJava"),
    // fwcd's grammar ships the highlight query (the tree-sitter-grammars rewrite has none).
    ("https://github.com/fwcd/tree-sitter-kotlin", "0.3.8", "tree-sitter-kotlin", "TreeSitterKotlin"),
    ("https://github.com/tree-sitter/tree-sitter-c-sharp", "0.24.0", "tree-sitter-c-sharp", "TreeSitterCSharp"),
    ("https://github.com/tree-sitter/tree-sitter-c", "0.24.2", "tree-sitter-c", "TreeSitterC"),
    ("https://github.com/tree-sitter/tree-sitter-cpp", "0.23.4", "tree-sitter-cpp", "TreeSitterCPP"),
    ("https://github.com/tree-sitter-grammars/tree-sitter-zig", "1.1.2", "tree-sitter-zig", "TreeSitterZig"),
]

let package = Package(
    name: "KiriKit",
    // Liquid Glass (`glassEffect`, `GlassEffectContainer`) needs macOS 26.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KiriKit", targets: ["KiriKit"]),
        .library(name: "KiriSyntax", targets: ["KiriSyntax"]),
        .library(name: "KiriMarkdown", targets: ["KiriMarkdown"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        // CommonMark + GitHub tables, task lists and strikethrough (cmark-gfm), for the Markdown preview.
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.9.0"),
    ] + grammars.map { .package(url: $0.url, exact: $0.version) },
    targets: [
        .target(name: "KiriKit", resources: [
            // Nunito (SIL OFL 1.1), the Honey UI typeface (docs/DESIGN.md §4).
            .copy("Fonts"),
        ], swiftSettings: swiftSettings),
        .target(
            name: "KiriSyntax",
            dependencies: ["KiriKit", .product(name: "SwiftTreeSitter", package: "swift-tree-sitter", condition: macOS)]
                + grammars.map { .product(name: $0.product, package: $0.package, condition: macOS) },
            resources: [
                // Highlight queries copied from the pinned grammars (LICENSES.txt).
                .copy("Queries"),
            ],
            swiftSettings: swiftSettings
        ),
        // The Markdown preview: Markdown and front matter to HTML, and the
        // page's stylesheet and scripts (Mermaid among them), which the app
        // shows in a web view. Plain Foundation, so it tests on Linux.
        .target(
            name: "KiriMarkdown",
            dependencies: ["KiriKit", .product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Web")],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "KiriKitTests", dependencies: ["KiriKit"], swiftSettings: swiftSettings),
        .testTarget(name: "KiriMarkdownTests", dependencies: ["KiriMarkdown"], swiftSettings: swiftSettings),
        .testTarget(name: "KiriSyntaxTests", dependencies: ["KiriSyntax"], swiftSettings: swiftSettings),
    ]
)
