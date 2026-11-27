import AppKit
import KiriKit
import SwiftUI

/// A Kiri window and its tabs: the SwiftUI `EditorScreen` in a hosting
/// controller, in a window made here because the documents are AppKit's
/// (`KiriDocument`). It looks as a SwiftUI `.hiddenTitleBar` window does:
/// the content runs under a transparent title bar, with the tall toolbar
/// band (`WindowTabs.useTallTitleBar`).
///
/// A window holds its documents as tabs (`WindowTabs`) and shows one at a
/// time. Its one window controller belongs to the document that shows, so
/// AppKit's title, edited dot, Save and sheets follow the selected tab;
/// the other documents are open without a window controller. Opening a
/// file adds a tab to the front window and never makes a window: only a
/// window of its own does (the first, `kiri -n`, a folder, Move Tab to New
/// Window, a tab dragged out of its strip).
enum DocumentWindow {
    static let defaultSize = NSSize(width: 900, height: 640)
    /// The name the last document window's frame is kept under.
    private static let frameName = "KiriDocumentWindow"
    private static let keepsState = !UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState")
    /// Every document window that is open.
    private static let windows = NSHashTable<DocumentNSWindow>.weakObjects()

    /// A new, empty window (not yet on screen); a tab goes in next.
    static func makeWindow(folder: FolderSession? = nil) -> DocumentNSWindow {
        let window = DocumentNSWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        let host = NSHostingController(rootView: DocumentRoot(tabs: window.tabs))
        // The content says how small the window may get (`EditorScreen`'s
        // minimum), never how big it is: that is the person's to choose.
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        // Kiri's own tabs, never the system's.
        window.tabbingMode = .disallowed
        // Files dropped anywhere on it open (`FileDrop`), and tabs dragged
        // from another window's strip join it (`TabDrag`).
        window.registerForDraggedTypes(FileDrop.types + [TabDrag.type])
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultSize)
        window.center()
        // Where the last one was. Not through `setFrameAutosaveName`: only
        // one window at a time can own a name. `FrameKeeper` saves it
        // instead. (A launch that leaves saved state alone, as the
        // self-tests do, neither reads nor writes it: its windows are
        // always the default size.)
        if keepsState {
            window.setFrameUsingName(frameName)
            FrameKeeper.shared.start()
        }
        if let folder { FolderSessions.set(folder, for: window) }
        WindowTabs.useTallTitleBar(window)
        // The close button asks about every tab, as Close Window does
        // (AppKit's own action would ask only the document that shows).
        if let close = window.standardWindowButton(.closeButton) {
            close.target = window
            close.action = #selector(NSWindow.performClose(_:))
        }
        window.tabs.attach(to: window)
        let controller = NSWindowController(window: window)
        // A new window steps down and right of the one before it.
        controller.shouldCascadeWindows = true
        window.keeper = controller
        windows.add(window)
        return window
    }

    /// Where a document that opens goes (`KiriDocument.makeWindowControllers`):
    /// a tab of the window `WindowPlacement` names, or of the front window,
    /// after the tab that shows; a window of its own when it is asked for
    /// or there is no window.
    static func place(_ document: KiriDocument) {
        guard tab(of: document) == nil else { return }
        let placement = WindowPlacement.take()
        var host: DocumentNSWindow?
        if let placement {
            if let wanted = placement.host, !wanted.closing { host = wanted }
        } else {
            host = front
        }
        if let host {
            let after = placement?.after.flatMap { host.tabs.tab(for: $0) }
            let tab = DocumentTab(document: document, arriving: host.isVisible)
            if let source = placement?.toSide {
                host.tabs.insert(tab, after: after, select: false)
                let side = placement?.side ?? host.tabs.keyboardSide?.other ?? .right
                if !host.tabs.show(tab, on: side, source: source) { host.tabs.select(tab) }
            } else {
                host.tabs.insert(tab, after: after)
            }
        } else {
            let window = makeWindow(folder: placement?.folder)
            window.tabs.insert(DocumentTab(document: document, arriving: false))
        }
    }

    /// The front document window: where a file that opens goes.
    static var front: DocumentNSWindow? {
        NSApp.orderedWindows.lazy.compactMap { $0 as? DocumentNSWindow }.first { $0.isVisible && !$0.closing }
    }

    /// The document windows, front to back.
    static var all: [DocumentNSWindow] {
        let open = windows.allObjects.filter { !$0.closing }
        let ordered = NSApp.orderedWindows.compactMap { $0 as? DocumentNSWindow }.filter { open.contains($0) }
        return ordered + open.filter { !ordered.contains($0) }
    }

    /// The tab that shows `document`, in whichever window.
    static func tab(of document: NSDocument) -> DocumentTab? {
        for window in windows.allObjects { if let tab = window.tabs.tab(for: document) { return tab } }
        return nil
    }

    /// The window `document` is a tab of.
    static func window(of document: NSDocument) -> DocumentNSWindow? { tab(of: document)?.window }

    /// The window's controller goes to `document`, from the one before.
    static func attachController(of window: DocumentNSWindow, to document: KiriDocument) {
        guard let controller = window.keeper else { return }
        if let current = controller.document as? NSDocument, current !== document {
            current.removeWindowController(controller)
        }
        if controller.document == nil { document.addWindowController(controller) }
        controller.synchronizeWindowTitleWithDocumentName()
        window.isDocumentEdited = document.isDocumentEdited
    }

    /// Shows `document` in `tab`, in place of the document that is there,
    /// which closes. The tab stays: the folder sidebar's preview tab goes
    /// from file to file this way, without a tab closing and another
    /// opening in the strip.
    ///
    /// False, with nothing done, when it can't be: the document there has
    /// unsaved changes (it is never put aside), or `document` is in a tab.
    @discardableResult
    static func show(_ document: KiriDocument, in tab: DocumentTab) -> Bool {
        let old = tab.document
        guard old !== document, !old.isDocumentEdited, self.tab(of: document) == nil, let window = tab.window else { return false }
        tab.replaceDocument(with: document)
        if window.tabs.selectedTab === tab {
            attachController(of: window, to: document)
            FrontEditor.shared.selectionChanged(in: window)
        }
        // The tab's title in the same turn as the text, not one later.
        window.tabs.refresh()
        window.invalidateRestorableState()
        // Not in a tab any more: closing it touches no window.
        old.close()
        return true
    }

    /// Whether `window` shows documents.
    static func isDocumentWindow(_ window: NSWindow) -> Bool { window is DocumentNSWindow }

    // MARK: Closing

    /// Closes `tab`'s document, asking first if it has unsaved changes
    /// (in a sheet, with the tab brought forward: `KiriDocument.canClose`).
    static func close(_ tab: DocumentTab, then done: ((Bool) -> Void)? = nil) {
        let document = tab.document
        guard document.isDocumentEdited else {
            document.close()
            done?(true)
            return
        }
        // The tab beside comes forward to be asked about (the question is
        // the window's): closed, it still ends the split, as it would have
        // without the question.
        let tabs = tab.window?.tabs
        if tabs?.besideTab === tab { tabs?.closingFromBeside = tab.id }
        CloseQuestion.ask(document) { shouldClose in
            if shouldClose { document.close() } else if tabs?.closingFromBeside == tab.id { tabs?.closingFromBeside = nil }
            done?(shouldClose)
        }
    }

    /// Closes the window: each tab with unsaved changes asks in turn, and
    /// Cancel on any keeps them all. Then every document closes, and the
    /// window with the last.
    static func closeWindow(_ window: DocumentNSWindow) {
        func ask(_ remaining: [DocumentTab]) {
            guard let tab = remaining.first else {
                for tab in window.tabs.list { tab.document.close() }
                return
            }
            guard tab.document.isDocumentEdited, tab.window === window else { ask(Array(remaining.dropFirst())); return }
            CloseQuestion.ask(tab.document) { shouldClose in
                if shouldClose { ask(Array(remaining.dropFirst())) }
            }
        }
        ask(window.tabs.list)
    }

    /// `document` is about to close: its tab goes, and the window with the
    /// last tab (`KiriDocument.close`).
    static func documentWillClose(_ document: KiriDocument) {
        guard let tab = tab(of: document), let window = tab.window else { return }
        // Where it was, for the next time it opens.
        tab.controller.rememberPosition()
        window.tabs.remove(tab)
    }

    // MARK: Moving tabs

    /// Move Tab to New Window, and a tab dragged out of its strip: a window
    /// of its own (without the folder), with its top left at `topLeft` if
    /// given.
    static func moveToNewWindow(_ tab: DocumentTab, topLeft: NSPoint? = nil) {
        guard let from = tab.window, from.tabs.list.count > 1 else { return }
        let frame = from.frame
        let window = makeWindow()
        window.setFrame(frame, display: false)
        if let topLeft { window.setFrameTopLeftPoint(topLeft) } else { window.cascadeTopLeft(from: NSPoint(x: frame.minX, y: frame.maxY)) }
        window.tabs.insert(tab)
        window.makeKeyAndOrderFront(nil)
    }

    /// Window ▸ Merge All Windows: every tab of every window in `into`,
    /// window after window, and the other windows close.
    static func mergeAll(into window: DocumentNSWindow) {
        let selected = window.tabs.selectedTab
        for other in all where other !== window {
            for tab in other.tabs.list { window.tabs.insert(tab, at: window.tabs.list.count, select: false) }
        }
        if let selected { window.tabs.select(selected) }
    }

    /// Remembers where the document window is, for the next one and the
    /// next launch: saved when one has been moved or resized, and when one
    /// closes.
    private final class FrameKeeper {
        static let shared = FrameKeeper()
        private var started = false

        func start() {
            guard !started else { return }
            started = true
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

/// Asks a document whether it may close (Save, Don't Save, Cancel) and
/// reports the answer.
private final class CloseQuestion: NSObject {
    private static var asking: [CloseQuestion] = []
    private let answer: (Bool) -> Void

    private init(_ answer: @escaping (Bool) -> Void) { self.answer = answer }

    static func ask(_ document: NSDocument, answer: @escaping (Bool) -> Void) {
        let question = CloseQuestion(answer)
        asking.append(question)
        document.canClose(withDelegate: question, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Self.asking.removeAll { $0 === self }
        answer(shouldClose)
    }
}

/// A Kiri window. It holds its tabs, and takes the files and folders
/// dropped on it where no view of its own does: the top bar, the tab
/// strip, the sidebar and the canvas. (The text view takes them itself:
/// `KiriTextView`.)
final class DocumentNSWindow: NSWindow, NSDraggingDestination {
    let tabs = WindowTabs()
    /// The editors' slots (`TabEditorSlot`), by identity: one, or two in a
    /// window split side by side.
    private var slots: [Int: WeakSlot] = [:]
    private struct WeakSlot { weak var slot: TabEditorSlot? }

    /// A slot is on screen in this window.
    func register(_ slot: TabEditorSlot) { slots[slot.identity] = WeakSlot(slot: slot) }

    func slot(identity: Int) -> TabEditorSlot? {
        guard let slot = slots[identity]?.slot, slot.window === self else { return nil }
        return slot
    }

    /// Where the editor of the tab with the keyboard goes.
    var editorSlot: TabEditorSlot? { slot(identity: tabs.mainSlot) }

    /// The slot that shows `tab` (its text or a viewer, not the preview
    /// beside it), if it shows.
    func slot(for tab: DocumentTab) -> TabEditorSlot? {
        tabs.panels.first { $0.tab === tab && !$0.preview }.flatMap { slot(identity: $0.slot) }
    }

    /// The slot that shows `tab`'s preview beside its text.
    func previewSlot(for tab: DocumentTab) -> TabEditorSlot? {
        tabs.panels.first { $0.tab === tab && $0.preview }.flatMap { slot(identity: $0.slot) }
    }

    /// The side of the split whose panel holds `responder` (its text, a
    /// viewer, its find bar or palette), if one does. Told by where it is
    /// in the window: the bars over a panel are SwiftUI's, not the slot's,
    /// and their field editor is the window's.
    func side(holding responder: NSResponder?) -> SplitLayout.Side? {
        guard var view = responder as? NSView, view !== contentView else { return nil }
        if let field = view as? NSTextView, field.isFieldEditor, let owner = field.delegate as? NSView { view = owner }
        guard view.window === self else { return nil }
        // In a slot: that slot's side, wherever it is on screen (a side
        // that is coming in isn't where it will be yet).
        var ancestor: NSView? = view
        while let v = ancestor {
            if let slot = v as? TabEditorSlot {
                return tabs.panels.first { $0.slot == slot.identity }?.side
            }
            ancestor = v.superview
        }
        let rect = view.convert(view.bounds, to: nil)
        guard rect.width > 0, rect.height > 0 else { return nil }
        for panel in tabs.panels {
            guard let slot = slot(identity: panel.slot) else { continue }
            let frame = slot.convert(slot.bounds, to: nil).insetBy(dx: -1, dy: -1)
            if frame.contains(rect) { return panel.side }
        }
        return nil
    }

    /// A click (or anything) that gives the keyboard to the other side of
    /// a split window makes that side the keyboard's (`WindowTabs.focus`).
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let before = firstResponder
        guard super.makeFirstResponder(responder) else { return false }
        if tabs.isSplit, firstResponder !== before {
            tabs.keyboardMoved(to: firstResponder, from: before)
        }
        return true
    }
    /// The window's controller, kept while the window is open: it moves
    /// from document to document, and none of them keeps it while it moves.
    var keeper: NSWindowController?
    /// The window is on its way out: nothing new goes into it.
    private(set) var closing = false

    /// The window's close button, Close Window (⇧⌘W) and Close All: every
    /// tab, asking about each with unsaved changes (`closeWindow`).
    override func performClose(_ sender: Any?) {
        guard !closing else { return }
        if tabs.list.isEmpty { closeEmpty(); return }
        DocumentWindow.closeWindow(self)
    }

    /// File ▸ Close (⌘W): the tab that shows.
    @objc func performCloseTab(_ sender: Any?) {
        guard let tab = tabs.selectedTab else { performClose(sender); return }
        tabs.close(tab.id)
    }

    /// Window ▸ Move Tab to New Window.
    @objc func moveTabToNewKiriWindow(_ sender: Any?) {
        if let tab = tabs.selectedTab { DocumentWindow.moveToNewWindow(tab) }
    }

    /// Window ▸ Merge All Windows.
    @objc func mergeAllKiriWindows(_ sender: Any?) {
        DocumentWindow.mergeAll(into: self)
    }

    /// The last tab has gone: the window closes, with no document of its own.
    func closeEmpty() {
        guard !closing else { return }
        closing = true
        if let controller = keeper, let document = controller.document as? NSDocument {
            document.removeWindowController(controller)
        }
        tabs.invalidate()
        close()
        keeper = nil
    }

    // MARK: Dropping

    // Over the editors, a tab or a file goes to the side it is over
    // (`SplitLayout.drop`), and that side shows the drop zone while it is.
    // (The editor's own views hand their drags to these: `KiriTextView`,
    // the viewers, the preview.)

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { track(sender) }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { track(sender) }
    func draggingExited(_ sender: (any NSDraggingInfo)?) { showDropZone(nil) }
    func draggingEnded(_ sender: any NSDraggingInfo) { showDropZone(nil) }
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !operation(sender, side: dropSide(sender)).isEmpty }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let side = dropSide(sender)
        showDropZone(nil)
        if TabDrag.isTabDrag(sender) { return TabDrag.perform(sender, in: self, side: side) }
        return FileDrop.perform(sender, in: self, side: side)
    }

    private func track(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let side = dropSide(sender)
        let operation = operation(sender, side: side)
        showDropZone(operation.isEmpty ? nil : side)
        return operation
    }

    private func operation(_ sender: any NSDraggingInfo, side: SplitLayout.Side?) -> NSDragOperation {
        TabDrag.isTabDrag(sender) ? TabDrag.operation(sender, in: self, side: side) : FileDrop.operation(sender)
    }

    private func showDropZone(_ side: SplitLayout.Side?) {
        if tabs.dropZone != side { tabs.dropZone = side }
    }

    /// The side a drag over the editors would go to: nil outside them, and
    /// in the middle third for files (they open as tabs there).
    func dropSide(_ sender: any NSDraggingInfo) -> SplitLayout.Side? {
        let frames = tabs.panels.compactMap { panel in slot(identity: panel.slot).map { (panel, $0.convert($0.bounds, to: nil)) } }
        guard let first = frames.first?.1 else { return nil }
        let row = frames.dropFirst().reduce(first) { $0.union($1.1) }
        let point = sender.draggingLocation
        guard row.contains(point) else { return nil }
        let divider = frames.count > 1 ? frames.map(\.1).min { $0.minX < $1.minX }.map { $0.maxX + Honey.gap / 2 - row.minX } : nil
        guard case .side(let side)? = SplitLayout.drop(at: point.x - row.minX, width: row.width, divider: divider.map(Double.init),
                                                       files: !TabDrag.isTabDrag(sender)) else { return nil }
        return side
    }

    // MARK: Restoring

    /// The window's tabs, in order, for the next launch: AppKit restores
    /// the window with the document that shows; the others come back from
    /// this list (`restoreState`), with their unsaved changes.
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(TabRestoration.records(of: tabs) as NSArray, forKey: TabRestoration.key)
        if let split = TabRestoration.split(of: tabs) { coder.encode(split as NSDictionary, forKey: TabRestoration.splitKey) }
        if let root = FolderSessions.session(for: self)?.root.url { coder.encode(root as NSURL, forKey: TabRestoration.folderKey) }
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        let records = coder.decodeObject(of: [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self, NSData.self],
                                         forKey: TabRestoration.key) as? [[String: Any]]
        let folder = coder.decodeObject(of: NSURL.self, forKey: TabRestoration.folderKey) as URL?
        let split = coder.decodeObject(of: [NSDictionary.self, NSString.self, NSNumber.self], forKey: TabRestoration.splitKey)
            as? [String: Any]
        if let folder, FolderSessions.session(for: self) == nil { FolderSessions.set(FolderSession(root: folder), for: self) }
        if let records { TabRestoration.restore(records, in: self, split: split) }
    }
}

/// What a window keeps of its tabs for the next launch, and how they come
/// back. Each tab is its file (as a bookmark, which finds it after a move)
/// and its recovery copy, if it has unsaved changes; an untitled document
/// with nothing kept for it is not.
enum TabRestoration {
    static let key = "KiriTabs"
    static let folderKey = "KiriFolder"
    /// A split window's edge and sides: `fraction`, `besideIsLeft`, and
    /// `preview` for the selected tab's preview beside its text. (The tab
    /// beside is the record with `beside`.)
    static let splitKey = "KiriSplit"

    static func split(of tabs: WindowTabs) -> [String: Any]? {
        guard let beside = tabs.beside else { return nil }
        return ["fraction": tabs.splitFraction, "besideIsLeft": tabs.besideIsLeft, "preview": beside == .preview]
    }

    static func records(of tabs: WindowTabs) -> [[String: Any]] {
        let beside = tabs.besideTab
        return tabs.list.compactMap { tab in
            let document = tab.document
            let selected = tab === tabs.selectedTab
            var record: [String: Any] = ["selected": selected, "preview": tab.preview]
            if tab === beside { record["beside"] = true }
            if let url = document.fileURL {
                record["file"] = (try? url.bookmarkData()) ?? Data()
                record["path"] = url.path
            }
            if let copy = document.autosavedContentsFileURL {
                record["copy"] = copy.path
            } else if document.fileURL == nil, !selected {
                return nil
            }
            return record
        }
    }

    /// Opens the tabs `records` lists around the one AppKit restored into
    /// `window`, in their order; a split window shows its two sides again
    /// once the tab beside is back (and one side if it never comes).
    static func restore(_ records: [[String: Any]], in window: DocumentNSWindow, split: [String: Any]? = nil) {
        guard let shown = records.firstIndex(where: { $0["selected"] as? Bool == true }) else { return }
        window.tabs.selectedTab?.restoreIndex = shown
        let fraction = split?["fraction"] as? Double ?? SplitLayout.defaultFraction
        let besideIsLeft = split?["besideIsLeft"] as? Bool ?? false
        if split?["preview"] as? Bool == true {
            // Once the tab knows its language.
            DispatchQueue.main.async { window.tabs.restorePreviewBeside(besideIsLeft: besideIsLeft, fraction: fraction) }
        }
        for (index, record) in records.enumerated() where index != shown {
            var stale = false
            let file = (record["file"] as? Data).flatMap { try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale) }
                ?? (record["path"] as? String).map { URL(fileURLWithPath: $0) }
            let copy = (record["copy"] as? String).map { URL(fileURLWithPath: $0) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            guard let contents = copy ?? file, FileManager.default.fileExists(atPath: contents.path) else { continue }
            let preview = record["preview"] as? Bool ?? false
            /// It goes after the tabs that are back from before it in the list.
            func put(_ document: KiriDocument) {
                guard !window.closing else { return }
                let tab = DocumentWindow.tab(of: document) ?? DocumentTab(document: document, arriving: false)
                tab.restoreIndex = index
                let position = window.tabs.list.filter { $0 !== tab && ($0.restoreIndex ?? shown) < index }.count
                window.tabs.insert(tab, at: position, select: false)
                if preview { PreviewTabs.mark(tab) }
                if split != nil, record["beside"] as? Bool == true {
                    window.tabs.restoreBeside(tab, besideIsLeft: besideIsLeft, fraction: fraction)
                }
            }
            if let file, let open = NSDocumentController.shared.document(for: file) as? KiriDocument {
                put(open)
                continue
            }
            if let copy, let open = NSDocumentController.shared.documents.first(where: { $0.autosavedContentsFileURL == copy }) as? KiriDocument {
                put(open)
                continue
            }
            NSDocumentController.shared.reopenDocument(for: file, withContentsOf: contents, display: false) { document, _, _ in
                MainActor.assumeIsolated {
                    guard let document = document as? KiriDocument else { return }
                    put(document)
                }
            }
        }
    }
}

/// Files and folders dragged from Finder (or anywhere) onto a document
/// window: files open as tabs of that window, after the tab that shows and
/// in the order dropped, as `kiri a b c` opens them in the front one; a
/// folder opens as a folder window of its own, as Open Folder does. The
/// window need not be in front, nor Kiri the active app, and a drop
/// doesn't make it so.
enum FileDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL]

    /// The files and folders a drag carries.
    static func urls(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.standardizedFileURL)
    }

    /// What dropping would do: a copy (the pointer shows the green plus)
    /// when the drag carries files, nothing otherwise.
    static func operation(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard !urls(info.draggingPasteboard).isEmpty else { return [] }
        let offered = info.draggingSourceOperationMask
        return offered.contains(.copy) ? .copy : offered.contains(.generic) ? .generic : []
    }

    /// - Parameter side: let go over that side of the editors (`SplitLayout.drop`):
    ///   the first file shows there, the keyboard with it (the rest open
    ///   as tabs).
    static func perform(_ info: any NSDraggingInfo, in window: NSWindow, side: SplitLayout.Side? = nil) -> Bool {
        let urls = urls(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        // Once the drag is over: opening shows windows, and may ask.
        DispatchQueue.main.async {
            var isDirectory: ObjCBool = false
            if let side, let first = urls.first(where: { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                                                         && !isDirectory.boolValue }) {
                SidebarOpen.open(first, keep: true, from: window, keyboard: .editor, toSide: .drag, side: side)
                let rest = urls.filter { $0 != first }
                if !rest.isEmpty { open(rest, in: window) }
            } else {
                open(urls, in: window)
            }
        }
        return true
    }

    /// Opens `urls` as dropped on `window`: the files as its tabs, then
    /// each folder in a window of its own.
    static func open(_ urls: [URL], in window: NSWindow) {
        var isDirectory: ObjCBool = false
        let folders = urls.filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue }
        let files = urls.filter { !folders.contains($0) }
        var requests = folders.map { (KiriCLI.Request(entries: [.folder($0)]), nil as NSWindow?) }
        if !files.isEmpty {
            requests.insert((KiriCLI.Request(entries: files.map { .file($0, line: 0, column: 0) }), window), at: 0)
        }
        // One after another: each takes its windows' places in turn.
        func next() {
            guard !requests.isEmpty else { return }
            let (request, target) = requests.removeFirst()
            KiriCLI.open(request, in: target, then: next)
        }
        next()
    }
}

/// What a document window hosts: the editor screen, in the appearance
/// chosen in Settings (or being previewed).
private struct DocumentRoot: View {
    let tabs: WindowTabs

    var body: some View {
        AppearanceRoot { EditorScreen(tabs: tabs) }
    }
}
