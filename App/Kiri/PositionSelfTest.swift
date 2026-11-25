#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

/// `-KiriPositionTest YES` (and part of `-KiriBehaviorTest`): a file that
/// opens again comes back where it was, the selection and the line at the
/// top; `kiri file:12` wins over that; a tab that never showed keeps what
/// was kept for its file; the preview tab keeps each file's place as it
/// goes from file to file. The positions are the test launch's own
/// (`FilePositions`), in memory.
extension SelfTest {
    static func positionStage(_ window: NSWindow) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-position-test-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = (1...400).map { "line \($0) of the file, with some words after it" }.joined(separator: "\n") + "\n"
        func file(_ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? Data(text.utf8).write(to: url)
            return url
        }
        func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        func tab(of doc: NSDocument?) async -> DocumentTab? {
            guard let doc else { return nil }
            var found: DocumentTab?
            _ = await wait {
                found = DocumentWindow.tab(of: doc)
                return found?.window != nil && found?.controller.document === doc
            }
            return found
        }
        func open(_ url: URL) async -> DocumentTab? {
            let doc: NSDocument? = await withCheckedContinuation { c in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { d, _, _ in c.resume(returning: d) }
            }
            return await tab(of: doc)
        }
        func close(_ tab: DocumentTab) async {
            let doc = tab.document
            closeTab(of: doc)
            _ = await wait { !NSDocumentController.shared.documents.contains { $0 === doc } }
        }
        /// Shown and laid out, with nothing left to put back.
        func shown(_ tab: DocumentTab) async -> Bool {
            await wait { isShowing(tab.document) && tab.controller.pendingPosition == nil && tab.container.bounds.height > 0 }
        }
        func scroll(_ tab: DocumentTab, topLine: Int, select range: NSRange) {
            let c = tab.controller
            tab.container.textView.setSelectedRange(range)
            c.pendingPosition = FilePosition(selection: range.location..<NSMaxRange(range), topLine: topLine,
                                             in: c.currentLineIndex)
            c.applyPendingPosition()
        }
        func offset(line: Int, column: Int) -> Int {
            (text as NSString).components(separatedBy: "\n").prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 } + column
        }
        FilePositions.forgetAll()

        // Closed and opened again: back where it was.
        let a = file("again.txt")
        guard let first = await open(a), await shown(first) else { report(false, "the position test's file opens"); return }
        let selection = NSRange(location: offset(line: 250, column: 5), length: 7)
        scroll(first, topLine: 238, select: selection)
        await settle(100)
        let measured = first.controller.currentPosition()
        report(measured?.topLine == 238 && measured?.selection(in: first.controller.currentLineIndex) ==
               selection.location..<NSMaxRange(selection),
               "the editor measures the line at its top and the selection (line \(measured.map { $0.topLine + 1 } ?? 0))")
        // (It notes the position by itself, a moment after the scroll rests.)
        try? await Task.sleep(for: .milliseconds(Int(EditorController.rememberPause * 1000) + 200))
        let noted = FilePositions.position(for: a)
        report(noted?.topLine == 238, "the position is noted a moment after the scroll rests (top line \(noted.map { $0.topLine + 1 } ?? 0))")
        scroll(first, topLine: 120, select: NSRange(location: offset(line: 130, column: 2), length: 0))
        await close(first)
        report(FilePositions.position(for: a)?.topLine == 120, "closing the tab notes where it was, at once")
        guard let again = await open(a), await shown(again) else { report(false, "the file opens again"); return }
        let back = again.controller.currentPosition()
        let caret = again.container.textView.selectedRange()
        report(caret == NSRange(location: offset(line: 130, column: 2), length: 0) && back?.topLine == 120,
               "opened again, the file is back where it was: the caret on line \(again.model.line), line \(back.map { $0.topLine + 1 } ?? 0) at the top")
        await close(again)

        // `kiri file:12` wins over the kept position.
        let cliDoc: NSDocument? = await withCheckedContinuation { c in
            NSDocumentController.shared.openDocument(withContentsOf: a, display: true) { d, _, _ in
                if let d { Editors.whenReady(d) { $0.goTo(line: 12, column: 1) } }
                c.resume(returning: d)
            }
        }
        if let cli = await tab(of: cliDoc) {
            _ = await wait { cli.model.line == 12 }
            await settle(200)
            cli.container.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let visible = cli.container.textView.visibleCharacters()?.range
            let line12 = offset(line: 11, column: 0)
            report(cli.model.line == 12 && cli.controller.pendingPosition == nil && visible?.contains(line12) == true,
                   "a line asked for (kiri file:12) wins over the kept position: caret on line \(cli.model.line), in sight (\(visible.map { "\($0)" } ?? "nothing") shows, pending \(cli.controller.pendingPosition != nil))")
            await close(cli)
        } else {
            report(false, "the file opens for kiri file:12")
        }

        // A tab that never showed keeps what was kept for its file.
        let b = file("background.txt")
        let kept = FilePosition(start: .init(line: 300, column: 3), end: .init(line: 300, column: 3), topLine: 290)
        FilePositions.set(kept, for: b)
        if let doc = try? NSDocumentController.shared.makeDocument(withContentsOf: b, ofType: "public.plain-text") as? KiriDocument,
           let tabs = (window as? DocumentNSWindow)?.tabs {
            NSDocumentController.shared.addDocument(doc)
            let background = DocumentTab(document: doc, arriving: false)
            tabs.insert(background, select: false)
            report(background.controller.pendingPosition == kept && background.controller.currentPosition() == kept,
                   "a tab that hasn't shown yet holds its file's position to put back")
            await close(background)
            report(FilePositions.position(for: b) == kept, "closed without having shown, it leaves its file's position as it was")
        } else {
            report(false, "a background tab of the test's file")
        }

        // The preview tab: each file keeps its place as it goes from file to file.
        let p1 = file("preview1.txt")
        let p2 = file("preview2.txt")
        FilePositions.set(FilePosition(start: .init(line: 200, column: 0), end: .init(line: 200, column: 0), topLine: 190),
                          for: p2)
        guard let preview = await open(p1), await shown(preview) else { report(false, "the preview test's file opens"); return }
        scroll(preview, topLine: 60, select: NSRange(location: offset(line: 70, column: 0), length: 0))
        if let doc2 = try? NSDocumentController.shared.makeDocument(withContentsOf: p2, ofType: "public.plain-text") as? KiriDocument {
            NSDocumentController.shared.addDocument(doc2)
            let moved = DocumentWindow.show(doc2, in: preview)
            await settle(100)
            let there = preview.controller.currentPosition()
            report(moved && FilePositions.position(for: p1)?.topLine == 60 && there?.topLine == 190 && preview.model.line == 201,
                   "a tab that takes another file keeps the first one's place and shows the other where it was (moved \(moved), first kept at \(FilePositions.position(for: p1).map { $0.topLine + 1 } ?? 0), second at line \(preview.model.line), \(there.map { $0.topLine + 1 } ?? 0) at the top)")
        } else {
            report(false, "the preview test's second file")
        }
        await close(preview)
        FilePositions.forgetAll()
    }
}
#endif
