#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

extension SelfTest {
    /// The folder sidebar, in a folder window of the test's own on a
    /// folder it makes in the temporary directory (nothing outside that
    /// folder is created, renamed or revealed).
    ///
    /// Rows are pressed as VoiceOver presses them where the window is
    /// drawn; otherwise, and for what only a pointer does (a double-click),
    /// the checks call what the click calls (`SidebarOpen.open`,
    /// `WindowTabs.keep`).
    static func sidebarStage(_ original: NSWindow) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-sidebar-test-\(getpid())")
            .standardizedFileURL
        let f = SidebarFixture(root: dir.appendingPathComponent("project"))
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        f.write()

        // The folder window, as `kiri <folder>` opens it.
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        KiriCLI.open(KiriCLI.Request(entries: [.folder(f.root)]))
        var found: NSWindow?
        _ = await f.wait(4) {
            found = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible && FolderSessions.session(for: $0)?.root.url == f.root }
            return found.flatMap { WindowTabs.model(for: $0) }?.folder != nil && found.flatMap { findTextView(in: $0.contentView) } != nil
        }
        guard let first = found, FolderSessions.session(for: first) != nil else {
            report(false, "a folder window opens for the sidebar checks"); return
        }
        defer {
            // Back to the one window the stages after this one count on.
            original.orderFront(nil)
            FrontEditor.shared.selfTestMain(original)
        }
        await settle(300)
        // What the strip and the sidebar show, they show by observation.
        WindowTabs.safetyNetEnabled = false
        defer { WindowTabs.safetyNetEnabled = true }

        await previewChecks(first, f)
        await edgeChecks(first, f)

        // Everything of the folder window closes; nothing is unsaved.
        for w in f.group(first) { w.performClose(nil) }
        let closed = await f.wait { f.openDocuments().isEmpty && !NSApp.windows.contains { $0.isVisible && FolderSessions.session(for: $0)?.root.url == f.root } }
        report(closed, "the folder window's tabs all close, and no document of the folder is left open (\(f.openDocuments().count) left)")
    }

    /// The preview tab: one click shows a file in it, the next file takes
    /// it over, and each way of keeping it makes it a tab like any other.
    private static func previewChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        func isPreview(_ w: NSWindow?) -> Bool {
            guard let w, let tabs = WindowTabs.model(for: w) else { return false }
            return PreviewTabs.isPreview(w) && tabs.tabs.first { $0.id == w.windowNumber }?.preview == true
        }
        guard let tabs = WindowTabs.model(for: first), let ktv = findTextView(in: first.contentView) as? KiriTextView,
              let controller = ktv.delegate as? EditorController else { report(false, "the folder window's editor and tabs"); return }
        let untitled = f.document(first)
        let shownBefore = tabs.shown.count

        // One click after another: one tab, the same one.
        var sameTab = true, contentsShown = true, wasPreview = true, together = true
        for name in ["a.swift", "b.md", "c.json", "d.txt", "e.py"] {
            let shown = await f.open(name, from: first)
            together = together && f.atAnswer.map { $0.title == name && $0.text == f.onDisk(name) } ?? false
            sameTab = sameTab && shown === first && f.group(first).count == 1
            contentsShown = contentsShown && ktv.string == f.onDisk(name) && controller.document === f.document(first)
                && controller.model.language == Language.detect(fileName: name)
            wasPreview = wasPreview && isPreview(first)
        }
        report(sameTab && f.titles(first) == ["e.py"],
               "five files clicked one after another show in one tab, the window's first (\(f.group(first).count) tabs: \(f.strip(first)))")
        report(contentsShown, "each shows its own text, in its language (“\(ktv.string.prefix(12).replacingOccurrences(of: "\n", with: "⏎"))”, \(controller.model.language.name))")
        report(wasPreview, "the tab is a preview all the while, its title slanted (\(f.strip(first)))")
        report(together, "the tab's title and the text change in the same turn: never one file's name over another's text (\(f.atAnswer?.title ?? "nil"))")
        // The strip never had another tab, nor lost this one: only titles changed.
        let ids = Set(tabs.shown.dropFirst(max(shownBefore - 1, 0)).map { $0 })
        report(ids == [[first.windowNumber]], "the strip kept its one tab throughout: no tab closed or opened (\(tabs.shown.count - shownBefore) changes, all of the title)")
        let untitledGone = untitled.map { u in !NSDocumentController.shared.documents.contains { $0 === u } } ?? false
        report(untitledGone && f.openDocuments().count == 1,
               "the empty document the window began with is closed, and so is each file left behind (\(f.openDocuments().count) of the folder's files open)")
        // A file looked at before is read again: none was left open unseen.
        let again = await f.open("a.swift", from: first)
        report(again === first && ktv.string == f.onDisk("a.swift") && f.openDocuments().count == 1 && isPreview(first),
               "a file clicked a second time shows again (\(f.strip(first)))")

        // The window's bars outlive the file: find searches the file that
        // shows now, and Go to Line, which was a line of the other, closes.
        let find = controller.model.find, goToLine = controller.model.goToLine
        find.board = NSPasteboard.withUniqueName()
        find.show()
        find.query = "e"
        let foundInA = await f.wait { find.status == .found(current: nil, total: 1, more: false) || find.matches.count == 1 }
        _ = await f.open("h.txt", from: first)
        let foundInH = await f.wait { find.matches.count == 6 && ktv.marks.shownMatches == 6 }
        report(foundInA && foundInH && find.isOpen && find.label.contains("6"),
               "the find bar, open on one file, counts and marks its matches in the next file clicked (\(find.label), \(ktv.marks.shownMatches) marked)")
        find.close()
        ktv.setSelectedRange(NSRange(location: (ktv.string as NSString).length, length: 0))
        goToLine.open()
        goToLine.text = "3"
        let previewed = await f.wait { controller.model.line == 3 }
        _ = await f.open("a.swift", from: first)
        let goToLineClosed = !goToLine.isOpen
        goToLine.cancel() // Escape, late: nothing of the other file's to go back to
        report(previewed && goToLineClosed && ktv.selectedRange() == NSRange(location: 0, length: 0) && ktv.string == f.onDisk("a.swift"),
               "Go to Line, open on a line of one file, closes when the next file is clicked, and the caret is at its start (open: \(goToLine.isOpen), selection \(ktv.selectedRange()))")

        // Kept by an edit, in the tab that went from file to file; and the
        // menus act on the file it shows now.
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        ktv.insertText("// kept\n", replacementRange: ktv.selectedRange())
        let keptAtOnce = !PreviewTabs.isPreview(first)
        await settle()
        let dirty = await f.wait { tabs.items.first?.dirty == true && tabs.items.first?.preview == false }
        report(keptAtOnce && dirty, "typing into a preview keeps it: a tab like any other, with its dot (\(f.strip(first)))")
        FrontEditor.shared.selfTestMain(first)
        if let main = NSApp.mainMenu, let menu = main.item(withTitle: "File")?.submenu {
            updateMenu(main)
            if let i = menu.items.firstIndex(where: { $0.title == "Save" }), menu.items[i].isEnabled {
                menu.performActionForItem(at: i)
            }
        }
        let saved = await f.wait { f.document(first)?.isDocumentEdited == false && tabs.items.first?.dirty == false }
        let others = SidebarFixture.contents.keys.filter { $0 != "a.swift" }
        report(saved && f.onDisk("a.swift") == "// kept\nlet a = 1\n" && others.allSatisfy { f.onDisk($0) == SidebarFixture.contents[$0] },
               "File ▸ Save writes the file the tab shows now, and no other (a.swift: “\(f.onDisk("a.swift").replacingOccurrences(of: "\n", with: "⏎"))”)")

        // With that tab kept, the next file gets a preview tab of its own,
        // after it, and the one after that takes the preview over.
        let second = await f.open("b.md", from: first)
        let third = await f.open("c.json", from: first)
        report(second != nil && second !== first && third === second && f.titles(first) == ["a.swift", "c.json"] && isPreview(second) && !isPreview(first),
               "with the first tab kept, the next file opens a preview tab after it and the one after reuses that (\(f.strip(first)))")
        guard let second else { return }

        // A file that is open in a tab of its own is selected, and the preview stays.
        let back = await f.open("a.swift", from: second)
        report(back === first && first.tabGroup?.selectedWindow === first && f.group(first).count == 2 && isPreview(second),
               "a file that is open in a tab of its own is selected, not opened again (\(f.strip(first)))")

        // Kept by a save.
        f.document(second)?.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        let keptBySave = await f.wait { !isPreview(second) && WindowTabs.model(for: first)?.tabs.last?.preview == false }
        report(keptBySave && f.onDisk("c.json") == SidebarFixture.contents["c.json"], "saving a preview keeps it (\(f.strip(first)))")

        // Kept by a double-click on the tab.
        let fourth = await f.open("d.txt", from: first)
        let previewBefore = isPreview(fourth)
        if let fourth { WindowTabs.model(for: fourth)?.keep(fourth.windowNumber) }
        let keptByTab = await f.wait { fourth.map { !isPreview($0) } ?? false }
        report(previewBefore && keptByTab && f.titles(first) == ["a.swift", "d.txt", "c.json"],
               "a double-click on a preview's tab keeps it; it opened after the tab it was picked in (\(f.strip(first)))")

        // Kept by a double-click on the row: the click shows it, the second keeps it.
        let fifth = await f.open("e.py", from: first)
        let previewFirst = isPreview(fifth)
        let fifthAgain = await f.open("e.py", keep: true, from: first)
        report(previewFirst && fifthAgain === fifth && fifth.map { !isPreview($0) } ?? false && f.group(first).count == 4,
               "a double-click on a file's row keeps its tab (\(f.strip(first)))")

        // Return on a row: open to stay, the keyboard in the file's editor.
        let sixth = await f.open("sub/f.rs", keep: true, from: first, keyboard: .editor)
        let inEditor = await f.wait { sixth.map { $0.firstResponder is KiriTextView && $0.tabGroup?.selectedWindow === $0 } ?? false }
        report(sixth != nil && !isPreview(sixth) && inEditor && f.group(first).count == 5,
               "Return on a row opens the file to stay and puts the keyboard in its editor (\(f.strip(first)))")

        // Space on a row: the preview, with the keyboard still in the sidebar
        // (here in the sidebar of the new tab the preview is).
        let seventh = await f.open("g.txt", from: first, keyboard: .sidebar)
        let inSidebar = await f.wait { seventh.flatMap { FrontEditor.shared.editor(in: $0) }?.sidebarHasFocus == true }
        report(seventh != nil && isPreview(seventh) && inSidebar && f.group(first).count == 6,
               "Space on a row shows the file in a preview tab and leaves the keyboard in the sidebar (\(f.strip(first)))")
        report(f.openDocuments().count == f.group(first).count, "every open document of the folder has its tab (\(f.openDocuments().count) documents, \(f.group(first).count) tabs)")

        // What VoiceOver hears of a preview tab.
        if let seventh, seventh.occlusionState.contains(.visible) {
            await wakeAccessibility()
            let tab = accessibilityElements(of: seventh).first { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "g.txt" && $0.value == "Preview" }
            report(tab != nil && tab?.actions.contains("Keep Open") == true,
                   "VoiceOver hears the preview tab as “g.txt, Preview”, with a Keep Open action (\(tab?.actions ?? []))")
        } else {
            print("SELFTEST SKIP what VoiceOver hears of a preview tab (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }

        // A double-click on a file that isn't open: its two clicks come
        // before the first has been answered. One document, shown once,
        // kept, and still watching its file.
        var firstClick: NSWindow?? = nil
        let tabsBefore = f.group(first).count
        SidebarOpen.open(f.file("i.txt"), keep: false, from: first) { firstClick = .some($0) }
        let answeredAtOnce = firstClick != nil
        let both = await f.open("i.txt", keep: true, from: first)
        let iDocuments = f.openDocuments().filter { $0.fileURL?.standardizedFileURL == f.file("i.txt") }
        let watching = iDocuments.first.map { d in NSFileCoordinator.filePresenters.contains { $0 === d } } ?? false
        report(both != nil && !isPreview(both) && both.map { f.text($0) } == f.onDisk("i.txt") && iDocuments.count == 1 && watching
               && f.group(first).count == tabsBefore && f.openDocuments().count == f.group(first).count,
               "a double-click on a file that isn't open shows it once, to stay, in the preview's tab (\(f.strip(first)); \(iDocuments.count) document, watching its file: \(watching), first click answered \(answeredAtOnce ? "at once" : "later"))")
    }

    /// The edge between the sidebar and the editor: what a drag, a
    /// double-click and VoiceOver's steps do to the width (by what the
    /// gestures call: no pointer is moved), that every tab has it, that it
    /// is remembered without the person's preferences being written, and
    /// that a narrow window keeps the editor its minimum.
    private static func edgeChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        let store = SidebarWidth.shared
        guard let shown = first.tabGroup?.selectedWindow, let other = f.group(first).first(where: { $0 !== shown }) else {
            report(false, "two tabs for the sidebar's edge checks"); return
        }
        let saved = { UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Prefs.sidebarWidthKey] as? NSObject }
        let savedBefore = saved(), given = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Prefs.sidebarWidthKey] as? String
        defer {
            // As the launch found it.
            setArgument(Prefs.sidebarWidthKey, given)
            store.set(SidebarWidth.remembered)
        }
        let drawn = shown.occlusionState.contains(.visible)
        let row = Double(shown.frame.width) - 2 * Honey.gap
        func widest(_ w: NSWindow) -> Double { SidebarLayout.widest(in: Double(w.frame.width) - 2 * Honey.gap, gap: Honey.gap) }
        /// The sidebar's width as `w` lays it out: what is left of the editor's panel.
        func laidOut(_ w: NSWindow) -> Double? {
            guard let panel = findTextView(in: w.contentView)?.enclosingScrollView?.superview else { return nil }
            return Double(panel.convert(panel.bounds, to: nil).minX) - 2 * Honey.gap
        }
        func shows(_ width: Double, in w: NSWindow) async -> Bool {
            await f.wait(drawn ? 2 : 0) { laidOut(w).map { abs($0 - width) < 0.6 } ?? false }
        }

        store.reset()
        let atDefault = store.preferred == SidebarLayout.defaultWidth
        let defaultShown = await shows(SidebarLayout.defaultWidth, in: shown)
        // A drag of 70 pt to the right, then let go.
        store.set(SidebarLayout.dragged(from: store.preferred, by: 70, widest: widest(shown)))
        let dragged = store.preferred == 300
        let draggedShown = await shows(300, in: shown)
        let unsavedYet = SidebarWidth.remembered == SidebarLayout.defaultWidth
        store.save()
        report(atDefault && dragged && unsavedYet, "the sidebar's edge dragged 70 pt makes it 300 pt wide, from the default 230 (\(store.preferred))")
        if drawn {
            report(defaultShown && draggedShown, "the window lays the sidebar out at that width, and the editor takes the rest (\(laidOut(shown) ?? -1) pt)")
        } else {
            print("SELFTEST SKIP the window lays the sidebar out at the dragged width (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        // Remembered: what the next launch, and the next window, begin with.
        report(SidebarWidth.remembered == 300 && SidebarWidth().preferred == 300 && saved() == savedBefore,
               "the width is remembered for the next window and launch, and a test launch leaves the saved preferences as they were (remembered \(SidebarWidth.remembered), saved \(saved().map { "\($0)" } ?? "none"))")
        // The limits, and the narrow window.
        store.set(SidebarLayout.dragged(from: store.preferred, by: -1000, widest: widest(shown)))
        let narrowest = store.preferred
        store.set(SidebarLayout.dragged(from: store.preferred, by: 1000, widest: widest(shown)))
        report(narrowest == 180 && store.preferred == 400 && row >= 630, "the edge stops at 180 pt and at 400 pt (\(narrowest), \(store.preferred))")
        if drawn {
            let frame = shown.frame, minimum = shown.contentMinSize.width
            shown.setFrame(NSRect(x: frame.minX, y: frame.minY, width: minimum, height: frame.height), display: true)
            let squeezed = await shows(230, in: shown)
            let editor = findTextView(in: shown.contentView)?.enclosingScrollView?.superview?.frame.width ?? 0
            shown.setFrame(frame, display: true)
            let back = await shows(400, in: shown)
            report(minimum == SidebarLayout.narrowestWindow && squeezed && editor >= SidebarLayout.editorMinimum && back && store.preferred == 400,
                   "a window at its narrowest (\(minimum) pt) shows less of a 400 pt sidebar so the editor keeps its minimum, and all of it again when widened (editor \(editor) pt)")
        } else {
            print("SELFTEST SKIP a window at its narrowest keeps the editor its minimum beside a wide sidebar (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        // Every tab is a window with a sidebar of its own: all have the width.
        store.set(320)
        f.select(other)
        let otherShows = await shows(320, in: other)
        f.select(shown)
        if drawn && other.occlusionState.contains(.visible) || otherShows {
            report(otherShows, "another tab of the window has the same width (\(laidOut(other) ?? -1) pt)")
        } else {
            print("SELFTEST SKIP another tab of the window has the same width (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        // What VoiceOver is given: a slider, which it can step.
        if drawn {
            _ = await shows(320, in: shown)
            await wakeAccessibility()
            let edge = accessibilityElements(of: shown).first { $0.name == "Sidebar width" }
            let value = edge?.value ?? ""
            edge?.increment()
            let stepped = await f.wait(1) { store.preferred == 330 }
            report(edge?.role == NSAccessibility.Role.slider.rawValue && value == "320 points" && stepped && edge?.actions.contains("Default Width") == true
                   && (edge?.frame.width ?? 0) == Honey.gap,
                   "VoiceOver has the edge as a slider, “Sidebar width, \(value)”, 10 pt wide between the panels, and a step makes it \(store.preferred) (role \(edge?.role ?? "none"), actions \(edge?.actions ?? []))")
        } else {
            print("SELFTEST SKIP what VoiceOver is given for the sidebar's edge (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        // A double-click on the edge: the default, and nothing remembered.
        store.reset()
        report(store.preferred == SidebarLayout.defaultWidth && SidebarWidth.remembered == SidebarLayout.defaultWidth && saved() == savedBefore,
               "a double-click on the edge gives the default width back (\(store.preferred))")
    }
}

/// The folder `sidebarStage` works in, and what it asks of its windows.
@MainActor private final class SidebarFixture {
    let root: URL
    private let clock = ContinuousClock()
    /// The tab's title and the editor's text when the last `open` was answered.
    private(set) var atAnswer: (title: String, text: String)?

    static let contents = ["a.swift": "let a = 1\n", "b.md": "# B\n", "c.json": "{\"c\": 3}\n", "d.txt": "d\n", "e.py": "e = 5\n",
                           "g.txt": "g\n", "h.txt": "one\ntwo e\nthree e e\n", "i.txt": "i\n", "sub/f.rs": "fn f() {}\n"]

    init(root: URL) { self.root = root.standardizedFileURL }

    func write() {
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for (name, text) in Self.contents { try? text.write(to: file(name), atomically: true, encoding: .utf8) }
    }

    func file(_ name: String) -> URL { root.appendingPathComponent(name).standardizedFileURL }
    func onDisk(_ name: String) -> String { (try? String(contentsOf: file(name), encoding: .utf8)) ?? "<unreadable>" }

    func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
        let start = clock.now
        while clock.now - start < .seconds(seconds) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    /// Brings a tab forward, as a click on it in the strip does.
    func select(_ w: NSWindow) {
        w.tabGroup?.selectedWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    func document(_ w: NSWindow) -> KiriDocument? { NSDocumentController.shared.document(for: w) as? KiriDocument }
    func group(_ w: NSWindow) -> [NSWindow] { w.tabbedWindows ?? [w] }
    func titles(_ w: NSWindow) -> [String] { group(w).map { document($0)?.displayName ?? "?" } }
    func text(_ w: NSWindow) -> String { SelfTest.findTextView(in: w.contentView)?.string ?? "<no editor>" }

    /// The strip's items, as the window's own tab model has them.
    func strip(_ w: NSWindow) -> String {
        // (Of the tab that shows: the others' strips are not watching.)
        (WindowTabs.model(for: w.tabGroup?.selectedWindow ?? w)?.tabs ?? []).map { $0.title + ($0.preview ? " (preview)" : "") + ($0.dirty ? " •" : "") }
            .joined(separator: ", ")
    }

    /// The documents of the test's folder that are open, with or without a window.
    func openDocuments() -> [NSDocument] {
        NSDocumentController.shared.documents.filter { $0.fileURL?.path.hasPrefix(root.path) ?? false }
    }

    /// What a click on the file's row does (and a double-click, with
    /// `keep`); answers with the window the file shows in.
    func open(_ name: String, keep: Bool = false, from w: NSWindow, keyboard: SidebarOpen.Keyboard = .stays) async -> NSWindow? {
        let shown: NSWindow? = await withCheckedContinuation { c in
            SidebarOpen.open(file(name), keep: keep, from: w, keyboard: keyboard) { shown in
                // In the turn the file is shown in: what the strip and the editor say.
                self.atAnswer = shown.map { s in
                    ((WindowTabs.model(for: s.tabGroup?.selectedWindow ?? s)?.tabs ?? []).first { $0.id == s.windowNumber }?.title ?? "", self.text(s))
                }
                c.resume(returning: shown)
            }
        }
        guard let shown else { return nil }
        // A new tab joins its group a turn later; its strip follows.
        _ = await wait { group(w).contains(shown) && shown.tabGroup?.selectedWindow === shown
            && document(shown)?.fileURL?.standardizedFileURL == file(name) && text(shown) == onDisk(name) }
        await SelfTest.settle()
        return shown
    }
}
#endif
