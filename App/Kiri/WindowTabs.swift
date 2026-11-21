import AppKit
import KiriKit
import SwiftUI

/// The documents in this window's tab group, for the Honey tab strip.
/// Kiri uses native window tabbing (each document is a window, ⌘N/⌘O open
/// new tabs, Window ▸ Merge All Windows works) but hides the native tab bar
/// and draws its own.
@MainActor @Observable final class WindowTabs {
    struct Item: Equatable {
        let id: Int
        let title: String
        let dirty: Bool
    }

    private(set) var items: [Item] = []
    private(set) var selected = 0
    /// This window's document has unsaved changes.
    private(set) var dirty = false
    /// The folder this window's sidebar shows (`kiri <folder>`).
    private(set) var folder: FolderSession?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var timer: Timer?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { resume(); return }
        self.window = window
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "se.hellsoft.kiri.document"
        Self.useTallTitleBar(window)
        // `kiri -n` and folders get a window of their own.
        if let placement = WindowPlacement.take() {
            if let folder = placement.folder { FolderSessions.set(folder, for: window) }
            refresh()
            timer?.invalidate()
            timer = nil
            resume()
            return
        }
        // SwiftUI opens each document in a window of its own; join the
        // frontmost document window's tab group instead. A folder window's
        // folder comes along now, so the new tab opens with the sidebar
        // already there instead of sliding it in a moment later.
        if let host = NSApp.orderedWindows.first(where: {
            $0 !== window && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier
        }), let f = FolderSessions.session(for: host) {
            FolderSessions.set(f, for: window)
            folder = f
        }
        DispatchQueue.main.async {
            let host = NSApp.orderedWindows.first {
                $0 !== window && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier
                    && !($0.tabbedWindows?.contains(window) ?? false)
            }
            if let host {
                host.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
            self.refresh()
        }
        refresh()
        timer?.invalidate()
        timer = nil
        resume()
    }

    /// Starts (or restarts, after the view came back) the refresh timer.
    func resume() {
        guard timer == nil, window != nil else { return }
        // Titles and dirty state change without notifications we can watch
        // cheaply; four checks a second cost nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard let window else { return }
        hideNativeTabBar(window)
        let windows = window.tabbedWindows ?? [window]
        let next = windows.map { w in
            let doc = NSDocumentController.shared.document(for: w)
            return Item(id: w.windowNumber, title: doc?.displayName ?? w.title, dirty: doc?.isDocumentEdited ?? false)
        }
        if next != items { items = next }
        let sel = (window.tabGroup?.selectedWindow ?? window).windowNumber
        if sel != selected { selected = sel }
        let d = NSDocumentController.shared.document(for: window)?.isDocumentEdited ?? false
        if d != dirty { dirty = d }
        let f = FolderSessions.session(for: window)
        if f !== folder { folder = f }
    }

    /// An empty unified toolbar makes the title bar 52 pt tall, and macOS
    /// keeps the traffic lights centred in it, through resizing, full screen
    /// and tabs. Kiri's top bar fills that band: 10 pt gap, the 32 pt row,
    /// 10 pt gap (`EditorScreen.topBar`).
    static func useTallTitleBar(_ window: NSWindow) {
        guard window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "se.hellsoft.kiri.titlebar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }

    /// macOS puts the window tab bar in a title bar accessory, and
    /// `toggleTabBar` doesn't hide it on windows with a hidden title bar;
    /// hiding the accessory does, and gives its space back.
    private func hideNativeTabBar(_ window: NSWindow) {
        for vc in window.titlebarAccessoryViewControllers where !vc.isHidden {
            if Self.containsTabBar(vc.view) { vc.isHidden = true }
        }
    }

    private static func containsTabBar(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("TabBar") || view.subviews.contains(where: containsTabBar)
    }

    func select(_ id: Int) {
        guard let w = window?.tabbedWindows?.first(where: { $0.windowNumber == id }) else { return }
        w.tabGroup?.selectedWindow = w
        w.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// ⌘1 … ⌘9: the tab at `position` (0-based).
    func select(position: Int) {
        guard items.indices.contains(position) else { return }
        select(items[position].id)
    }

    func selectNext() {
        window?.selectNextTab(nil)
        refresh()
    }

    func selectPrevious() {
        window?.selectPreviousTab(nil)
        refresh()
    }

    func close(_ id: Int) {
        let w = (window?.tabbedWindows ?? [window].compactMap { $0 }).first { $0.windowNumber == id }
        w?.performClose(nil)
    }

    var document: NSDocument? { window.flatMap { NSDocumentController.shared.document(for: $0) } }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

/// Finds the NSWindow that hosts a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

/// Saves a document and reports back, for the Save button's busy → done.
@MainActor final class SaveObserver: NSObject {
    private var completion: ((Bool) -> Void)?

    func save(_ document: NSDocument, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        document.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion?(didSave)
        completion = nil
    }
}
