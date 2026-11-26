import Testing
@testable import KiriKit

/// The folder sidebar's file icons: every language has one, and every
/// tint can be seen on what the sidebar is filled with.
struct FileIconTests {
    @Test func everyLanguageButPlainTextHasAnIconOfItsOwn() {
        for language in Language.all where language != .plainText {
            let icon = FileIcon.of(language)
            #expect(icon != .document, "\(language.name) has the plain document")
            #expect(icon.tint != nil, "\(language.name) has no tint")
        }
        #expect(FileIcon.of(.plainText) == .document)
        #expect(FileIcon.document.tint == nil)
    }

    @Test func theIconComesFromTheFilesName() {
        #expect(FileIcon.forFile(named: "Greeter.swift") == FileIcon.of(.swift))
        #expect(FileIcon.forFile(named: "package.json") == FileIcon.of(.json))
        #expect(FileIcon.forFile(named: "Makefile") == FileIcon.of(.makefile))
        #expect(FileIcon.forFile(named: ".env.local") == FileIcon.of(.ini))
        #expect(FileIcon.forFile(named: "LICENSE") == .document)
        // Pictures, videos and archives open in a viewer, and show what they are.
        #expect(FileIcon.forFile(named: "photo.heic") == .image)
        #expect(FileIcon.forFile(named: "clip.mov") == .video)
        #expect(FileIcon.forFile(named: "site.tar.gz") == .archive)
    }

    @Test func aShapeForEachKindSoColorIsNotAllThatTellsThem() {
        // Code, data, settings, a script, a table and prose do not share a shape.
        let kinds: [Language] = [.swift, .json, .yaml, .shell, .csv, .markdown, .sql, .plainText]
        #expect(Set(kinds.map { FileIcon.of($0).symbol }).count == kinds.count)
        // Folders are amber: no file is tinted with the amber token.
        #expect(!FileIcon.tints.contains(.heading))
    }

    /// Icons are graphics: at least 3:1 (WCAG 1.4.11) on the sidebar's
    /// solid fill and what the glass is tinted toward (`surface-2`,
    /// `canvas`, `surface`), on a hovered row (`surface-2`) and on the
    /// current file's capsule (`accent-soft`). `fg-muted`, the plain
    /// document's color, is held to the same.
    @Test(arguments: Honey.Theme.all) func tintsShowOnTheSidebar(_ theme: Honey.Theme) {
        for m in HoneyContrastTests.modes {
            let tints = FileIcon.tints.map { ($0.rawValue, $0.token) } + [("fg-muted", Honey.fgMuted)]
            for (name, token) in tints {
                for bg in [Honey.surface2, Honey.canvas, Honey.surface, Honey.accentSoft] {
                    let r = Honey.contrast(theme[token].value(dark: m.dark, highContrast: m.hc),
                                           theme[bg].value(dark: m.dark, highContrast: m.hc))
                    #expect(r >= 3, "\(theme.id) \(name) on \(bg.name) in \(m): \(r)")
                }
            }
        }
    }
}
