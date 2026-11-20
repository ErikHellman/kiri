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

    @Test func radii() {
        #expect(Honey.Radius.allCases.map(\.value) == [20, 16, 12, 8])
    }
}
