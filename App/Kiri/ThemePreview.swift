import AppKit
import KiriKit
import Observation
import SwiftUI

/// A color theme, or light and dark, shown without being chosen: what the
/// command palette does while the selection is on "Theme: Tide", and what
/// anything else that offers a theme can do while the pointer or the
/// keyboard is on one. `show` shows it, `end` puts the chosen one back,
/// `keep` chooses what is shown.
///
/// It is an override held in memory, over the saved settings: nothing is
/// written until `keep`, so a preview that ends, or an app that quits in
/// the middle of one, leaves the settings as they were. (Never written
/// and then written back: every other copy of Kiri would follow.)
///
/// Changes are spaced out by the crossfade's length: someone holding an
/// arrow key down over six themes sees the first and then the one they
/// stopped on, not six fades begun on top of each other.
@MainActor @Observable final class ThemePreview {
    static let shared = ThemePreview()

    enum Look: Equatable {
        case theme(Honey.Theme)
        /// Light, dark, or following the system.
        case appearance(HoneyTheme)
    }

    /// The theme and the appearance that show in place of the saved ones,
    /// nil while the saved ones show. (`ThemeController` and
    /// `AppearanceRoot` read these first.)
    private(set) var theme: Honey.Theme?
    private(set) var appearance: HoneyTheme?

    /// What was last asked for; it shows at once, or when the crossfade
    /// before it is over.
    @ObservationIgnored private var wanted: Look?
    @ObservationIgnored private var shown: Look?
    @ObservationIgnored private var changedAt = ContinuousClock.now - .seconds(60)
    @ObservationIgnored private var pending: DispatchWorkItem?

    /// Shows `look` in every window, for now.
    func show(_ look: Look) { want(look) }

    /// The chosen theme and appearance again.
    func end() { want(nil) }

    /// What is shown (or about to be) is chosen: it is the setting from
    /// now on.
    func keep() {
        guard let wanted else { return }
        // At once: it was asked for, whatever fade is still running.
        apply()
        let (key, value) = switch wanted {
        case .theme(let theme): (Prefs.colorThemeKey, theme.id)
        case .appearance(let appearance): (Prefs.themeKey, appearance.rawValue)
        }
        #if DEBUG || KIRI_SELFTEST
        // A test launch leaves the person's preferences as they are: its
        // choice is kept among the launch's arguments, where a setting
        // given on the command line lives. Nothing announces a change
        // there, so the override stays to show it.
        if SelfTest.isTestLaunch { SelfTest.setArgument(key, value); return }
        #endif
        UserDefaults.standard.set(value, forKey: key)
        // The setting says it now; the override has nothing left to say.
        self.wanted = nil
        shown = nil
        if theme != nil { theme = nil }
        if appearance != nil { appearance = nil }
        // (And the Dock icon, which a theme that was only looked at left alone.)
        ThemeController.apply()
    }

    private func want(_ look: Look?) {
        wanted = look
        pending?.cancel()
        pending = nil
        guard look != shown else { return }
        let wait = ThemeFade.isOn ? ThemeFade.duration - Self.seconds(ContinuousClock.now - changedAt) : 0
        if wait <= 0 {
            apply()
        } else {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.apply() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func apply() {
        pending?.cancel()
        pending = nil
        guard wanted != shown else { return }
        shown = wanted
        changedAt = .now
        #if DEBUG || KIRI_SELFTEST
        selfTestShown.append(shown)
        #endif
        var theme: Honey.Theme?, appearance: HoneyTheme?
        switch shown {
        case .theme(let t): theme = t
        case .appearance(let a): appearance = a
        case nil: break
        }
        // The colors first, and with them the crossfade, which has to
        // begin while the windows still show the old ones; then what
        // SwiftUI follows.
        ThemeController.show(previewing: theme, appearance: appearance)
        if self.theme != theme { self.theme = theme }
        if self.appearance != appearance { self.appearance = appearance }
    }

    #if DEBUG || KIRI_SELFTEST
    /// Every look that was shown, in order (nil: the chosen one again).
    @ObservationIgnored private(set) var selfTestShown: [Look?] = []
    #endif
}

/// The root of a Kiri window: Honey in the appearance (light, dark or the
/// system's) and with the motion chosen in Settings, or in the appearance
/// that is being previewed (`ThemePreview`).
struct AppearanceRoot<Content: View>: View {
    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system
    @State private var preview = ThemePreview.shared
    @ViewBuilder let content: Content

    var body: some View {
        content.honeyRoot(HoneyAppearance(theme: preview.appearance ?? theme, motion: motion))
    }
}
