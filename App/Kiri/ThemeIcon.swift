import AppKit
import KiriKit

/// Applies Settings ▸ Theme: the colors everywhere, and the Dock icon.
/// Finder and the app switcher keep the bundle's Honey icon; macOS has no
/// alternate icons for Mac apps, so the running app's Dock tile changes only.
@MainActor enum ThemeController {
    private static var observer: NSObjectProtocol?
    private static var iconTheme: String?

    /// Call once at launch.
    static func start() {
        apply()
        // NSApp may not exist yet while the App initializes.
        DispatchQueue.main.async { apply() }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    static func apply() {
        let theme = Honey.Theme.named(UserDefaults.standard.string(forKey: Prefs.colorThemeKey) ?? Honey.Theme.honey.id)
        Honey.theme = theme
        updateDockIcon(theme)
    }

    private static func updateDockIcon(_ theme: Honey.Theme) {
        guard let app = NSApp, iconTheme != theme.id else { return }
        iconTheme = theme.id
        // nil puts the bundle's icon back.
        app.applicationIconImage = theme == .honey ? nil : Bundle.main.image(forResource: "ThemeIcon-\(theme.id)")
    }
}
