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
            LaunchDocument.watchRestoration()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // What Kiri was launched for: simply to be opened (the "open
        // application" event is being handled now), or to open documents or
        // a kiri:// request, which then come by themselves a moment later
        // (no event is current here in that case).
        let event = NSAppleEventManager.shared().currentAppleEvent
        let simplyOpened = event.map { $0.eventClass == kCoreEventClass && $0.eventID == kAEOpenApplication } ?? false
        MainActor.assumeIsolated {
            // Again, in case SwiftUI set up its own URL handler in between.
            KiriCLI.install()
            LaunchDocument.finishedLaunching(simplyOpened: simplyOpened)
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

/// Launching into an empty editor. SwiftUI's app delegate, which is in front
/// of Kiri's, never asks for an untitled document, so it is done here: when
/// Kiri was simply opened and, once launching and window restoration are
/// both over, nothing else is open. Files named on the command line,
/// restored windows and the unsaved documents AppKit brings back after a
/// crash are all there by then. (AppKit's "default launch" flag is no
/// guide: it is off after a crash or a forced quit even when there is
/// nothing to restore, which would leave Kiri without a window.)
@MainActor enum LaunchDocument {
    private static var launched = false
    private static var restored = false
    private static var wanted = false

    static func watchRestoration() {
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishRestoringWindowsNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                restored = true
                openIfNothingElse()
            }
        }
    }

    static func finishedLaunching(simplyOpened: Bool) {
        launched = true
        wanted = simplyOpened
        openIfNothingElse()
    }

    private static func openIfNothingElse() {
        guard launched, restored, wanted else { return }
        wanted = false
        DispatchQueue.main.async {
            guard NSDocumentController.shared.documents.isEmpty, !KiriCLI.hasOpenedSomething else { return }
            NSDocumentController.shared.newDocument(nil)
        }
    }
}

/// The document controller: AppKit's, which also tells the File menu when
/// the recent documents change (the menu is SwiftUI's and has to be told).
final class KiriDocumentController: NSDocumentController {
    /// How long after an edit its recovery copy is written.
    static let recoveryDelay: TimeInterval = 5

    override func noteNewRecentDocumentURL(_ url: URL) {
        #if DEBUG || KIRI_SELFTEST
        // A test launch opens temporary files by the dozen: they stay out
        // of the person's Open Recent, which every copy of Kiri shares.
        if SelfTest.isTestLaunch { return }
        #endif
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

    #if DEBUG || KIRI_SELFTEST
    /// The self-test shows a list of its own: its files never go into the
    /// real one.
    func selfTestShow(_ list: [URL]) { urls = list }
    #endif
}
