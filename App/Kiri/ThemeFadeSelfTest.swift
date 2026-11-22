#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit
import QuartzCore

extension SelfTest {
    /// -KiriThemeFadeTo <theme id> [-KiriThemeFadeSeconds <s>]: two seconds
    /// after launch the theme changes to that one for this launch (nothing
    /// is saved), with a fade as long as asked, so that pictures can be
    /// taken of the fade under way.
    static func themeFadeDemo() {
        guard let id = UserDefaults.standard.string(forKey: "KiriThemeFadeTo"), !fadeDemoStarted else { return }
        fadeDemoStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if UserDefaults.standard.string(forKey: "KiriThemeFadeSeconds") != nil {
                ThemeFade.selfTestDuration = UserDefaults.standard.double(forKey: "KiriThemeFadeSeconds")
            }
            ThemeFade.selfTestMotion = (.full, false)
            ThemeController.selfTestHoldsTheme = true
            ThemeController.show(Honey.Theme.named(id), appearance: UserDefaults.standard.string(forKey: Prefs.themeKey) ?? HoneyTheme.system.rawValue)
            print("SELFTEST info theme fade to \(id) begun")
            fflush(stdout)
        }
    }

    private static var fadeDemoStarted = false

    /// A change of theme crossfades (`ThemeFade`) and leaves nothing
    /// behind: the transition is on the window's content layer while the
    /// fade runs and gone after it, also when the theme changes again or
    /// the window closes mid-fade; the colors that are drawn afterwards
    /// are the new theme's; and with reduced motion or Motion: Off nothing
    /// fades. The theme is shown through `ThemeController.show`, as a
    /// changed setting shows it, without the setting being written.
    static func themeFadeStage(_ window: NSWindow) async {
        guard let content = window.contentView, let layer = content.layer,
              let ktv = findTextView(in: content) as? KiriTextView,
              let container = ktv.enclosingScrollView?.superview as? EditorContainerView else {
            report(false, "the window's content layer and editor, for the theme checks"); return
        }
        let chosen = Honey.theme
        let appearance = UserDefaults.standard.string(forKey: Prefs.themeKey) ?? HoneyTheme.system.rawValue
        // The other themes, the one whose line numbers differ most first.
        func distance(_ theme: Honey.Theme) -> Int {
            let a = theme[Honey.gutter].light, b = chosen[Honey.gutter].light
            return [16, 8, 0].reduce(0) { $0 + abs(Int((a >> $1) & 0xFF) - Int((b >> $1) & 0xFF)) }
        }
        let others = Honey.Theme.all.filter { $0 != chosen }.sorted { distance($0) > distance($1) }
        let (first, second, third) = (others[1], others[0], others[2])
        ThemeController.selfTestHoldsTheme = true
        defer {
            // Back to the theme of this launch, at once.
            ThemeFade.selfTestMotion = (.off, false)
            ThemeController.show(chosen, appearance: appearance)
            ThemeFade.selfTestMotion = nil
            ThemeController.selfTestHoldsTheme = false
        }
        func fade(_ l: CALayer = layer) -> CATransition? { l.animation(forKey: ThemeFade.key) as? CATransition }
        /// Every layer under `root` that still has a transition on it.
        func transitions(under root: CALayer) -> Int {
            ((root.animationKeys() ?? []).contains { root.animation(forKey: $0) is CATransition } ? 1 : 0)
                + (root.sublayers ?? []).reduce(0) { $0 + transitions(under: $1) }
        }
        /// What a fade could leave behind: views and layers beside the
        /// window's own, and windows.
        func shape() -> [Int] {
            [content.subviews.count, layer.sublayers?.count ?? 0, content.superview?.subviews.count ?? 0,
             content.superview?.layer?.sublayers?.count ?? 0, NSApp.windows.filter(\.isVisible).count, window.childWindows?.count ?? 0]
        }
        /// The color of a token as it is drawn in this window now.
        func drawn(_ token: Honey.Token) -> NSColor {
            var color = NSColor.clear
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                color = NSColor.honey(token).usingColorSpace(.sRGB) ?? .clear
            }
            return color
        }
        func value(_ token: Honey.Token, in theme: Honey.Theme) -> NSColor {
            var color = NSColor.clear
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                color = NSColor.honeyFixed(theme[token]).usingColorSpace(.sRGB) ?? .clear
            }
            return color
        }
        func close(_ a: NSColor, _ b: NSColor, within tolerance: CGFloat = 0.03) -> Bool {
            abs(a.redComponent - b.redComponent) <= tolerance && abs(a.greenComponent - b.greenComponent) <= tolerance
                && abs(a.blueComponent - b.blueComponent) <= tolerance
        }
        /// The color the line numbers are drawn in: of the gutter's fully
        /// covered pixels, the color most of them have once the paper
        /// behind them is set aside (a number's edges are blends, each a
        /// little different; its strokes are the color itself).
        func lineNumberColor() -> NSColor? {
            let gutter = container.gutter
            guard let rep = gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds) else { return nil }
            gutter.cacheDisplay(in: gutter.bounds, to: rep)
            var counts: [UInt32: Int] = [:]
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent >= 0.999 else { continue }
                    let key = UInt32(c.redComponent * 255 + 0.5) << 16 | UInt32(c.greenComponent * 255 + 0.5) << 8 | UInt32(c.blueComponent * 255 + 0.5)
                    counts[key, default: 0] += 1
                }
            }
            let space = rep.colorSpace
            let ranked = counts.sorted { $0.value > $1.value }.prefix(3).compactMap { entry -> NSColor? in
                let parts = [CGFloat((entry.key >> 16) & 0xFF) / 255, CGFloat((entry.key >> 8) & 0xFF) / 255, CGFloat(entry.key & 0xFF) / 255, 1]
                return NSColor(colorSpace: space, components: parts, count: 4).usingColorSpace(.sRGB)
            }
            let paper = [drawn(Honey.surface), drawn(Honey.currentLine)]
            return ranked.first { c in !paper.contains { close(c, $0, within: 0.015) } }
        }
        func hex(_ c: NSColor?) -> String {
            c.map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255 + 0.5), Int($0.greenComponent * 255 + 0.5), Int($0.blueComponent * 255 + 0.5)) } ?? "none"
        }
        let before = shape()

        // Full motion: the fade is on the content layer the moment the theme changes.
        ThemeFade.selfTestMotion = (.full, false)
        ThemeController.show(first, appearance: appearance)
        let started = fade()
        report(started != nil && started?.type == .fade && started?.duration == Honey.medium && Honey.theme == first,
               "a change of theme begins a \(Int(Honey.medium * 1000)) ms crossfade on the window (\(started.map { "\($0.type.rawValue), \($0.duration) s" } ?? "no transition"))")

        // Again mid-fade: one transition still, the new one.
        try? await Task.sleep(for: .milliseconds(70))
        ThemeController.show(second, appearance: appearance)
        let again = fade()
        report(again != nil && again !== started && transitions(under: layer) == 1 && Honey.theme == second,
               "a second change mid-fade takes the first one's place (\(transitions(under: layer)) transition)")

        // After it: nothing left, and the new theme's colors.
        try? await Task.sleep(for: .milliseconds(Int(Honey.medium * 1000) + 250))
        ktv.displayIfNeeded()
        container.gutter.displayIfNeeded()
        let number = lineNumberColor()
        let gutterColor = value(Honey.gutter, in: second), old = value(Honey.gutter, in: chosen)
        report(fade() == nil && transitions(under: layer) == 0 && shape() == before,
               "after the fade nothing of it is left: no transition on any layer, the same views, layers and windows (\(shape()) of \(before))")
        report(Honey.theme == second && close(drawn(Honey.surface), value(Honey.surface, in: second))
               && close(drawn(Honey.fg), value(Honey.fg, in: second)) && number.map { close($0, gutterColor) } == true
               && (close(old, gutterColor, within: 0.06) || number.map { !close($0, old) } == true),
               "and the colors are the new theme's: paper, text, and the line numbers as the gutter draws them (\(hex(number)); \(second.name)'s are \(hex(gutterColor)), \(chosen.name)'s \(hex(old)))")

        // A window that closes mid-fade takes its fade along.
        let extra = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .seconds(3), extra.flatMap({ Editors.window(for: $0) })?.contentView?.layer == nil
            || !(window.tabbedWindows ?? []).contains(where: { $0 === extra.flatMap { Editors.window(for: $0) } }) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(200))
        if let extra, let other = Editors.window(for: extra), let otherLayer = other.contentView?.layer {
            ThemeController.show(third, appearance: appearance)
            let fading = fade(otherLayer) != nil
            extra.close()
            try? await Task.sleep(for: .milliseconds(Int(Honey.medium * 1000) + 350))
            report(fading && !NSDocumentController.shared.documents.contains { $0 === extra } && fade() == nil
                   && transitions(under: layer) == 0 && shape() == before && Honey.theme == third,
                   "a window closed mid-fade leaves nothing behind, and the theme has changed (\(shape()) of \(before))")
        } else {
            report(false, "a second tab opens for the close mid-fade check")
        }

        // Light or dark alone fades too.
        ThemeController.show(third, appearance: appearance == HoneyTheme.dark.rawValue ? HoneyTheme.light.rawValue : HoneyTheme.dark.rawValue)
        let forAppearance = fade() != nil
        ThemeController.show(third, appearance: appearance)
        try? await Task.sleep(for: .milliseconds(Int(Honey.medium * 1000) + 150))
        report(forAppearance && fade() == nil, "a change of light or dark begins the crossfade too, and it ends")

        // The setting itself, as Settings and the View menu change it:
        // set among this launch's arguments, which is where a setting
        // given on the command line lives, so nothing is saved.
        func setting(_ key: String, _ value: String?) {
            let domain = UserDefaults.argumentDomain
            var arguments = UserDefaults.standard.volatileDomain(forName: domain)
            arguments[key] = value
            UserDefaults.standard.removeVolatileDomain(forName: domain)
            UserDefaults.standard.setVolatileDomain(arguments, forName: domain)
        }
        let given = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Prefs.colorThemeKey] as? String
        let wanted = Honey.theme == first ? second : first
        ThemeController.selfTestHoldsTheme = false
        setting(Prefs.colorThemeKey, wanted.id)
        // Heard at once (the fade has to start before SwiftUI redraws), or not at all.
        let heard = Honey.theme == wanted, fadedForSetting = fade() != nil
        setting(Prefs.colorThemeKey, given)
        ThemeController.selfTestHoldsTheme = true
        try? await Task.sleep(for: .milliseconds(Int(Honey.medium * 1000) + 150))
        if heard {
            report(fadedForSetting && fade() == nil, "the color theme set as a setting changes the theme in the same turn, with the crossfade (\(wanted.name))")
        } else {
            print("SELFTEST SKIP the color theme set as a setting (a change among the launch's arguments isn't announced; saved settings are not the test's to write)")
        }

        // Reduced motion (the setting's or the system's) and Motion: Off: no fade.
        var quiet: [String] = []
        for (name, motion) in [("Motion: Reduced", (HoneyMotionLevel.reduced, false)), ("Motion: Off", (.off, false)),
                               ("Reduce Motion", (.system, true))] {
            ThemeFade.selfTestMotion = motion
            let next = Honey.theme == first ? second : first
            ThemeController.show(next, appearance: appearance)
            if fade() == nil && transitions(under: layer) == 0 && Honey.theme == next { quiet.append(name) }
        }
        report(quiet.count == 3, "with reduced motion or Motion: Off the theme changes without a fade (\(quiet.joined(separator: ", ")))")
    }
}

extension SelfTest {
    /// A theme or an appearance shown without being chosen
    /// (`ThemePreview`): it shows at once, stays through other settings
    /// changing, goes when the preview ends, and writes nothing until it
    /// is kept; a run of them shows the first and the last. Kept in a
    /// test launch, it goes among the launch's arguments, not into the
    /// saved preferences.
    static func themePreviewStage(_ window: NSWindow) async {
        let preview = ThemePreview.shared
        let chosen = Honey.theme, others = Honey.Theme.all.filter { $0 != Honey.theme }
        let domain = Bundle.main.bundleIdentifier ?? ""
        let saved = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        func given(_ key: String) -> String? { UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String }
        let givenTheme = given(Prefs.colorThemeKey), givenAppearance = given(Prefs.themeKey)
        let settingBefore = UserDefaults.standard.string(forKey: Prefs.colorThemeKey)
        defer { ThemeFade.selfTestMotion = nil }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

        // Without a fade: shown at once, held, and gone when it ends.
        ThemeFade.selfTestMotion = (.off, false)
        preview.show(.theme(others[0]))
        let shown = Honey.theme == others[0] && preview.theme == others[0]
        // Any setting that changes brings the saved theme up to date; a preview stays.
        ThemeController.apply()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        await pause(0.05)
        let held = Honey.theme == others[0] && UserDefaults.standard.string(forKey: Prefs.colorThemeKey) == settingBefore
        preview.end()
        report(shown && held && Honey.theme == chosen && preview.theme == nil,
               "a previewed theme shows at once, stays while other settings change and goes when the preview ends, the setting untouched (\(shown), \(held), back to \(Honey.theme.name))")

        // With the crossfade: a run of previews shows the first and the
        // last, one fade at a time.
        ThemeFade.selfTestMotion = (.full, false)
        await pause(ThemeFade.duration + 0.05)
        let before = preview.selfTestShown.count
        preview.show(.theme(others[0]))
        preview.show(.theme(others[1]))
        preview.show(.theme(others[2]))
        let first = Honey.theme
        await pause(ThemeFade.duration + 0.15)
        let run = preview.selfTestShown.dropFirst(before)
        report(first == others[0] && Honey.theme == others[2] && Array(run) == [.theme(others[0]), .theme(others[2])],
               "three themes previewed in a row show the first at once and the last when its fade is over, never three fades at a time (\(run.map { look in if case .theme(let t)? = look { t.name } else { "the chosen one" } }))")
        preview.end()
        await pause(ThemeFade.duration + 0.15)
        let ended = Honey.theme == chosen

        // Light and dark.
        ThemeFade.selfTestMotion = (.off, false)
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        preview.show(.appearance(dark ? .light : .dark))
        let asked = preview.appearance == (dark ? .light : .dark)
        var flipped = false
        for _ in 0..<60 where !flipped {
            await pause(0.025)
            flipped = (window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) != dark
        }
        preview.end()
        var back = false
        for _ in 0..<60 where !back {
            await pause(0.025)
            back = (window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == dark
        }
        if flipped || window.occlusionState.contains(.visible) {
            report(ended && asked && flipped && back && preview.appearance == nil,
                   "a previewed appearance turns the window \(dark ? "light" : "dark") and back (\(asked), \(flipped), \(back))")
        } else {
            report(ended && asked && preview.appearance == nil, "a previewed appearance is held and let go")
            print("SELFTEST SKIP the window turning \(dark ? "light" : "dark") for a previewed appearance (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }

        // Kept: the setting, which in a test launch is one of the
        // launch's arguments and never a saved preference.
        preview.show(.theme(others[1]))
        preview.keep()
        let kept = given(Prefs.colorThemeKey) == others[1].id && Honey.theme == others[1]
        setArgument(Prefs.colorThemeKey, givenTheme)
        setArgument(Prefs.themeKey, givenAppearance)
        preview.end()
        ThemeController.apply()
        let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        report(kept && Honey.theme == chosen && NSDictionary(dictionary: saved).isEqual(to: after),
               "a preview that is kept becomes the setting (here among the launch's arguments), and none of this wrote a saved preference (\(kept), \(Honey.theme.name))")
    }
}
#endif
