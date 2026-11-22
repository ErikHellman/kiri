#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

extension SelfTest {
    /// Settings, in its own window, opened from the app menu as ⌘, opens
    /// it: the theme swatches show a theme while the pointer or the
    /// keyboard is on one and put the chosen one back after, and a press
    /// chooses one. None of it may write a saved preference.
    ///
    /// The pointer can't be moved by a test, so hovering calls what the
    /// swatch's hover calls (`SwatchPreview.pointer`); a swatch is pressed
    /// as VoiceOver presses it, which runs the button's own action.
    /// `-KiriSettingsTest YES` runs these alone.
    static func settingsStage(_ original: NSWindow) async {
        let domain = Bundle.main.bundleIdentifier ?? ""
        let saved = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        func given(_ key: String) -> String? { UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String }
        let givenTheme = given(Prefs.colorThemeKey)
        let preview = ThemePreview.shared
        let chosen = Honey.theme, others = Honey.Theme.all.filter { $0 != Honey.theme }
        // Without the crossfade, a preview shows at once.
        ThemeFade.selfTestMotion = (.off, false)
        defer {
            ThemeFade.selfTestMotion = nil
            original.orderFront(nil)
            FrontEditor.shared.selfTestMain(original)
        }

        guard let settings = await openSettings() else { report(false, "Settings opens from the app menu"); return }
        await settle(300)
        report(settings.firstResponder === settings && preview.theme == nil && Honey.theme == chosen,
               "Settings opens with no control focused and no theme shown in place of the chosen one (first responder \(settings.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")

        // The pointer: on a swatch its theme shows, on the next one that
        // one (entered before the last says it was left), off them the
        // chosen theme again.
        SwatchPreview.pointer(others[0])
        let onFirst = Honey.theme == others[0] && preview.theme == others[0]
        SwatchPreview.pointer(others[1])
        SwatchPreview.pointer(nil, leaving: others[0])
        let onSecond = Honey.theme == others[1]
        SwatchPreview.pointer(nil, leaving: others[1])
        report(onFirst && onSecond && Honey.theme == chosen && preview.theme == nil,
               "the pointer on a swatch shows its theme in every window, the next swatch shows its own, and off the swatches the chosen theme is back (\(onFirst), \(onSecond), \(Honey.theme.name))")

        // The keyboard: only a key that moves it onto a swatch shows the
        // theme (a window that opens with the keyboard on one shows
        // nothing); the pointer wins while it is on one.
        SwatchPreview.keyboard(others[2], byKey: false)
        let notByOpening = Honey.theme == chosen && preview.theme == nil
        SwatchPreview.keyboard(others[2], byKey: true)
        let byKey = Honey.theme == others[2]
        SwatchPreview.pointer(others[3])
        let pointerWins = Honey.theme == others[3]
        SwatchPreview.pointer(nil, leaving: others[3])
        let keyboardAgain = Honey.theme == others[2]
        // The window going to the back takes the keyboard's preview down.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        await settle(60)
        report(notByOpening && byKey && pointerWins && keyboardAgain && Honey.theme == chosen && preview.theme == nil,
               "the keyboard on a swatch shows its theme only when a key moved it there, the pointer goes before it, and the Settings window going to the back puts the chosen theme back (\(notByOpening), \(byKey), \(pointerWins), \(keyboardAgain), \(Honey.theme.name))")

        // A press chooses: in a test launch the setting is one of the
        // launch's arguments, and the swatch says it is selected.
        await wakeAccessibility()
        func swatch(_ theme: Honey.Theme) -> AccessibilityElement? {
            accessibilityElements(of: settings).first { $0.role == NSAccessibility.Role.button.rawValue && $0.name == theme.name }
        }
        if let button = swatch(others[1]), button.object.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
            SwatchPreview.pointer(others[1])
            _ = button.object.perform(NSSelectorFromString("accessibilityPerformPress"))
            await settle(200)
            let selected = swatch(others[1])?.selected == true && swatch(chosen)?.selected == false
            let kept = given(Prefs.colorThemeKey) == others[1].id && Honey.theme == others[1]
            SwatchPreview.pointer(nil, leaving: others[1])
            let stays = Honey.theme == others[1]
            report(kept && selected && stays,
                   "pressing a swatch chooses its theme (here among the launch's arguments), the swatch is selected, and the pointer leaving it keeps it (\(kept), \(selected), \(stays))")
        } else {
            report(false, "the swatches are buttons VoiceOver can press (\(accessibilityElements(of: settings).filter { $0.role == NSAccessibility.Role.button.rawValue }.map(\.name)))")
        }
        setArgument(Prefs.colorThemeKey, givenTheme)
        preview.end()
        ThemeController.apply()

        await fontChecks(original, settings: settings)

        // Closing Settings with the pointer still on a swatch (it never
        // says it left) puts the chosen theme back.
        SwatchPreview.pointer(others[4])
        let shownBeforeClose = Honey.theme == others[4]
        settings.performClose(nil)
        for _ in 0..<40 where Honey.theme != chosen { await settle(25) }
        report(shownBeforeClose && Honey.theme == chosen && preview.theme == nil,
               "closing Settings while a swatch is under the pointer puts the chosen theme back (\(Honey.theme.name))")

        let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        report(NSDictionary(dictionary: saved).isEqual(to: after), "nothing in Settings' checks wrote a saved preference")
    }

    /// Settings ▸ Font: what the menu lists, and every window's editor
    /// (its text, bold headings and line numbers) following a choice at
    /// once, at the size it had; a family that is gone gives SF Mono.
    private static func fontChecks(_ original: NSWindow, settings: NSWindow) async {
        let store = EditorFont.shared
        let givenFamily = store.family
        let families = EditorFont.families
        print("SELFTEST info editor fonts: \(families.joined(separator: ", "))")
        // Measured here, apart from how the list was made: every family's
        // regular face sets i, W, m, 0 and a space equally wide.
        let uneven = families.filter { family in
            let font = EditorFont.font(family, size: 13)
            let widths = ["i", "W", "m", "0", " "].map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            return font.familyName != family || widths.contains { abs($0 - widths[0]) > 0.01 }
        }
        report(!families.isEmpty && families.contains("Menlo") && uneven.isEmpty && !families.contains { $0.hasPrefix(".") || $0 == "SF Mono" }
               && families == families.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
               "the Font menu lists \(families.count) installed families, by name, every one with letters of one width (not: \(uneven))")

        // (Whether the menu lists them so, each in its own face, a test
        // can't see: SwiftUI makes the menu's items only when it opens.)
        print("SELFTEST SKIP the Font menu's items in their own faces (SwiftUI builds the menu only when it is opened, which a test launch must not do)")

        guard let controller = FrontEditor.shared.editor(in: original)?.controller, let text = controller.textView,
              let gutter = controller.gutter else { report(false, "the editor of the test's window"); return }
        let size = text.font?.pointSize ?? 0, gutterSize = gutter.font.pointSize
        func shows(_ family: String) -> Bool {
            let storageFont = text.textStorage?.length ?? 0 > 0
                ? text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : text.font
            return text.font?.familyName == family && storageFont?.familyName == family && gutter.font.familyName == family
                && text.font?.pointSize == size && gutter.font.pointSize == gutterSize
        }
        let other = families.first { $0 == "Menlo" } ?? families.first ?? ""
        store.choose(other)
        var followed = false
        for _ in 0..<40 where !followed { await settle(25); followed = shows(other) }
        report(followed && UserDefaults.standard.string(forKey: Prefs.editorFontKey) == other,
               "choosing \(other) changes the open window's text and line numbers to it at once, at the size they had (\(text.font?.fontName ?? "-") \(text.font?.pointSize ?? 0), gutter \(gutter.font.fontName))")

        // A family that isn't installed (uninstalled since it was chosen).
        let missing = "Kiri Missing Mono \(getpid())"
        store.choose(missing)
        await settle(150)
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        report(store.shown.isEmpty && text.font?.fontName == system.fontName && EditorFont.font(missing, size: 13, weight: .bold).pointSize == 13,
               "a family that is gone gives SF Mono in the editor (\(text.font?.fontName ?? "-"))")

        store.choose(givenFamily)
        setArgument(Prefs.editorFontKey, givenFamily.isEmpty ? nil : givenFamily)
        await settle(100)
    }

    /// Kiri ▸ Settings… chosen from the app menu (SwiftUI opens the
    /// window), and the window once it is there.
    static func openSettings() async -> NSWindow? {
        func window() -> NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == SettingsView.windowID && $0.isVisible } }
        if let open = window() { return open }
        guard let main = NSApp.mainMenu, let app = main.items.first?.submenu else { return nil }
        updateMenu(main)
        guard let i = app.items.firstIndex(where: { $0.title == "Settings…" }) else { return nil }
        app.performActionForItem(at: i)
        for _ in 0..<80 {
            if let w = window() { return w }
            await settle(25)
        }
        return nil
    }
}
#endif
