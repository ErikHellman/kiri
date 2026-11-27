import AppKit
import Observation

/// The editor's typeface (Settings ▸ Font), and the one place the
/// editor's fonts are made: its text, bold headings, and the line numbers.
/// The size stays the editor text size's (⌘+ and ⌘-).
///
/// The family is held here, in memory, so every window follows a change
/// at once; it is written to the preferences (a test launch keeps it among
/// its arguments instead, `-editorFont Menlo`). A family that is no longer
/// installed shows as the system's monospace, SF Mono, and comes back if
/// it is installed again.
@Observable final class EditorFont {
    static let shared = EditorFont()

    /// What the menu calls SF Mono, the system's monospace, which is not
    /// installed as a family of its own.
    static let systemName = "System (SF Mono)"

    /// The family chosen: "" for SF Mono.
    private(set) var family: String

    init() { family = UserDefaults.standard.string(forKey: Prefs.editorFontKey) ?? "" }

    /// The family the editor draws with: the chosen one while it is
    /// installed, "" (SF Mono) otherwise.
    var shown: String { Self.isInstalled(family) ? family : "" }

    /// Settings' menu: every window's editor follows at once.
    func choose(_ family: String) {
        guard family != self.family else { return }
        self.family = family
        let value: String? = family.isEmpty ? nil : family
        #if DEBUG || KIRI_SELFTEST
        // A test launch leaves the person's preferences as they are: its
        // choice is kept among the launch's arguments, where a setting
        // given on the command line lives.
        if SelfTest.isTestLaunch { SelfTest.setArgument(Prefs.editorFontKey, value); return }
        #endif
        if let value { UserDefaults.standard.set(value, forKey: Prefs.editorFontKey) } else {
            UserDefaults.standard.removeObject(forKey: Prefs.editorFontKey)
        }
    }

    // MARK: The families

    /// The installed families whose letters all have one width, by name,
    /// for the menu (SF Mono is its first item, apart). Read once: a font
    /// installed while Kiri runs shows after a relaunch.
    static let families: [String] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let candidates = Set(names.compactMap { NSFont(name: $0, size: 13)?.familyName })
        return candidates
            // Hidden system faces (".SF Mono"), and SF Mono itself where a
            // copy is installed: it is the first item already.
            .filter { !$0.hasPrefix(".") && $0 != "SF Mono" }
            .filter { isMonospaced(regular($0, size: 13)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    static func isInstalled(_ family: String) -> Bool {
        !family.isEmpty && NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false
    }

    /// A face that sets text: the letters, digits and brackets of code,
    /// every one as wide as the next. (The fixed-pitch trait alone lets in
    /// symbol and bitmap faces.)
    static func isMonospaced(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        let sample = "iW0m{_ "
        guard font.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: sample)) else { return false }
        let widths = sample.map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
        return widths.allSatisfy { abs($0 - widths[0]) < 0.01 }
    }

    // MARK: The fonts

    /// The editor's font in `family` ("" for SF Mono) at `size`, bold for
    /// a weight of semibold and up. A family that is gone, or has no such
    /// face, gives its regular face or SF Mono: never nothing.
    static func font(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        guard !family.isEmpty else { return system }
        if weight >= .semibold,
           let bold = NSFontManager.shared.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size),
           bold.familyName == family {
            return bold
        }
        return regular(family, size: size) ?? system
    }

    /// The line numbers' font: SF's digits for SF Mono (as wide as each
    /// other, and lighter than the text's), the family's own otherwise.
    static func gutterFont(_ family: String, size: CGFloat) -> NSFont {
        family.isEmpty ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : font(family, size: size)
    }

    private static func regular(_ family: String, size: CGFloat) -> NSFont? {
        let manager = NSFontManager.shared
        guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? manager.font(withFamily: family, traits: .unboldFontMask, weight: 5, size: size),
              font.familyName == family else { return nil }
        return font
    }
}
