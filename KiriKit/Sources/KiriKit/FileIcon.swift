import Foundation

/// The small icon a file has in the folder sidebar: a shape for what kind
/// of file it is and a tint for its language, so a folder can be scanned
/// by color. The tints are the syntax tokens the editor already uses, and
/// a file Kiri has no language for keeps the plain muted document.
///
/// The shape carries the kind (code, markup, data, settings, a script, a
/// table, prose) and the tint only tells languages of a kind apart, so
/// color is never the only thing that says what a file is.
public struct FileIcon: Hashable, Sendable {
    /// An SF Symbol's name.
    public let symbol: String
    /// The syntax token it is tinted with, or nil for `fg-muted`.
    public let tint: SyntaxKind?

    public init(symbol: String, tint: SyntaxKind? = nil) {
        self.symbol = symbol
        self.tint = tint
    }

    /// A file of no known language, and plain text.
    public static let document = FileIcon(symbol: "doc.text")

    private static let code = "chevron.left.forwardslash.chevron.right"
    private static let data = "curlybraces"
    private static let settings = "gearshape"
    private static let script = "terminal"
    private static let table = "tablecells"
    private static let prose = "doc.richtext"
    private static let database = "cylinder"

    /// By language id. Markup shares the code shape (it is tags) in the
    /// tag color; folders are amber, so no file is (`heading`, the amber
    /// token, is not used).
    private static let byLanguage: [String: FileIcon] = [
        Language.markdown.id: FileIcon(symbol: prose, tint: .function),
        Language.json.id: FileIcon(symbol: data, tint: .attribute),
        Language.yaml.id: FileIcon(symbol: settings, tint: .property),
        Language.toml.id: FileIcon(symbol: settings, tint: .property),
        Language.ini.id: FileIcon(symbol: settings, tint: .property),
        Language.xml.id: FileIcon(symbol: code, tint: .tag),
        Language.html.id: FileIcon(symbol: code, tint: .tag),
        Language.css.id: FileIcon(symbol: data, tint: .type),
        Language.csv.id: FileIcon(symbol: table, tint: .string),
        Language.swift.id: FileIcon(symbol: code, tint: .number),
        Language.javascript.id: FileIcon(symbol: code, tint: .attribute),
        Language.typescript.id: FileIcon(symbol: code, tint: .function),
        Language.tsx.id: FileIcon(symbol: code, tint: .function),
        Language.python.id: FileIcon(symbol: code, tint: .string),
        Language.ruby.id: FileIcon(symbol: code, tint: .tag),
        Language.go.id: FileIcon(symbol: code, tint: .function),
        Language.rust.id: FileIcon(symbol: code, tint: .property),
        Language.java.id: FileIcon(symbol: code, tint: .tag),
        Language.kotlin.id: FileIcon(symbol: code, tint: .type),
        Language.csharp.id: FileIcon(symbol: code, tint: .type),
        Language.c.id: FileIcon(symbol: code, tint: .keyword),
        Language.cpp.id: FileIcon(symbol: code, tint: .keyword),
        Language.objectiveC.id: FileIcon(symbol: code, tint: .keyword),
        Language.zig.id: FileIcon(symbol: code, tint: .number),
        Language.gradle.id: FileIcon(symbol: code, tint: .string),
        Language.sql.id: FileIcon(symbol: database, tint: .escape),
        Language.shell.id: FileIcon(symbol: script, tint: .string),
        Language.makefile.id: FileIcon(symbol: script, tint: .property),
        Language.dockerfile.id: FileIcon(symbol: script, tint: .function),
    ]

    /// The tints in use: each is checked for contrast on the sidebar's
    /// fills in every theme and mode (`FileIconTests`).
    public static let tints: Set<SyntaxKind> = Set(byLanguage.values.compactMap(\.tint))

    public static func of(_ language: Language) -> FileIcon { byLanguage[language.id] ?? document }

    /// The icon for a file, from its name alone (nothing is read): a
    /// picture, a video or an archive (which Kiri shows in a viewer) by
    /// its kind, any other by its language.
    public static func forFile(named name: String) -> FileIcon {
        switch MediaKind.guess(fileName: name) {
        case .image?: image
        case .video?: video
        case .archive?: archive
        case nil: of(Language.detect(fileName: name))
        }
    }

    // In tints the languages use already (`tints`).
    public static let image = FileIcon(symbol: "photo", tint: .function)
    public static let video = FileIcon(symbol: "film", tint: .keyword)
    public static let archive = FileIcon(symbol: "doc.zipper", tint: .property)
}
