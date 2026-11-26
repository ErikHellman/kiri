import AppKit
import KiriKit
import SwiftUI

/// A name being typed in place in the folder sidebar.
enum SidebarEdit: Equatable {
    /// Rename…: the file's row has a field in place of its name.
    case rename(URL)
    /// New File…: a row with an empty field at the top of the folder.
    case newFile(in: URL)
}

/// One item of a context menu in the folder sidebar.
@MainActor struct SidebarMenuItem: Identifiable {
    let title: String
    var enabled = true
    let action: () -> Void

    nonisolated var id: String { title }
}

/// The context menus of the folder sidebar, as values: the menu draws
/// them (`SidebarMenuItems`) and the self-test reads them.
@MainActor enum SidebarMenu {
    enum Target: Equatable {
        case file(URL)
        case folder(URL)
        /// The empty area and the header: the folder the window shows.
        case root
    }

    static let openToSide = WindowTabs.openToSideTitle
    static let openInNewWindow = "Open in New Window"
    static let reveal = "Reveal in Finder"
    static let copyPath = "Copy Path"
    static let copyRelativePath = "Copy Relative Path"
    static let newFile = "New File…"
    static let rename = "Rename…"

    /// The items for `target`, in groups (a divider between two).
    /// - Parameter window: the tab whose sidebar the menu is in: where a
    ///   name is then typed.
    static func groups(for target: Target, session: FolderSession, window: NSWindow?) -> [[SidebarMenuItem]] {
        let root = session.root.url
        func writable(_ folder: URL) -> Bool { FileManager.default.isWritableFile(atPath: folder.path) }
        func finder(_ url: URL, relative: Bool = true) -> [SidebarMenuItem] {
            var items = [SidebarMenuItem(title: reveal) { SidebarFiles.reveal(url) },
                         SidebarMenuItem(title: copyPath) { SidebarFiles.copy(url.path) }]
            if relative {
                items.append(SidebarMenuItem(title: copyRelativePath) { SidebarFiles.copy(SidebarFiles.relativePath(of: url, in: root)) })
            }
            return items
        }
        switch target {
        case .file(let url):
            return [[SidebarMenuItem(title: openToSide, enabled: window != nil) {
                        if let window { SidebarOpen.open(url, keep: true, from: window, keyboard: .editor, toSide: .sidebar) }
                     },
                     SidebarMenuItem(title: openInNewWindow) { SidebarFiles.openInNewWindow(url, isDirectory: false) }],
                    finder(url),
                    // A name is the folder's to change.
                    [SidebarMenuItem(title: rename, enabled: writable(url.deletingLastPathComponent())) { session.beginRename(url, in: window) }]]
        case .folder(let url):
            return [[SidebarMenuItem(title: newFile, enabled: writable(url)) { session.beginNewFile(in: url, in: window) }],
                    [SidebarMenuItem(title: openInNewWindow) { SidebarFiles.openInNewWindow(url, isDirectory: true) }],
                    finder(url)]
        case .root:
            return [[SidebarMenuItem(title: newFile, enabled: writable(root)) { session.beginNewFile(in: root, in: window) }],
                    finder(root, relative: false)]
        }
    }
}

/// A context menu's items, drawn.
struct SidebarMenuItems: View {
    let groups: [[SidebarMenuItem]]

    var body: some View {
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index]) { item in
                Button(item.title, action: item.action).disabled(!item.enabled)
            }
        }
    }
}

/// What the sidebar's menus do to files.
@MainActor enum SidebarFiles {
    /// Where Copy Path puts the path: the clipboard. A test launch has a
    /// pasteboard of its own instead, so no test can write over what the
    /// person has copied.
    static var pasteboard: NSPasteboard = {
        #if DEBUG || KIRI_SELFTEST
        if SelfTest.isTestLaunch { return NSPasteboard.withUniqueName() }
        #endif
        return .general
    }()

    #if DEBUG || KIRI_SELFTEST
    /// What a test launch would have shown in Finder (it never does).
    private(set) static var revealed: [URL] = []
    #endif

    static func copy(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Shows the file or folder selected in a Finder window.
    static func reveal(_ url: URL) {
        #if DEBUG || KIRI_SELFTEST
        // Finder would come forward, over what the person is doing.
        if SelfTest.isTestLaunch { revealed.append(url); return }
        #endif
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// `url` as written from `root`: "Sources/Tidepool/Greeter.swift".
    static func relativePath(of url: URL, in root: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return path == base ? "." : path }
        return String(path.dropFirst(base.count + 1))
    }

    /// A file in a window of its own, without the sidebar, as `kiri -n`
    /// opens it (a tab that shows it already moves out to one); a folder
    /// in a folder window of its own.
    static func openInNewWindow(_ url: URL, isDirectory: Bool) {
        if isDirectory {
            KiriCLI.open(KiriCLI.Request(entries: [.folder(url)]))
        } else if let open = NSDocumentController.shared.document(for: url), let tab = DocumentWindow.tab(of: open),
                  let window = tab.window {
            PreviewTabs.keep(tab)
            if window.tabs.list.count > 1 {
                DocumentWindow.moveToNewWindow(tab)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            KiriCLI.open(KiriCLI.Request(newWindow: true, entries: [.file(url, line: 0, column: 0)]))
        }
    }

    // MARK: Names

    /// What is wrong with `name` for a file in `folder`, in words, or nil.
    /// - Parameter old: the file being renamed, which may keep its own
    ///   name in other capitals.
    static func problem(with name: String, in folder: URL, renaming old: URL? = nil) -> String? {
        if name.isEmpty { return "A file needs a name." }
        if name == "." || name == ".." || name.contains("/") || name.contains(":") {
            return "A name can't be “.” or “..”, or have / or : in it."
        }
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            // The same file, as a file system that ignores capitals sees it.
            let same = old.flatMap { identifier($0) }.flatMap { a in identifier(url).map { a.isEqual($0) } } ?? false
            if !same { return "“\(name)” is already in this folder." }
        }
        return nil
    }

    private static func identifier(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    /// Makes an empty file. Never writes over one that is there.
    static func create(named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name).standardizedFileURL
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Gives the file another name in its folder. A document that has it
    /// open moves it itself (`NSDocument.move`), so its tab follows and
    /// its unsaved changes stay unsaved; otherwise the file is moved, and
    /// never onto another.
    static func rename(_ url: URL, to name: String, then done: @escaping (Result<URL, Error>) -> Void) {
        let target = url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        if let document = NSDocumentController.shared.document(for: url) {
            document.move(to: target) { error in
                DispatchQueue.main.async { done(error.map { .failure($0) } ?? .success(target)) }
            }
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            done(.success(target))
        } catch {
            done(.failure(error))
        }
    }
}
