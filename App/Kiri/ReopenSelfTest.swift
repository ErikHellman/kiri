#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

/// `-KiriReopenTest YES` (and part of `-KiriBehaviorTest`): what a plain
/// launch reopens (`LastOpened`) and the recent folders. A folder window
/// is noted as its folder and the file in front, an untitled tab leaves
/// what was noted; what is kept is read back as it was written; what is
/// gone is left out; reopening opens the folder's window with the file;
/// a recent folder opens as a folder window from Open Recent (which lists
/// five, folders with their symbol) and from the command palette. The
/// launch's own kept item lives among its arguments, never the person's.
extension SelfTest {
    static func reopenStage(_ window: NSWindow) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-reopen-test-\(getpid())")
            .resolvingSymlinksInPath()
        try? FileManager.default.removeItem(at: dir)
        let folder = dir.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = folder.appendingPathComponent("notes.md")
        try? Data("# Notes\n".utf8).write(to: file)
        let preferences = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let before = Set(DocumentWindow.all.map { ObjectIdentifier($0) })
        func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        /// The folder window that opened for `root`, once its tab is in.
        func folderWindow(_ root: URL) async -> DocumentNSWindow? {
            var found: DocumentNSWindow?
            _ = await wait {
                found = DocumentWindow.all.first { w in
                    !before.contains(ObjectIdentifier(w)) && FolderSessions.session(for: w)?.root.url.path == root.path
                        && w.tabs.selectedTab != nil
                }
                return found != nil
            }
            return found
        }
        func close(_ w: DocumentNSWindow?) async {
            guard let w else { return }
            for doc in documents(in: w) { closeTab(of: doc) }
            _ = await wait { w.closing || !DocumentWindow.all.contains(w) }
        }
        LastOpened.forget()

        // Kept as paths, and read back so; never a relative path.
        let item = LastOpened.Item(folder: folder, file: file)
        report(LastOpened.Item(plist: item.plist) == item && LastOpened.Item(plist: ["file": "notes.md"]) == nil
               && LastOpened.Item(plist: [:]) == nil, "the last file or folder is kept as its paths and read back as it was (\(item.plist))")

        // What is gone is left out, off the main thread.
        let gone = dir.appendingPathComponent("gone", isDirectory: true)
        let onlyFile = await LastOpened.existing(LastOpened.Item(folder: gone, file: file))
        let none = await LastOpened.existing(LastOpened.Item(folder: gone, file: gone.appendingPathComponent("x.txt")))
        let swapped = await LastOpened.existing(LastOpened.Item(folder: file, file: folder))
        report(onlyFile == LastOpened.Item(file: file) && none == nil && swapped == nil,
               "a folder or file that is gone is left out, and nothing is reopened when all of it is gone (\(String(describing: onlyFile)), \(String(describing: none)), \(String(describing: swapped)))")

        // Reopening: the folder's window, with the file in front.
        LastOpened.open(item)
        let reopened = await folderWindow(folder)
        let shown = (reopened?.tabs.selectedTab?.document.fileURL).map { $0.standardizedFileURL.path }
        report(reopened != nil && shown == file.standardizedFileURL.path,
               "reopening opens the folder in a window of its own with the file in front (\(shown ?? "no file"))")
        let controller = NSDocumentController.shared as? KiriDocumentController
        report(controller?.selfTestNoted.contains { $0.path == folder.path && $0.hasDirectoryPath } == true,
               "a folder that opens in a window is a recent item (noted as a folder)")

        // Noted as it comes forward: the folder and the file; an untitled
        // tab in front leaves the file noted; a window without a folder or
        // a file is nothing to note.
        if let reopened {
            LastOpened.note(reopened)
            let noted = LastOpened.current
            report(noted == item, "a folder window is noted as its folder and the file in front (\(String(describing: noted)))")
            KiriCLI.open(KiriCLI.Request(entries: [.untitled]), in: reopened)
            let untitled = await wait { reopened.tabs.list.count == 2 && reopened.tabs.selectedTab?.document.fileURL == nil }
            LastOpened.note(reopened)
            report(untitled && LastOpened.current == item,
                   "an untitled tab in front leaves the file noted (\(String(describing: LastOpened.current)))")
        }
        if let plain = window as? DocumentNSWindow, FolderSessions.session(for: plain) == nil, plain.tabs.selectedTab?.document.fileURL == nil {
            LastOpened.note(plain)
            report(LastOpened.current == item, "a window with only an untitled document changes nothing")
        }
        await close(reopened)

        // A folder alone.
        LastOpened.open(LastOpened.Item(folder: folder))
        let alone = await folderWindow(folder)
        report(alone != nil && alone?.tabs.selectedTab?.document.fileURL == nil, "a folder kept alone reopens as its folder window")
        await close(alone)

        // Off in Settings, or nothing kept: the empty document instead.
        var otherwise = 0
        setArgument(LastOpened.key, plist: nil)
        LastOpened.reopen { otherwise += 1 }
        setArgument(LastOpened.key, plist: item.plist)
        setArgument(Prefs.reopenAtLaunchKey, plist: false)
        LastOpened.reopen { otherwise += 1 }
        setArgument(Prefs.reopenAtLaunchKey, plist: nil)
        report(otherwise == 2 && LastOpened.saved == item,
               "with nothing kept, or Reopen at launch off, a plain launch opens the empty document (\(otherwise) of 2)")
        setArgument(LastOpened.key, plist: nil)

        // Recent folders: Open Recent lists five, a folder with its
        // symbol, and choosing it opens its folder window.
        let others = (1...5).map { i -> URL in
            let url = dir.appendingPathComponent("other\(i).txt")
            try? Data("\(i)\n".utf8).write(to: url)
            return url
        }
        let folderItem = URL(fileURLWithPath: folder.path, isDirectory: true)
        RecentDocuments.shared.selfTestShow([folderItem] + others)
        defer { RecentDocuments.shared.refresh() }
        if let main = NSApp.mainMenu, let menu = main.item(withTitle: "File")?.submenu?.item(withTitle: "Open Recent")?.submenu {
            await settle(250)
            updateMenu(main)
            let listed = menu.items.filter { !$0.isSeparatorItem && $0.title != "Clear Menu" }
            report(listed.map(\.title) == ["project", "other1.txt", "other2.txt", "other3.txt", "other4.txt"]
                   && listed.allSatisfy { $0.image != nil },
                   "File ▸ Open Recent lists the last five files and folders, each with its symbol (\(listed.map(\.title)))")
            if let i = menu.items.firstIndex(where: { $0.title == "project" }) { menu.performActionForItem(at: i) }
            let chosen = await folderWindow(folder)
            report(chosen != nil, "choosing a recent folder opens it in a folder window")
            await close(chosen)
        } else {
            report(false, "File ▸ Open Recent exists")
        }

        // The command palette lists it as a folder, and opens it so.
        if let model = (window as? DocumentNSWindow)?.tabs.selectedTab?.model {
            let palette = model.palette
            palette.open()
            _ = await wait { palette.isOpen }
            let row = palette.rows.first { if case .folder = $0.action { true } else { false } }
            report(row?.title == "project" && row?.symbol == "folder" && row?.spoken.contains("folder") == true,
                   "the command palette lists a recent folder with the folder symbol (\(row.map { $0.spoken } ?? "none"))")
            if let row {
                palette.run(row)
                let fromPalette = await folderWindow(folder)
                report(fromPalette != nil, "a recent folder chosen in the palette opens in a folder window")
                await close(fromPalette)
            }
            if palette.isOpen { palette.cancel() }
        }

        let after = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        report(NSDictionary(dictionary: preferences).isEqual(to: after), "the reopen checks wrote no preference")
        LastOpened.forget()
    }
}
#endif
