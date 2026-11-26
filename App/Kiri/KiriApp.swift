import KiriKit
import SwiftUI

/// Kiri for macOS: documents as tabs of a window, launching straight into an editor.
///
/// The documents and their windows are AppKit's (`KiriDocument`,
/// `DocumentWindow`), because saving is explicit and a SwiftUI
/// `DocumentGroup` autosaves. Everything else is SwiftUI: the scenes below,
/// the menus (`KiriCommands`) and what the document windows host.
@main
struct KiriApp: App {
    @NSApplicationDelegateAdaptor private var delegate: KiriAppDelegate

    init() {
        // First, so a crash anywhere after it is reported (if allowed).
        Telemetry.start()
        Honey.registerFonts()
        ThemeController.start()
    }

    var body: some Scene {
        // Not a `Settings` scene: that one keeps its system title bar
        // whatever the window style. As a window of its own, Settings looks
        // like every other Kiri window; `KiriCommands` adds Kiri ▸ Settings…
        Window("Settings", id: SettingsView.windowID) {
            AppearanceRoot { SettingsView() }
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
            AppearanceRoot { ShortcutsView() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Help ▸ Command Line Tool: the `kiri` command's options and examples.
        Window("Command Line Tool", id: CommandLineHelpView.windowID) {
            AppearanceRoot { CommandLineHelpView() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 700)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // The component gallery is a development tool: Debug builds only,
        // so Release has neither the window nor its Window-menu entry.
        #if DEBUG
        Window("Style Gallery", id: "style-gallery") {
            AppearanceRoot { StyleGallery().frame(minWidth: 900, minHeight: 600) }
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
            // Before Sparkle starts (it leaves keys of its own behind).
            WhatsNew.launch()
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
            // Sparkle: a check once a day, the first a moment after launch.
            Updater.start()
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

    /// Files that are open only to be looked at: shown in the folder
    /// sidebar's preview tab and not kept (`SidebarOpen`). AppKit notes a
    /// document as recent when it is added and again when it closes, and
    /// neither is told whether a window was wanted; Open Recent (and the
    /// command palette's recent files) would otherwise be a log of every
    /// file glanced at. Such a file becomes recent when it is kept
    /// (`PreviewTabs.keep`).
    private var glanced: Set<URL> = []

    /// `url` is about to open in the preview tab.
    func glance(at url: URL) { glanced.insert(url.standardizedFileURL) }

    /// The file at `url` is here to stay (kept, or opened by name): if it
    /// was only being looked at, it is a recent document from now on.
    func kept(_ url: URL?) {
        guard !glanced.isEmpty, let url, glanced.remove(url.standardizedFileURL) != nil else { return }
        noteNewRecentDocumentURL(url)
    }

    /// The same, for the document `window` shows. (Asked at every edit:
    /// nothing is looked up while no file is only being looked at.)
    func kept(in window: NSWindow) {
        guard !glanced.isEmpty else { return }
        kept(document(for: window)?.fileURL)
    }

    /// Large files open without asking whether to open them read-only:
    /// one that is only looked at, and one AppKit reopens (a window
    /// brought back at launch).
    func opensQuietly(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return reopening.contains(url) || glanced.contains(url) || streams.contains(url)
    }

    /// Piped input that goes on (`adb logcat | kiri -`), copied into a
    /// file by the `kiri` script as it comes: read-only in the large-file
    /// viewer whatever its size, following it as it grows.
    private var streams: Set<URL> = []

    func stream(_ url: URL) { streams.insert(url.standardizedFileURL) }
    func isStream(_ url: URL?) -> Bool { url.map { streams.contains($0.standardizedFileURL) } ?? false }

    /// The stream's tab closed: its file goes, with the folder the script
    /// made for it.
    func endStream(_ url: URL) {
        guard streams.remove(url.standardizedFileURL) != nil else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The files AppKit is reopening, until each has been read (which may
    /// be after `reopenDocument` returns).
    private var reopening: Set<URL> = []

    override func reopenDocument(for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        let url = contentsURL.standardizedFileURL
        let added = reopening.insert(url).inserted
        super.reopenDocument(for: urlOrNil, withContentsOf: contentsURL, display: displayDocument) { document, alreadyOpen, error in
            MainActor.assumeIsolated { if added { self.reopening.remove(url) } }
            completionHandler(document, alreadyOpen, error)
        }
    }

    /// The file at `url` did not open after all.
    func forgetGlance(at url: URL) { glanced.remove(url.standardizedFileURL) }

    override func noteNewRecentDocumentURL(_ url: URL) {
        if glanced.contains(url.standardizedFileURL) { return }
        #if DEBUG || KIRI_SELFTEST
        selfTestNoted.append(url.standardizedFileURL)
        // A test launch opens temporary files by the dozen: they stay out
        // of the person's Open Recent, which every copy of Kiri shares.
        if SelfTest.isTestLaunch { return }
        #endif
        super.noteNewRecentDocumentURL(url)
        RecentDocuments.shared.refresh()
    }

    #if DEBUG || KIRI_SELFTEST
    /// What would have gone into Open Recent, in order: a test launch
    /// leaves the real list alone and reads this instead.
    private(set) var selfTestNoted: [URL] = []
    #endif

    /// A document that closes is noted once more (by AppKit, as it goes),
    /// and one that was only looked at is forgotten after that.
    override func removeDocument(_ document: NSDocument) {
        let url = document.fileURL
        super.removeDocument(document)
        if let url, !glanced.isEmpty { glanced.remove(url.standardizedFileURL) }
    }

    /// A file opened by name (⌘O, Open Recent, `kiri`, a drop) that is
    /// showing in a preview tab is there to stay. (The sidebar opens its
    /// files without a window first, and says itself what is kept.)
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            // (Asked for by name while it is still opening for the preview
            // tab, it is no longer only being looked at.)
            if displayDocument, let document {
                MainActor.assumeIsolated {
                    if alreadyOpen { PreviewTabs.keep(document) } else { (NSDocumentController.shared as? KiriDocumentController)?.kept(document.fileURL) }
                }
            }
            completionHandler(document, alreadyOpen, error)
        }
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
