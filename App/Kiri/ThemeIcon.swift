import AppKit
import KiriKit

/// Applies Settings ▸ Theme: the colors everywhere, and the Dock icon. A
/// change of the theme, or of light and dark, crossfades (`ThemeFade`).
/// Finder and the app switcher keep the bundle's Honey icon; macOS has no
/// alternate icons for Mac apps, so the running app's Dock tile changes only.
@MainActor enum ThemeController {
    private static var observers: [NSObjectProtocol] = []
    private static var iconTheme: String?
    /// The app has finished launching, so the Dock tile can be drawn.
    private static var launched = false
    /// Light, dark or system, as last seen: a change of it fades too.
    private static var appearance = savedAppearance
    private static let watcher = ThemeWatcher()

    /// Call once at launch.
    static func start() {
        // Colors now, so the first window draws in the theme.
        Honey.theme = savedTheme
        // The Dock icon waits until launch has finished. Before that NSApp
        // exists but is still inside its own init, and drawing the Dock tile
        // makes AppKit create a second NSApplication and trap: a crash at
        // launch with any theme but Honey (whose icon is nil, so nothing drew).
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated {
                launched = true
                apply()
            }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        })
        // The two settings themselves, heard the moment either is set
        // and so before SwiftUI redraws anything: the windows' crossfade
        // has to begin while they still show the old colors.
        for key in [Prefs.colorThemeKey, Prefs.themeKey] {
            UserDefaults.standard.addObserver(watcher, forKeyPath: key, options: [], context: nil)
        }
    }

    private static var savedAppearance: String { UserDefaults.standard.string(forKey: Prefs.themeKey) ?? HoneyTheme.system.rawValue }

    private static var savedTheme: Honey.Theme {
        Honey.Theme.named(UserDefaults.standard.string(forKey: Prefs.colorThemeKey) ?? Honey.Theme.honey.id)
    }

    static func apply() {
        #if DEBUG || KIRI_SELFTEST
        if selfTestHoldsTheme { return }
        #endif
        show(savedTheme, appearance: savedAppearance)
    }

    #if DEBUG || KIRI_SELFTEST
    /// While the self-test shows themes of its own, a change of some other
    /// setting must not bring the saved one back in the middle of a check.
    static var selfTestHoldsTheme = false
    #endif

    /// The colors become `theme`'s, in `appearance` (light, dark or
    /// system, which SwiftUI applies to the windows itself), with a
    /// crossfade if either is a change.
    static func show(_ theme: Honey.Theme, appearance: String) {
        if theme != Honey.theme || appearance != self.appearance { ThemeFade.begin() }
        self.appearance = appearance
        Honey.theme = theme
        updateDockIcon(theme)
    }

    private static func updateDockIcon(_ theme: Honey.Theme) {
        guard launched, let app = NSApp, iconTheme != theme.id else { return }
        iconTheme = theme.id
        // nil puts the bundle's icon back.
        app.applicationIconImage = theme == .honey ? nil : Bundle.main.image(forResource: "ThemeIcon-\(theme.id)")
    }
}

/// Tells `ThemeController` that the theme or the appearance was set.
private final class ThemeWatcher: NSObject {
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        // Settings and the View menu set them on the main thread; a
        // change from elsewhere (`defaults write`) arrives on another.
        if Thread.isMainThread {
            MainActor.assumeIsolated { ThemeController.apply() }
        } else {
            DispatchQueue.main.async { ThemeController.apply() }
        }
    }
}
