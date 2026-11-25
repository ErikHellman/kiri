import AppKit
import KiriKit
import SwiftUI

/// One tab of a document window: a document and its editor. The editor
/// (the text view with its selection, scroll position and highlighting,
/// the find bar, the palette and the language) is the tab's own and stays
/// while other tabs show; the window shows one tab's editor at a time
/// (`TabEditorSlot`). Undo is the document's.
///
/// A tab moves between windows whole: dragged to another window's strip,
/// Move Tab to New Window, Merge All Windows.
@MainActor @Observable final class DocumentTab {
    private static var lastID = 0

    /// Stable for the tab's life, also when it moves to another window or
    /// takes another document (the preview tab).
    let id: Int
    /// What the tab shows. Only the folder sidebar's preview tab ever
    /// changes it (`DocumentWindow.show`).
    private(set) var document: KiriDocument
    /// What the status bar shows and the menus act on, for this tab.
    let model = EditorModel()
    @ObservationIgnored let controller: EditorController
    @ObservationIgnored let container = EditorContainerView(frame: .zero)
    /// The folder sidebar's preview tab (`PreviewTabs`).
    var preview = false
    /// The tab shows its Markdown rendered, in the editor's place
    /// (`setMarkdownPreview`).
    var showsMarkdownPreview = false
    /// Made the first time the tab shows its Markdown rendered.
    @ObservationIgnored var markdownPreview: MarkdownPreview?
    /// The file arrived (a new tab, or the preview tab taking another
    /// file) and its text is to fade in when it next shows
    /// (`TabEditorSlot.arrive`).
    @ObservationIgnored var arriving = false
    /// The window the tab is in.
    @ObservationIgnored weak var window: DocumentNSWindow?
    /// What had the keyboard in this tab when another one took its place.
    @ObservationIgnored weak var lastResponder: NSResponder?
    /// The editor has been put in a window once (`TabEditorSlot.show`).
    @ObservationIgnored var installed = false
    /// The file the language was last read for.
    @ObservationIgnored private var languageFor: URL?
    /// Its place in the list it was restored from (`TabRestoration`).
    @ObservationIgnored var restoreIndex: Int?
    /// The read-only viewer that shows a large file in the editor's place
    /// (`KiriDocument.isLargeFile`).
    @ObservationIgnored private(set) var largeViewer: LargeFileViewer?

    init(document: KiriDocument, arriving: Bool) {
        Self.lastID += 1
        id = Self.lastID
        self.document = document
        controller = EditorController(model: model)
        controller.tab = self
        // The editor now, not when it first shows: a tab that isn't showing
        // has one too (Go to Line from `kiri file:12`, the self-tests).
        controller.undoManager = document.undoManager
        controller.attach(container)
        controller.setUntitled(document.fileURL == nil)
        controller.load(document)
        languageFor = document.location
        model.language = document.detectedLanguage
        controller.setLanguage(model.language)
        updateLargeViewer()
        // Where the file was the last time it was open (`FilePositions`).
        controller.restorePosition()
        trackLocation()
        if arriving { arrive() }
    }

    /// The document's file grew past the limit while it was open, and it
    /// was read again read-only: the viewer takes the editor's place.
    func documentBecameLarge() {
        // (Large files are read-only, and have no preview.)
        showsMarkdownPreview = false
        updateLargeViewer()
        if let slot = window?.editorSlot, window?.tabs.selectedTab === self { slot.show(self) }
    }

    /// A large file shows in a viewer of its own; any other in the editor.
    private func updateLargeViewer() {
        if let file = document.largeFile {
            guard largeViewer?.document !== document else { return }
            largeViewer?.stop()
            largeViewer = LargeFileViewer(document: document, file: file, model: model)
        } else if let viewer = largeViewer {
            viewer.stop()
            largeViewer = nil
        }
    }

    /// The text fades in: now, if the tab shows, or when it next does.
    func arrive() {
        arriving = true
        if let slot = window?.editorSlot, slot.tab === self { slot.arrive(self) }
    }

    /// Another file takes this tab (the preview tab going from file to
    /// file): its editor shows it where it was the last time it was open,
    /// or from the first line. The file before keeps its place for next time.
    func replaceDocument(with new: KiriDocument) {
        guard new !== document else { return }
        controller.rememberPosition()
        document = new
        controller.show(new)
        updateLargeViewer()
        controller.restorePosition()
        languageFor = new.location
        trackLocation()
        arrive()
    }

    /// The language follows the file's name: Save As, a rename, a move in
    /// Finder. (One picked in the status bar stays until then.)
    private func trackLocation() {
        let document = document
        withObservationTracking { _ = document.location } onChange: { [weak self] in
            Task { @MainActor in self?.locationChanged(of: document) }
        }
    }

    private func locationChanged(of old: KiriDocument) {
        guard old === document else { return }
        trackLocation()
        controller.setUntitled(document.fileURL == nil)
        if languageFor != document.location {
            languageFor = document.location
            let language = document.detectedLanguage
            if model.language != language { model.language = language }
            controller.setLanguage(language)
        }
        window?.tabs.setNeedsRefresh()
    }
}

/// The tabs of one document window, and the Honey tab strip's view of
/// them. Kiri draws its own tabs: a window holds its documents, shows one
/// at a time, and opening a file never makes a window (only a window of
/// its own does: `kiri -n`, a folder, Move Tab to New Window, a tab
/// dragged out of its strip).
///
/// The strip follows the documents by observation, so a change shows in
/// the next run-loop turn: a document turning dirty is not observable
/// (`NSDocument.isDocumentEdited` tells nobody), but every edit, undo and
/// redo closes an undo group, a save sets the document's
/// `fileModificationDate`, and a rename moves its `location`.
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

    /// The window's tabs, in order.
    private(set) var list: [DocumentTab] = []
    /// What the strip shows of them (`refresh`).
    private(set) var items: [Item] = []
    /// The id of the tab that shows.
    private(set) var selected = 0
    /// The tab that shows.
    var selectedTab: DocumentTab? { list.first { $0.id == selected } ?? list.first }
    /// The document that shows has unsaved changes.
    private(set) var dirty = false
    /// The folder this window's sidebar shows (`kiri <folder>`).
    private(set) var folder: FolderSession?
    /// Where the tab strip is scrolled to, when it has more tabs than fit.
    var stripOffset: CGFloat = 0
    @ObservationIgnored weak var window: DocumentNSWindow?
    @ObservationIgnored private var observer: TabObserver?
    @ObservationIgnored private var watches: [Watch] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var safetyNet: Timer?

    /// A key of a document that `observer` is registered for.
    private struct Watch {
        weak var object: NSObject?
        let keyPath: String
        let id: ObjectIdentifier
    }

    #if DEBUG || KIRI_SELFTEST
    /// The self-test turns the safety net off, to show that the strip
    /// follows its tabs without it.
    static var safetyNetEnabled = true
    /// The tabs model of a document window, for the self-test.
    static func model(for window: NSWindow) -> WindowTabs? { (window as? DocumentNSWindow)?.tabs }
    /// Every list of tabs this model has shown, in order.
    @ObservationIgnored private(set) var shown: [[Int]] = []
    #endif

    private func show(_ next: [Item]) {
        guard next != items else { return }
        items = next
        #if DEBUG || KIRI_SELFTEST
        shown.append(next.map(\.id))
        #endif
    }

    /// Starts watching the documents, for `window`.
    func attach(to window: DocumentNSWindow) {
        self.window = window
        let observer = TabObserver { [weak self] in
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        }
        self.observer = observer
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
    }

    // MARK: The list

    /// Puts `tab` among this window's tabs: after `after` (by default the
    /// tab that shows), or at `index`.
    func insert(_ tab: DocumentTab, after: DocumentTab? = nil, at index: Int? = nil, select: Bool = true) {
        guard !list.contains(where: { $0 === tab }) else {
            if select { self.select(tab) }
            return
        }
        tab.window?.tabs.remove(tab)
        tab.window = window
        let position: Int
        if let index {
            position = min(max(index, 0), list.count)
        } else if let anchor = after ?? selectedTab, let i = list.firstIndex(where: { $0 === anchor }) {
            position = i + 1
        } else {
            position = list.count
        }
        list.insert(tab, at: position)
        if select || list.count == 1 { self.select(tab) } else { refresh() }
        window?.invalidateRestorableState()
    }

    /// Takes `tab` out of this window, its document still open (it is
    /// closing, or moving to another window). The tab beside it shows in
    /// its place: the one after it, or the one before at the end. Without
    /// tabs, the window closes.
    func remove(_ tab: DocumentTab) {
        guard let index = list.firstIndex(where: { $0 === tab }) else { return }
        if tab.id == selected, list.count > 1 {
            select(list[index + 1 < list.count ? index + 1 : index - 1])
        }
        list.remove(at: index)
        if tab.window === window { tab.window = nil }
        if tab.container.superview != nil, tab.container.window === window { tab.container.removeFromSuperview() }
        if list.isEmpty {
            // (Its document's own close may already be under way: it takes
            // the window controller with it.)
            if let controller = window?.windowController, let document = controller.document as? NSDocument,
               document === tab.document {
                document.removeWindowController(controller)
            }
            window?.closeEmpty()
        } else {
            refresh()
            window?.invalidateRestorableState()
        }
    }

    func tab(for document: NSDocument) -> DocumentTab? { list.first { $0.document === document } }
    func tab(id: Int) -> DocumentTab? { list.first { $0.id == id } }

    // MARK: Selecting

    func select(_ id: Int) {
        guard let tab = tab(id: id) else { return }
        select(tab)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows `tab`: its document takes the window (and its controller, so
    /// AppKit's document machinery—the title, the edited dot, Save—follows
    /// the tab that shows), and its editor takes the editor's place.
    /// Not while a sheet is up: it asks about the tab that shows.
    func select(_ tab: DocumentTab) {
        guard let window, list.contains(where: { $0 === tab }) else { return }
        guard tab.id != selected || window.windowController?.document !== tab.document else { refresh(); return }
        if window.attachedSheet != nil, selected != 0, tab.id != selected { return }
        let old = list.first { $0.id == selected && $0 !== tab }
        if let old {
            old.lastResponder = window.firstResponder
            // The sidebar's keyboard is the window's, not the tab's.
            tab.model.sidebarHasFocus = old.model.sidebarHasFocus
            tab.model.sidebarShowsKeyboard = old.model.sidebarShowsKeyboard
        }
        selected = tab.id
        DocumentWindow.attachController(of: window, to: tab.document)
        let hadEditor = old.map { o in window.firstResponder.map { Self.isInside($0, o.container) } ?? true } ?? false
        window.editorSlot?.show(tab)
        // The keyboard goes to the editor of the tab that shows, where it
        // was in that tab, if it was in the editor of the tab before.
        if hadEditor || window.firstResponder === window || window.firstResponder == nil {
            let target = tab.lastResponder.flatMap { Self.isInside($0, tab.container) ? $0 : nil } ?? tab.container.textView
            window.makeFirstResponder(target)
        }
        FrontEditor.shared.selectionChanged(in: window)
        refresh()
        window.invalidateRestorableState()
    }

    private static func isInside(_ responder: NSResponder, _ container: NSView) -> Bool {
        (responder as? NSView)?.isDescendant(of: container) ?? false
    }

    /// ⌘1 … ⌘9: the tab at `position` (0-based).
    func select(position: Int) {
        guard list.indices.contains(position) else { return }
        select(list[position].id)
    }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }

    /// The next or previous tab, round from the last to the first.
    private func step(_ by: Int) {
        guard list.count > 1, let current = list.firstIndex(where: { $0.id == selected }) else { return }
        select(list[(current + by + list.count) % list.count].id)
    }

    // MARK: Closing

    /// The tab's close button and File ▸ Close: a tab with unsaved
    /// changes comes forward and asks first (`KiriDocument.canClose`).
    func close(_ id: Int) {
        guard let tab = tab(id: id) else { return }
        DocumentWindow.close(tab)
    }

    /// A preview tab was double-clicked: it stays.
    func keep(_ id: Int) {
        PreviewTabs.keep(tab(id: id))
    }

    var document: NSDocument? { selectedTab?.document }

    // MARK: The strip

    /// One refresh at the end of this run-loop turn, however many things
    /// changed in it. (The notifications arrive before a document has
    /// counted its change.)
    func setNeedsRefresh() {
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
        // A preview never has unsaved changes: whatever changed it (an
        // edit is heard of sooner, in the editor) keeps it.
        for tab in list where tab.preview && tab.document.isDocumentEdited {
            PreviewTabs.keep(tab)
        }
        show(list.map { tab in
            Item(id: tab.id, title: tab.document.displayName, path: tab.document.fileURL?.path,
                 dirty: tab.document.isDocumentEdited, preview: tab.preview)
        })
        let d = selectedTab?.document.isDocumentEdited ?? false
        if d != dirty { dirty = d }
        let f = FolderSessions.session(for: window)
        if f !== folder { folder = f }
        if observer != nil { watch() }
    }

    /// Watches what the documents can say about themselves: a save.
    private func watch() {
        guard let observer else { return }
        let wanted = list.map { Watch(object: $0.document, keyPath: "fileModificationDate", id: ObjectIdentifier($0.document)) }
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
    /// keeps the traffic lights centred in it, through resizing and full
    /// screen. Kiri's top bar fills that band: 10 pt gap, the 32 pt row,
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

    /// Stops watching (the window closed).
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
