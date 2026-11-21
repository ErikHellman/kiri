import KiriKit
import SwiftUI

/// Kiri for macOS: one window per document, launching straight into an editor.
@main
struct KiriApp: App {
    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system
    @NSApplicationDelegateAdaptor private var delegate: KiriAppDelegate

    init() {
        // Launch into a new, empty document instead of the Open panel.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        Honey.registerFonts()
        ThemeController.start()
    }

    private var appearance: HoneyAppearance { HoneyAppearance(theme: theme, motion: motion) }

    var body: some Scene {
        DocumentGroup(newDocument: { KiriDocument(text: KiriDocument.pendingText ?? "") }) { file in
            EditorScreen(document: file.document, fileURL: file.fileURL)
                .honeyRoot(appearance)
        }
        // Honey on macOS (DESIGN.md §5): no title bar, the traffic lights
        // sit on the canvas and the panels float below them.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)
        .commands { KiriCommands() }

        Settings {
            SettingsView().honeyRoot(appearance)
        }
        .windowResizability(.contentSize)

        Window("Keyboard Shortcuts", id: ShortcutsView.windowID) {
            ShortcutsView().honeyRoot(appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Style Gallery", id: "style-gallery") {
            StyleGallery()
                .frame(minWidth: 900, minHeight: 600)
                .honeyRoot(appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Takes `kiri` command-line requests (kiri:// URLs).
final class KiriAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { KiriCLI.install() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Again, in case SwiftUI set up its own URL handler in between.
        MainActor.assumeIsolated { KiriCLI.install() }
    }
}
