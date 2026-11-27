#if DEBUG || KIRI_SELFTEST
// swiftlint:disable force_unwrapping - in a self-test a nil is a failed test, and the crash says where
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

        await focusChecks(first, f)
        await previewChecks(first, f)
        // The rows' icons: a symbol this macOS has for every language, and
        // the fixture's files told apart (the mapping and the tints'
        // contrast are KiriKit's `FileIconTests`).
        let icons = Language.all.map { FileIcon.of($0) } + [.document]
        let missing = Set(icons.map(\.symbol)).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        let told = Set(["a.swift", "b.md", "c.json", "d.txt", "e.py", "f.rs"].map { FileIcon.forFile(named: $0) })
        report(missing.isEmpty && told.count == 6,
               "every file icon is a symbol this macOS has, and the folder's files differ by shape or tint (\(Set(icons.map(\.symbol)).count) symbols, missing \(missing.sorted()); \(told.count) of 6 differ)")
        await markChecks(first, f)
        await edgeChecks(first, f)
        await menuChecks(first, f)
        await findChecks(first, f)

        // Everything of the folder window closes; nothing is unsaved.
        first.performClose(nil)
        let closed = await f.wait { f.openDocuments().isEmpty && !NSApp.windows.contains { $0.isVisible && FolderSessions.session(for: $0)?.root.url == f.root } }
        report(closed, "the folder window's tabs all close, and no document of the folder is left open (\(f.openDocuments().count) left)")
    }

    /// Where the keyboard is when a folder window opens, and when the
    /// sidebar shows that it has it: on the keyboard's row, in the key
    /// window only. (A background launch has no key window: the test says
    /// when the sidebar is to draw as in one.)
    private static func focusChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        guard let model = FrontEditor.shared.editor(in: first) else { report(false, "the folder window's editor for the focus checks"); return }
        // A folder alone: nothing to edit yet, and the files are a key away.
        let inSidebar = await f.wait(f.drawn(first) ? 2 : 0.3) { model.sidebarHasFocus }
        if inSidebar || f.drawn(first) {
            report(inSidebar && !model.sidebarShowsKeyboard,
                   "a folder window with no file open has the keyboard in its sidebar, which shows no ring while the window is not the key one (in the sidebar \(model.sidebarHasFocus), ring \(model.sidebarShowsKeyboard))")
        } else {
            print("SELFTEST SKIP where the keyboard is in a folder window with no file open (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        // As in the key window: the keyboard's row has the ring; back in the editor it has not.
        if inSidebar {
            FolderSidebar.drawsAsKey = true
            model.controller?.focus()
            let left = await f.wait(1) { !model.sidebarHasFocus && !model.sidebarShowsKeyboard }
            model.sidebarFocusRequest += 1
            let ringed = await f.wait(1) { model.sidebarHasFocus && model.sidebarShowsKeyboard }
            FolderSidebar.drawsAsKey = false
            report(left && ringed, "in the key window the sidebar shows the keyboard's row while it has the keyboard, and not once the editor has it (\(left), \(ringed))")
        }

        // A folder opened with a file: the keyboard is in the file's editor.
        let sub = f.file("sub")
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        KiriCLI.open(KiriCLI.Request(entries: [.folder(sub), .file(f.file("sub/f.rs"), line: 0, column: 0)]))
        var second: NSWindow?
        _ = await f.wait(4) {
            second = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible && f.document($0)?.fileURL?.standardizedFileURL == f.file("sub/f.rs") }
            return second.map { FolderSessions.session(for: $0)?.root.url == sub && findTextView(in: $0.contentView) != nil } ?? false
        }
        guard let second, let secondModel = FrontEditor.shared.editor(in: second) else { report(false, "a folder window opens with a file for the focus check"); return }
        await settle(400)
        report(second.firstResponder is KiriTextView && !secondModel.sidebarHasFocus && !secondModel.sidebarShowsKeyboard,
               "a folder window that opens with a file has the keyboard in the editor, not the sidebar (first responder \(second.firstResponder.map { "\(type(of: $0))" } ?? "nil"), sidebar \(secondModel.sidebarHasFocus))")
        second.performClose(nil)
        _ = await f.wait { !second.isVisible && f.openDocuments().isEmpty }
        first.makeKeyAndOrderFront(nil)
        FrontEditor.shared.selfTestMain(first)
    }

    /// The preview tab: one click shows a file in it, the next file takes
    /// it over, and each way of keeping it makes it a tab like any other.
    private static func previewChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        func isPreview(_ t: DocumentTab?) -> Bool {
            guard let t, let tabs = WindowTabs.model(for: first) else { return false }
            return PreviewTabs.isPreview(t) && tabs.tabs.first { $0.id == t.id }?.preview == true
        }
        guard let tabs = WindowTabs.model(for: first), let firstTab = tabs.selectedTab, let ktv = findTextView(in: first.contentView) as? KiriTextView,
              let controller = ktv.delegate as? EditorController, controller === firstTab.controller else {
            report(false, "the folder window's editor and tabs"); return
        }
        /// The folder's files that would be in Open Recent by now (a test
        /// launch leaves the real list alone and keeps its own record).
        let notedBefore = (NSDocumentController.shared as? KiriDocumentController)?.selfTestNoted.count ?? 0
        func recent() -> Set<String> {
            Set(((NSDocumentController.shared as? KiriDocumentController)?.selfTestNoted.dropFirst(notedBefore) ?? [])
                .filter { $0.path.hasPrefix(f.root.path) }.map(\.lastPathComponent))
        }
        let untitled = f.document(first)
        let shownBefore = tabs.shown.count

        // One click after another: one tab, the same one.
        var sameTab = true, contentsShown = true, wasPreview = true, together = true
        for name in ["a.swift", "b.md", "c.json", "d.txt", "e.py"] {
            let shown = await f.open(name, from: first)
            together = together && f.atAnswer.map { $0.title == name && $0.text == f.onDisk(name) } ?? false
            sameTab = sameTab && shown === firstTab && f.group(first).count == 1
            contentsShown = contentsShown && ktv.string == f.onDisk(name) && controller.document === f.document(first)
                && controller.model.language == Language.detect(fileName: name)
            wasPreview = wasPreview && isPreview(firstTab)
        }
        report(sameTab && f.titles(first) == ["e.py"],
               "five files clicked one after another show in one tab, the window's first (\(f.group(first).count) tabs: \(f.strip(first)))")
        report(contentsShown, "each shows its own text, in its language (“\(ktv.string.prefix(12).replacingOccurrences(of: "\n", with: "⏎"))”, \(controller.model.language.name))")
        report(wasPreview, "the tab is a preview all the while, its title slanted (\(f.strip(first)))")
        report(together, "the tab's title and the text change in the same turn: never one file's name over another's text (\(f.atAnswer?.title ?? "nil"))")
        // The strip never had another tab, nor lost this one: only titles changed.
        let ids = Set(tabs.shown.dropFirst(max(shownBefore - 1, 0)).map { $0 })
        report(ids == [[firstTab.id]], "the strip kept its one tab throughout: no tab closed or opened (\(tabs.shown.count - shownBefore) changes, all of the title)")
        let untitledGone = untitled.map { u in !NSDocumentController.shared.documents.contains { $0 === u } } ?? false
        report(untitledGone && f.openDocuments().count == 1,
               "the empty document the window began with is closed, and so is each file left behind (\(f.openDocuments().count) of the folder's files open)")
        // A file looked at before is read again: none was left open unseen.
        let again = await f.open("a.swift", from: first)
        report(again === firstTab && ktv.string == f.onDisk("a.swift") && f.openDocuments().count == 1 && isPreview(firstTab),
               "a file clicked a second time shows again (\(f.strip(first)))")
        // Looking is not opening: Open Recent is not a log of every file glanced at.
        report(recent().isEmpty, "files only looked at in the preview tab, and the ones it left behind, are not in Open Recent (\(recent().sorted()))")

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
        let palette = controller.model.palette
        goToLine.open()
        palette.text = ":3"
        let previewed = await f.wait { controller.model.line == 3 }
        // (a.swift comes back where it was when h.txt took its place: `FilePositions`.)
        let keptA = FilePositions.position(for: f.file("a.swift"))?.selection(in: LineIndex(f.onDisk("a.swift"))) ?? 0..<0
        _ = await f.open("a.swift", from: first)
        let goToLineClosed = !goToLine.isOpen && !palette.isOpen
        palette.cancel() // Escape, late: nothing of the other file's to go back to
        report(previewed && goToLineClosed && ktv.selectedRange() == NSRange(location: keptA.lowerBound, length: keptA.count)
               && ktv.string == f.onDisk("a.swift"),
               "Go to Line (the palette, on a line of one file) closes when the next file is clicked, and the caret is where that file was left, not on the line asked for in the other (open: \(goToLine.isOpen), selection \(ktv.selectedRange()), kept \(keptA))")

        // Kept by an edit, in the tab that went from file to file; and the
        // menus act on the file it shows now.
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        ktv.insertText("// kept\n", replacementRange: ktv.selectedRange())
        let keptAtOnce = !PreviewTabs.isPreview(firstTab)
        await settle()
        let dirty = await f.wait { tabs.items.first?.dirty == true && tabs.items.first?.preview == false }
        report(keptAtOnce && dirty, "typing into a preview keeps it: a tab like any other, with its dot (\(f.strip(first)))")
        report(recent() == ["a.swift"], "and a recent document from then on, the only one so far (\(recent().sorted()))")
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
        report(second != nil && second !== firstTab && third === second && f.titles(first) == ["a.swift", "c.json"] && isPreview(second) && !isPreview(firstTab),
               "with the first tab kept, the next file opens a preview tab after it and the one after reuses that (\(f.strip(first)))")
        guard let second else { return }

        // A file that is open in a tab of its own is selected, and the preview stays.
        let back = await f.open("a.swift", from: first)
        report(back === firstTab && tabs.selectedTab === firstTab && f.group(first).count == 2 && isPreview(second),
               "a file that is open in a tab of its own is selected, not opened again (\(f.strip(first)))")

        // Kept by a save.
        second.document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        let keptBySave = await f.wait { !isPreview(second) && WindowTabs.model(for: first)?.tabs.last?.preview == false }
        report(keptBySave && f.onDisk("c.json") == SidebarFixture.contents["c.json"], "saving a preview keeps it (\(f.strip(first)))")

        // Kept by a double-click on the tab.
        let fourth = await f.open("d.txt", from: first)
        let previewBefore = isPreview(fourth)
        if let fourth { tabs.keep(fourth.id) }
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
        let inEditor = await f.wait { sixth.map { first.firstResponder === $0.container.textView && tabs.selectedTab === $0 } ?? false }
        report(sixth != nil && !isPreview(sixth) && inEditor && f.group(first).count == 5,
               "Return on a row opens the file to stay and puts the keyboard in its editor (\(f.strip(first)))")

        // Space on a row: the preview, with the keyboard still in the sidebar.
        let seventh = await f.open("g.txt", from: first, keyboard: .sidebar)
        let inSidebar = await f.wait { seventh?.model.sidebarHasFocus == true }
        // Kept one way or another, each is in Open Recent; the files
        // that were only looked at on the way (b.md, g.txt) are not.
        report(recent() == ["a.swift", "c.json", "d.txt", "e.py", "f.rs"],
               "a file is a recent document once it is kept: by an edit, a save, a double-click on its tab or its row, or Return (\(recent().sorted()))")
        report(seventh != nil && isPreview(seventh) && inSidebar && f.group(first).count == 6,
               "Space on a row shows the file in a preview tab and leaves the keyboard in the sidebar (\(f.strip(first)))")
        report(f.openDocuments().count == f.group(first).count, "every open document of the folder has its tab (\(f.openDocuments().count) documents, \(f.group(first).count) tabs)")

        // What VoiceOver hears of a preview tab.
        if seventh != nil, f.drawn(first) {
            await wakeAccessibility()
            let tab = accessibilityElements(of: first).first { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "g.txt" && $0.value == "Preview" }
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

        // A file showing in the preview that is then opened by name (⌘O,
        // Open Recent, `kiri`, a drop) is there to stay.
        let byName = await f.open("h.txt", from: first)
        let wasPreviewed = isPreview(byName)
        let tabsThen = f.group(first).count
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            KiriCLI.open(KiriCLI.Request(entries: [.file(f.file("h.txt"), line: 0, column: 0)])) { c.resume() }
        }
        let keptByName = await f.wait { byName.map { !PreviewTabs.isPreview($0) && tabs.tabs.contains { $0.title == "h.txt" && !$0.preview } } ?? false }
        report(wasPreviewed && keptByName && f.group(first).count == tabsThen && byName.map { tabs.selectedTab === $0 } == true,
               "a file in the preview tab that is opened by name stays: the same tab, no longer a preview (\(f.strip(first)))")
        report(recent().contains("h.txt") && recent().contains("i.txt") && !recent().contains("g.txt") && !recent().contains("b.md"),
               "and is a recent document, as the file a double-click opened is; g.txt and b.md, only looked at, are not (\(recent().sorted()))")
    }

    /// The marks on rows: which files are open in a tab, which is the
    /// preview and which have unsaved changes, following the tabs without
    /// the safety net (it is off for this stage).
    private static func markChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        /// The marks the sidebar of the tab that shows draws from.
        func marks() -> [URL: WindowTabs.FileMark] {
            WindowTabs.model(for: first)?.openFiles ?? [:]
        }
        func says(_ m: WindowTabs.FileMark?) -> String { m.map { $0.preview ? "preview" : $0.edited ? "open, edited" : "open" } ?? "not open" }
        let kept = f.group(first).compactMap { $0.document.fileURL?.standardizedFileURL }
        let before = marks()
        report(Set(before.keys) == Set(kept) && before.values.allSatisfy { !$0.edited && !$0.preview } && before[f.file("b.md")] == nil,
               "the sidebar marks the files open in the window's tabs, and no other (\(before.count) of \(kept.count) tabs; b.md \(says(before[f.file("b.md")])))")
        // A click: the preview. An edit: unsaved. A save: open. Closed: no mark.
        guard let g = await f.open("g.txt", from: first) else {
            report(false, "g.txt opens for the marks"); return
        }
        let asPreview = await f.wait { marks()[f.file("g.txt")] == .init(edited: false, preview: true) }
        let ktv = g.container.textView
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        ktv.insertText("x", replacementRange: ktv.selectedRange())
        await settle()
        let asEdited = await f.wait { marks()[f.file("g.txt")] == .init(edited: true, preview: false) }
        // What VoiceOver hears on the rows, and that the current one is the selected one.
        var heard: Bool?, rows = ""
        if f.drawn(first) {
            await wakeAccessibility()
            let all = accessibilityElements(of: first).filter { $0.role == NSAccessibility.Role.button.rawValue }
            // (Below the top bar: the tabs have the files' names too.)
            let row = { (name: String) in all.first { $0.name == name && $0.frame.maxY < first.frame.maxY - 60 } }
            // (sub is open: f.rs, inside it, was shown from the sidebar earlier, but by its path. Open it here.)
            if let session = FolderSessions.session(for: first), !session.expanded.contains(f.file("sub")) {
                all.first { $0.name == "sub, folder" }?.press()
                _ = await f.wait(1) { session.expanded.contains(f.file("sub")) }
                await settle(150)
            }
            let after = accessibilityElements(of: first).filter { $0.role == NSAccessibility.Role.button.rawValue && $0.frame.maxY < first.frame.maxY - 60 }
            let deep = { (name: String) in after.first { $0.name == name } }
            rows = ["g.txt", "a.swift", "b.md"].map { "\($0): “\(row($0)?.value ?? "none")”" }.joined(separator: ", ")
                + ", sub: “\(deep("sub, folder")?.value ?? "none")”, f.rs in it: “\(deep("f.rs")?.value ?? "none")”"
            heard = row("g.txt")?.value == "Open, edited" && row("g.txt")?.selected == true && row("a.swift")?.value == "Open"
                && row("a.swift")?.selected == false && row("b.md")?.value.isEmpty == true
                && all.first { $0.name == "sub, folder" }?.value == "collapsed" && deep("sub, folder")?.value == "expanded"
                && deep("f.rs")?.value == "Open, level 2"
        }
        g.document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        let asSaved = await f.wait { marks()[f.file("g.txt")] == .init(edited: false, preview: false) }
        try? "g\n".write(to: f.file("g.txt"), atomically: true, encoding: .utf8)
        WindowTabs.model(for: first)?.close(g.id)
        let asClosed = await f.wait { marks()[f.file("g.txt")] == nil && marks().count == kept.count }
        report(asPreview && asEdited && asSaved && asClosed,
               "a row's mark follows its tab: the preview when clicked, unsaved once typed in, open when saved, none when the tab closes (\(asPreview) \(asEdited) \(asSaved) \(asClosed))")
        if let heard {
            report(heard, "VoiceOver hears a row's state as its value (a folder collapsed or expanded, a file in a folder its level), and the current file as selected (\(rows))")
        } else {
            print("SELFTEST SKIP what VoiceOver hears of an open file's row (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
    }

    /// The rows' context menus: their items and when they are off, and
    /// what New File…, Rename…, the two Copy items and Open in New Window
    /// do. Everything made or renamed is in the test's own folder; Reveal
    /// in Finder is never chosen (a test launch would not show Finder
    /// anyway), and the paths are copied to a pasteboard of the test's.
    private static func menuChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        guard let session = FolderSessions.session(for: first), let shownTab = WindowTabs.model(for: first)?.selectedTab else {
            report(false, "the folder window's session for the menu checks"); return
        }
        typealias Menu = SidebarMenu
        let shown = first
        func groups(_ target: Menu.Target) -> [[SidebarMenuItem]] { Menu.groups(for: target, session: session, window: shown) }
        func titles(_ target: Menu.Target) -> [[String]] { groups(target).map { $0.map(\.title) } }
        func item(_ title: String, _ target: Menu.Target) -> SidebarMenuItem? { groups(target).joined().first { $0.title == title } }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: f.file(name).path) }
        func tab(of name: String) -> DocumentTab? {
            NSDocumentController.shared.document(for: f.file(name)).flatMap { DocumentWindow.tab(of: $0) }
        }
        let sub = f.file("sub")

        // What each menu has.
        let finder = [Menu.reveal, Menu.copyPath, Menu.copyRelativePath]
        let targets: [Menu.Target] = [.file(f.file("b.md")), .folder(sub), .root]
        let allOn = targets.allSatisfy { groups($0).joined().allSatisfy(\.enabled) }
        report(titles(targets[0]) == [[Menu.openToSide, Menu.openInNewWindow], finder, [Menu.rename]]
               && titles(targets[1]) == [[Menu.newFile], [Menu.openInNewWindow], finder]
               && titles(targets[2]) == [[Menu.newFile], [Menu.reveal, Menu.copyPath]] && allOn,
               "a file's menu has Open to the Side, Open in New Window, Reveal in Finder, Copy Path, Copy Relative Path and Rename…; a folder's has New File… and no Rename…; the empty area's is the folder's own (\(titles(targets[0]).joined().count), \(titles(targets[1]).joined().count) and \(titles(targets[2]).joined().count) items, all on)")
        // The menus the sidebar really shows are made of the same values;
        // AppKit asks the window for them as a right-click would, without
        // one being shown: on a file's row, a folder's, and the empty area.
        await wakeAccessibility()
        let elements = accessibilityElements(of: shown)
        /// The menu a right-click at `onScreen` would open, not opened.
        func menu(at onScreen: NSPoint) -> NSMenu? {
            guard let content = shown.contentView else { return nil }
            let inWindow = shown.convertPoint(fromScreen: onScreen)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                                                 windowNumber: shown.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
            var view = content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
            while let v = view {
                if let menu = v.menu(for: event) { return menu }
                view = v.superview
            }
            return nil
        }
        func shownTitles(_ menu: NSMenu?) -> [[String]] {
            (menu?.items ?? []).split(whereSeparator: \.isSeparatorItem).map { $0.map(\.title) }
        }
        let fileRow = elements.first { $0.name == "b.md" && $0.role == NSAccessibility.Role.button.rawValue }
        let folderRow = elements.first { $0.name == "sub, folder" }
        let panel = elements.first { $0.name == "Files in \(session.name)" }
        if let fileRow, let folderRow, let panel {
            let onFile = menu(at: NSPoint(x: fileRow.frame.midX, y: fileRow.frame.midY))
            let onFolder = menu(at: NSPoint(x: folderRow.frame.midX, y: folderRow.frame.midY))
            // Under the last row, where the panel is empty.
            let onEmpty = menu(at: NSPoint(x: panel.frame.midX, y: panel.frame.minY + 14))
            if onFile != nil || onFolder != nil || onEmpty != nil {
                let on = [onFile, onFolder, onEmpty].allSatisfy { $0?.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled } ?? false }
                report(shownTitles(onFile) == titles(targets[0]) && shownTitles(onFolder) == titles(targets[1]) && shownTitles(onEmpty) == titles(targets[2]) && on,
                       "a right-click on a file's row, a folder's row and the empty area is given those menus, their items on (\(shownTitles(onFile).joined().count), \(shownTitles(onFolder).joined().count) and \(shownTitles(onEmpty).joined().count) items: \(shownTitles(onEmpty)))")
            } else {
                print("SELFTEST info the rows' menus are not handed over without a real right-click: their items are checked as the values they are drawn from")
            }
        } else {
            print("SELFTEST info no rows to ask for their menus (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }

        // A folder that can't be written to: nothing to make or rename there.
        let locked = f.file("locked")
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try? "l\n".write(to: f.file("locked/l.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let lockedFile = Menu.Target.file(f.file("locked/l.txt")), lockedFolder = Menu.Target.folder(locked)
        let off = item(Menu.rename, lockedFile)?.enabled == false && item(Menu.newFile, lockedFolder)?.enabled == false
        let stillOn = [Menu.reveal, Menu.copyPath, Menu.openInNewWindow].allSatisfy { item($0, lockedFile)?.enabled == true && item($0, lockedFolder)?.enabled == true }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        report(off && stillOn, "in a folder that can't be written to, Rename… and New File… are off and the rest stay on")

        // The paths, on a pasteboard that is not the person's clipboard.
        let ownBoard = SidebarFiles.pasteboard.name != NSPasteboard.general.name
        item(Menu.copyPath, .file(f.file("sub/f.rs")))?.action()
        let path = SidebarFiles.pasteboard.string(forType: .string)
        item(Menu.copyRelativePath, .file(f.file("sub/f.rs")))?.action()
        let relative = SidebarFiles.pasteboard.string(forType: .string)
        report(ownBoard && path == f.file("sub/f.rs").path && relative == "sub/f.rs",
               "Copy Path copies the file's path and Copy Relative Path the path from the folder (“\(relative ?? "nil")”), in a test launch never to the clipboard (\(ownBoard))")

        // New File… on a folder: the folder opens with a field at its top;
        // the name is typed as keys (a space among them) and Return makes it.
        item(Menu.newFile, .folder(sub))?.action()
        let fieldUp = session.editing == .newFile(in: sub) && session.expanded.contains(sub)
        var typed = false
        if f.drawn(shown), await f.wait(1.5, until: { fieldEditor(of: shown) != nil }) {
            typed = await typeKeys("new note.md\r", in: shown)
        } else {
            session.commitEdit("new note.md")
        }
        let made = await f.wait { exists("sub/new note.md") && session.editing == nil }
        let madeTab = await f.wait { tab(of: "sub/new note.md").map { t in f.group(first).contains { $0 === t } && first.firstResponder === t.container.textView } ?? false }
        let newTab = tab(of: "sub/new note.md")
        report(fieldUp && made && madeTab && f.onDisk("sub/new note.md").isEmpty && newTab.map { !PreviewTabs.isPreview($0) } == true
               && session.cursor == f.file("sub/new note.md") && session.visibleRows().contains { $0.node.url == f.file("sub/new note.md") },
               "New File… on a folder asks for the name in place, makes the empty file there and opens it in a tab to stay, the keyboard in its editor (“new note.md”, \(typed ? "typed as keys, the space too" : "given without keys: the window is covered or the screen locked, and SwiftUI isn't showing the field"))")

        // New File… on the folder itself with the rows scrolled away from
        // the top: its field is there all the same, and takes the keyboard.
        // (The new file's tab is in front: back to the one before.)
        f.select(shownTab)
        _ = await f.wait(1) { WindowTabs.model(for: first)?.selectedTab === shownTab && shown.isVisible }
        let editor = FrontEditor.shared.editor(in: shown)
        if f.drawn(shown), let editor, let last = session.visibleRows().last?.node.url {
            let frame = shown.frame
            shown.setFrame(NSRect(x: frame.minX, y: frame.maxY - shown.contentMinSize.height, width: frame.width, height: shown.contentMinSize.height), display: true)
            editor.sidebarFocusRequest += 1
            _ = await f.wait(1) { editor.sidebarHasFocus }
            session.cursor = last
            await settle(300)
            item(Menu.newFile, .root)?.action()
            let rootField = await f.wait(1.5) { fieldEditor(of: shown) != nil }
            let escaped = rootField ? await typeKeys("\u{1b}", in: shown) : false
            let gone = await f.wait(1) { session.editing == nil }
            shown.setFrame(frame, display: true)
            report(rootField && escaped && gone, "with the rows scrolled to the end in a short window, New File… on the folder still shows its field, with the keyboard in it, and Escape gives it up (\(rootField), \(gone))")
            session.cancelEdit()
            editor.controller?.focus()
        } else {
            print("SELFTEST SKIP New File… on the folder with the rows scrolled away (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }

        // Names that can't be used: said, and nothing is made or written over.
        let aBefore = f.onDisk("a.swift")
        item(Menu.newFile, .root)?.action()
        session.commitEdit("a.swift")
        let taken = session.editing == .newFile(in: f.root) && session.editProblem != nil
        let takenSays = session.editProblem ?? ""
        session.commitEdit("x/y.txt")
        let slash = session.editing != nil && session.editProblem != nil
        session.cancelEdit()
        report(taken && slash && session.editing == nil && f.onDisk("a.swift") == aBefore && !exists("x"),
               "a name that is taken, or has a / in it, is refused with its reason and nothing is made or written over; Escape gives it up (“\(takenSays)”)")

        // Rename… on a file that is open with unsaved changes: the file
        // moves, its tab follows, and what was unsaved still is.
        if let eTab = tab(of: "e.py") {
            let eText = eTab.container.textView, eDocument = eTab.document
            f.select(eTab)
            eText.insertText("# unsaved\n", replacementRange: NSRange(location: 0, length: 0))
            await settle()
            _ = await f.wait { eDocument.isDocumentEdited }
            item(Menu.rename, .file(f.file("e.py")))?.action()
            let renaming = session.editing == .rename(f.file("e.py"))
            session.commitEdit("renamed.py")
            let moved = await f.wait { !exists("e.py") && exists("renamed.py") && eDocument.fileURL?.standardizedFileURL == f.file("renamed.py") && session.editing == nil }
            let model = { WindowTabs.model(for: first) }
            let followed = await f.wait {
                model()?.tabs.contains { $0.title == "renamed.py" && $0.dirty } == true && model()?.openFiles[f.file("renamed.py")]?.edited == true
                    && model()?.openFiles[f.file("e.py")] == nil
            }
            let unsaved = eDocument.isDocumentEdited && eText.string.hasPrefix("# unsaved\n") && f.onDisk("renamed.py") == SidebarFixture.contents["e.py"]
            report(renaming && moved && followed && unsaved && session.cursor == f.file("renamed.py"),
                   "Rename… on an open file with unsaved changes moves the file, its tab and its row follow, and the changes are still unsaved (\(f.strip(first)))")
            // Saved, it is the new name that is written (and the stage ends with nothing unsaved).
            eDocument.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            let savedThere = await f.wait { !eDocument.isDocumentEdited && f.onDisk("renamed.py").hasPrefix("# unsaved\n") }
            report(savedThere && !exists("e.py"), "a save after the rename writes the file under its new name")
        } else {
            report(false, "e.py is open in a tab for the rename check")
        }

        // Rename… on a file that isn't open; and never onto another file.
        let documents = f.openDocuments().count
        item(Menu.rename, .file(f.file("b.md")))?.action()
        session.commitEdit("a.swift")
        let kept = session.editProblem != nil && exists("b.md") && f.onDisk("a.swift") == aBefore
        session.commitEdit("notes.md")
        let renamed = await f.wait { exists("notes.md") && !exists("b.md") && session.editing == nil }
        report(kept && renamed && f.onDisk("notes.md") == SidebarFixture.contents["b.md"] && f.openDocuments().count == documents
               && session.visibleRows().contains { $0.node.url == f.file("notes.md") } && session.cursor == f.file("notes.md"),
               "Rename… on a file that isn't open renames it without opening it, and refuses another file's name")

        // Open in New Window: a file that is open in a tab moves out to a
        // window of its own, one that isn't opens in one; neither has the sidebar.
        let before = f.group(first).count
        let dTab = tab(of: "d.txt")
        item(Menu.openInNewWindow, .file(f.file("d.txt")))?.action()
        func alone(_ t: DocumentTab?) -> Bool {
            guard let t, let w = t.window else { return false }
            return w !== first && w.tabs.list.count == 1 && w.tabs.folder == nil && w.isVisible
        }
        let movedOut = await f.wait { alone(dTab) }
        item(Menu.openInNewWindow, .file(f.file("notes.md")))?.action()
        let opened = await f.wait { alone(tab(of: "notes.md")) }
        report(movedOut && opened && f.group(first).count == before - 1,
               "Open in New Window moves an open file's tab out to a window of its own and opens another file in one, both without the sidebar (\(f.group(first).count) tabs left of \(before))")
        for t in [dTab, tab(of: "notes.md")].compactMap({ $0 }) { t.window?.performClose(nil) }
        _ = await f.wait { tab(of: "d.txt") == nil && tab(of: "notes.md") == nil }
        // Back to the folder window, for what comes after.
        first.makeKeyAndOrderFront(nil)
        report(SidebarFiles.revealed.isEmpty, "nothing was shown in Finder (\(SidebarFiles.revealed.count))")
    }

    /// Find in the sidebar: ⌘F, ⌘G and ⇧⌘G are the sidebar's while it has
    /// the keyboard and the editor's when not; a match in a closed folder
    /// opens it; files and folders are found in the sidebar's order and
    /// round at both ends; Escape puts the row back, Return leaves the
    /// keyboard on the match. The keys go through the menu bar as a key
    /// press does where AppKit takes them; the field's own keys are typed
    /// where the window is drawn, and otherwise called as they call.
    private static func findChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        guard let session = FolderSessions.session(for: first), let editor = FrontEditor.shared.editor(in: first),
              let ktv = findTextView(in: first.contentView) else {
            report(false, "the folder window's session and editor for the find checks"); return
        }
        let find = session.find!
        // A folder of the check's own, closed, two deep; an empty folder in
        // one that is open (no file in it, so only its row can be found);
        // a file at the top. None of the fixture's names has "needle" in it.
        // And for "git": a `.git` file, as a worktree has (the tree never
        // shows it), and a file that will be gone after the folder is read.
        let made = ["nest/inner/a-needle.txt", "nest/inner/Needle.md", "nest/haystack.txt", "needle-root.txt",
                    "nest/.git", "nest/inner/.gitkeep", "vanish/a.git.txt"]
        for name in made {
            try? FileManager.default.createDirectory(at: f.file(name).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "\(name)\n".write(to: f.file(name), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.createDirectory(at: f.file("sub/needles"), withIntermediateDirectories: true)
        defer {
            for name in ["nest", "vanish", "needle-root.txt", "sub/needles"] { try? FileManager.default.removeItem(at: f.file(name)) }
            session.refresh()
        }
        if !session.expanded.contains(f.file("sub")), let sub = session.root.children.first(where: { $0.name == "sub" }) { session.toggle(sub) }
        session.refresh()
        editor.find.board = NSPasteboard.withUniqueName()
        FrontEditor.shared.selfTestMain(first)
        let top = session.visibleRows().first?.node.url
        let closedBefore = !session.expanded.contains(f.file("nest")) && !session.visibleRows().contains { $0.node.url == f.file("nest/inner/a-needle.txt") }

        /// The Edit ▸ Find item with that key, chosen (a test launch in the
        /// background has no key window for a key press to go to).
        func press(_ key: String, shift: Bool = false) async {
            guard let main = NSApp.mainMenu, let menu = main.item(withTitle: "Edit")?.submenu?.item(withTitle: "Find")?.submenu else {
                report(false, "the Edit ▸ Find menu"); return
            }
            updateMenu(main)
            let mods: NSEvent.ModifierFlags = shift ? [.shift, .command] : .command
            guard let i = menu.items.firstIndex(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == mods
            }) else { report(false, "an Edit ▸ Find item on \(shift ? "⇧" : "")⌘\(key.uppercased())"); return }
            menu.performActionForItem(at: i)
            await settle(120)
        }
        /// The sidebar has the keyboard: by ⇧⌘E where the window is drawn;
        /// otherwise SwiftUI moves no focus, and the model is told so.
        func giveSidebarTheKeyboard() async {
            if !editor.sidebarHasFocus { editor.sidebarFocusRequest += 1 }
            if !(await f.wait(f.drawn(first) ? 1.5 : 0.3) { editor.sidebarHasFocus }) { editor.sidebarHasFocus = true }
        }
        func at(_ name: String) -> Bool { session.cursor == f.file(name) }
        let drawn = f.drawn(first)
        // As in the key window, where the rows show the keyboard's ring.
        FolderSidebar.drawsAsKey = true
        defer { FolderSidebar.drawsAsKey = false }

        // ⌘F with the keyboard in the sidebar: its field, not the find bar.
        session.cursor = top
        await giveSidebarTheKeyboard()
        await press("f")
        let opened = await f.wait(1) { find.isOpen }
        let fieldHasKeys = drawn ? await f.wait(1.5) { find.fieldHasFocus && fieldEditor(of: first) != nil } : false
        report(opened && !editor.find.isOpen && closedBefore,
               "⌘F with the keyboard in the sidebar opens the sidebar's find field, not the editor's find bar (sidebar \(find.isOpen), find bar \(editor.find.isOpen))")
        if drawn {
            report(fieldHasKeys && editor.sidebarHasFocus, "the field has the keyboard, and the window still counts it as the sidebar's (\(find.fieldHasFocus), \(editor.sidebarHasFocus))")
        }

        // Typing: the first match at or after the row the find began on, in
        // a folder that was closed. The folder is read in the background.
        let textBefore = ktv.string
        if fieldHasKeys {
            await typeKeys("needle", in: first)
        } else {
            find.query = "needle"
        }
        let wanted = ["nest/inner/a-needle.txt", "nest/inner/Needle.md", "sub/needles", "needle-root.txt"]
        let all = await f.wait(4) { find.found.map(\.path) == wanted }
        let expanded = session.expanded.contains(f.file("nest")) && session.expanded.contains(f.file("nest/inner"))
        let shown = session.visibleRows().contains { $0.node.url == f.file("nest/inner/a-needle.txt") }
        report(find.query == "needle" && all && at("nest/inner/a-needle.txt") && expanded && shown && find.label == "1 of 4",
               "typing “needle” finds the files and the empty folder in the sidebar's order and goes to the first, in a closed folder that opens, two deep (\(find.found.map(\.path)), \(find.label), \(fieldHasKeys ? "typed as keys" : "given without keys"))")
        report(!editor.find.isOpen && ktv.string == textBefore && editor.find.query != "needle",
               "typing in the sidebar's field leaves the editor's find bar and the text alone")
        if drawn {
            report(editor.sidebarShowsKeyboard, "the match's row shows the keyboard's ring while the field is up")
        }

        // ⌘G and ⇧⌘G, round at both ends.
        var path: [String] = []
        for _ in 0..<4 {
            await press("g")
            path.append(session.cursor?.lastPathComponent ?? "nil")
        }
        let wrappedDown = at("nest/inner/a-needle.txt") && find.label == "1 of 4"
        await press("g", shift: true)
        let wrappedUp = at("needle-root.txt") && find.label == "4 of 4"
        report(path == ["Needle.md", "needles", "needle-root.txt", "a-needle.txt"] && wrappedDown && wrappedUp && !editor.find.isOpen,
               "⌘G goes to each match in turn and from the last round to the first, ⇧⌘G from the first round to the last (\(path), then \(session.cursor?.lastPathComponent ?? "nil"))")
        if fieldHasKeys {
            // ↑ and ↓ in the field.
            await typeKeys("\u{F701}", in: first) // ↓: round to the first again
            let down = at("nest/inner/a-needle.txt")
            await typeKeys("\u{F700}", in: first) // ↑
            report(down && at("needle-root.txt"), "↓ and ↑ in the field go to the next and previous match")
        }

        // A folder found by its name, from the index's paths; and nothing found.
        find.query = "inner"
        let folderFound = await f.wait(1) { find.found == [SidebarSearch.Entry(path: "nest/inner", isFolder: true)] && at("nest/inner") }
        find.query = "zzq-nothing"
        let nothing = find.found.isEmpty && find.label == "No matches" && at("nest/inner")
        report(folderFound && nothing, "a folder is found by its name, and a query that finds nothing says so and leaves the row where it is (\(find.label))")

        // What the tree never shows, or no longer has, is not gone to: the
        // `.git` file is not found, and the file deleted since the folder
        // was read is let go of when ⌘G comes to it, without opening its folder.
        try? FileManager.default.removeItem(at: f.file("vanish/a.git.txt"))
        find.query = "git"
        let gitFound = find.found.map(\.path)
        await press("g")
        report(gitFound == ["nest/inner/.gitkeep", "vanish/a.git.txt"] && at("nest/inner/.gitkeep") && find.found.map(\.path) == ["nest/inner/.gitkeep"]
               && find.label == "1 of 1" && !session.expanded.contains(f.file("vanish")),
               "a hidden .git file is never found, and a match deleted since the folder was read is passed over by ⌘G, its folder left closed (\(gitFound) → \(find.found.map(\.path)), \(find.label))")

        // Escape: the field closes and the row is the one before ⌘F.
        find.query = "needle"
        if fieldHasKeys, fieldEditor(of: first) != nil {
            await typeKeys("\u{1b}", in: first)
        } else {
            find.cancel()
        }
        let escaped = await f.wait(1) { !find.isOpen }
        let backInTree = drawn ? await f.wait(1.5) { editor.sidebarHasFocus && !find.fieldHasFocus && fieldEditor(of: first) == nil } : true
        report(escaped && session.cursor == top && backInTree,
               "Escape closes the field and puts the keyboard back on the row it was on before ⌘F (\(session.cursor?.lastPathComponent ?? "nil"))")

        // ⌘F again: the last query is there; Return leaves the keyboard on the match.
        await giveSidebarTheKeyboard()
        await press("f")
        let reopened = await f.wait(1) { find.isOpen && at("nest/inner/a-needle.txt") }
        await press("g")
        let typedAgain = drawn ? await f.wait(1.5) { fieldEditor(of: first) != nil } : false
        if typedAgain {
            await typeKeys("\r", in: first)
        } else {
            find.commit()
        }
        let returned = await f.wait(1) { !find.isOpen }
        let keysInTree = drawn ? await f.wait(1.5) { editor.sidebarHasFocus && !find.fieldHasFocus && fieldEditor(of: first) == nil } : true
        await settle(300)
        let stillHere = FrontEditor.shared.editor === editor && editor.sidebarHasFocus
        report(reopened && find.query == "needle" && returned && at("nest/inner/Needle.md") && keysInTree && stillHere,
               "⌘F again has the last query and goes to its first match; Return closes the field and leaves the keyboard on the match in the tree, opening nothing (\(session.cursor?.lastPathComponent ?? "nil"), \(f.strip(first)), same tab \(FrontEditor.shared.editor === editor), first responder \(first.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")

        // ⌘G in the tree, the field closed: the next match, and the keyboard stays.
        if !drawn { editor.sidebarHasFocus = true }
        await press("g")
        report(at("sub/needles") && !find.isOpen && editor.sidebarHasFocus && !editor.find.isOpen,
               "with the field closed, ⌘G in the sidebar goes to the next match of the last query and the field stays closed (\(session.cursor?.lastPathComponent ?? "nil"))")
        await press("g", shift: true)
        report(at("nest/inner/Needle.md") && !find.isOpen, "and ⇧⌘G to the one before")

        // With the keyboard in the editor, ⌘F is the editor's again.
        editor.controller?.focus()
        if !(await f.wait(1) { !editor.sidebarHasFocus }) { editor.sidebarHasFocus = false }
        await press("f")
        let editorFind = await f.wait(1) { editor.find.isOpen }
        report(editorFind && !find.isOpen, "with the keyboard in the editor, ⌘F opens the editor's find bar and not the sidebar's field")
        editor.find.close()
        _ = await f.wait(1) { !editor.find.isOpen }
    }

    /// The edge between the sidebar and the editor: what a drag, a
    /// double-click and VoiceOver's steps do to the width (by what the
    /// gestures call: no pointer is moved), that every tab has it, that it
    /// is remembered without the person's preferences being written, and
    /// that a narrow window keeps the editor its minimum.
    private static func edgeChecks(_ first: NSWindow, _ f: SidebarFixture) async {
        let store = SidebarWidth.shared
        guard let shownTab = WindowTabs.model(for: first)?.selectedTab, let other = f.group(first).first(where: { $0 !== shownTab }) else {
            report(false, "two tabs for the sidebar's edge checks"); return
        }
        let saved = { UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Prefs.sidebarWidthKey] as? NSObject }
        let savedBefore = saved(), given = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Prefs.sidebarWidthKey] as? String
        defer {
            // As the launch found it.
            setArgument(Prefs.sidebarWidthKey, given)
            store.set(SidebarWidth.remembered)
        }
        let shown = first
        // (The tab that showed before this one has just closed.)
        f.select(shownTab)
        let drawn = await f.wait(1) { f.drawn(shown) }
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
        // The window's one sidebar keeps its width from tab to tab.
        store.set(320)
        f.select(other)
        let otherShows = await shows(320, in: shown)
        f.select(shownTab)
        if drawn || otherShows {
            report(otherShows, "another tab of the window has the same width (\(laidOut(shown) ?? -1) pt)")
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
private final class SidebarFixture {
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

    /// Whether SwiftUI is drawing `w`: it stops while a window is covered,
    /// the display asleep or the screen locked, and what is read off the
    /// drawn window is then skipped. -KiriAssumeDrawn YES runs those
    /// checks anyway (they may then fail for that reason alone).
    func drawn(_ w: NSWindow) -> Bool {
        w.occlusionState.contains(.visible) || UserDefaults.standard.bool(forKey: "KiriAssumeDrawn")
    }

    /// Brings a tab forward, as a click on it in the strip does.
    func select(_ t: DocumentTab) {
        t.window?.tabs.select(t)
        t.window?.makeKeyAndOrderFront(nil)
    }

    /// The document of the tab `w` shows.
    func document(_ w: NSWindow) -> KiriDocument? { SelfTest.shownDocument(in: w) }
    func group(_ w: NSWindow) -> [DocumentTab] { (w as? DocumentNSWindow)?.tabs.list ?? [] }
    func titles(_ w: NSWindow) -> [String] { group(w).map(\.document.displayName) }
    func text(_ t: DocumentTab) -> String { t.container.textView.string }

    /// The strip's items, as the window's tab model has them.
    func strip(_ w: NSWindow) -> String {
        (WindowTabs.model(for: w)?.tabs ?? []).map { $0.title + ($0.preview ? " (preview)" : "") + ($0.dirty ? " •" : "") }
            .joined(separator: ", ")
    }

    /// The documents of the test's folder that are open, with or without a window.
    func openDocuments() -> [NSDocument] {
        NSDocumentController.shared.documents.filter { $0.fileURL?.path.hasPrefix(root.path) ?? false }
    }

    /// What a click on the file's row does (and a double-click, with
    /// `keep`); answers with the tab the file shows in.
    func open(_ name: String, keep: Bool = false, from w: NSWindow, keyboard: SidebarOpen.Keyboard = .stays) async -> DocumentTab? {
        let url = file(name)
        let shown: DocumentTab? = await withCheckedContinuation { c in
            SidebarOpen.open(url, keep: keep, from: w, keyboard: keyboard) { window in
                let tab = window.flatMap { _ in NSDocumentController.shared.document(for: url).flatMap { DocumentWindow.tab(of: $0) } }
                // In the turn the file is shown in: what the strip and the editor say.
                self.atAnswer = tab.map { t in
                    ((t.window?.tabs.tabs ?? []).first { $0.id == t.id }?.title ?? "", self.text(t))
                }
                c.resume(returning: tab)
            }
        }
        guard let shown else { return nil }
        _ = await wait { group(w).contains { $0 === shown } && shown.window?.tabs.selectedTab === shown
            && shown.document.fileURL?.standardizedFileURL == url && text(shown) == onDisk(name) }
        await SelfTest.settle()
        return shown
    }
}
#endif
