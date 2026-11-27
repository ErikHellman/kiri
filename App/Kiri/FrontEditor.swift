import AppKit
import KiriKit
import SwiftUI

/// The front document window, for the menus: the editor of its selected
/// tab (Find, Go to Line, the Format menu), its tabs, its folder and the
/// selected tab's document (Save, Revert).
///
/// The document windows are AppKit's, each hosting an `EditorScreen` of its
/// own, so the menus are told which is in front by the window that is main
/// rather than by SwiftUI's focused scene values. A window that isn't a
/// document's (Settings, Keyboard Shortcuts) leaves all of it nil: the
/// document items are disabled there, and Find goes down the responder
/// chain to whatever text has the keyboard.
@Observable final class FrontEditor {
    static let shared = FrontEditor()

    private(set) var editor: EditorModel?
    private(set) var tabs: WindowTabs?
    private(set) var document: KiriDocument?
    var folder: FolderSession? { tabs?.folder }

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var started = false

    /// `EditorScreen` says its window is up.
    func register(_ window: DocumentNSWindow) {
        if window.isMainWindow || window === self.window { windowBecameMain(window) }
    }

    /// The editor of a document window's selected tab, in front or not.
    func editor(in window: NSWindow) -> EditorModel? { (window as? DocumentNSWindow)?.tabs.selectedTab?.model }

    /// The tabs model of a document window, in front or not.
    func tabs(in window: NSWindow) -> WindowTabs? { (window as? DocumentNSWindow)?.tabs }

    /// `window` shows another tab, or another document in its tab.
    func selectionChanged(in window: DocumentNSWindow) {
        if window === self.window { windowBecameMain(window) }
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
        // SwiftUI brings a menu's items up to date when the menu is about
        // to open, and a key equivalent doesn't open it: ⌘S in a window
        // that has just come forward would find Save as it was for the
        // window before (off, after Settings) and do nothing. So a key
        // that may be a menu's has the menus brought up to date first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // ⌃⇥ and ⌃⇧⇥: the next and previous tab, as in every tabbed
            // window on the Mac (which gives them only to its own tabs).
            if event.keyCode == 48, modifiers.subtracting(.shift) == .control,
               let window = event.window as? DocumentNSWindow, window.attachedSheet == nil {
                MainActor.assumeIsolated {
                    if modifiers.contains(.shift) { window.tabs.selectPrevious() } else { window.tabs.selectNext() }
                }
                return nil
            }
            if !modifiers.isDisjoint(with: [.command, .control]) { MainActor.assumeIsolated { MainMenu.refresh() } }
            return event
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
        let tabs = (window as? DocumentNSWindow)?.tabs
        let tab = tabs?.selectedTab
        if editor !== tab?.model { editor = tab?.model }
        if self.tabs !== tabs { self.tabs = tabs }
        if document !== tab?.document { document = tab?.document }
    }

    private func windowResignedMain(_ window: NSWindow) {
        guard window === self.window else { return }
        self.window = nil
        if editor != nil { editor = nil }
        if tabs != nil { tabs = nil }
        if document != nil { document = nil }
    }
}

/// The menu bar's menus.
enum MainMenu {
    /// Brings every menu's items up to date, as opening it would.
    static func refresh() {
        if let menu = NSApp.mainMenu { refresh(menu) }
    }

    private static func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items { if let submenu = item.submenu { refresh(submenu) } }
    }
}
