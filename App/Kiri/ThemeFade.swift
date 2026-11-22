import AppKit
import KiriKit
import QuartzCore

/// A change of color theme, or of light and dark, crossfades: every window
/// that shows goes from its old colors to its new ones over `Honey.medium`
/// instead of in one frame.
///
/// The fade is a Core Animation transition on each window's content layer,
/// begun before the colors change (`ThemeController`). Core Animation keeps
/// the picture of the window as it was and fades it out over the window as
/// it now draws: the chrome SwiftUI recolors, and the editor's text, paper
/// and line numbers, which AppKit redraws. Nothing is put into the view or
/// layer tree, so there is nothing to be left behind: a second change
/// mid-fade takes the first one's place (one transition per layer, by its
/// key), and a window that closes takes its layer along.
///
/// With reduced motion (the system's, or Motion: Reduced) and with Motion:
/// Off there is no fade: the colors change at once.
@MainActor enum ThemeFade {
    /// The transition's key on a window's content layer. (A layer has one
    /// transition at a time, under this key whatever key it is added with.)
    static let key = kCATransition
    static var duration: CFTimeInterval {
        #if DEBUG || KIRI_SELFTEST
        if let selfTestDuration { return selfTestDuration }
        #endif
        return Honey.medium
    }

    #if DEBUG || KIRI_SELFTEST
    /// For pictures of the fade under way: a fade slow enough to catch.
    static var selfTestDuration: CFTimeInterval?
    /// The self-test says how much motion there is, instead of the setting
    /// (which it must not write).
    static var selfTestMotion: (level: HoneyMotionLevel, systemReduced: Bool)?
    #endif

    /// Whether a change fades now.
    static var isOn: Bool {
        var level = UserDefaults.standard.string(forKey: Prefs.motionKey).flatMap(HoneyMotionLevel.init(rawValue:)) ?? .system
        var systemReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #if DEBUG || KIRI_SELFTEST
        if let selfTestMotion { (level, systemReduced) = selfTestMotion }
        #endif
        // (Off counts as reduced.)
        return !HoneyMotion(HoneyAppearance(motion: level), systemReduced: systemReduced).reduced
    }

    private static let fading = NSHashTable<CALayer>.weakObjects()
    private static var latest = 0

    /// Call just before the colors change.
    static func begin() {
        guard isOn else { return }
        for window in NSApp.windows where window.isVisible {
            guard let layer = window.contentView?.layer else { continue }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: key)
            fading.add(layer)
        }
        // Core Animation takes a finished transition off its layer. In a
        // window that isn't being drawn (covered, the display asleep) it
        // may not get to: it comes off here, once the last fade is over.
        latest += 1
        let mine = latest
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            guard mine == latest else { return }
            for layer in fading.allObjects { layer.removeAnimation(forKey: key) }
            fading.removeAllObjects()
        }
    }
}
