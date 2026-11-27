import AppKit
import Observation
import Sparkle

/// Updates, with Sparkle: Kiri ▸ Check for Updates…, a check once a day in
/// the background, and the switch for that in Settings. A new version is
/// downloaded, its EdDSA signature checked against `SUPublicEDKey`, and it
/// replaces this copy when Kiri quits (or at once, if asked).
///
/// The feed (`SUFeedURL`) and the public key come from `App/project.yml`;
/// the release workflow (.github/workflows/release.yml) publishes both the
/// disk image and the feed. A build without a key or a feed, such as a
/// fresh checkout's or a self-test's, leaves Sparkle off and the menu item
/// disabled, instead of Sparkle's "the updater failed to start" alert.
@Observable final class Updater {
    static let shared = Updater()

    /// Whether this build can update itself at all.
    let isAvailable: Bool
    /// Whether Check for Updates… can run now (not while a check is on).
    private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let feed = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var available = !key.isEmpty && !feed.isEmpty
        #if DEBUG || KIRI_SELFTEST
        // A self-test must never stop for an update dialog.
        if SelfTest.isTestLaunch { available = false }
        #endif
        isAvailable = available
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        guard available else { return }
        controller.startUpdater()
        canCheck = controller.updater.canCheckForUpdates
        // Sparkle's updater is the main actor's, and tells on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { _, _ in
            MainActor.assumeIsolated { Updater.shared.refreshCanCheck() }
        }
    }

    /// Starts the updater, at launch.
    static func start() { _ = shared }

    private func refreshCanCheck() {
        let can = controller.updater.canCheckForUpdates
        if canCheck != can { canCheck = can }
    }

    /// Kiri ▸ Check for Updates…: Sparkle's own window, which says when
    /// Kiri is up to date too.
    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }

    /// Settings' switch: a check once a day, in the background.
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return isAvailable && controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// This copy's version, as Settings shows it: "0.2.0 (41)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
