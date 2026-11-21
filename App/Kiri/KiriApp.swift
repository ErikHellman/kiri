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
