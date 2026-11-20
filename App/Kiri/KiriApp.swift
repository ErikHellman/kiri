import KiriKit
import SwiftUI

/// Kiri for macOS: one window per document, launching straight into an editor.
@main
struct KiriApp: App {
    @AppStorage(Settings.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Settings.motionKey) private var motion = HoneyMotionLevel.system

    init() {
        // Launch into a new, empty document instead of the Open panel.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        Honey.registerFonts()
    }

    private var appearance: HoneyAppearance { HoneyAppearance(theme: theme, motion: motion) }

    var body: some Scene {
        DocumentGroup(newDocument: { KiriDocument() }) { file in
            EditorScreen(document: file.document, fileURL: file.fileURL)
                .honeyRoot(appearance)
        }
        // Honey on macOS (DESIGN.md §5): no title bar, the traffic lights
        // sit on the canvas and the panels float below them.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)
        .commands {
            TextEditingCommands()
        }

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
