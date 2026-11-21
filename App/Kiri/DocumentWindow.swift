import AppKit
import KiriKit
import SwiftUI

/// A document's window: the SwiftUI `EditorScreen` in a hosting controller,
/// in a window made here because the document is AppKit's (`KiriDocument`).
/// It looks as a SwiftUI `.hiddenTitleBar` window does: the content runs
/// under a transparent title bar, and `WindowTabs` gives it the tall
/// toolbar band and joins it to the front window's tabs.
@MainActor enum DocumentWindow {
    static let defaultSize = NSSize(width: 900, height: 640)
    /// The name the last document window's frame is kept under.
    private static let frameName = "KiriDocumentWindow"

    static func controller(for document: KiriDocument) -> NSWindowController {
        let host = NSHostingController(rootView: DocumentRoot(document: document))
        // The content says how small the window may get (`EditorScreen`'s
        // minimum), never how big it is: that is the person's to choose.
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultSize)
        window.center()
        // Where the last one was. Not through `setFrameAutosaveName`: only
        // one window at a time can own a name, and the tabs of a group share
        // one frame anyway. `FrameKeeper` saves it instead.
        window.setFrameUsingName(frameName)
        FrameKeeper.shared.start()
        let controller = NSWindowController(window: window)
        // A window of its own (`kiri -n`, a folder) steps down and right of
        // the one before it; a tab takes its group's frame.
        controller.shouldCascadeWindows = true
        return controller
    }

    /// Whether `window` shows a document.
    static func isDocumentWindow(_ window: NSWindow) -> Bool {
        window.windowController?.document is KiriDocument
    }

    /// Remembers where the document window is, for the next one and the
    /// next launch: saved when one has been moved or resized, and when one
    /// closes.
    @MainActor private final class FrameKeeper {
        static let shared = FrameKeeper()
        private var started = false

        func start() {
            guard !started else { return }
            started = true
            // A launch that leaves saved state alone leaves this alone too.
            guard !UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState") else { return }
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    nonisolated(unsafe) let object = note.object
                    MainActor.assumeIsolated {
                        guard let window = object as? NSWindow, DocumentWindow.isDocumentWindow(window),
                              window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
                        window.saveFrame(usingName: DocumentWindow.frameName)
                    }
                }
            }
        }
    }
}

/// What a document window hosts: the editor screen, in the appearance
/// chosen in Settings.
private struct DocumentRoot: View {
    let document: KiriDocument
    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system

    var body: some View {
        EditorScreen(document: document)
            .honeyRoot(HoneyAppearance(theme: theme, motion: motion))
    }
}
