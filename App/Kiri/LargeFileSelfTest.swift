#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

extension SelfTest {
    /// Screenshot helper: `-KiriFind <word>` (with `-KiriFindCase`,
    /// `-KiriFindRegex`, `-KiriFindNext <n>`) on a large file, as on any
    /// other; `-KiriGoToLine <n>` goes there first.
    static func largeFileShown(_ tab: DocumentTab) {
        guard let viewer = tab.largeViewer else { return }
        let defaults = UserDefaults.standard
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if let line = defaults.string(forKey: "KiriGoToLine").flatMap(Int.init) { tab.controller.goTo(line: line) }
            guard let query = defaults.string(forKey: "KiriFind") else { return }
            let find = tab.model.find
            find.board = NSPasteboard.withUniqueName()
            viewer.view.window?.makeFirstResponder(viewer.view)
            find.show()
            find.options = SearchOptions(matchCase: defaults.bool(forKey: "KiriFindCase"),
                                         regularExpression: defaults.bool(forKey: "KiriFindRegex"))
            find.query = query
            Task { @MainActor in
                for _ in 0..<400 where find.isSearching { await settle(25) }
                for _ in 0..<defaults.integer(forKey: "KiriFindNext") { find.step(forward: true) }
                print("SELFTEST info find “\(query)”: \(find.label)")
                fflush(stdout)
            }
        }
    }

    /// Large files (`LargeFileView`): a file over the limit opens read-only
    /// after asking (and not at all on Cancel), in the viewer instead of
    /// the editor; its lines are counted; nothing saves it; find counts
    /// its matches and goes to them; Go to Line goes to a line; it follows
    /// the file as it grows and starts over when it gets shorter. A file
    /// under the limit opens in the editor. `-KiriLargeFileTest YES` runs
    /// these, in a launch with any small file.
    static func largeFileStage() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiri-large-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Over the limit: numbered lines, with a needle on every 1000th.
        let lineCount = 1_500_000
        let url = folder.appendingPathComponent("big.log")
        do {
            var text = ""
            text.reserveCapacity(KiriDocument.largeFileThreshold + (8 << 20))
            for i in 0..<lineCount {
                text += "2026-11-25 line \(i) " + (i % 1000 == 0 ? "needle " : "") + String(repeating: "x", count: 50) + "\n"
            }
            try Data(text.utf8).write(to: url)
        } catch { report(false, "a large file to open (\(error))"); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        report(size >= KiriDocument.largeFileThreshold, "the test file is over the limit (\(size) bytes)")

        func open(_ url: URL) async -> KiriDocument? {
            await withCheckedContinuation { done in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
                    done.resume(returning: document as? KiriDocument)
                }
            }
        }

        // Cancel: nothing opens.
        LargeFileAnswer.forTests = false
        let cancelled = await open(url)
        report(cancelled == nil && NSDocumentController.shared.document(for: url) == nil, "Cancel on the read-only question opens nothing")

        LargeFileAnswer.forTests = true
        guard let document = await open(url) else { report(false, "a large file opens read-only"); return }
        await settle(300)
        guard let tab = DocumentWindow.tab(of: document), let viewer = tab.largeViewer else {
            report(false, "a large file shows in the read-only viewer"); return
        }
        let model = tab.model
        report(document.isLargeFile && document.text.isEmpty && viewer.view.window != nil
               && tab.container.superview == nil,
               "a large file opens in the read-only viewer, not the editor")

        // The lines are counted.
        for _ in 0..<100 where model.largeStatus?.counting != nil || viewer.file.lineCount < lineCount + 1 {
            await settle(50)
        }
        report(viewer.file.lineCount == lineCount + 1 && model.lineCount == lineCount + 1 && model.largeStatus?.counting == nil,
               "its lines are counted (\(viewer.file.lineCount))")

        // Nothing saves it.
        let observer = SaveObserver()
        let saved: Bool = await withCheckedContinuation { done in
            observer.save(document) { done.resume(returning: $0) }
        }
        withExtendedLifetime(observer) {}
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        document.updateChangeCount(.changeDone)
        document.setEncoding(.utf16LE)
        if let main = NSApp.mainMenu { updateMenu(main) }
        let saveItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(NSDocument.save(_:)) }
        let saveEnabled = saveItem.map { document.validateUserInterfaceItem($0) } ?? false
        report(!saved && sizeAfter == size && !document.isDocumentEdited && document.encoding == .utf8 && !saveEnabled,
               "a large file never saves (saved \(saved), size \(sizeAfter == size), edited \(document.isDocumentEdited), menu \(saveEnabled))")

        // Find: every match counted, Next goes to the first after the caret.
        let find = model.find
        // (A find pasteboard of its own: the shared one is the person's.)
        find.board = NSPasteboard.withUniqueName()
        find.show()
        find.query = "needle"
        for _ in 0..<200 where find.isSearching { await settle(25) }
        await settle(100)
        let expected = lineCount / 1000
        report(find.label == "\(expected.formatted()) matches" || find.label == "1 of \(expected.formatted())",
               "find counts every match in a large file (\(find.label))")
        find.step(forward: true)
        find.close()
        let second = viewer.view.selectedBytes
        let text = String(decoding: viewer.file.read(second), as: UTF8.self)
        report(text == "needle" && model.line == 1001, "Find Next selects the next match, on its line (\(text), line \(model.line))")
        find.show()
        find.options.matchCase = true
        find.query = "NEEDLE"
        for _ in 0..<200 where find.isSearching { await settle(25) }
        await settle(100)
        report(find.label == "No matches", "Match Case is honoured (\(find.label))")
        find.options = SearchOptions(regularExpression: true)
        find.query = "line 12\\d{4} needle"
        for _ in 0..<400 where find.isSearching { await settle(25) }
        await settle(100)
        report(find.label.hasSuffix("10 matches") || find.label.hasSuffix("of 10"),
               "a regular expression finds its matches (\(find.label))")
        find.options = SearchOptions()
        find.query = "needle"
        for _ in 0..<200 where find.isSearching { await settle(25) }
        find.close()

        // Go to Line.
        tab.controller.goTo(line: 750_000)
        await settle(50)
        report(model.line == 750_000 && viewer.view.caret.line == 749_999, "Go to Line goes to a line of a large file (\(model.line))")
        model.goToLine.open()
        await settle(100)
        model.goToLine.text = "1200000"
        await settle(50)
        model.goToLine.cancel()
        await settle(50)
        report(model.line == 750_000, "Escape in Go to Line goes back to where the viewer was (\(model.line))")

        // It follows the file as it grows: the new lines, and their matches.
        viewer.view.scrollToEndOfDocument(nil)
        find.show()
        for _ in 0..<200 where find.isSearching { await settle(25) }
        let before = viewer.file.lineCount
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("added one needle\nadded two\n".utf8))
            try? handle.close()
        }
        for _ in 0..<60 where viewer.file.lineCount == before { await settle(50) }
        for _ in 0..<100 where find.isSearching { await settle(25) }
        await settle(200)
        report(viewer.file.lineCount == before + 2 && model.lineCount == before + 2,
               "a large file that grows shows its new lines (\(before) → \(viewer.file.lineCount))")
        report(find.label.contains((expected + 1).formatted()), "find counts the matches in what was added (\(find.label))")
        find.close()

        // Shorter: opened again, from the top.
        try? Data("short\nfile\n".utf8).write(to: url)
        for _ in 0..<60 where viewer.file.lineCount != 3 { await settle(50) }
        report(viewer.file.lineCount == 3 && viewer.view.caret.line == 0, "a large file that gets shorter is read again from the top")
        document.close()

        // Quietly, without the question (Cancel is the answer it would
        // get): the folder sidebar's preview, and a window brought back.
        try? Data(String(repeating: "quiet line\n", count: 2000).utf8).write(to: url)
        KiriDocument.largeFileThresholdForTests = 4096
        LargeFileAnswer.forTests = false
        if let window = NSApp.windows.first(where: { $0 is DocumentNSWindow }) {
            let shown: NSWindow? = await withCheckedContinuation { done in
                SidebarOpen.open(url, keep: false, from: window) { done.resume(returning: $0) }
            }
            await settle(200)
            let previewed = NSDocumentController.shared.document(for: url) as? KiriDocument
            report(shown != nil && previewed?.isLargeFile == true, "the sidebar's preview opens a large file without asking")
            previewed?.close()
            await settle(100)
        } else {
            report(false, "a window for the sidebar's preview")
        }
        let reopened: KiriDocument? = await withCheckedContinuation { done in
            NSDocumentController.shared.reopenDocument(for: url, withContentsOf: url, display: false) { document, _, _ in
                done.resume(returning: document as? KiriDocument)
            }
        }
        report(reopened?.isLargeFile == true, "a large file AppKit reopens (a restored window) opens without asking")
        reopened?.close()

        // A binary file over the limit is refused, as the editor refuses one.
        LargeFileAnswer.forTests = true
        let binary = folder.appendingPathComponent("disk.img")
        try? Data([0x00, 0x01, 0x02] + [UInt8](repeating: 0x41, count: 8192)).write(to: binary)
        let refused = await open(binary)
        report(refused == nil, "a binary file over the limit doesn't open")

        // A file open in the editor that grows past the limit while it is
        // open: read again, read-only, in the viewer.
        let growing = folder.appendingPathComponent("growing.log")
        try? Data("first\n".utf8).write(to: growing)
        if let doc = await open(growing), let growingTab = DocumentWindow.tab(of: doc) {
            await settle(200)
            let wasEditor = growingTab.largeViewer == nil && !doc.isLargeFile
            if let handle = try? FileHandle(forWritingTo: growing) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(String(repeating: "more\n", count: 2000).utf8))
                try? handle.close()
            }
            try? doc.revert(toContentsOf: growing, ofType: doc.fileType ?? "public.plain-text")
            await settle(300)
            report(wasEditor && doc.isLargeFile && growingTab.largeViewer != nil && growingTab.largeViewer?.view.window != nil
                   && doc.text.isEmpty,
                   "a file that grows past the limit while open goes on read-only in the viewer (\(doc.isLargeFile))")
            doc.close()
        } else {
            report(false, "a small file opens to grow")
        }
        KiriDocument.largeFileThresholdForTests = nil

        // Under the limit: the editor, as always.
        let small = folder.appendingPathComponent("small.log")
        try? Data("small\n".utf8).write(to: small)
        if let doc = await open(small) {
            await settle(200)
            report(!doc.isLargeFile && DocumentWindow.tab(of: doc)?.largeViewer == nil && doc.text == "small\n",
                   "a file under the limit opens in the editor")
            doc.close()
        } else {
            report(false, "a file under the limit opens")
        }
        LargeFileAnswer.forTests = nil
    }
}
#endif
