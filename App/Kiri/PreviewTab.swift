import AppKit
import KiriKit

/// Which tabs are previews. A file clicked once in the folder sidebar
/// shows in the window's preview tab (its title slanted), and the next
/// file clicked takes that tab over, so looking through a folder leaves
/// one tab and not one for each file. A preview becomes a tab like any
/// other when it is kept: by an edit, a save, a double-click on its row
/// or its tab, or Return on its row.
///
/// A preview never has unsaved changes: the first edit keeps it.
@MainActor enum PreviewTabs {
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    /// Posted when a tab becomes a preview or stops being one, so the tab
    /// strips show it in the same turn.
    static let didChange = Notification.Name("KiriPreviewTabsDidChange")

    static func isPreview(_ window: NSWindow) -> Bool { windows.contains(window) }

    static func mark(_ window: NSWindow) {
        guard !windows.contains(window) else { return }
        windows.add(window)
        NotificationCenter.default.post(name: didChange, object: window)
    }

    /// The preview stays: it is a tab like any other from here on.
    static func keep(_ window: NSWindow?) {
        guard let window, windows.contains(window) else { return }
        windows.remove(window)
        NotificationCenter.default.post(name: didChange, object: window)
    }

    static func keep(_ document: NSDocument) {
        for controller in document.windowControllers { keep(controller.window) }
    }

    /// The preview among the tabs `window` is one of, if there is one.
    static func preview(among window: NSWindow) -> NSWindow? {
        (window.tabbedWindows ?? [window]).first { isPreview($0) }
    }
}

/// Opening a file from the folder sidebar.
@MainActor enum SidebarOpen {
    /// Where the keyboard is afterwards.
    enum Keyboard {
        /// Where it was (a click).
        case stays
        /// In the sidebar, also when the file shows in another tab (Space).
        case sidebar
        /// In the file's editor (Return).
        case editor
    }

    /// The latest request, and its file: a file that finishes opening
    /// after another was asked for is not shown.
    private static var request = 0
    private static var requested: URL?

    /// Shows `url` among the tabs of `window`, the tab whose sidebar it
    /// was picked in.
    ///
    /// A file that is open already is selected. Otherwise it takes the
    /// place of the document in the window's preview tab, or of an empty
    /// untitled document (what a folder window starts with), in that same
    /// tab: the tab strip keeps its tabs and only a title changes. With
    /// neither, it opens as a new tab after this one. Unless `keep`, the
    /// tab it shows in is the preview from then on.
    ///
    /// - Parameter done: called with the window the file shows in, or nil
    ///   when it could not be opened or another file was asked for first.
    static func open(_ url: URL, keep: Bool, from window: NSWindow, keyboard: Keyboard = .stays,
                     then done: ((NSWindow?) -> Void)? = nil) {
        let url = url.standardizedFileURL
        request += 1
        requested = url
        let mine = request
        /// The keyboard goes where it was asked to, once `shown` has its
        /// screen (a tab that was just made has not, for a moment).
        func place(in shown: NSWindow, tries: Int = 0) {
            guard keyboard != .stays else { return }
            guard let editor = FrontEditor.shared.editor(in: shown) else {
                if tries < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { place(in: shown, tries: tries + 1) } }
                return
            }
            switch keyboard {
            case .stays: break
            // Each tab is a window with a sidebar of its own.
            case .sidebar: if shown !== window { editor.sidebarFocusRequest += 1 }
            case .editor: editor.controller?.focus()
            }
        }
        /// `shown` is a tab that was there already: it comes forward.
        func finish(_ shown: NSWindow) {
            if keep { PreviewTabs.keep(shown) }
            if shown.tabGroup?.selectedWindow !== shown { shown.tabGroup?.selectedWindow = shown }
            shown.makeKeyAndOrderFront(nil)
            place(in: shown)
            done?(shown)
        }
        if let open = NSDocumentController.shared.document(for: url), let shown = Editors.window(for: open) {
            finish(shown)
            return
        }
        // Without a window: where it shows is decided once it is read.
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, alreadyOpen, error in
            MainActor.assumeIsolated {
                if let error {
                    _ = NSApp.presentError(error)
                    done?(nil)
                    return
                }
                guard let document = document as? KiriDocument else { done?(nil); return }
                if let shown = Editors.window(for: document) {
                    finish(shown)
                    return
                }
                guard mine == request else {
                    // Another file was asked for in the meantime. A document
                    // without a window would stay open unseen. (The same
                    // file asked for again, the second click of a
                    // double-click, is this document: that request shows it.)
                    if !alreadyOpen, requested != url { document.close() }
                    done?(nil)
                    return
                }
                if !NSDocumentController.shared.documents.contains(document) {
                    NSDocumentController.shared.addDocument(document)
                }
                if let tab = reusableTab(for: window) {
                    // Said first, so the strip shows the new title and
                    // whether it slants in one step.
                    let was = PreviewTabs.isPreview(tab)
                    if keep { PreviewTabs.keep(tab) } else { PreviewTabs.mark(tab) }
                    if DocumentWindow.show(document, in: tab) {
                        finish(tab)
                        return
                    }
                    if was { PreviewTabs.mark(tab) } else { PreviewTabs.keep(tab) }
                }
                // A tab of its own, after the one it was picked in
                // (`WindowTabs.attach` puts it there and brings it forward).
                let inGroup = window.isVisible || window.tabGroup?.selectedWindow?.isVisible == true
                if inGroup { WindowPlacement.next = .init(host: window, after: window) }
                document.makeWindowControllers()
                guard let shown = Editors.window(for: document) else {
                    WindowPlacement.next = nil
                    document.close()
                    done?(nil)
                    return
                }
                if !keep { PreviewTabs.mark(shown) }
                document.showWindows()
                forgetPlacement()
                place(in: shown)
                done?(shown)
            }
        }
    }

    /// A placement nothing took (the window never came up) must not be
    /// left for some later window.
    private static func forgetPlacement(tries: Int = 0) {
        guard WindowPlacement.next != nil else { return }
        if tries < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { forgetPlacement(tries: tries + 1) }
        } else {
            WindowPlacement.next = nil
        }
    }

    /// The tab a file from the sidebar may take over: the preview among
    /// `window`'s tabs, or `window` itself while it holds nothing (an
    /// untitled document that is empty and unedited).
    private static func reusableTab(for window: NSWindow) -> NSWindow? {
        if let preview = PreviewTabs.preview(among: window) {
            // Never a tab with unsaved changes: that one is kept instead.
            if NSDocumentController.shared.document(for: preview)?.isDocumentEdited == true {
                PreviewTabs.keep(preview)
            } else {
                return preview
            }
        }
        if let document = NSDocumentController.shared.document(for: window) as? KiriDocument,
           document.fileURL == nil, !document.isDocumentEdited, document.text.isEmpty {
            return window
        }
        return nil
    }
}
