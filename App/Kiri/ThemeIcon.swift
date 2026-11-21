import AppKit
import KiriKit

/// Applies Settings ▸ Theme: the colors everywhere, and the Dock icon.
/// Finder and the app switcher keep the bundle's Honey icon; macOS has no
/// alternate icons for Mac apps, so the running app's Dock tile changes only.
@MainActor enum ThemeController {
    private static var observers: [NSObjectProtocol] = []
    private static var iconTheme: String?
    /// The app has finished launching, so the Dock tile can be drawn.
    private static var launched = false

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
    }

    private static var savedTheme: Honey.Theme {
        Honey.Theme.named(UserDefaults.standard.string(forKey: Prefs.colorThemeKey) ?? Honey.Theme.honey.id)
    }

    static func apply() {
        let theme = savedTheme
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
