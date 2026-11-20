import KiriKit
import SwiftUI

/// Kiri for macOS. Until the editor lands (plan step 2) the main window shows
/// the Honey + Liquid Glass style kit.
@main
struct KiriApp: App {
    init() {
        Honey.registerFonts()
    }

    var body: some Scene {
        WindowGroup("Kiri") {
            StyleGallery()
                .frame(minWidth: 900, minHeight: 600)
        }
        // Honey on macOS (DESIGN.md §11): no title bar, the traffic lights
        // sit on the canvas and the panels float below them.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
    }
}
