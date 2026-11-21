import AppKit
import KiriKit
import SwiftUI

/// The front document window, for the menus: its editor (Find, Go to Line,
/// the Format menu), its tabs, its folder and its document (Save, Revert).
///
/// The document windows are AppKit's, each hosting an `EditorScreen` of its
/// own, so the menus are told which is in front by the window that is main
/// rather than by SwiftUI's focused scene values. A window that isn't a
/// document's (Settings, Keyboard Shortcuts) leaves all of it nil: the
/// document items are disabled there, and Find goes down the responder
/// chain to whatever text has the keyboard.
@MainActor @Observable final class FrontEditor {
    static let shared = FrontEditor()

    private(set) var editor: EditorModel?
    private(set) var tabs: WindowTabs?
    private(set) var document: KiriDocument?
    var folder: FolderSession? { tabs?.folder }

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private let screens = NSMapTable<NSWindow, Screen>.weakToStrongObjects()
    @ObservationIgnored private var started = false

    /// What a document window holds. The screen owns the three (as SwiftUI
    /// state, and the document as AppKit's); this only points at them.
    private final class Screen {
        weak var editor: EditorModel?
        weak var tabs: WindowTabs?
        weak var document: KiriDocument?

        init(editor: EditorModel, tabs: WindowTabs, document: KiriDocument) {
            self.editor = editor
            self.tabs = tabs
            self.document = document
        }
    }

    /// `EditorScreen` says what is in its window, once it has one.
    func register(_ window: NSWindow, editor: EditorModel, tabs: WindowTabs, document: KiriDocument) {
        screens.setObject(Screen(editor: editor, tabs: tabs, document: document), forKey: window)
        if window.isMainWindow || window === self.window { windowBecameMain(window) }
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                if let window = object as? NSWindow { FrontEditor.shared.windowBecameMain(window) }
            }
        }
        center.addObserver(forName: NSWindow.didResignMainNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                if let window = object as? NSWindow { FrontEditor.shared.windowResignedMain(window) }
            }
        }
    }

    #if DEBUG || KIRI_SELFTEST
    /// Self-tests run in the background, where no window is ever main:
    /// they say which one would be (nil for none), as the notifications do.
    func selfTestMain(_ window: NSWindow?) {
        if let old = self.window, old !== window { windowResignedMain(old) }
        if let window { windowBecameMain(window) }
    }
    #endif

    private func windowBecameMain(_ window: NSWindow) {
        self.window = window
        let screen = screens.object(forKey: window)
        if editor !== screen?.editor { editor = screen?.editor }
        if tabs !== screen?.tabs { tabs = screen?.tabs }
        if document !== screen?.document { document = screen?.document }
    }

    private func windowResignedMain(_ window: NSWindow) {
        guard window === self.window else { return }
        self.window = nil
        if editor != nil { editor = nil }
        if tabs != nil { tabs = nil }
        if document != nil { document = nil }
    }
}
