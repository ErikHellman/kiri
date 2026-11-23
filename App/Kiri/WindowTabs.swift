import AppKit
import KiriKit
import SwiftUI

/// The documents in this window's tab group, for the Honey tab strip.
/// Kiri uses native window tabbing (each document is a window, ⌘N/⌘O open
/// new tabs, Window ▸ Merge All Windows works) but hides the native tab bar
/// and draws its own.
///
/// The strip follows the tab group by observation, so a change shows in the
/// next run-loop turn: the group's `windows` and `selectedWindow` and each
/// window's `title` are key-value observable; a document turning dirty is
/// not (`NSDocument.isDocumentEdited` tells nobody), but every edit, undo
/// and redo closes an undo group, and a save sets the document's
/// `fileModificationDate`.
@MainActor @Observable final class WindowTabs {
    struct Item: Equatable {
        let id: Int
        let title: String
        /// The file, or nil for a document that hasn't been saved.
        let path: String?
        let dirty: Bool
        /// The folder sidebar's preview tab (`PreviewTabs`).
        let preview: Bool
    }

    /// The items as tabs: each with its path as a tooltip (`~` for the home
    /// folder), and those that share a title with the folder that tells
    /// them apart.
    var tabs: [HoneyTab<Int>] {
        let details = TabNames.details(titles: items.map(\.title), paths: items.map(\.path))
        let home = NSHomeDirectory()
        return zip(items, details).map { item, detail in
            HoneyTab(id: item.id, title: item.title, detail: detail,
                     tooltip: item.path.map { TabNames.abbreviatingHome($0, home: home) }, dirty: item.dirty,
                     preview: item.preview)
        }
    }

    /// How the folder sidebar marks the row of a file that is open in one
    /// of this window's tabs.
    struct FileMark: Equatable {
        /// It has unsaved changes: the tab's dot.
        let edited: Bool
        /// It shows in the preview tab: the tab's slant.
        let preview: Bool
    }

    /// The files open in this window's tabs. Made from `items`, so the
    /// sidebar's marks follow tabs opening and closing, edits and saves in
    /// the same refresh as the strip does.
    var openFiles: [URL: FileMark] {
        Dictionary(items.compactMap { item in
            item.path.map { (URL(fileURLWithPath: $0).standardizedFileURL, FileMark(edited: item.dirty, preview: item.preview)) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private(set) var items: [Item] = []
    private(set) var selected = 0
    /// This window's document has unsaved changes.
    private(set) var dirty = false
    /// The folder this window's sidebar shows (`kiri <folder>`).
    private(set) var folder: FolderSession?
    @ObservationIgnored weak var window: NSWindow?
    /// Set while this object watches its tab group (while its view shows).
    @ObservationIgnored private var observer: TabObserver?
    @ObservationIgnored private var watches: [Watch] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var safetyNet: Timer?

    /// A key of a window or document that `observer` is registered for.
    private struct Watch {
        weak var object: NSObject?
        let keyPath: String
        let id: ObjectIdentifier
    }

    #if DEBUG || KIRI_SELFTEST
    /// The self-test turns the safety net off, to show that the strip
    /// follows its tabs without it.
    static var safetyNetEnabled = true
    private static let models = NSMapTable<NSWindow, WindowTabs>.weakToWeakObjects()
    /// The tabs model of a document window, for the self-test.
    static func model(for window: NSWindow) -> WindowTabs? { models.object(forKey: window) }
    /// Every list of tabs this model has shown, in order.
    @ObservationIgnored private(set) var shown: [[Int]] = []
    #endif

    /// Where the tab strip is scrolled to, when it has more tabs than fit.
    /// Shared by the windows of a tab group: each draws its own strip, and
    /// the one that shows next starts where the last one was, so the tabs
    /// stay put when a click swaps one window for another.
    var stripOffset: CGFloat {
        get {
            guard let group = window?.tabGroup, let x = Self.stripOffsets.object(forKey: group) else { return 0 }
            return CGFloat(x.doubleValue)
        }
        set {
            // Only the strip that is showing says where the strip is.
            guard let window, let group = window.tabGroup, group.selectedWindow === window else { return }
            Self.stripOffsets.setObject(NSNumber(value: Double(newValue)), forKey: group)
        }
    }

    private static let stripOffsets = NSMapTable<NSWindowTabGroup, NSNumber>.weakToStrongObjects()

    private func show(_ next: [Item]) {
        guard next != items else { return }
        items = next
        #if DEBUG || KIRI_SELFTEST
        shown.append(next.map(\.id))
        #endif
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { resume(); return }
        invalidate()
        self.window = window
        #if DEBUG || KIRI_SELFTEST
        Self.models.setObject(self, forKey: window)
        #endif
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        Self.useTallTitleBar(window)
        // `kiri -n` and folders get a window of their own; files dropped
        // on a window join that one's tabs, whichever window is in front.
        let placement = WindowPlacement.take()
        if let placement, placement.host == nil {
            if let folder = placement.folder { FolderSessions.set(folder, for: window) }
            resume()
            return
        }
        weak let wanted = placement?.host, after = placement?.after
        /// The window whose tabs this one joins.
        func host() -> NSWindow? {
            if let wanted, wanted !== window, wanted.isVisible || wanted.tabGroup?.selectedWindow?.isVisible == true { return wanted }
            return Self.host(for: window)
        }
        // Each document has a window of its own; join the frontmost
        // document window's tab group instead. A folder window's
        // folder comes along now, so the new tab opens with the sidebar
        // already there instead of sliding it in a moment later.
        Self.joining.insert(ObjectIdentifier(window))
        if let host = host() {
            if let f = FolderSessions.session(for: host) {
                FolderSessions.set(f, for: window)
                folder = f
            }
            // Until this window has joined, its strip shows the host's
            // tabs as they are; its own tab then grows in at the end and
            // the selection slides to it, instead of the others arriving
            // around a tab that stood alone for a moment.
            show(Self.items(of: host.tabbedWindows ?? [host]))
            selected = (host.tabGroup?.selectedWindow ?? host).windowNumber
        }
        DispatchQueue.main.async {
            if let host = host(), !(host.tabbedWindows?.contains(window) ?? false) {
                // After the tab it was asked to follow, or after the host.
                if let after, let group = host.tabGroup, let index = group.windows.firstIndex(of: after) {
                    group.insertWindow(window, at: index + 1)
                } else {
                    host.addTabbedWindow(window, ordered: .above)
                }
                window.makeKeyAndOrderFront(nil)
            }
            Self.joining.remove(ObjectIdentifier(window))
            self.refresh()
        }
        resume()
    }

    static let tabbingIdentifier = "se.hellsoft.kiri.document"

    /// The window a document window made now will join as a tab
    /// (`attach`, which takes the placement, decides it the same way), or
    /// nil for one that gets a window of its own: the first, `kiri -n`, a
    /// folder. Asked while the window is made, before it shows, so that it
    /// can come up where its tabs are (`DocumentWindow.controller`).
    static func upcomingHost() -> NSWindow? {
        if let placement = WindowPlacement.next {
            guard let wanted = placement.host else { return nil }
            if wanted.isVisible { return wanted }
            if let shown = wanted.tabGroup?.selectedWindow, shown.isVisible { return shown }
        }
        return NSApp.orderedWindows.first {
            $0.isVisible && $0.tabbingIdentifier == tabbingIdentifier && !joining.contains(ObjectIdentifier($0))
        }
    }

    /// Windows that are up but haven't joined a tab group yet. Several files
    /// opened at once (Finder, the Open panel, `kiri a b c`) all have their
    /// windows, in front, before the first of them joins.
    private static var joining: Set<ObjectIdentifier> = []

    /// The window whose tab group a new document window joins: the frontmost
    /// one that isn't itself still waiting to join. Waiting windows would
    /// otherwise pair up with each other, and then leave again for a third,
    /// which scatters the files over several windows.
    private static func host(for window: NSWindow) -> NSWindow? {
        NSApp.orderedWindows.first {
            $0 !== window && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier
                && !joining.contains(ObjectIdentifier($0))
        }
    }

    /// Starts (or restarts, after the view came back) watching the tab
    /// group. What changed while the view was away shows at once, without
    /// the strip animating its way there.
    func resume() {
        guard observer == nil, let window else { return }
        let observer = TabObserver { [weak self] in
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        }
        self.observer = observer
        // The tab group itself is watched from `watch`, with the titles
        // and the documents.
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, of object: AnyObject? = nil) {
            tokens.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsRefresh() }
            })
        }
        // An edit, an undo or a redo, in any tab: its document's change
        // count follows before the turn is over.
        on(.NSUndoManagerDidCloseUndoGroup)
        on(.NSUndoManagerDidUndoChange)
        on(.NSUndoManagerDidRedoChange)
        on(FolderSessions.didChange)
        on(PreviewTabs.didChange)
        // A tab closing; when it is this window, there is nothing left to watch.
        let ownWindow = ObjectIdentifier(window)
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let own = (note.object as AnyObject?).map { ObjectIdentifier($0) } == ownWindow
            MainActor.assumeIsolated { if own { self?.invalidate() } else { self?.setNeedsRefresh() } }
        })
        // macOS brings the native tab bar back in a few places; `refresh`
        // hides it again.
        on(NSWindow.didBecomeKeyNotification, of: window)
        on(NSWindow.didEnterFullScreenNotification, of: window)
        on(NSWindow.didExitFullScreenNotification, of: window)
        // Not what keeps the strip current (the self-test runs without
        // it): a net under whatever changes a document's state by a path
        // none of the above sees.
        safetyNet = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                #if DEBUG || KIRI_SELFTEST
                guard Self.safetyNetEnabled else { return }
                #endif
                self?.refresh()
            }
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { refresh() }
    }

    /// One refresh at the end of this run-loop turn, however many things
    /// changed in it. (The notifications arrive in the middle of AppKit
    /// moving tabs about, and before a document has counted its change.)
    private func setNeedsRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    func refresh() {
        guard let window else { return }
        hideNativeTabBar(window)
        // A window on its way into a tab group shows the group it is
        // joining (see `attach`), not itself alone.
        let joining = Self.joining.contains(ObjectIdentifier(window)) && !items.isEmpty
        let windows = window.tabbedWindows ?? [window]
        // A preview never has unsaved changes: whatever changed it (an
        // edit is heard of sooner, in the editor) keeps it.
        for w in windows where PreviewTabs.isPreview(w) && NSDocumentController.shared.document(for: w)?.isDocumentEdited == true {
            PreviewTabs.keep(w)
        }
        if !joining {
            show(Self.items(of: windows))
            let sel = (window.tabGroup?.selectedWindow ?? window).windowNumber
            if sel != selected { selected = sel }
        }
        let d = NSDocumentController.shared.document(for: window)?.isDocumentEdited ?? false
        if d != dirty { dirty = d }
        let f = FolderSessions.session(for: window)
        if f !== folder { folder = f }
        if observer != nil { watch(windows) }
    }

    private static func items(of windows: [NSWindow]) -> [Item] {
        windows.map { w in
            let doc = NSDocumentController.shared.document(for: w)
            return Item(id: w.windowNumber, title: doc?.displayName ?? w.title, path: doc?.fileURL?.path,
                        dirty: doc?.isDocumentEdited ?? false, preview: PreviewTabs.isPreview(w))
        }
    }

    /// Watches what the group's windows and documents can say about
    /// themselves: a title (a rename, Save As, a move in Finder) and a save.
    private func watch(_ windows: [NSWindow]) {
        guard let observer, let window else { return }
        var wanted: [Watch] = []
        // The group itself, not the window's "tabGroup.windows": a window
        // that closes leaves its group without telling KVO, and taking an
        // observer of such a path off it then throws. A window that moves
        // to another group (dragged out, merged) changes the group it
        // leaves, and the refresh that follows watches the new one.
        if let group = window.tabGroup {
            for keyPath in ["windows", "selectedWindow"] {
                wanted.append(Watch(object: group, keyPath: keyPath, id: ObjectIdentifier(group)))
            }
        }
        for w in windows {
            wanted.append(Watch(object: w, keyPath: "title", id: ObjectIdentifier(w)))
            if let doc = NSDocumentController.shared.document(for: w) {
                wanted.append(Watch(object: doc, keyPath: "fileModificationDate", id: ObjectIdentifier(doc)))
            }
        }
        // A watch whose object is gone says nothing about a new one at its address.
        watches.removeAll { $0.object == nil }
        func same(_ a: Watch, _ b: Watch) -> Bool { a.id == b.id && a.keyPath == b.keyPath }
        for old in watches where !wanted.contains(where: { same($0, old) }) {
            old.object?.removeObserver(observer, forKeyPath: old.keyPath)
        }
        let kept = watches.filter { old in wanted.contains { same($0, old) } }
        for new in wanted where !kept.contains(where: { same($0, new) }) {
            new.object?.addObserver(observer, forKeyPath: new.keyPath, options: [], context: nil)
        }
        watches = kept + wanted.filter { new in !kept.contains { same($0, new) } }
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
        guard let w = (window?.tabbedWindows ?? [window].compactMap { $0 }).first(where: { $0.windowNumber == id }) else { return }
        // A tab with unsaved changes asks before it closes, in a sheet on
        // its own window: it comes forward first, so the question is seen.
        if NSDocumentController.shared.document(for: w)?.isDocumentEdited == true, w.tabGroup?.selectedWindow !== w {
            w.tabGroup?.selectedWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        w.performClose(nil)
    }

    /// A preview tab was double-clicked: it stays.
    func keep(_ id: Int) {
        PreviewTabs.keep((window?.tabbedWindows ?? [window].compactMap { $0 }).first { $0.windowNumber == id })
    }

    var document: NSDocument? { window.flatMap { NSDocumentController.shared.document(for: $0) } }

    /// Stops watching (the view went away: a tab that isn't showing).
    func invalidate() {
        if let observer {
            for watch in watches { watch.object?.removeObserver(observer, forKeyPath: watch.keyPath) }
        }
        watches = []
        observer = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        safetyNet?.invalidate()
        safetyNet = nil
    }
}

/// Tells a `WindowTabs` that a key it watches changed.
private final class TabObserver: NSObject {
    private let changed: @Sendable () -> Void

    init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        changed()
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
