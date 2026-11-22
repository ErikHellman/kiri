#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit
import SwiftUI

extension SelfTest {
    /// Debug flags of the command palette, read when an editor comes up:
    /// -KiriPaletteTest YES runs `paletteStage` alone (it is part of
    /// -KiriBehaviorTest too); -KiriPalette <text> opens the palette with
    /// that typed, for a picture of the window ("" for nothing typed), and
    /// -KiriPaletteDown <n> then moves the selection down n rows;
    /// -KiriDumpPalette YES prints its rows; -KiriRenderPalette <folder>
    /// draws it offscreen in its states.
    static func paletteFlags(_ textView: NSTextView) -> Bool {
        let defaults = UserDefaults.standard
        if let folder = defaults.string(forKey: "KiriRenderPalette"), !renderedPalette {
            renderedPalette = true
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let renderer = ImageRenderer(content: PaletteSample.sheet(scheme))
                renderer.scale = 2
                let path = "\(folder)/palette-\(Honey.theme.id)-\(name).png"
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("SELFTEST rendered palette \(path)")
                }
            }
            fflush(stdout)
        }
        if defaults.string(forKey: "KiriPalette") != nil || defaults.bool(forKey: "KiriDumpPalette"), !shownPalette {
            shownPalette = true
            // (In the folder window, with -KiriOpenFolder: that one opens a little later.)
            let folder = defaults.string(forKey: "KiriOpenFolder") != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (folder ? 2.6 : 1.2)) {
                let front = folder ? NSApp.orderedWindows.first { $0.isVisible && FolderSessions.session(for: $0) != nil } : nil
                guard let window = front?.tabGroup?.selectedWindow ?? front ?? textView.window,
                      let palette = FrontEditor.shared.editor(in: window)?.palette else { return }
                // The menus are the front window's once SwiftUI has heard which that is.
                FrontEditor.shared.selfTestMain(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    palette.open(with: defaults.string(forKey: "KiriPalette") ?? "")
                    // (Once a folder's files are in.)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { palette.move(by: defaults.integer(forKey: "KiriPaletteDown")) }
                    guard defaults.bool(forKey: "KiriDumpPalette") else { return }
                    for row in palette.rows {
                        print("PALETTE \(row.symbol.padding(toLength: 10, withPad: " ", startingAt: 0)) \(row.title)  ·  \(row.detail)  ·  \(row.shortcut?.glyphs ?? "")  ·  “\(row.spoken)”")
                    }
                    print("PALETTE \(palette.rows.count) rows; announced “\(palette.lastAnnouncement)”")
                    fflush(stdout)
                    quit()
                }
            }
        }
        if defaults.bool(forKey: "KiriPaletteTest"), !startedPalette {
            startedPalette = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = textView.window else { report(false, "a window for the palette checks"); quit(); return }
                Task { @MainActor in
                    // (With the previews the palette shows: `ThemePreview`.)
                    await themePreviewStage(window)
                    await paletteStage(window)
                    reportStayedInTheBackground()
                    print("SELFTEST DONE palette")
                    fflush(stdout)
                    quit()
                }
            }
            return true
        }
        return false
    }

    private static var renderedPalette = false
    private static var shownPalette = false
    private static var startedPalette = false

    /// A key pressed with the keyboard in `window`, through the app's own
    /// event queue, as a pressed key comes (it reaches only this instance).
    private static func paletteKey(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    /// The command palette (`PaletteController`, shown by `CommandPalette`):
    /// ⌘K as a key opens and closes it, typing filters, Return runs a
    /// command with the keyboard back in the editor, and it is never open
    /// together with the find bar or Go to Line.
    ///
    /// What needs the field (typing, the arrows, Return and Escape as
    /// keys, what VoiceOver has) runs where SwiftUI is drawing the window;
    /// the rest goes through the controller, which is all the view calls.
    static func paletteStage(_ window: NSWindow) async {
        guard let main = NSApp.mainMenu, let view = main.item(withTitle: "View")?.submenu,
              let ktv = findTextView(in: window.contentView) as? KiriTextView,
              let controller = ktv.delegate as? EditorController else { report(false, "the View menu and the editor, for the palette checks"); return }
        let model = controller.model, palette = model.palette, find = model.find, goToLine = model.goToLine
        let clock = ContinuousClock()
        func wait(_ seconds: Double = 2, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        let drawn = window.occlusionState.contains(.visible) || UserDefaults.standard.bool(forKey: "KiriAssumeDrawn")
        func inField() -> Bool { fieldEditor(of: window) != nil }
        func skip(_ what: String) {
            print("SELFTEST SKIP \(what) (the window is covered or the screen locked: SwiftUI isn't drawing it)")
        }
        FrontEditor.shared.selfTestMain(window)
        window.makeFirstResponder(ktv)
        find.board = NSPasteboard.withUniqueName()
        find.close()
        palette.cancel()
        EditAction.selfTestTarget = ktv
        let original = ktv.string
        let preferences = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        await settle(250)
        updateMenu(main)

        // ⌘K, as a key: opens it with the keyboard in its field, and closes it.
        let item = view.item(withTitle: KiriCommands.paletteTitle)
        report(item?.isEnabled == true && item?.keyEquivalent == "k"
               && item?.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command,
               "View ▸ Command Palette… is on ⌘K (⌘\(item?.keyEquivalent ?? "none"))")
        paletteKey("k", code: 40, .command, in: window)
        let opened = await wait { palette.isOpen }
        let fielded = await wait(drawn ? 2 : 0.3) { inField() }
        if drawn {
            report(opened && fielded, "⌘K opens the palette with the keyboard in its field (open \(opened), in the field \(fielded): first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"), key window \(NSApp.keyWindow.map { "\($0.title)" } ?? "none"))")
        } else {
            report(opened, "⌘K opens the palette")
            skip("the keyboard in the palette's field")
        }
        paletteKey("k", code: 40, .command, in: window)
        let closed = await wait { !palette.isOpen }
        report(closed && window.firstResponder === ktv, "⌘K again closes it and the editor has the keyboard (first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")

        // What it lists with nothing typed: the menus' commands.
        palette.open()
        let rows = palette.rows
        func row(_ title: String) -> PaletteRow? { palette.rows.first { $0.title == title } }
        let save = row("Save")
        report(save?.shortcut?.glyphs == "⌘S" && save?.detail == "File" && save?.spoken == "Save, Command S"
               && row("Find…")?.detail == "Edit ▸ Find" && row("Toggle Comment")?.shortcut != nil,
               "it lists the menus' commands with their menu and key (\(rows.count) rows; Save: \(save?.detail ?? "missing") \(save?.shortcut?.glyphs ?? "no key"), “\(save?.spoken ?? "")”)")
        let titles = Set(rows.map(\.title))
        let unwanted = ["Hide Kiri", "Hide Others", "Show All", "Quit Kiri", "Clear Menu", "Tab 2", "sample.swift",
                        KiriCommands.paletteTitle, KiriCommands.goToFileTitle, "Start Dictation…", "Contact…", "Emoji & Symbols"].filter(titles.contains)
        report(unwanted.isEmpty && titles.count == rows.count && rows.count > 40,
               "without the app's own items, recent files, tabs, the window list, its own items or anything twice (\(unwanted), \(rows.count - titles.count) twice)")
        let theme = row("Theme: \(Honey.theme.name)"), language = row("Language: Swift"), endings = row("Line Endings: LF")
        if case .command(let t)? = theme?.action, case .command(let l)? = language?.action, case .command(let e)? = endings?.action {
            report(t.isOn && t.detail == "View ▸ Theme" && l.isOn && l.detail == "Format ▸ Language" && e.isOn
                   && row("Language: Rust") != nil && row("Appearance: Dark") != nil && row("Motion: Off") != nil,
                   "one choice of several reads “Theme: \(Honey.theme.name)”, “Language: Swift”, “Line Endings: LF”, the one in force checked (\(t.path), \(l.path), \(e.path))")
        } else {
            report(false, "one choice of several reads “Theme: \(Honey.theme.name)”, “Language: Swift”, “Line Endings: LF” (\(rows.filter { $0.title.contains(":") }.map(\.title).prefix(8)))")
        }
        let lost = rows.filter { r in
            guard case .command(let command) = r.action, let place = MenuCommands.find(command.path) else { return true }
            return place.menu.items[place.index].title != command.path.last
        }
        report(lost.isEmpty, "every row is found again in the menu bar by its path (\(lost.map(\.title)))")

        // Typing filters, best first, the letters marked; > is commands only.
        palette.text = "upper"
        report(palette.rows.first?.title == "Make Upper Case" && palette.rows.first?.titleMarks == [5..<10] && palette.selection == 0
               && palette.rows.count < rows.count,
               "typing filters: “upper” puts Make Upper Case first, its letters marked (\(palette.rows.prefix(3).map(\.title)), \(palette.rows.first?.titleMarks ?? []))")
        palette.text = ">tc"
        report(palette.mode == .commands && palette.query == "tc" && palette.rows.first?.title == "Toggle Comment"
               && palette.rows.first?.titleMarks == [0..<1, 7..<8],
               "> is commands only: “>tc” finds Toggle Comment by its words' first letters (\(palette.rows.prefix(3).map(\.title)))")
        palette.text = "zzqqxx"
        report(palette.rows.isEmpty && palette.emptyMessage?.contains("zzqqxx") == true && palette.lastAnnouncement.contains("zzqqxx"),
               "what matches nothing says so, kindly (“\(palette.emptyMessage ?? "")”)")
        palette.text = "sav"
        let first = palette.lastAnnouncement
        palette.move(by: 1)
        let second = palette.lastAnnouncement
        palette.move(by: -5)
        report(first.contains("results. Save, Command S") && second.contains(", 2 of \(palette.rows.count)") && palette.selection == 0,
               "VoiceOver is told how many results there are and the selected row as it changes (“\(first)”; “\(second)”)")
        palette.cancel()

        // Never open together with the find bar; and Go to Line is the
        // palette itself, with a colon, so never beside either.
        palette.open()
        find.show()
        let findAlone = find.isOpen && !palette.isOpen
        palette.open()
        let paletteAlone = palette.isOpen && !find.isOpen
        goToLine.open()
        let lineAlone = goToLine.isOpen && palette.isOpen && palette.mode == .line && !find.isOpen
        find.show()
        let findAgain = find.isOpen && !palette.isOpen && !goToLine.isOpen
        palette.open()
        report(findAlone && paletteAlone && lineAlone && findAgain && palette.isOpen && !goToLine.isOpen && !find.isOpen,
               "the palette, the find bar and Go to Line are never open together (\(findAlone), \(paletteAlone), \(lineAlone), \(findAgain))")
        palette.cancel()
        report(!palette.isOpen && window.firstResponder === ktv, "Escape closes it and the editor has the keyboard")

        // ⌘L, as a key: the palette with the colon typed. A line typed
        // there moves the caret, and Escape puts it back.
        let caret = NSRange(location: 3, length: 4)
        ktv.setSelectedRange(caret)
        paletteKey("l", code: 37, .command, in: window)
        let byL = await wait { palette.isOpen && goToLine.isOpen }
        let colon = palette.text == ":" && palette.mode == .line
        palette.text = ":12"
        let moved = model.line == 12 && palette.lineStatus?.text == "Go to line 12"
        palette.text = ":12:7"
        let column = model.line == 12 && model.column == 7
        palette.cancel()
        report(byL && colon && moved && column && ktv.selectedRange() == caret && !goToLine.isOpen && window.firstResponder === ktv,
               "⌘L opens the palette with a colon typed; :12 moves the caret there, :12:7 to its column, and Escape puts the selection back (\(byL), \(colon), \(moved), \(column), selection \(ktv.selectedRange()))")

        // Return on a command runs it with the keyboard in the editor:
        // Make Upper Case changes the document's word, not the field's.
        let ns = original as NSString
        let word = ns.range(of: "name")
        guard word.location != NSNotFound else { report(false, "the sample has the word the palette's command changes"); return }
        ktv.setSelectedRange(word)
        palette.open()
        let ready = await wait(drawn ? 2 : 0.3) { inField() }
        if ready {
            await typeKeys("case", in: window)
            let filtered = palette.rows.first?.title == "Make Upper Case" && palette.text == "case" && palette.rows.count > 1
            paletteKey("\u{F701}", code: 125, [.numericPad, .function], in: window)
            await settle(120)
            let down = palette.selection
            paletteKey("\u{F700}", code: 126, [.numericPad, .function], in: window)
            await settle(120)
            report(filtered && down == 1 && palette.selection == 0 && inField() && palette.text == "case",
                   "typed into the field: the list follows, and ↓ and ↑ move the selection while the keyboard stays in the field (\(palette.rows.prefix(2).map(\.title)), ↓ \(down), ↑ \(palette.selection))")
            await wakeAccessibility()
            let elements = accessibilityElements(of: window)
            let button = elements.first { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "Make Upper Case, Edit ▸ Transformations" }
            report(button != nil && button?.selected == true && (button?.frame.height ?? 0) >= 24,
                   "a row is a button VoiceOver can press, named with its menu or key, the selected one said to be (\(button.map { "\($0.name), selected \($0.selected), \($0.frame.height) pt" } ?? "not found"))")
            await typeKeys("\r", in: window)
        } else {
            if drawn { report(false, "the palette's field takes the keyboard (first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"))") }
            else { skip("typing, ↑, ↓ and Return in the palette's field, and its rows as VoiceOver has them") }
            palette.text = "upper"
            palette.commit()
        }
        let ran = await wait { ktv.string != original }
        let upper = (ktv.string as NSString).substring(with: word)
        report(ran && upper == "NAME" && !palette.isOpen && palette.selfTestRan?.responder === ktv && window.firstResponder === ktv,
               "Return runs the command with the keyboard back in the editor: Make Upper Case changes the document’s word (“\(upper)”; the keyboard was with \(palette.selfTestRan?.responder.map { "\(type(of: $0))" } ?? "nobody"))")
        await settle()
        ktv.undoManager?.undo()
        await settle()
        report(ktv.string == original, "and one undo takes it back")

        // Opened with something in the field, the caret is after it: what
        // is typed next is added, and doesn't take its place.
        palette.open(with: ">")
        if await wait(drawn ? 2 : 0.3, until: { inField() }) {
            _ = await wait(1) { fieldEditor(of: window)?.selectedRange() == NSRange(location: 1, length: 0) }
            await typeKeys("tc", in: window)
            report(palette.text == ">tc" && palette.rows.first?.title == "Toggle Comment",
                   "opened with a prefix, what is typed next is added to it (“\(palette.text)”)")
            await typeKeys("\u{1b}", in: window)
            report(!palette.isOpen && window.firstResponder === ktv && ktv.string == original, "Escape in the field closes it and runs nothing")
        } else if drawn {
            report(false, "the palette's field takes the keyboard when it opens with a prefix")
        } else {
            skip("typing after a prefix, and Escape in the palette's field")
        }
        palette.cancel()

        // A click on a row runs it too (what the row's button calls).
        ktv.setSelectedRange(word)
        palette.open(with: "capital")
        if let capitalize = palette.rows.first(where: { $0.title == "Capitalize" }) {
            palette.run(capitalize)
            let clicked = await wait { ktv.string != original }
            report(clicked && (ktv.string as NSString).substring(with: word) == "Name" && !palette.isOpen,
                   "a click on a row runs it (“\((ktv.string as NSString).substring(with: word))”)")
            await settle()
            ktv.undoManager?.undo()
            await settle()
        } else {
            report(false, "Capitalize is found by “capital” (\(palette.rows.prefix(3).map(\.title)))")
        }

        // A command that is off when its turn comes does nothing.
        palette.open(with: "toggle comment")
        let comment = palette.rows.first { $0.title == "Toggle Comment" }
        model.language = .plainText
        await settle(250)
        if let comment { palette.run(comment) }
        await settle(250)
        report(comment != nil && ktv.string == original, "a command that has gone off before it runs does nothing")
        model.language = .swift
        await settle(250)

        // With no document window in front the item is off.
        FrontEditor.shared.selfTestMain(NSWindow())
        await settle(250)
        updateMenu(main)
        let off = view.item(withTitle: KiriCommands.paletteTitle)?.isEnabled == false
        FrontEditor.shared.selfTestMain(window)
        await settle(250)
        updateMenu(main)
        report(off && view.item(withTitle: KiriCommands.paletteTitle)?.isEnabled == true,
               "with no document window in front, Command Palette… is off")

        // ⌘P, the key other editors find a file with, opens it too.
        let file = main.item(withTitle: "File")?.submenu?.item(withTitle: KiriCommands.goToFileTitle)
        paletteKey("p", code: 35, .command, in: window)
        let byP = await wait { palette.isOpen }
        report(byP && file?.keyEquivalent == "p" && file?.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command,
               "File ▸ Go to File… is on ⌘P and opens the palette")
        // A window without a folder lists no folder's files.
        RecentDocuments.shared.selfTestShow([])
        palette.open()
        func isFile(_ row: PaletteRow) -> Bool { if case .file = row.action { true } else { false } }
        let noneListed = !palette.rows.contains(where: isFile) && !palette.isReadingFolder
        palette.text = "swift"
        report(noneListed && !palette.rows.contains(where: isFile) && !palette.rows.isEmpty,
               "in a window without a folder there are no folder's files, only tabs, recent files and commands (\(palette.rows.prefix(2).map(\.title)))")
        palette.cancel()

        await paletteFiles(window)
        RecentDocuments.shared.refresh()
        FrontEditor.shared.selfTestMain(window)

        // Nothing here wrote a preference.
        let after = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        report(NSDictionary(dictionary: preferences).isEqual(to: after), "the palette's checks wrote no preference")
        palette.cancel()
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(ktv)
    }

    /// Files, tabs and recent files in the palette, in a folder window of
    /// the test's own on a folder it makes in the temporary directory.
    private static func paletteFiles(_ original: NSWindow) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-palette-test-\(getpid())").standardizedFileURL
        let root = dir.appendingPathComponent("project")
        let files = ["README.md": "# Project\n", "Makefile": "all:\n", "Sources/App/EditorScreen.swift": "struct EditorScreen {}\n",
                     "Sources/App/Greeter.swift": "struct Greeter {}\n", "Sources/Kit/Honey.swift": "enum Honey {}\n",
                     "Tests/GreeterTests.swift": "import Testing\n", "docs/notes/deep/idea.md": "An idea.\n",
                     ".git/config": "[core]\n", "node_modules/pkg/index.js": "x\n", "build/out.txt": "x\n", "DerivedData/x.txt": "x\n",
                     ".build/y.txt": "y\n"]
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }
        for (path, text) in files {
            try? FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url(path), atomically: true, encoding: .utf8)
        }
        let outside = dir.appendingPathComponent("elsewhere.txt")
        try? "elsewhere\n".write(to: outside, atomically: true, encoding: .utf8)
        let clock = ContinuousClock()
        func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        func document(_ w: NSWindow) -> URL? { NSDocumentController.shared.document(for: w)?.fileURL?.standardizedFileURL }

        // What is read of the folder: every file under it from the top
        // down, without what version control, package managers and
        // builds keep there; and no more than the limit.
        let read = FolderIndex.read(root)
        let wanted = ["Makefile", "README.md", "Tests/GreeterTests.swift", "Sources/App/EditorScreen.swift", "Sources/App/Greeter.swift",
                      "Sources/Kit/Honey.swift", "docs/notes/deep/idea.md"]
        report(read.map { Set($0.paths) } == Set(wanted) && read?.cut == false && read?.paths.prefix(2) == ["Makefile", "README.md"]
               && read?.paths.last == "docs/notes/deep/idea.md",
               "the folder's files are read from the top down, without .git, node_modules, .build, build and DerivedData (\(read?.paths ?? []))")
        let few = FolderIndex.read(root, limit: 3)
        report(few?.paths.count == 3 && few?.cut == true && FolderIndex.limit == 20_000 && FolderIndex.read(root, isCancelled: { true }) == nil,
               "no more than the limit is kept (3 of 3 asked for; \(FolderIndex.limit.formatted()) in use), and a reading can be given up")

        // The folder window, as `kiri <folder> <file>` opens it.
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        KiriCLI.open(KiriCLI.Request(entries: [.folder(root), .file(url("Sources/App/Greeter.swift"), line: 0, column: 0)]))
        var found: NSWindow?
        _ = await wait(4) {
            found = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible && document($0) == url("Sources/App/Greeter.swift") }
            return found.flatMap { FrontEditor.shared.editor(in: $0) }?.controller?.textView != nil && found.flatMap { FolderSessions.session(for: $0) } != nil
        }
        guard let first = found, let session = FolderSessions.session(for: first), let model = FrontEditor.shared.editor(in: first) else {
            report(false, "a folder window opens for the palette's file checks"); return
        }
        defer {
            for w in first.tabbedWindows ?? [first] { NSDocumentController.shared.document(for: w)?.close() }
            original.orderFront(nil)
        }
        await settle(300)
        FrontEditor.shared.selfTestMain(first)
        let palette = model.palette
        func isFile(_ row: PaletteRow, _ path: String) -> Bool { row.action == .file(url(path)) }

        // Typing never waits for the folder: the list is there at once,
        // and the files join it when they have been read.
        palette.open()
        let atOnce = (palette.isReadingFolder, palette.rows.count, session.index.paths.count)
        let indexed = await wait { session.index.paths.count == wanted.count && !palette.isReadingFolder }
        report(atOnce.0 && atOnce.1 > 40 && atOnce.2 == 0 && indexed,
               "the palette opens at once, the folder's files still being read (\(atOnce.1) rows, \(atOnce.2) files), and they are in soon after (\(session.index.paths.count))")

        // A file anywhere under the folder, by a few letters.
        palette.text = "hon"
        let honey = palette.rows.first
        report(honey.map { isFile($0, "Sources/Kit/Honey.swift") } == true && honey?.title == "Honey.swift" && honey?.detail == "Sources/Kit"
               && honey?.titleMarks == [0..<3] && honey?.symbol == FileIcon.forFile(named: "a.swift").symbol && honey?.tint == FileIcon.forFile(named: "a.swift").tint
               && honey?.spoken == "Honey.swift, Sources/Kit",
               "“hon” finds Sources/Kit/Honey.swift: its name with the letters marked, its folder after it, its kind's icon (\(honey.map { "\($0.title) · \($0.detail) \($0.titleMarks)" } ?? "nothing"))")
        palette.text = "kithon"
        let both = palette.rows.first
        report(both?.title == "Honey.swift" && both?.detailMarks == [8..<11] && both?.titleMarks == [0..<3],
               "letters of the folder and of the name are marked where they are (“kithon”: \(both?.detailMarks ?? []) in “\(both?.detail ?? "")”, \(both?.titleMarks ?? []) in “\(both?.title ?? "")”)")
        palette.text = "idea"
        report(palette.rows.first.map { isFile($0, "docs/notes/deep/idea.md") } == true && !palette.rows.contains { $0.title.contains("config") || $0.title == "index.js" },
               "a file three folders down is found, and nothing of .git or node_modules (\(palette.rows.prefix(2).map(\.title)))")

        // Return on a file opens it as a tab of this window, to stay.
        let noted = (NSDocumentController.shared as? KiriDocumentController)?.selfTestNoted.count ?? 0
        palette.commit()
        var ideaTab: NSWindow?
        let openedIdea = await wait {
            ideaTab = (first.tabbedWindows ?? []).first { document($0) == url("docs/notes/deep/idea.md") }
            return ideaTab.map { $0.tabGroup?.selectedWindow === $0 && $0.firstResponder is KiriTextView } ?? false
        }
        let recentNow = (NSDocumentController.shared as? KiriDocumentController)?.selfTestNoted.dropFirst(noted).map(\.lastPathComponent) ?? []
        report(openedIdea && !palette.isOpen && ideaTab.map { !PreviewTabs.isPreview($0) } == true && (first.tabbedWindows?.count ?? 1) == 2
               && recentNow.contains("idea.md"),
               "Return on a file opens it in a tab of this window, to stay, with the keyboard in its editor, and it is a recent document (\(first.tabbedWindows?.count ?? 1) tabs, recent: \(recentNow))")
        guard let ideaTab, let ideaModel = FrontEditor.shared.editor(in: ideaTab) else { return }
        await settle(300)
        FrontEditor.shared.selfTestMain(ideaTab)

        // With nothing typed: the other tabs, the recent files, then the
        // commands. A recent file that is in a tab is listed as the tab.
        RecentDocuments.shared.selfTestShow([outside, url("Sources/App/Greeter.swift"), url("README.md"), url("docs/notes/deep/idea.md")])
        let second = ideaModel.palette
        second.open()
        let top = second.rows.prefix(4)
        report(top.count == 4 && top[0].action == .tab(first.windowNumber) && top[0].title == "Greeter.swift" && top[0].detail == "Sources/App"
               && top[0].spoken == "Greeter.swift, tab, Sources/App" && top[1].action == .file(outside.standardizedFileURL)
               && top[2].action == .file(url("README.md")) && top[2].detail.isEmpty && { if case .command = top[3].action { true } else { false } }(),
               "with nothing typed: the other open tab, then the recent files (not the one in a tab, nor this window's own), then the commands (\(top.map { "\($0.title) · \($0.detail)" }))")
        // A file that is open in a tab and in the folder shows once, as the tab.
        second.text = "greeter"
        let greeters = second.rows.filter { $0.title == "Greeter.swift" }
        report(greeters.count == 1 && greeters.first?.action == .tab(first.windowNumber) && second.rows.contains { isFile($0, "Tests/GreeterTests.swift") }
               && second.rows.first?.title == "Greeter.swift",
               "a file that is open in a tab and in the folder shows once, as the tab, ahead of the files (\(second.rows.prefix(3).map { "\($0.title) · \($0.spoken)" }))")
        second.text = "readme"
        report(second.rows.filter { $0.title == "README.md" }.count == 1, "and a recent file that is in the folder shows once")
        // Return on a tab brings it forward.
        second.text = "greeter"
        second.commit()
        let selected = await wait { first.tabGroup?.selectedWindow === first }
        report(selected && !second.isOpen && (first.tabbedWindows?.count ?? 1) == 2, "Return on a tab brings that tab forward (\(first.tabbedWindows?.count ?? 1) tabs)")
        await settle(300)
        FrontEditor.shared.selfTestMain(first)

        // The folder is read again when the session refreshes, and an
        // open palette follows.
        palette.open(with: "zebra")
        _ = await wait(1) { !palette.isReadingFolder }
        let noZebra = !palette.rows.contains { $0.title == "Zebra.swift" }
        try? "enum Zebra {}\n".write(to: url("Sources/Kit/Zebra.swift"), atomically: true, encoding: .utf8)
        session.refresh()
        let zebra = await wait { palette.rows.first.map { isFile($0, "Sources/Kit/Zebra.swift") } == true }
        report(noZebra && zebra && palette.isOpen, "a file made since is found once the folder session has refreshed, in the palette that is open (\(palette.rows.prefix(1).map(\.title)))")
        palette.cancel()
    }
}

/// The palette in its states with no editor behind it, for
/// `-KiriRenderPalette`: over a strip of the editor's paper as wide as a
/// default window's editor, as the narrowest window's, and as the editor
/// beside the sidebar in the narrowest folder window.
enum PaletteSample {
    private static func command(_ title: String, _ detail: String, _ key: KeyboardShortcut? = nil, marks: [Range<Int>] = [],
                                on: Bool = false, choice: Bool = false) -> PaletteRow {
        PaletteRow(action: .command(MenuCommand(path: [detail, title], title: title, detail: detail, shortcut: key, isOn: on, isChoice: choice)),
                   symbol: on ? "checkmark" : choice ? "circle" : "command", title: title, titleMarks: marks, detail: detail, shortcut: key)
    }

    private static func file(_ path: String, marks: [Range<Int>] = [], tab: Int? = nil) -> PaletteRow {
        .file(tab.map { .tab($0) } ?? .file(URL(fileURLWithPath: "/" + path)), path: path, marks: marks, tab: tab != nil)
    }

    @MainActor static func sheet(_ scheme: ColorScheme) -> some View {
        let commands = [
            command("Save", "File", Keys.save, marks: [0..<1]),
            command("Save As…", "File", Keys.saveAs, marks: [0..<1]),
            command("Select All", "Edit", KeyboardShortcut("a", modifiers: .command), marks: [0..<1]),
            command("Shift Right", "Format", Keys.shiftRight, marks: [0..<1]),
            command("Theme: Sakura", "View ▸ Theme", marks: [7..<8], choice: true),
            command("Language: Swift", "Format ▸ Language", marks: [10..<11], on: true, choice: true),
            command("Wrap Lines", "View", Keys.wrapLines, marks: [9..<10], on: true),
            command("Use Selection for Find", "Edit ▸ Find", Keys.useSelectionForFind, marks: [0..<1]),
            command("Make Upper Case", "Edit ▸ Transformations", marks: [12..<13]),
        ]
        // Nothing typed: the other tabs, the recent files, then the commands.
        let resting = [
            file("Sources/Tidepool/Greeter.swift", tab: 1), file("README.md", tab: 2),
            PaletteRow(action: .tab(3), symbol: "rectangle.stack", title: "Untitled", detail: ""),
            file("~/Sources/kiri/docs/DESIGN.md"), file("~/Sources/tidepool/Package.swift"), file("~/.zshrc"),
            command("About Kiri", "Kiri"), command("Settings…", "Kiri", Keys.settings), command("New", "File", Keys.new),
        ]
        // "gre" typed in a folder window: files, a tab and commands, mixed.
        let mixed = [
            file("Sources/Tidepool/Greeter.swift", marks: [17..<20], tab: 1),
            file("Tests/TidepoolTests/GreeterTests.swift", marks: [20..<23]),
            file("Sources/Tidepool/Resources/greetings.json", marks: [26..<29]),
            file("docs/a/very/long/way/down/in/the/folders/of/this/project/agreement.md", marks: [57..<60]),
            command("Go to Line…", "Edit", Keys.goToLine, marks: [0..<1, 9..<10, 6..<7].sorted { $0.lowerBound < $1.lowerBound }),
            file("scripts/regenerate.sh", marks: [8..<9, 10..<11, 11..<12]),
            command("Find and Replace…", "Edit ▸ Find", Keys.findAndReplace, marks: [9..<10, 10..<11, 11..<12]),
        ]
        let states: [(String, PaletteController, Int)] = [
            (": and a line: where Return goes", .sample(text: ":42", rows: [], line: .init(text: "Go to line 42", isTarget: true)), 8),
            (": with a column", .sample(text: ":42:7", rows: [], line: .init(text: "Go to line 42, column 7", isTarget: true)), 8),
            (": alone (⌘L)", .sample(text: ":", rows: [], line: .init(text: "Type a line number, or line:column")), 8),
            (": and what is not a line", .sample(text: ":12b", rows: [], line: .init(text: "Not a line", isProblem: true)), 8),
            ("nothing typed: tabs, recent files, commands", .sample(text: "", rows: resting), 8),
            ("“gre” in a folder window: a tab, files and commands, the letters marked", .sample(text: "gre", rows: mixed, selection: 1), 8),
            ("> and a letter: commands with their keys, more than fit", .sample(text: ">s", rows: commands, selection: 5), 8),
            ("no match", .sample(text: "zzqq", rows: []), 8),
            ("a short window: three rows", .sample(text: ">s", rows: commands), 3),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            ForEach([860.0, 460.0, 220.0], id: \.self) { width in
                ForEach(states.indices, id: \.self) { i in
                    strip("\(states[i].0), \(Int(width)) pt", width: width) {
                        CommandPalette(palette: states[i].1, lineCount: 340, rowsThatFit: states[i].2)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.honeyCanvas)
        .environment(\.honeyOffscreen, true)
        .environment(\.colorScheme, scheme)
        .honeyRoot(HoneyAppearance())
    }

    @MainActor private static func strip(_ caption: String, width: CGFloat, @ViewBuilder bar: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).font(.system(size: 10)).foregroundStyle(Color.honeyMuted)
            bar()
                .padding(.top, EditorBar.topPadding)
                .padding(.bottom, EditorBar.clearance)
                .frame(width: width)
                .background(Color.honeySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
#endif
