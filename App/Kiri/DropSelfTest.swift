#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

/// A drag as a drop target is told of it, made by the self-test around a
/// pasteboard of its own: never a real drag, which would need the pointer.
final class TestDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    var draggingSourceOperationMask: NSDragOperation = [.copy, .generic, .link]
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    let draggingSequenceNumber = Int.random(in: 1...1_000_000)
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    /// - Parameter location: in the window's coordinates.
    @MainActor init(_ pasteboard: NSPasteboard, on window: NSWindow, at location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingLocation = location
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

extension SelfTest {
    /// A pasteboard as Finder fills one for a drag of `urls`: the files,
    /// and their paths as text beside them.
    static func pasteboard(files urls: [URL]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects(urls.map { $0 as NSURL })
        board.addTypes([.string], owner: nil)
        board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return board
    }

    /// What takes a drop at `point` (window coordinates): the deepest view
    /// there that asked for one of the pasteboard's types, or else the
    /// window, as AppKit picks it.
    static func dropTarget(in window: NSWindow, at point: NSPoint, for board: NSPasteboard) -> NSDraggingDestination? {
        let types = Set(board.types ?? [])
        var view = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
        while let v = view {
            if !types.isDisjoint(with: v.registeredDraggedTypes) { return v }
            view = v.superview
        }
        return window as? NSDraggingDestination
    }

    /// Drops `board` at `point`, the way AppKit walks a target through it.
    @discardableResult
    static func drop(_ board: NSPasteboard, on window: NSWindow, at point: NSPoint) -> (target: String, taken: Bool) {
        guard let target = dropTarget(in: window, at: point, for: board) else { return ("nothing", false) }
        let drag = TestDrag(board, on: window, at: point)
        let name = "\(type(of: target))"
        guard let entered = target.draggingEntered?(drag), !entered.isEmpty else { return (name, false) }
        _ = target.draggingUpdated?(drag)
        guard target.prepareForDragOperation?(drag) ?? true else {
            target.draggingExited?(drag)
            return (name, false)
        }
        let taken = target.performDragOperation?(drag) ?? false
        target.concludeDragOperation?(drag)
        return (name, taken)
    }

    /// Files, folders and text dropped on a document window: on the text,
    /// on the tab strip and on the sidebar. Files open as tabs of the
    /// window they were dropped on, which need not be the front one, in
    /// the order dropped; a folder opens as a folder window; text goes
    /// into the text. Nothing here needs the app to be active.
    static func dropStage(_ original: NSWindow) async {
        guard let ktv = findTextView(in: original.contentView) as? KiriTextView, let scroll = ktv.enclosingScrollView else {
            report(false, "the editor, for the drop checks"); return
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-drop-test-\(getpid())").standardizedFileURL
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? "\(name)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let clock = ContinuousClock()
        func wait(_ seconds: Double = 4, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return done()
        }
        func window(of url: URL) -> NSWindow? {
            NSDocumentController.shared.documents.first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
                .flatMap { Editors.window(for: $0) }
        }
        func tabs(_ w: NSWindow) -> [String] { documents(in: w).map(\.displayName) }
        func document(of url: URL) -> NSDocument? {
            NSDocumentController.shared.documents.first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
        }
        func close(_ urls: [URL]) async {
            for url in urls { closeTab(of: document(of: url)) }
            _ = await wait { urls.allSatisfy { window(of: $0) == nil } }
        }
        let text = ktv.string, firstName = tabs(original)[0], firstDocument = shownDocument(in: original)
        /// What has been put into the text, if anything.
        func inserted() -> String {
            let now = ktv.string as NSString, was = text as NSString
            guard now.length > was.length else { return now.isEqual(to: text) ? "nothing" : "the text changed" }
            let head = now.commonPrefix(with: text, options: .literal) as NSString
            return "“" + now.substring(with: NSRange(location: head.length, length: now.length - was.length))
                .replacingOccurrences(of: dir.path, with: "<folder>").replacingOccurrences(of: "\n", with: "⏎") + "”"
        }
        // Where things are in the window: the middle of the text, and the
        // top bar's row (the tab strip and the canvas beside it).
        let onText = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let onStrip = NSPoint(x: 200, y: original.frame.height - 26)

        // Another window in front of the first, so the first is not the
        // one a new tab joins by itself.
        let other = file("in-front.txt")
        KiriCLI.open(KiriCLI.Request(newWindow: true, entries: [.file(other, line: 0, column: 0)]))
        guard await wait(until: { window(of: other).map { $0 !== original && $0.isVisible } ?? false }),
              let front = window(of: other) else { report(false, "a second window opens for the drop checks"); return }
        try? await Task.sleep(for: .milliseconds(300))

        // Three files on the text of the window behind.
        let onTextFiles = [file("drop-a.txt"), file("drop-b.md"), file("drop-c.swift")]
        let windowsBefore = Set(NSApp.windows.map { ObjectIdentifier($0) })
        var result = drop(pasteboard(files: onTextFiles), on: original, at: onText)
        var opened = await wait { onTextFiles.allSatisfy { url in window(of: url) === original } }
        try? await Task.sleep(for: .milliseconds(300))
        let made = NSApp.windows.filter { !windowsBefore.contains(ObjectIdentifier($0)) }.count
        report(result.taken && opened && tabs(original) == [firstName] + onTextFiles.map(\.lastPathComponent) && tabs(front) == [other.lastPathComponent]
               && ktv.string == text && made == 0,
               "three files dropped on the text of the window behind open as its tabs, in order, with no window made for them, and nothing goes into the text (taken by \(result.target): \(result.taken); tabs \(tabs(original)); the other window \(tabs(front)); put into the text: \(inserted()); \(made) windows made)")
        if ktv.string != text { ktv.undoManager?.undo() }

        // One on the tab strip: it joins after the tab that shows.
        let onStripFile = [file("drop-d.txt")]
        let showing = original
        result = drop(pasteboard(files: onStripFile), on: showing, at: onStrip)
        opened = await wait { window(of: onStripFile[0]) === original }
        try? await Task.sleep(for: .milliseconds(300))
        report(result.taken && opened && tabs(original).last == "drop-d.txt" && tabs(front) == [other.lastPathComponent],
               "a file dropped on the tab strip opens as a tab of that window (taken by \(result.target): \(result.taken); tabs \(tabs(original)))")

        // A file that is already open comes forward; no second tab.
        let count = tabs(original).count
        result = drop(pasteboard(files: [onTextFiles[0]]), on: showing, at: onStrip)
        let selected = await wait(1.5) { isShowing(document(of: onTextFiles[0])) }
        report(result.taken && selected && tabs(original).count == count,
               "a file that is open already is shown, not opened twice (\(tabs(original).count) tabs)")
        await close(onTextFiles + onStripFile)
        show(firstDocument)

        // A folder: a folder window of its own, as Open Folder gives.
        let folder = dir.appendingPathComponent("project")
        try? "x\n".write(to: folder.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        let before = Set(NSApp.windows.filter { DocumentWindow.isDocumentWindow($0) }.map { ObjectIdentifier($0) })
        result = drop(pasteboard(files: [folder]), on: original, at: onText)
        var folderWindow: NSWindow?
        opened = await wait {
            folderWindow = NSApp.windows.first { DocumentWindow.isDocumentWindow($0) && !before.contains(ObjectIdentifier($0)) && FolderSessions.session(for: $0) != nil }
            return folderWindow != nil
        }
        report(result.taken && opened && folderWindow.flatMap { FolderSessions.session(for: $0) }?.root.url == folder
               && folderWindow !== original && FolderSessions.session(for: original) == nil
               && ktv.string == text,
               "a folder dropped on the text opens as a folder window of its own (taken by \(result.target): \(result.taken); \(folderWindow.flatMap { FolderSessions.session(for: $0) }?.root.url.lastPathComponent ?? "no folder window"); put into the text: \(inserted()))")
        if ktv.string != text { ktv.undoManager?.undo() }

        // On the sidebar of that folder window: a file opens as its tab.
        if let folderWindow {
            let onSidebar = NSPoint(x: 60, y: folderWindow.frame.height / 2)
            let sidebarFile = [file("drop-e.txt")]
            result = drop(pasteboard(files: sidebarFile), on: folderWindow, at: onSidebar)
            opened = await wait { window(of: sidebarFile[0]) === folderWindow }
            try? await Task.sleep(for: .milliseconds(300))
            let inFolderWindow = window(of: sidebarFile[0]).map { FolderSessions.session(for: $0)?.root.url == folder } ?? false
            report(result.taken && opened && inFolderWindow,
                   "a file dropped on the sidebar opens in that folder window (taken by \(result.target): \(result.taken))")
            folderWindow.performClose(nil)
            _ = await wait { !NSApp.windows.contains { $0.isVisible && FolderSessions.session(for: $0)?.root.url == folder } }
        }

        // Text, as dragged from another app: into the text, where dropped.
        let words = NSPasteboard.withUniqueName()
        words.clearContents()
        words.setString("DROPPED WORDS", forType: .string)
        result = drop(words, on: original, at: onText)
        await settle()
        report(result.taken && result.target == "KiriTextView" && ktv.string.contains("DROPPED WORDS")
               && (ktv.string as NSString).length == (text as NSString).length + 13,
               "dragged text still drops into the text (taken by \(result.target): \(result.taken))")
        if ktv.string != text { ktv.undoManager?.undo() }
        await settle()

        // Back to the one window the stages after this one count on.
        front.performClose(nil)
        _ = await wait { window(of: other) == nil }
        original.orderFront(nil)
        FrontEditor.shared.selfTestMain(original)
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        report(ktv.string == text && tabs(original) == [firstName] && !NSApp.isActive,
               "after the drops the first window is as it was, and Kiri was never made the front app")
    }
}
#endif
