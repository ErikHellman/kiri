import Testing
@testable import KiriKit

/// The contrast promises in docs/DESIGN.md §3 and §12, in every mode.
struct HoneyContrastTests {
    static let modes: [(dark: Bool, hc: Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    func ratio(_ a: Honey.Token, on b: Honey.Token, _ m: (dark: Bool, hc: Bool)) -> Double {
        Honey.contrast(a.value(dark: m.dark, highContrast: m.hc), b.value(dark: m.dark, highContrast: m.hc))
    }

    @Test func textOnSurfaces() {
        for m in Self.modes {
            let text = m.hc ? 7.0 : 4.5
            for bg in [Honey.surface, Honey.surface2, Honey.canvas, Honey.currentLine, Honey.selection] {
                #expect(ratio(Honey.fg, on: bg, m) >= text, "fg in \(m)")
            }
            #expect(ratio(Honey.fgMuted, on: Honey.surface, m) >= 4.5, "fg-muted in \(m)")
            #expect(ratio(Honey.accentInk, on: Honey.surface, m) >= 4.5, "accent-ink in \(m)")
            #expect(ratio(Honey.accentFg, on: Honey.accent, m) >= 7, "accent-fg in \(m)")
            #expect(ratio(Honey.ok, on: Honey.surface, m) >= 4.5, "ok in \(m)")
            #expect(ratio(Honey.danger, on: Honey.surface, m) >= 4.5, "danger in \(m)")
        }
    }

    @Test func editorMarks() {
        for m in Self.modes {
            // Line numbers are incidental, but stay ≥ 3:1 (4.5:1 with more contrast).
            let gutter = m.hc ? 4.5 : 3.0
            #expect(ratio(Honey.gutter, on: Honey.surface, m) >= gutter, "gutter in \(m)")
            #expect(ratio(Honey.gutter, on: Honey.currentLine, m) >= gutter, "gutter on current line in \(m)")
            // The caret and focus ring are UI graphics: ≥ 3:1.
            #expect(ratio(Honey.caret, on: Honey.surface, m) >= 3, "caret in \(m)")
            #expect(ratio(Honey.focus, on: Honey.surface2, m) >= 3, "focus in \(m)")
        }
    }

    @Test func tokenNamesAreUnique() {
        let names = Honey.allTokens.map(\.name)
        #expect(Set(names).count == names.count)
    }
}

struct HoneyMotionTests {
    @Test func systemFollowsTheOS() {
        #expect(HoneyAppearance(motion: .system).reduced(systemReduceMotion: true))
        #expect(!HoneyAppearance(motion: .system).reduced(systemReduceMotion: false))
    }

    @Test func overridesWin() {
        #expect(!HoneyAppearance(motion: .full).reduced(systemReduceMotion: true))
        #expect(HoneyAppearance(motion: .reduced).reduced(systemReduceMotion: false))
        #expect(HoneyAppearance(motion: .off).reduced(systemReduceMotion: false))
    }

    @Test func editorAnimation() {
        typealias A = EditorAnimation
        #expect(A.resolve(motion: .system, systemReduceMotion: false, typingAnimations: true) == .full)
        #expect(A.resolve(motion: .system, systemReduceMotion: true, typingAnimations: true) == .fades)
        #expect(A.resolve(motion: .full, systemReduceMotion: true, typingAnimations: true) == .full)
        #expect(A.resolve(motion: .reduced, systemReduceMotion: false, typingAnimations: true) == .fades)
        #expect(A.resolve(motion: .off, systemReduceMotion: false, typingAnimations: true) == .none)
        #expect(A.resolve(motion: .full, systemReduceMotion: false, typingAnimations: false) == .none)
    }

    @Test func radii() {
        #expect(Honey.Radius.allCases.map(\.value) == [20, 16, 12, 8])
    }
}

/// Syntax colors (DESIGN.md §3.1): readable on the editor surface and the
/// current line in every mode.
struct SyntaxContrastTests {
    @Test func syntaxOnEditor() {
        for m in HoneyContrastTests.modes {
            let target = m.hc ? 7.0 : 4.5
            for (name, token) in Honey.syntaxTokens {
                for bg in [Honey.surface, Honey.currentLine] {
                    let r = Honey.contrast(token.value(dark: m.dark, highContrast: m.hc),
                                           bg.value(dark: m.dark, highContrast: m.hc))
                    #expect(r >= target, "\(name) in \(m): \(r)")
                }
            }
        }
    }

    @Test func everyKindHasAToken() {
        for kind in SyntaxKind.allCases { _ = kind.token }
    }
}

struct SyntaxCaptureTests {
    @Test func captureNames() {
        #expect(SyntaxKind(capture: "keyword") == .keyword)
        #expect(SyntaxKind(capture: "keyword.control.conditional") == .keyword)
        #expect(SyntaxKind(capture: "string") == .string)
        #expect(SyntaxKind(capture: "string.escape") == .escape)
        #expect(SyntaxKind(capture: "string.special.key") == .property)
        #expect(SyntaxKind(capture: "number") == .number)
        #expect(SyntaxKind(capture: "constant.builtin") == .number)
        #expect(SyntaxKind(capture: "comment.documentation") == .comment)
        #expect(SyntaxKind(capture: "function.method") == .function)
        #expect(SyntaxKind(capture: "function.macro") == .keyword)
        #expect(SyntaxKind(capture: "type.builtin") == .type)
        #expect(SyntaxKind(capture: "constructor") == .type)
        #expect(SyntaxKind(capture: "property") == .property)
        #expect(SyntaxKind(capture: "tag") == .tag)
        #expect(SyntaxKind(capture: "tag.attribute") == .attribute)
        #expect(SyntaxKind(capture: "punctuation.bracket") == .punctuation)
        #expect(SyntaxKind(capture: "text.title") == .heading)
        #expect(SyntaxKind(capture: "markup.heading.1") == .heading)
        #expect(SyntaxKind(capture: "text.literal") == .code)
        #expect(SyntaxKind(capture: "variable") == nil)
        #expect(SyntaxKind(capture: "variable.builtin") == .keyword)
        #expect(SyntaxKind(capture: "") == nil)
    }
}

struct FallbackHighlighterTests {
    func kinds(_ text: String, _ lang: Language) -> [(String, SyntaxKind)] {
        let u = Array(text.utf16)
        return FallbackHighlighter.spans(in: text, language: lang).map {
            (String(decoding: u[$0.range], as: UTF16.self), $0.kind)
        }
    }

    @Test func toml() {
        let k = kinds("[package]\nname = \"kiri\" # the app\nversion = 2\n", .toml)
        #expect(k.map(\.0) == ["[package]", "name", "\"kiri\"", "# the app", "version", "2"])
        #expect(k.map(\.1) == [.heading, .property, .string, .comment, .property, .number])
    }

    @Test func escapedQuotes() {
        let k = kinds(#"x = "a \" b" // done"#, .rust)
        #expect(k.map(\.0) == [#""a \" b""#, "// done"])
    }

    @Test func unterminatedStringStopsAtLineEnd() {
        let k = kinds("\"open\nlet x = 1", .rust)
        #expect(k.map(\.0) == ["\"open", "let", "1"])
    }

    @Test func rangeStartsAtLineBoundary() {
        let text = "// a comment\nlet y = 2\n"
        let spans = FallbackHighlighter.spans(in: text, language: .rust, range: 5..<20)
        #expect(spans.first?.range == 0..<12)
    }
}
