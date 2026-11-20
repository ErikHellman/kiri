import KiriKit
import SwiftUI

/// Persisted preferences (UserDefaults keys and helpers).
enum Settings {
    static let themeKey = "theme"
    static let motionKey = "motion"
    static let textScaleKey = "textScale"

    /// Text size steps for ⌘+ / ⌘-.
    static let textScales: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]
}
