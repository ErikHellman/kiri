#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit
import SwiftUI

/// The explicit-save half of `-KiriSelfTest`: the file changes on Save and
/// at no other time. A recovery copy is written a few seconds after an edit
/// and goes with Save, Revert and close; closing a dirty tab asks (Cancel,
/// Don't Save, Save); Revert reads the file into the same document; and
/// `kiri -w` waits until its tab has really closed.
///
/// The sheets are answered in-process, by pressing their buttons. Every file
/// is in a folder of the test's own, and every recovery copy it sees made is
/// checked gone again.
extension SelfTest {
    /// What the document is and how it saves, before anything is typed.
    static func probeDocument(_ doc: NSDocument) {
        let chain = sequence(first: type(of: doc) as AnyClass, next: { $0.superclass() }).map { NSStringFromClass($0) }
        print("SELFTEST info document class chain \(chain)")
        report(doc is KiriDocument && chain == ["KiriDocument", "NSDocument", "NSObject"],
               "the document is a plain NSDocument (\(chain.joined(separator: " : ")))")
        report(!type(of: doc).autosavesInPlace && !type(of: doc).preservesVersions,
               "it neither autosaves in place nor keeps versions")
        let controller = NSDocumentController.shared
        report(controller is KiriDocumentController && controller.autosavingDelay == KiriDocumentController.recoveryDelay
               && controller.autosavingDelay > 0,
               "recovery copies are written \(controller.autosavingDelay) s after an edit")
    }

    static func saveStages(_ first: NSDocument) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-save-test-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        await periodicRecovery(dir)
        await anyFileSavesInPlace(dir)
        await closeDirty(dir)
        await backgroundTab(dir)
        await revert(dir)
        await changedOnDisk(dir)
        await untitled(dir)
        await waiting(dir)
        await openRecent(dir)
        report(leftovers().isEmpty, "no recovery copy of the test's is left (\(leftovers().map(\.lastPathComponent)))")
        print("SELFTEST DONE save")
        fflush(stdout)
    }

    // MARK: Helpers

    /// Recovery copies this run has seen made, each checked gone at the end.
    private static var copies: [URL] = []

    private static func leftovers() -> [URL] { copies.filter { FileManager.default.fileExists(atPath: $0.path) } }

    private static func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    private static func wait(_ seconds: Double = 4, until done: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .seconds(seconds) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    private static func isOpen(_ doc: NSDocument) -> Bool { NSDocumentController.shared.documents.contains { $0 === doc } }

    private struct Tab {
        let doc: KiriDocument
        let window: NSWindow
        let text: KiriTextView
        let controller: EditorController
    }

    /// The tab of `doc`, once its editor shows the document.
    private static func tab(of doc: NSDocument?) async -> Tab? {
        guard let doc = doc as? KiriDocument else { return nil }
        var found: Tab?
        _ = await wait {
            guard let w = Editors.window(for: doc), let tv = findTextView(in: w.contentView) as? KiriTextView,
                  let c = tv.delegate as? EditorController, c.document === doc else { return false }
            found = Tab(doc: doc, window: w, text: tv, controller: c)
            return true
        }
        return found
    }

    private static func open(_ url: URL) async -> Tab? {
        let doc: NSDocument? = await withCheckedContinuation { c in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { d, _, _ in c.resume(returning: d) }
        }
        return await tab(of: doc)
    }

    private static func file(_ name: String, _ text: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        try? Data(text.utf8).write(to: url)
        return url
    }

    /// Types at the start of the tab's text, as an edit the document counts.
    private static func insert(_ text: String, in tab: Tab) async {
        tab.window.makeFirstResponder(tab.text)
        tab.text.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        await settle()
    }

    /// A forced recovery copy (the periodic one comes 5 s after an edit).
    @discardableResult
    private static func autosave(_ doc: NSDocument) async -> URL? {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            doc.autosave(withImplicitCancellability: false) { _ in c.resume() }
        }
        let copy = doc.autosavedContentsFileURL
        if let copy, !copies.contains(copy) { copies.append(copy) }
        return copy
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap { buttons(in: $0) }
    }

    private static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return field.stringValue.isEmpty ? [] : [field.stringValue] }
        return view.subviews.flatMap { texts(in: $0) }
    }

    /// The sheet on `window`, once it is up.
    private static func sheet(on window: NSWindow) async -> NSWindow? {
        _ = await wait { window.attachedSheet != nil }
        return window.attachedSheet
    }

    /// Presses the sheet's button of that title and waits for the sheet to go.
    @discardableResult
    private static func press(_ title: String, on window: NSWindow) async -> Bool {
        guard let sheet = window.attachedSheet, let button = buttons(in: sheet.contentView).first(where: { $0.title == title }) else {
            return false
        }
        button.performClick(nil)
        return await wait { window.attachedSheet == nil }
    }

    // MARK: Stages

    /// Without being asked: the recovery copy is there a little after the
    /// delay, the file as it was.
    private static func periodicRecovery(_ dir: URL) async {
        let url = file("periodic.txt", "one\n", in: dir)
        guard let tab = await open(url) else { report(false, "a file opens for the recovery check"); return }
        let untouched = FileState(url)
        await insert("typed ", in: tab)
        let delay = NSDocumentController.shared.autosavingDelay
        let made = await wait(delay + 4) { tab.doc.autosavedContentsFileURL != nil }
        let copy = tab.doc.autosavedContentsFileURL
        if let copy { copies.append(copy) }
        report(made && (copy.flatMap { try? Data(contentsOf: $0) }) == Data("typed one\n".utf8) && FileState(url) == untouched
               && tab.doc.isDocumentEdited,
               "a recovery copy is written by itself within \(Int(delay + 4)) s of an edit, the file untouched and the document still edited")
        report(copy?.deletingLastPathComponent().standardizedFileURL == RecoveryCopies.folder.standardizedFileURL
               && !exists(dir.appendingPathComponent("periodic (Autosaved).txt")),
               "the copy is in the recovery folder, not beside the file (\(copy?.path ?? "none"))")
        // What doesn't fit the chosen encoding still gets its copy.
        tab.doc.setEncoding(.windowsLatin1)
        await insert("→ ", in: tab)
        var failed: Error?
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            tab.doc.autosave(withImplicitCancellability: false) { failed = $0; c.resume() }
        }
        let kept = tab.doc.autosavedContentsFileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        report(failed == nil && kept == "→ typed one\n" && tab.window.attachedSheet == nil,
               "text that doesn't fit the chosen encoding still gets its recovery copy, with no alert (\(kept ?? "none"))")
        tab.doc.close()
        report(!exists(copy) && FileState(url) == untouched, "closing without saving deletes the copy and leaves the file")
    }

    /// ⌘S saves where the file is, whatever the system calls its type.
    private static func anyFileSavesInPlace(_ dir: URL) async {
        var wrong: [String] = []
        let names = ["Makefile", "Dockerfile", "LICENSE", "config.toml", ".gitignore", "notes.unknownext", "main.rs", "data.json",
                     "run.sh", "READ ME.md"]
        for name in names {
            let url = file(name, "text\n", in: dir)
            guard let tab = await open(url) else { wrong.append("\(name): didn't open"); continue }
            await insert("x", in: tab)
            let copy = await autosave(tab.doc)
            tab.doc.save(nil)
            let saved = await wait(3) { !tab.doc.isDocumentEdited || tab.window.attachedSheet != nil }
            let bytes = try? Data(contentsOf: url)
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if !saved || tab.window.attachedSheet != nil || bytes != Data("xtext\n".utf8)
                || tab.doc.fileURL?.standardizedFileURL != url.standardizedFileURL || exists(copy)
                || listing.contains(where: { $0 != name && $0.hasPrefix((name as NSString).deletingPathExtension) && !names.contains($0) }) {
                wrong.append("\(name): type \(tab.doc.fileType ?? "nil"), sheet \(tab.window.attachedSheet != nil), bytes \(bytes.map { String(decoding: $0, as: UTF8.self) } ?? "none"), copy left \(exists(copy))")
            }
            if let sheet = tab.window.attachedSheet { tab.window.endSheet(sheet) }
            tab.doc.close()
        }
        report(wrong.isEmpty, "Save writes the file in place and deletes its recovery copy, for \(names.count) kinds of file (\(wrong.isEmpty ? names.joined(separator: ", ") : wrong.joined(separator: "; ")))")
    }

    /// Closing a tab with unsaved changes asks: Cancel, Don't Save, Save.
    private static func closeDirty(_ dir: URL) async {
        let url = file("close.txt", "one\n", in: dir)
        guard var tab = await open(url) else { report(false, "a file opens for the close checks"); return }
        let untouched = FileState(url)
        await insert("typed ", in: tab)
        let copy = await autosave(tab.doc)

        tab.window.performClose(nil)
        let asked = await sheet(on: tab.window)
        let titles = buttons(in: asked?.contentView).map(\.title)
        report(titles == ["Save", "Don’t Save", "Cancel"], "closing a tab with unsaved changes asks (\(titles))")

        await press("Cancel", on: tab.window)
        report(isOpen(tab.doc) && tab.window.isVisible && tab.doc.isDocumentEdited && FileState(url) == untouched && exists(copy),
               "Cancel keeps the tab, its changes and its recovery copy; the file is untouched")

        tab.window.performClose(nil)
        _ = await sheet(on: tab.window)
        await press("Don’t Save", on: tab.window)
        let discarded = await wait { !isOpen(tab.doc) }
        report(discarded && FileState(url) == untouched && !exists(copy),
               "Don’t Save closes the tab, leaves the file as it was and deletes the recovery copy")

        guard let again = await open(url) else { report(false, "the file opens again"); return }
        tab = again
        report(tab.text.string == "one\n" && !tab.doc.isDocumentEdited, "opened again, it is the file as it was (“\(tab.text.string.replacingOccurrences(of: "\n", with: "⏎"))”)")
        await insert("kept ", in: tab)
        let second = await autosave(tab.doc)
        tab.window.performClose(nil)
        _ = await sheet(on: tab.window)
        await press("Save", on: tab.window)
        let saved = await wait { !isOpen(tab.doc) }
        report(saved && (try? Data(contentsOf: url)) == Data("kept one\n".utf8) && !exists(second),
               "Save writes the file, closes the tab and deletes the recovery copy")
    }

    /// The close button of a tab that isn't showing: with unsaved changes
    /// the tab comes forward first, so its question is seen.
    private static func backgroundTab(_ dir: URL) async {
        let one = file("behind.txt", "behind\n", in: dir), two = file("showing.txt", "showing\n", in: dir)
        guard let behind = await open(one), let showing = await open(two) else { report(false, "two files open for the tab check"); return }
        await insert("typed ", in: behind)
        showing.window.tabGroup?.selectedWindow = showing.window
        _ = await wait { showing.window.tabGroup?.selectedWindow === showing.window }
        await settle(200)
        guard let strip = WindowTabs.model(for: showing.window), behind.window.tabGroup === showing.window.tabGroup else {
            report(false, "the two files are tabs of one window"); behind.doc.close(); showing.doc.close(); return
        }
        strip.close(behind.window.windowNumber)
        let asked = await sheet(on: behind.window)
        report(asked != nil && behind.window.tabGroup?.selectedWindow === behind.window && isOpen(behind.doc),
               "closing a tab that isn't showing brings it forward to ask about its changes")
        await press("Cancel", on: behind.window)
        behind.doc.close()
        showing.doc.close()
    }

    /// A file changed by something else: a document without unsaved changes
    /// takes it up; one with changes keeps them, and Save doesn't write
    /// over the file without asking.
    private static func changedOnDisk(_ dir: URL) async {
        let url = file("shared.txt", "first\n", in: dir)
        guard let tab = await open(url) else { report(false, "a file opens for the changed-on-disk check"); return }
        func write(_ text: String) {
            try? Data(text.utf8).write(to: url)
            // A different modification date, whatever the clock's grain.
            let later = (tab.doc.fileModificationDate ?? Date()).addingTimeInterval(2 + Double.random(in: 0..<1))
            try? FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        }
        write("changed by git\n")
        let reloaded = await wait(4) { tab.text.string == "changed by git\n" }
        report(reloaded && !tab.doc.isDocumentEdited && isOpen(tab.doc) && tab.controller.document === tab.doc,
               "a file changed on disk is taken up by its document when that has no unsaved changes (“\(tab.text.string.replacingOccurrences(of: "\n", with: "⏎"))”)")

        await insert("mine ", in: tab)
        write("theirs\n")
        await settle(1200)
        report(tab.text.string == "mine changed by git\n" && tab.doc.isDocumentEdited,
               "a document with unsaved changes keeps them when its file changes on disk")
        tab.doc.save(nil)
        let asked = await sheet(on: tab.window)
        let titles = buttons(in: asked?.contentView).map(\.title)
        let words = texts(in: asked?.contentView).joined(separator: " ")
        report(asked != nil && (try? Data(contentsOf: url)) == Data("theirs\n".utf8),
               "and its Save asks before writing over the other change (“\(words)” \(titles))")
        if let cancel = titles.first(where: { $0 == "Cancel" }) ?? titles.last { await press(cancel, on: tab.window) }
        if let sheet = tab.window.attachedSheet { tab.window.endSheet(sheet) }
        tab.doc.close()
    }

    /// File ▸ Open Recent is Kiri's own menu over AppKit's list. (A test
    /// launch adds nothing to that list, which is the person's.)
    private static func openRecent(_ dir: URL) async {
        guard let main = NSApp.mainMenu, let menu = main.item(withTitle: "File")?.submenu?.item(withTitle: "Open Recent")?.submenu else {
            report(false, "File ▸ Open Recent exists"); return
        }
        let recent = NSDocumentController.shared.recentDocumentURLs
        RecentDocuments.shared.refresh()
        await settle(250)
        updateMenu(main)
        let listed = menu.items.filter { !$0.isSeparatorItem && $0.title != "Clear Menu" }
        report(listed.count == recent.count && menu.items.last?.title == "Clear Menu" && menu.items.last?.isEnabled == !recent.isEmpty,
               "File ▸ Open Recent lists the \(recent.count) documents AppKit remembers, then Clear Menu")
        report(!recent.contains { $0.path.hasPrefix(dir.path) || $0.path.hasPrefix(dir.resolvingSymlinksInPath().path) },
               "the test's own files are not in Open Recent")

        // With a list of the test's own: two of a name, and a third.
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        for folder in [a, b] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let files = [file("notes.md", "in a\n", in: a), file("notes.md", "in b\n", in: b), file("other.txt", "other\n", in: a)]
        RecentDocuments.shared.selfTestShow(files)
        defer { RecentDocuments.shared.refresh() }
        await settle(250)
        updateMenu(main)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        report(titles == ["notes.md — a", "notes.md — b", "other.txt", "Clear Menu"] && menu.items.last?.isEnabled == true,
               "recent documents are listed by name, two of a name with their folders (\(titles))")
        if let i = menu.items.firstIndex(where: { $0.title == "notes.md — b" }) { menu.performActionForItem(at: i) }
        var chosen: NSDocument?
        _ = await wait(3) {
            chosen = NSDocumentController.shared.documents.first { $0.fileURL?.standardizedFileURL == files[1].standardizedFileURL }
            return chosen != nil
        }
        let tab = await tab(of: chosen)
        report(tab?.text.string == "in b\n", "choosing one opens that file")
        chosen?.close()
    }

    /// File ▸ Revert to Saved: asks, then reads the file into the document
    /// that is open, whose editor shows it.
    private static func revert(_ dir: URL) async {
        let url = file("revert.swift", "let one = 1\n", in: dir)
        guard let tab = await open(url) else { report(false, "a file opens for the revert check"); return }
        await insert("// typed\n", in: tab)
        let copy = await autosave(tab.doc)
        report(exists(copy) && tab.doc.isDocumentEdited, "an edited document has its recovery copy")

        tab.doc.revertToSaved(nil)
        let asked = await sheet(on: tab.window)
        let titles = buttons(in: asked?.contentView).map(\.title)
        await press("Cancel", on: tab.window)
        let kept = tab.text.string == "// typed\nlet one = 1\n" && tab.doc.isDocumentEdited
        tab.doc.revertToSaved(nil)
        _ = await sheet(on: tab.window)
        await press("Revert", on: tab.window)
        let reverted = await wait { !tab.doc.isDocumentEdited }
        report(titles.contains("Revert") && titles.contains("Cancel") && kept, "Revert to Saved asks first, and Cancel keeps the changes (\(titles))")
        report(reverted && tab.text.string == "let one = 1\n" && isOpen(tab.doc) && tab.controller.document === tab.doc
               && Editors.window(for: tab.doc) === tab.window && findTextView(in: tab.window.contentView) === tab.text,
               "Revert reads the file into the same document, window and editor (“\(tab.text.string.replacingOccurrences(of: "\n", with: "⏎"))”)")
        report(!exists(copy) && tab.doc.autosavedContentsFileURL == nil && !(tab.text.undoManager?.canUndo ?? true),
               "and deletes the recovery copy and the undo history")
        tab.doc.close()
    }

    /// A document that has no file yet: Save asks where, with a name that
    /// can be anything; the tab then follows its file.
    private static func untitled(_ dir: URL) async {
        guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true), let tab = await tab(of: doc) else {
            report(false, "a new untitled document opens"); return
        }
        await insert("print(1)\n", in: tab)
        let copy = await autosave(tab.doc)
        report(exists(copy) && tab.doc.fileURL == nil, "an untitled document gets a recovery copy too (\(copy?.lastPathComponent ?? "none"))")

        tab.doc.save(nil)
        guard let panel = await sheet(on: tab.window) as? NSSavePanel else {
            report(false, "Save on an untitled document asks where (sheet: \(tab.window.attachedSheet.map { "\(type(of: $0))" } ?? "none"))")
            tab.doc.close()
            return
        }
        report(panel.nameFieldStringValue == tab.doc.displayName + ".txt" && panel.allowedContentTypes.isEmpty && panel.accessoryView == nil,
               "Save on an untitled document asks where, offering “\(panel.nameFieldStringValue)” with any extension allowed and no format pop-up")
        // The panel itself is the system's and out of reach of a test:
        // cancel it, and save where a chosen name would.
        panel.cancel(nil)
        _ = await wait { tab.window.attachedSheet == nil }
        report(isOpen(tab.doc) && tab.doc.isDocumentEdited && tab.doc.fileURL == nil && exists(copy),
               "cancelling the panel leaves the document as it was")

        let url = dir.appendingPathComponent("named.py")
        let saved: Bool = await withCheckedContinuation { c in
            tab.doc.save(to: url, ofType: tab.doc.fileType ?? "public.plain-text", for: .saveAsOperation) { error in
                c.resume(returning: error == nil)
            }
        }
        report(saved && (try? Data(contentsOf: url)) == Data("print(1)\n".utf8) && !tab.doc.isDocumentEdited && !exists(copy)
               && tab.doc.location?.standardizedFileURL == url.standardizedFileURL,
               "saved under a name, the file holds the text, the document is clean and its recovery copy gone")
        // The screen follows the file: no longer untitled, and colored by its name.
        let followed = await wait(2) { tab.controller.model.language == .python }
        if followed || tab.window.occlusionState.contains(.visible) {
            report(followed, "the tab follows its new file: \(tab.controller.model.language.name) by its name")
        } else {
            print("SELFTEST SKIP the tab follows its new file (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        tab.doc.close()
    }

    /// `kiri -w`: the marker goes when the tab has really closed, and not
    /// before the file has what Save wrote.
    private static func waiting(_ dir: URL) async {
        let url = file("COMMIT_EDITMSG", "\n# Please enter the commit message\n", in: dir)
        func request(_ n: Int) async -> (marker: URL, tab: Tab)? {
            let marker = dir.appendingPathComponent("request.\(n).wait")
            FileManager.default.createFile(atPath: marker.path, contents: Data())
            KiriCLI.open(KiriCLI.Request(waitMarker: marker, entries: [.file(url, line: 0, column: 0)]))
            var doc: NSDocument?
            _ = await wait { doc = NSDocumentController.shared.documents.first { $0.fileURL?.lastPathComponent == url.lastPathComponent }; return doc != nil }
            guard let tab = await tab(of: doc) else { return nil }
            await settle(200)
            return (marker, tab)
        }

        guard let (marker, tab) = await request(1) else { report(false, "kiri -w opens its file"); return }
        let untouched = FileState(url)
        await insert("Fix the thing", in: tab)
        tab.window.performClose(nil)
        _ = await sheet(on: tab.window)
        let whileAsked = exists(marker)
        await press("Cancel", on: tab.window)
        await settle(200)
        report(whileAsked && exists(marker) && isOpen(tab.doc) && FileState(url) == untouched,
               "kiri -w keeps waiting while the close question is up and after Cancel")

        // Save: the marker goes only once the file has the text.
        tab.window.performClose(nil)
        _ = await sheet(on: tab.window)
        var bytesWhenReleased: Data?
        let watcher = Task { @MainActor in
            while exists(marker) { try? await Task.sleep(for: .milliseconds(1)) }
            bytesWhenReleased = try? Data(contentsOf: url)
        }
        await press("Save", on: tab.window)
        let released = await wait { !exists(marker) }
        await watcher.value
        report(released && !isOpen(tab.doc) && bytesWhenReleased == Data("Fix the thing\n# Please enter the commit message\n".utf8),
               "Save closes the tab and ends the wait, the file already holding what was saved")

        // Don't Save: the wait ends, the file as it was.
        guard let (marker2, tab2) = await request(2) else { report(false, "kiri -w opens its file again"); return }
        let saved = FileState(url)
        await insert("Changed my mind ", in: tab2)
        tab2.window.performClose(nil)
        _ = await sheet(on: tab2.window)
        await press("Don’t Save", on: tab2.window)
        let released2 = await wait { !exists(marker2) }
        report(released2 && !isOpen(tab2.doc) && FileState(url) == saved, "Don’t Save ends the wait and leaves the file as it was")

        // Quitting while a tab with changes is waited for asks; Cancel
        // keeps Kiri, the tab and the wait.
        guard let (marker3, tab3) = await request(3) else { report(false, "kiri -w opens its file a third time"); return }
        await insert("Quit? ", in: tab3)
        var question: [String] = []
        let answer = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                // One document with changes: its own sheet. More: an alert.
                let asking = NSApp.modalWindow ?? tab3.window.attachedSheet
                question = buttons(in: asking?.contentView).map(\.title)
                buttons(in: asking?.contentView).first { $0.title == "Cancel" }?.performClick(nil)
            }
        }
        RunLoop.main.add(answer, forMode: .common)
        NSApp.terminate(nil)
        _ = await wait(3) { !question.isEmpty && tab3.window.attachedSheet == nil }
        report(question.contains("Cancel") && isOpen(tab3.doc) && exists(marker3) && FileState(url) == saved,
               "quitting while a changed tab is waited for asks first, and Cancel keeps Kiri and the wait (\(question))")
        tab3.window.performClose(nil)
        _ = await sheet(on: tab3.window)
        await press("Don’t Save", on: tab3.window)
        _ = await wait { !exists(marker3) }
    }
}

/// `-KiriRelaunchTest <phase>`: what only a second launch can show, and
/// only without `-ApplePersistenceIgnoreState YES`, which stops AppKit
/// reopening anything. So these run in a copy of the app under another
/// bundle identifier and name (its recovery record, its saved state and
/// its "Unsaved … Document" are then its own), never in Kiri itself:
///
/// - `crash` (with a file): types into the file's document and a new
///   untitled one, waits for both recovery copies and kills itself.
/// - `recover` (no arguments): both documents are back, edited, with the
///   typed text; they are then closed, which deletes the copies.
/// - `frame-set` / `frame-check`: the document window's frame is kept
///   from one launch to the next.
extension SelfTest {
    static func relaunch(_ phase: String, _ textView: NSTextView) {
        guard !isKiriItself else {
            report(false, "the relaunch tests run only in a copy with another bundle identifier, not in Kiri itself")
            exit(2)
        }
        Task { @MainActor in
            switch phase {
            case "crash": await crash(textView)
            case "recover": await recover()
            case "frame-set": frameSet(textView)
            case "frame-check": frameCheck(textView)
            default: report(false, "relaunch phase “\(phase)”")
            }
            print("SELFTEST DONE relaunch \(phase)")
            fflush(stdout)
            quit()
        }
    }

    private static func pause(_ seconds: Double = 5, until done: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .seconds(seconds) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    private static let typedInFile = "// recovered\n", typedInUntitled = "never saved\n"

    private static func crash(_ textView: NSTextView) async {
        guard let first = NSDocumentController.shared.documents.first(where: { $0.fileURL != nil }),
              let second = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) else {
            report(false, "a document with a file and a new untitled one"); return
        }
        var editors: [NSTextView] = []
        _ = await pause {
            editors = [first, second].compactMap { doc in Editors.window(for: doc).flatMap { findTextView(in: $0.contentView) } }
            return editors.count == 2 && editors.allSatisfy { (($0.delegate as? EditorController)?.document) != nil }
        }
        guard editors.count == 2 else { report(false, "both editors are up"); return }
        for (editor, text) in zip(editors, [typedInFile, typedInUntitled]) {
            editor.window?.tabGroup?.selectedWindow = editor.window
            await settle(200)
            editor.window?.makeFirstResponder(editor)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
            await settle(200)
        }
        let delay = NSDocumentController.shared.autosavingDelay
        let copied = await pause(delay + 6) { first.autosavedContentsFileURL != nil && second.autosavedContentsFileURL != nil }
        for doc in [first, second] { print("SELFTEST info recovery copy \(doc.autosavedContentsFileURL?.path ?? "none")") }
        report(copied && first.isDocumentEdited && second.isDocumentEdited,
               "both documents have unsaved changes and a recovery copy, written by itself; now the app is killed")
        fflush(stdout)
        guard copied else { return }
        kill(getpid(), SIGKILL)
    }

    private static func recover() async {
        var docs: [NSDocument] = []
        _ = await pause(6) {
            docs = NSDocumentController.shared.documents.filter { $0.autosavedContentsFileURL != nil }
            return docs.count == 2
        }
        let all = NSDocumentController.shared.documents
        print("SELFTEST info documents after the relaunch: \(all.map { "\($0.fileURL?.lastPathComponent ?? "untitled") edited=\($0.isDocumentEdited) copy=\($0.autosavedContentsFileURL?.lastPathComponent ?? "none")" })")
        report(docs.count == 2 && all.count == 2, "the relaunch reopens the two documents that had unsaved changes, and nothing else (\(all.count) open)")
        func text(_ doc: NSDocument) async -> String? {
            var found: String?
            _ = await pause(3) {
                guard let tv = Editors.window(for: doc).flatMap({ findTextView(in: $0.contentView) }),
                      ((tv.delegate as? EditorController)?.document) === doc else { return false }
                found = tv.string
                return true
            }
            return found
        }
        func tabIsDirty(_ doc: NSDocument) -> Bool {
            guard let w = Editors.window(for: doc), let strip = WindowTabs.model(for: w) else { return false }
            strip.refresh()
            return strip.items.first { $0.id == w.windowNumber }?.dirty == true
        }
        if let doc = docs.first(where: { $0.fileURL != nil }), let url = doc.fileURL {
            let shown = await text(doc)
            let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? "?"
            report(shown == typedInFile + onDisk && doc.isDocumentEdited && tabIsDirty(doc) && doc.windowControllers.first?.window?.isDocumentEdited == true,
                   "the file's document is back at its file (\(url.lastPathComponent)) with the typed text, edited, its tab dirty; the file itself still as it was saved")
        } else {
            report(false, "the document with a file came back")
        }
        if let doc = docs.first(where: { $0.fileURL == nil }) {
            let shown = await text(doc)
            report(shown == typedInUntitled && doc.isDocumentEdited && tabIsDirty(doc),
                   "the untitled document is back with its text, edited (“\((shown ?? "none").replacingOccurrences(of: "\n", with: "⏎"))”)")
        } else {
            report(false, "the untitled document came back")
        }
        // The copies are this test's own: closing the documents deletes them.
        let copies = docs.compactMap(\.autosavedContentsFileURL)
        for doc in all { doc.close() }
        report(!copies.isEmpty && copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
               "closing them deletes the recovery copies (\(copies.map(\.lastPathComponent)))")
    }

    private static let testFrame = NSRect(x: 220, y: 180, width: 777, height: 555)

    private static func frameSet(_ textView: NSTextView) {
        guard let window = textView.window else { report(false, "a document window"); return }
        window.setFrame(testFrame, display: true)
        window.performClose(nil)
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame KiriDocumentWindow")
        report(saved != nil, "closing a document window saves its frame (\(saved ?? "nothing"))")
    }

    private static func frameCheck(_ textView: NSTextView) {
        guard let window = textView.window else { report(false, "a document window"); return }
        report(window.frame == testFrame, "the next launch's document window has that frame (\(window.frame))")
    }
}
#endif
