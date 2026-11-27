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
    /// The read-only viewer that shows a picture, a video or an archive in
    /// the editor's place (`KiriDocument.media`).
    @ObservationIgnored private(set) var mediaViewer: MediaViewer?
    /// The preview beside the text renders again a moment after the last key.
    @ObservationIgnored var besideRender: DispatchWorkItem?
    /// The tab opened on an SVG file's picture, which isn't drawn yet: the
    /// slot shows the paper until it is, not the text (`TabEditorSlot.show`).
    @ObservationIgnored var opensInPreview = false

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
        updateViewer()
        // Where the file was the last time it was open (`FilePositions`).
        controller.restorePosition()
        trackLocation()
        openSVGAsPicture()
        if arriving { arrive() }
    }

    /// The document's file became another kind of file while it was open
    /// (it grew past the limit, or became a picture, or text again), and
    /// was read again: the viewer or the editor takes the other's place.
    func documentChangedKind() {
        // (Read-only files have no preview.)
        if document.isReadOnly { showsMarkdownPreview = false }
        updateViewer()
        window?.slot(for: self)?.show(self)
    }

    /// A large file shows in a viewer of its own, as does a picture, a
    /// video or an archive; any other file in the editor.
    private func updateViewer() {
        if let file = document.largeFile {
            if largeViewer?.document !== document {
                largeViewer?.stop()
                largeViewer = LargeFileViewer(document: document, file: file, model: model)
            }
        } else if let viewer = largeViewer {
            viewer.stop()
            largeViewer = nil
        }
        if let media = document.media {
            if mediaViewer?.document !== document || mediaViewer?.kind != media.kind {
                mediaViewer?.stop()
                mediaViewer = MediaViewer(document: document, media: media, model: model)
            }
        } else if let viewer = mediaViewer {
            viewer.stop()
            mediaViewer = nil
        }
    }

    /// An SVG file opens on its picture (the Text / Preview switch, as for
    /// Markdown, goes to its text).
    private func openSVGAsPicture() {
        guard isSVG, canPreviewMarkdown, !showsMarkdownPreview else { return }
        opensInPreview = true
        setMarkdownPreview(true)
    }

    /// The text fades in: now, if the tab shows, or when it next does.
    func arrive() {
        arriving = true
        if let slot = window?.slot(for: self), slot.tab === self { slot.arrive(self) }
    }

    /// Another file takes this tab (the preview tab going from file to
    /// file): its editor shows it where it was the last time it was open,
    /// or from the first line. The file before keeps its place for next time.
    func replaceDocument(with new: KiriDocument) {
        guard new !== document else { return }
        controller.rememberPosition()
        // An SVG's picture was showing: the next file opens as its own does.
        if isSVG, showsMarkdownPreview { setMarkdownPreview(false) }
        document = new
        controller.show(new)
        updateViewer()
        controller.restorePosition()
        languageFor = new.location
        trackLocation()
        openSVGAsPicture()
        arrive()
    }

    /// `responder` is one of this tab's views: its editor, or what shows
    /// in the editor's place (a viewer, the Markdown preview).
    func holds(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        let mine: [NSView?] = [container, markdownPreview?.webView, largeViewer?.view, mediaViewer?.view]
        return mine.contains { $0.map(view.isDescendant(of:)) ?? false }
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
        /// It shows on the other side of the split, beside the selected tab.
        var beside = false
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
                     preview: item.preview, beside: item.beside)
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
    /// The id of the tab that shows: the one with the keyboard, in a
    /// window split side by side.
    private(set) var selected = 0
    /// The tab that shows (with the keyboard).
    var selectedTab: DocumentTab? { list.first { $0.id == selected } ?? list.first }

    // MARK: Side by side

    typealias Side = SplitLayout.Side

    /// What the other side of a split window shows.
    enum Beside: Equatable {
        /// Another of the window's tabs.
        case tab(Int)
        /// The selected tab's Markdown or SVG preview, beside its text
        /// (View ▸ Preview to the Side).
        case preview
    }

    /// One of the editor panels of the window, left to right.
    struct Panel: Identifiable {
        /// Which of the window's two editor slots (`TabEditorSlot`) it is:
        /// it stays with its panel while the other comes and goes, while
        /// the keyboard moves between them and while they swap places.
        let slot: Int
        let tab: DocumentTab
        /// It shows `tab`'s preview, beside its text.
        let preview: Bool
        /// It has the keyboard: its tab is the selected one (or, beside
        /// the text, it is the preview the keyboard is in).
        let keyboard: Bool
        let side: Side
        var id: Int { slot }
    }

    /// What the other side shows; nil while the window shows one tab.
    private(set) var beside: Beside?
    /// The slot the selected tab's text is in.
    private(set) var mainSlot = 0
    /// The other side is the left one.
    private(set) var besideIsLeft = false
    /// Beside its text, the keyboard is in the preview.
    private(set) var keyboardInPreview = false
    /// The left side's share of the editors' row (`SplitLayout`).
    var splitFraction = SplitLayout.defaultFraction
    /// Where something dragged over the editors would go, while it is
    /// (the drop zone the window draws).
    var dropZone: Side?
    /// How wide the row of sidebar and editors is, as last laid out, and
    /// whether the sidebar is in it: how much a window has to grow to show
    /// two editors.
    @ObservationIgnored var rowWidth = 0.0
    @ObservationIgnored var sidebarInRow = false
    /// The tabs that have had the keyboard, newest first (Split Editor
    /// shows the one before).
    @ObservationIgnored private(set) var recent: [Int] = []
    /// The tab beside that is being asked about closing (it came forward
    /// for the question): closed, the split ends as for the tab beside.
    @ObservationIgnored var closingFromBeside: Int?
    /// The window's keyboard is being moved from here: what it lands on
    /// is not news (`keyboardMoved`).
    @ObservationIgnored private(set) var movingKeyboard = false

    var isSplit: Bool { beside != nil }

    /// The tab the other side shows.
    var besideTab: DocumentTab? {
        guard case .tab(let id)? = beside else { return nil }
        return tab(id: id)
    }

    /// The editor panels, left to right: one, or two side by side.
    var panels: [Panel] {
        guard let main = selectedTab else { return [] }
        let mainSide: Side = beside == nil ? .left : besideIsLeft ? .right : .left
        let first = Panel(slot: mainSlot, tab: main, preview: false, keyboard: beside != .preview || !keyboardInPreview,
                          side: mainSide)
        let other: Panel
        switch beside {
        case nil:
            return [first]
        case .tab:
            guard let tab = besideTab, tab !== main else { return [first] }
            other = Panel(slot: 1 - mainSlot, tab: tab, preview: false, keyboard: false, side: mainSide.other)
        case .preview:
            other = Panel(slot: 1 - mainSlot, tab: main, preview: true, keyboard: keyboardInPreview, side: mainSide.other)
        }
        return besideIsLeft ? [other, first] : [first, other]
    }

    /// The side the keyboard is on, in a split window.
    var keyboardSide: Side? {
        guard isSplit else { return nil }
        return panels.first { $0.keyboard }?.side
    }

    /// The side that shows `tab`'s text, if it shows.
    func side(of tab: DocumentTab) -> Side? {
        panels.first { $0.tab === tab && !$0.preview }?.side
    }

    /// `tab` shows, on one side or the other (or alone).
    func isShown(_ tab: DocumentTab) -> Bool { panels.contains { $0.tab === tab } }
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
        if let from = tab.window?.tabs, from !== self {
            // A tab that shows leaves its window: that window's split ends.
            if from.isShown(tab) { from.closeSplit() }
            from.remove(tab)
        }
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
        if besideTab === tab {
            // The other side's tab went: the split ends, the keyboard's side stays.
            endSplit()
        } else if closingFromBeside == tab.id, tab.id == selected, let other = besideTab, let side = side(of: other) {
            // It was beside the other until it came forward to be asked about.
            focus(side, force: true)
            endSplit()
        } else if tab.id == selected, list.count > 1 {
            // Its side shows its neighbour, never the tab beside it; with
            // only that one left, it has the window to itself.
            if beside == .preview { endSplit() }
            if let next = SplitLayout.neighbour(of: tab.id, in: list.map(\.id), beside: besideTab?.id).flatMap(self.tab(id:)) {
                select(next)
            } else if let other = besideTab, let side = side(of: other) {
                focus(side, force: true)
                endSplit()
            }
        }
        list.remove(at: index)
        recent.removeAll { $0 == tab.id }
        if closingFromBeside == tab.id { closingFromBeside = nil }
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
    ///
    /// In a split window the tab shows on the keyboard's side; the tab
    /// beside it is not shown twice: the keyboard goes to it instead.
    func select(_ tab: DocumentTab) {
        guard let window, list.contains(where: { $0 === tab }) else { return }
        if tab === besideTab, let side = side(of: tab) {
            focus(side)
            return
        }
        guard tab.id != selected || window.windowController?.document !== tab.document else { refresh(); return }
        if window.attachedSheet != nil, selected != 0, tab.id != selected { return }
        // The preview beside the text was the tab's.
        if beside == .preview, tab.id != selected { endSplit() }
        takeKeyboard(tab, show: true)
    }

    /// `tab` becomes the selected tab: its document takes the window's
    /// controller, and the keyboard goes to it if it was in the tab before.
    /// - Parameter show: its editor goes in the keyboard side's slot now
    ///   (false: it is in a slot already).
    /// - Parameter outgoing: what had the keyboard in the tab before, if
    ///   the window's first responder has already moved on.
    private func takeKeyboard(_ tab: DocumentTab, show: Bool, outgoing: NSResponder? = nil) {
        guard let window else { return }
        let old = list.first { $0.id == selected && $0 !== tab }
        let leaving = outgoing ?? window.firstResponder
        if let old {
            old.lastResponder = leaving
            // The sidebar's keyboard is the window's, not the tab's.
            tab.model.sidebarHasFocus = old.model.sidebarHasFocus
            tab.model.sidebarShowsKeyboard = old.model.sidebarShowsKeyboard
        }
        selected = tab.id
        recent.removeAll { $0 == tab.id }
        recent.insert(tab.id, at: 0)
        if recent.count > 32 { recent.removeLast() }
        DocumentWindow.attachController(of: window, to: tab.document)
        let hadEditor = old.map { o in leaving.map { o.holds($0) } ?? true } ?? false
        if show { window.slot(identity: mainSlot)?.show(tab) }
        // The keyboard goes to the editor of the tab that shows, where it
        // was in that tab, if it was in the editor of the tab before.
        // (Not when it has gone there already: a click in that side's
        // text, its find bar or its palette is where it stays.)
        if outgoing == nil, hadEditor || window.firstResponder === window || window.firstResponder == nil {
            // (Once: a tab whose editor isn't in the window yet leaves the
            // keyboard where the window's first view to take it puts it.)
            giveKeyboard(to: tab, tries: show ? 40 : 0)
        }
        FrontEditor.shared.selectionChanged(in: window)
        refresh()
        window.invalidateRestorableState()
    }

    /// The keyboard goes to `tab`'s editor, where it was in that tab: now,
    /// or once its panel is on screen (a side that has just opened isn't,
    /// for a turn or two).
    private func giveKeyboard(to tab: DocumentTab, preview: Bool = false, tries: Int = 0) {
        guard let window, list.contains(where: { $0 === tab }) else { return }
        let target: NSView? = preview ? tab.markdownPreview?.webView
            : (tab.lastResponder.flatMap { tab.holds($0) ? $0 as? NSView : nil } ?? tab.container.textView)
        if let target, target.window === window {
            movingKeyboard = true
            _ = window.makeFirstResponder(target)
            movingKeyboard = false
        } else if tries < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self, weak tab] in
                guard let self, let tab, tab.id == self.selected else { return }
                self.giveKeyboard(to: tab, preview: preview, tries: tries + 1)
            }
        }
    }

    /// ⌘1 … ⌘9: the tab at `position` (0-based).
    func select(position: Int) {
        guard list.indices.contains(position) else { return }
        select(list[position].id)
    }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }

    /// The next or previous tab, round from the last to the first, on the
    /// keyboard's side: passing over the tab beside it.
    private func step(_ by: Int) {
        guard list.count > 1,
              let next = SplitLayout.step(from: selected, by: by, in: list.map(\.id), beside: besideTab?.id) else { return }
        select(next)
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
        // A tab beside that has gone (by a path none of the above saw).
        if case .tab(let id)? = beside, tab(id: id) == nil || id == selected { endSplit() }
        let besideID = besideTab?.id
        show(list.map { tab in
            Item(id: tab.id, title: tab.document.displayName, path: tab.document.fileURL?.path,
                 dirty: tab.document.isDocumentEdited, preview: tab.preview, beside: tab.id == besideID)
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

/// Where a split was asked for, for the one event it sends (`Telemetry`).
enum SplitSource: String {
    case sidebar, tab, palette, drag, key, menu

    /// A menu item's: the palette's when it runs the command, a key's when
    /// one was pressed for it, the menu's when it was chosen there.
    @MainActor static var ofMenuItem: SplitSource {
        if MenuCommands.performing { return .palette }
        return NSApp.currentEvent?.type == .keyDown ? .key : .menu
    }
}

// MARK: Side by side

extension WindowTabs {
    /// Shows `tab` on `side`, the keyboard with it (Open to the Side, a
    /// tab or a file dropped on that half of the editors). The other side
    /// keeps what it shows; a window that showed one tab shows that one on
    /// the other side. A tab that shows already moves to `side`.
    ///
    /// False, with nothing changed, when it can't be: the tab is the only
    /// one, or the window can't be made wide enough for two editors.
    @discardableResult
    func show(_ tab: DocumentTab, on side: Side, source: SplitSource) -> Bool {
        guard list.contains(where: { $0 === tab }), let current = selectedTab else { return false }
        if beside == .preview { endSplit() }
        let other: DocumentTab?
        if let shown = besideTab {
            if tab === shown { other = current }
            else if tab === current { other = shown }
            else { other = keyboardSide == side ? shown : current }
        } else {
            other = tab === current ? previousTab(of: current) : current
        }
        guard let other, other !== tab else { return false }
        return arrange(keyboard: tab, keyboardSide: side, other: other, source: source)
    }

    /// Open to the Side: `tab` on the side without the keyboard (the right
    /// one in a window that shows one tab), the keyboard with it.
    @discardableResult
    func openToSide(_ tab: DocumentTab, source: SplitSource) -> Bool {
        show(tab, on: keyboardSide?.other ?? .right, source: source)
    }

    /// View ▸ Split Editor (⌘\): the tab that showed before this one, on
    /// the right, the keyboard staying where it is. False with only one
    /// tab (the caller then offers Go to File, to the side).
    @discardableResult
    func splitEditor(source: SplitSource) -> Bool {
        guard !isSplit, let current = selectedTab, let other = previousTab(of: current) else { return false }
        return arrange(keyboard: current, keyboardSide: .left, other: other, source: source)
    }

    /// The tab that had the keyboard before `tab`, or its neighbour.
    private func previousTab(of tab: DocumentTab) -> DocumentTab? {
        SplitLayout.previous(of: tab.id, recent: recent, tabs: list.map(\.id)).flatMap(self.tab(id:))
    }

    /// Two tabs side by side: `keyboard` on `keyboardSide` with the
    /// keyboard, `other` on the other side. A tab that shows already keeps
    /// its slot (its editor stays where it is in the window), so nothing
    /// that doesn't change is put in place again.
    private func arrange(keyboard k: DocumentTab, keyboardSide: Side, other o: DocumentTab, source: SplitSource) -> Bool {
        guard let window, window.attachedSheet == nil || k === selectedTab else { return false }
        let wasSplit = isSplit
        if !wasSplit, !makeRoom() {
            NSSound.beep()
            return false
        }
        let before = panels
        let kSlot = before.first { $0.tab === k && !$0.preview }?.slot
            ?? before.first { $0.tab === o && !$0.preview }.map { 1 - $0.slot } ?? mainSlot
        let outgoing = selectedTab
        if let outgoing, outgoing !== k { closeBars(of: outgoing) }
        keyboardInPreview = false
        beside = .tab(o.id)
        mainSlot = kSlot
        besideIsLeft = keyboardSide == .right
        if k !== outgoing {
            // (Shown already, it is in its slot: else the slot is new, and
            // SwiftUI puts it there.)
            takeKeyboard(k, show: false)
            if !wasSplit || window.firstResponder.map({ o.holds($0) }) == true { giveKeyboard(to: k) }
        } else {
            refresh()
            window.invalidateRestorableState()
        }
        // The other side's editor shows where it was the last time.
        o.arriving = !before.contains { $0.tab === o }
        if !wasSplit { Telemetry.track("split_open", ["source": source.rawValue, "kind": "tabs"]) }
        return true
    }

    /// The keyboard goes to `side`, if it is the other one (a click there,
    /// ⌥⌘← and ⌥⌘→, the tab beside clicked in the strip). Nothing moves:
    /// the tab there becomes the selected one, and the one that was takes
    /// its place beside.
    /// - Parameter outgoing: what had the keyboard, when it has already
    ///   moved there (a click).
    func focus(_ side: Side, outgoing: NSResponder? = nil, force: Bool = false) {
        guard let window, let panel = panels.first(where: { $0.side == side }), !panel.keyboard else { return }
        guard force || window.attachedSheet == nil else { return }
        if beside == .preview {
            keyboardInPreview = panel.preview
            if outgoing == nil { giveKeyboard(to: panel.tab, preview: panel.preview) }
            refresh()
            return
        }
        guard let current = selectedTab, panel.tab !== current else { return }
        closeBars(of: current)
        beside = .tab(current.id)
        mainSlot = panel.slot
        besideIsLeft.toggle()
        takeKeyboard(panel.tab, show: false, outgoing: outgoing)
    }

    /// The window's keyboard moved to `responder` (a click in the other
    /// side's text, its find bar or its preview): that side is the
    /// keyboard's from now on. Anywhere else (the sidebar, the top bar)
    /// changes nothing.
    func keyboardMoved(to responder: NSResponder?, from outgoing: NSResponder?) {
        guard isSplit, !movingKeyboard, let window, let side = window.side(holding: responder), side != keyboardSide else { return }
        focus(side, outgoing: outgoing)
    }

    /// The bars of a side the keyboard leaves: the palette is the
    /// keyboard's and goes (the find bar stays, as it does between tabs).
    private func closeBars(of tab: DocumentTab) {
        if tab.model.palette.isOpen { tab.model.palette.close(focusEditor: false) }
    }

    /// View ▸ Close Split (⌘\ again): the side with the keyboard stays.
    /// (The preview beside the text, with the keyboard in it, stays as the
    /// tab's preview.)
    func closeSplit() {
        guard isSplit else { return }
        let previewStays = beside == .preview && keyboardInPreview
        endSplit()
        if previewStays { selectedTab?.setMarkdownPreview(true) }
    }

    /// The other side goes.
    func endSplit() {
        guard isSplit else { return }
        beside = nil
        keyboardInPreview = false
        dropZone = nil
        refresh()
        window?.invalidateRestorableState()
    }

    /// View ▸ Swap Sides.
    func swapSides() {
        guard isSplit else { return }
        besideIsLeft.toggle()
        window?.invalidateRestorableState()
    }

    /// Window ▸ Move Tab to Other Side: the keyboard's tab goes to the
    /// other side, the keyboard with it.
    @discardableResult
    func moveToOtherSide(source: SplitSource) -> Bool {
        guard let current = selectedTab else { return false }
        return show(current, on: keyboardSide?.other ?? .right, source: source)
    }

    /// View ▸ Preview to the Side (⌥⌃⌘P): the selected tab's text on the
    /// left and its Markdown rendered (or its SVG drawn) on the right,
    /// following the text as it is typed; again, the text alone.
    @discardableResult
    func togglePreviewBeside(source: SplitSource) -> Bool {
        if beside == .preview {
            endSplit()
            return true
        }
        guard let window, let tab = selectedTab, tab.canPreviewMarkdown, window.attachedSheet == nil else { return false }
        let wasSplit = isSplit
        if !wasSplit, !makeRoom() {
            NSSound.beep()
            return false
        }
        // The text on its side, the preview on the other.
        if tab.showsMarkdownPreview { tab.setMarkdownPreview(false) }
        keyboardInPreview = false
        beside = .preview
        besideIsLeft = false
        tab.startPreviewBeside()
        refresh()
        window.invalidateRestorableState()
        if !wasSplit { Telemetry.track("split_open", ["source": source.rawValue, "kind": "preview"]) }
        return true
    }

    /// A tab's context menu in the strip.
    static let openToSideTitle = "Open to the Side"
    func menu(for id: Int) -> [[HoneyTabAction]] {
        guard let tab = tab(id: id) else { return [] }
        let alone = list.count < 2
        return [[HoneyTabAction(Self.openToSideTitle, enabled: !alone) { [weak self] in _ = self?.openToSide(tab, source: .tab) }],
                [HoneyTabAction("Move Tab to New Window", enabled: !alone) { DocumentWindow.moveToNewWindow(tab) }],
                [HoneyTabAction("Close Tab") { [weak self] in self?.close(id) }]]
    }

    /// The window grows to hold two editors side by side, within its
    /// screen. False when the screen can't hold it (or it is full screen
    /// and too narrow).
    func makeRoom() -> Bool {
        guard let window, rowWidth > 0 else { return true }
        let needed = SplitLayout.minimumRow(gap: Honey.gap)
            + (sidebarInRow ? SidebarLayout.widths.lowerBound + Honey.gap : 0)
        let grow = needed - rowWidth
        guard grow > 0.5 else { return true }
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { return false }
        var frame = window.frame
        frame.size.width += ceil(grow)
        guard frame.width <= screen.width else { return false }
        if frame.maxX > screen.maxX { frame.origin.x = screen.maxX - frame.width }
        if frame.minX < screen.minX { frame.origin.x = screen.minX }
        window.setFrame(frame, display: true)
        rowWidth += ceil(grow)
        return true
    }

    /// A window coming back at launch: `tab` beside the selected one, as
    /// it was (`TabRestoration`).
    func restoreBeside(_ tab: DocumentTab, besideIsLeft left: Bool, fraction: Double) {
        guard !isSplit, tab !== selectedTab, list.contains(where: { $0 === tab }) else { return }
        beside = .tab(tab.id)
        mainSlot = 0
        besideIsLeft = left
        splitFraction = fraction
        refresh()
    }

    /// A window coming back with the selected tab's preview beside it.
    func restorePreviewBeside(besideIsLeft left: Bool, fraction: Double) {
        guard !isSplit, let tab = selectedTab, tab.canPreviewMarkdown else { return }
        if tab.showsMarkdownPreview { tab.setMarkdownPreview(false) }
        beside = .preview
        besideIsLeft = left
        splitFraction = fraction
        tab.startPreviewBeside()
        refresh()
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
