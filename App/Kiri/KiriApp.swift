import KiriKit
import SwiftUI

/// Kiri for macOS: one window per document, launching straight into an editor.
///
/// The documents and their windows are AppKit's (`KiriDocument`,
/// `DocumentWindow`), because saving is explicit and a SwiftUI
/// `DocumentGroup` autosaves. Everything else is SwiftUI: the scenes below,
/// the menus (`KiriCommands`) and what the document windows host.
@main
struct KiriApp: App {
    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system
    @NSApplicationDelegateAdaptor private var delegate: KiriAppDelegate

    init() {
        Honey.registerFonts()
        ThemeController.start()
    }

    private var appearance: HoneyAppearance { HoneyAppearance(theme: theme, motion: motion) }

    var body: some Scene {
        // Not a `Settings` scene: that one keeps its system title bar
        // whatever the window style. As a window of its own, Settings looks
        // like every other Kiri window; `KiriCommands` adds Kiri ▸ Settings…
        Window("Settings", id: SettingsView.windowID) {
            SettingsView().honeyRoot(appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // No "Settings" entry in the Window menu: it lives in the app menu.
        .commandsRemoved()
        // The app's menus hang on its first scene.
        .commands { KiriCommands() }

        Window("Keyboard Shortcuts", id: ShortcutsView.windowID) {
            ShortcutsView().honeyRoot(appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // The component gallery is a development tool: Debug builds only,
        // so Release has neither the window nor its Window-menu entry.
        #if DEBUG
        Window("Style Gallery", id: "style-gallery") {
            StyleGallery()
                .frame(minWidth: 900, minHeight: 600)
                .honeyRoot(appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}

/// Launching, quitting and `kiri` command-line requests (kiri:// URLs).
final class KiriAppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        // Before anything asks for the shared document controller: the
        // first one made is it.
        MainActor.assumeIsolated { _ = KiriDocumentController() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            #if DEBUG || KIRI_SELFTEST
            SelfTest.guardLaunch()
            #endif
            KiriCLI.install()
            FrontEditor.shared.start()
            // Unsaved text is kept for a crash: a recovery copy this long
            // after an edit (AppKit's default is never).
            NSDocumentController.shared.autosavingDelay = KiriDocumentController.recoveryDelay
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's app delegate, which is in front of this one, never asks
        // to open an untitled document, so launching into an empty editor
        // is done here. Only when Kiri was simply started: not when it was
        // launched with a file or a kiri:// request, and not when windows
        // are being restored or unsaved documents recovered, all of which
        // arrive after this.
        let plain = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? false
        MainActor.assumeIsolated {
            // Again, in case SwiftUI set up its own URL handler in between.
            KiriCLI.install()
            guard plain else { return }
            // A turn later: a file named on the command line is open by now.
            DispatchQueue.main.async {
                guard NSDocumentController.shared.documents.isEmpty, !KiriCLI.hasOpenedSomething else { return }
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }

    /// A click on the Dock icon with no window open: a new document.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            // With documents open but out of sight, AppKit brings one back.
            guard !flag, NSDocumentController.shared.documents.isEmpty else { return true }
            NSDocumentController.shared.newDocument(nil)
            return false
        }
    }
}

/// The document controller: AppKit's, which also tells the File menu when
/// the recent documents change (the menu is SwiftUI's and has to be told).
final class KiriDocumentController: NSDocumentController {
    /// How long after an edit its recovery copy is written.
    static let recoveryDelay: TimeInterval = 5

    override func noteNewRecentDocumentURL(_ url: URL) {
        super.noteNewRecentDocumentURL(url)
        RecentDocuments.shared.refresh()
    }

    override func clearRecentDocuments(_ sender: Any?) {
        super.clearRecentDocuments(sender)
        RecentDocuments.shared.refresh()
    }
}

/// File ▸ Open Recent's list.
@MainActor @Observable final class RecentDocuments {
    static let shared = RecentDocuments()
    private(set) var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    func refresh() {
        let now = NSDocumentController.shared.recentDocumentURLs
        if now != urls { urls = now }
    }
}
