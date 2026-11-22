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
    private static let keepsState = !UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState")

    static func controller(for document: KiriDocument) -> NSWindowController {
        let host = NSHostingController(rootView: DocumentRoot(document: document))
        // The content says how small the window may get (`EditorScreen`'s
        // minimum), never how big it is: that is the person's to choose.
        host.sizingOptions = [.minSize]
        let window = DocumentNSWindow(contentViewController: host)
        // Files dropped anywhere on it open (`FileDrop`).
        window.registerForDraggedTypes(FileDrop.types)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultSize)
        window.center()
        // Where the last one was. Not through `setFrameAutosaveName`: only
        // one window at a time can own a name, and the tabs of a group share
        // one frame anyway. `FrameKeeper` saves it instead. (A launch that
        // leaves saved state alone, as the self-tests do, neither reads
        // nor writes it: its windows are always the default size.)
        if keepsState {
            window.setFrameUsingName(frameName)
            FrameKeeper.shared.start()
        }
        let controller = NSWindowController(window: window)
        // A window of its own (`kiri -n`, a folder) steps down and right of
        // the one before it; a tab takes its group's frame.
        controller.shouldCascadeWindows = true
        return controller
    }

    /// Shows `document` in `window`, in place of the document that is
    /// there, which closes. The window, and so its tab, stays: the folder
    /// sidebar's preview tab goes from file to file this way, without a
    /// tab closing and another opening in the strip.
    ///
    /// False, with nothing done, when it can't be: the document there has
    /// unsaved changes (it is never put aside), or `document` has a window.
    @discardableResult
    static func show(_ document: KiriDocument, in window: NSWindow) -> Bool {
        guard let controller = window.windowController, let old = controller.document as? KiriDocument,
              old !== document, !old.isDocumentEdited, document.windowControllers.isEmpty,
              let host = window.contentViewController as? NSHostingController<DocumentRoot> else { return false }
        old.removeWindowController(controller)
        document.addWindowController(controller)
        // The editor at once, not when SwiftUI next updates the window
        // (which may be a tab that isn't showing): it never comes forward
        // with the file before.
        FrontEditor.shared.editor(in: window)?.controller?.show(document)
        host.rootView = DocumentRoot(document: document)
        FrontEditor.shared.documentChanged(to: document, in: window)
        controller.synchronizeWindowTitleWithDocumentName()
        // The tab's title in the same turn as the text, not one later
        // (in this window's strip and in that of the tab that shows).
        for shown in Set([window, window.tabGroup?.selectedWindow ?? window]) {
            FrontEditor.shared.tabs(in: shown)?.refresh()
        }
        window.invalidateRestorableState()
        old.close()
        // No window closed, which is what these two wait for.
        Waits.shared.check()
        NewFiles.shared.check()
        return true
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

/// A document's window. It takes the files and folders dropped on it
/// where no view of its own does: the top bar, the tab strip, the sidebar
/// and the canvas. (The text view takes them itself: `KiriTextView`.)
final class DocumentNSWindow: NSWindow, NSDraggingDestination {
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { FileDrop.operation(sender) }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { FileDrop.operation(sender) }
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !FileDrop.operation(sender).isEmpty }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { FileDrop.perform(sender, in: self) }
}

/// Files and folders dragged from Finder (or anywhere) onto a document
/// window: files open as tabs of that window, after the tab that shows and
/// in the order dropped, as `kiri a b c` opens them in the front one; a
/// folder opens as a folder window of its own, as Open Folder does. The
/// window need not be in front, nor Kiri the active app, and a drop
/// doesn't make it so.
@MainActor enum FileDrop {
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

    static func perform(_ info: any NSDraggingInfo, in window: NSWindow) -> Bool {
        let urls = urls(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        // Once the drag is over: opening shows windows, and may ask.
        DispatchQueue.main.async { open(urls, in: window) }
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
            // Into the tab that shows, if the window dropped on is one of a group.
            requests.insert((KiriCLI.Request(entries: files.map { .file($0, line: 0, column: 0) }),
                             window.tabGroup?.selectedWindow ?? window), at: 0)
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
    let document: KiriDocument

    var body: some View {
        AppearanceRoot { EditorScreen(document: document) }
    }
}
