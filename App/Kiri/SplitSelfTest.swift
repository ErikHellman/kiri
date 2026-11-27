#if DEBUG || KIRI_SELFTEST
// swiftlint:disable force_unwrapping - in a self-test a nil is a failed test, and the crash says where
import AppKit
import KiriKit
import WebKit

/// Side-by-side editing (`WindowTabs.panels`, `EditorPanels`):
/// `-KiriSplitTest YES`, in a launch with any small file. It makes a
/// folder of its own in the temporary directory and a folder window on
/// it, and checks every way into a split and out of it: View ▸ Split
/// Editor on ⌘\ and Close Split, the keyboard moving between the sides
/// (a click, ⌥⌘← ⌥⌘→, the tab beside clicked in the strip) and the top
/// bar and title with it, Swap Sides, Move Tab to Other Side, Open to the
/// Side from the sidebar (⌥-click, ⌥↩, its menu), from the strip and
/// from the palette (⌥↩, and Split Editor's Go to File with one tab), a
/// tab and a file dragged onto a half of the editors, ⌘W and the tab
/// beside closing, ⌃⇥ and ⌘1–9 passing over the tab beside, the preview
/// tab coming to the keyboard's side, a file that shows already, a
/// window too narrow growing, a tab moved out ending the split, the
/// split kept for the next launch, and Preview to the Side following the
/// text as it is typed.
extension SelfTest {
    private static var splitStarted = false

    /// Also, for pictures: `-KiriSplitWith <path>` opens that file to the
    /// side of the front window, `-KiriSplitPreviewShow YES` shows its tab's
    /// preview beside the text, `-KiriDropZoneShow left|right` draws the
    /// drop zone, and `-KiriSplitFocus left|right` puts the keyboard there.
    static func splitFlags(_ textView: NSTextView) -> Bool {
        let defaults = UserDefaults.standard
        let picture = ["KiriSplitWith", "KiriSplitPreviewShow", "KiriDropZoneShow", "KiriSplitFocus"].contains { defaults.object(forKey: $0) != nil }
        if picture, !splitStarted {
            splitStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let window = DocumentWindow.all.first(where: { FolderSessions.session(for: $0) != nil })
                    ?? DocumentWindow.front ?? textView.window as? DocumentNSWindow else { return }
                if let path = defaults.string(forKey: "KiriSplitWith") {
                    SidebarOpen.open(URL(fileURLWithPath: path), keep: true, from: window, keyboard: .editor, toSide: .menu)
                }
                if defaults.bool(forKey: "KiriSplitPreviewShow") { _ = window.tabs.togglePreviewBeside(source: .menu) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let side = defaults.string(forKey: "KiriSplitFocus").flatMap(SplitLayout.Side.init) { window.tabs.focus(side) }
                    if let side = defaults.string(forKey: "KiriDropZoneShow").flatMap(SplitLayout.Side.init) { window.tabs.dropZone = side }
                    print("SELFTEST info split picture ready: \(window.tabs.panels.map { $0.tab.document.displayName })")
                    fflush(stdout)
                }
            }
        }
        guard defaults.bool(forKey: "KiriSplitTest") else { return false }
        guard !splitStarted else { return true }
        splitStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = textView.window else { report(false, "a window for the split checks"); quit(); return }
            FrontEditor.shared.selfTestMain(window)
            Task { @MainActor in
                await splitStage(window)
                reportStayedInTheBackground()
                print("SELFTEST DONE split")
                fflush(stdout)
                quit()
            }
        }
        return true
    }

    // MARK: The fixture

    private final class SplitFixture {
        let root: URL
        let window: DocumentNSWindow
        private let clock = ContinuousClock()

        static let contents = ["a.swift": "let a = 1\n", "b.md": "# Bee\n\nThe first words.\n", "c.txt": "c\n", "d.swift": "let d = 4\n",
                               "e.txt": "e\n", "f.txt": "f\n", "g.txt": "g\n", "h.txt": "h\n"]

        init(root: URL, window: DocumentNSWindow) {
            self.root = root
            self.window = window
        }

        var tabs: WindowTabs { window.tabs }
        func file(_ name: String) -> URL { root.appendingPathComponent(name).standardizedFileURL }

        func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }

        func tab(_ name: String) -> DocumentTab? { tabs.list.first { $0.document.fileURL?.lastPathComponent == name } }
        func name(_ tab: DocumentTab?) -> String { tab?.document.fileURL?.lastPathComponent ?? tab?.document.displayName ?? "-" }

        /// The panels, left to right: "a.swift* | c.txt" (* has the keyboard).
        var layout: String {
            tabs.panels.map { name($0.tab) + ($0.preview ? " (preview)" : "") + ($0.keyboard ? "*" : "") }.joined(separator: " | ")
        }

        /// Each panel shows its tab's editor in its slot.
        var slotsShowTheirTabs: Bool {
            tabs.panels.allSatisfy { panel in
                guard let slot = window.slot(identity: panel.slot) else { return false }
                if panel.preview { return panel.tab.markdownPreview?.webView.superview === slot }
                return panel.tab.container.superview === slot
            }
        }

        /// Opens `name` from the sidebar, as a click (or with `toSide`, a
        /// ⌥-click) does, and waits for it.
        func open(_ name: String, keep: Bool = true, toSide: SplitSource? = nil, side: SplitLayout.Side? = nil) async {
            final class Done { var done = false }
            let done = Done()
            SidebarOpen.open(file(name), keep: keep, from: window, keyboard: .editor, toSide: toSide, side: side) { _ in done.done = true }
            _ = await wait { done.done }
            await SelfTest.settle(150)
        }

        /// A menu item's key, through the menu bar as a key press goes.
        func press(_ characters: String, unmodified: String? = nil, _ modifiers: NSEvent.ModifierFlags, code: UInt16 = 0) async -> Bool {
            guard let main = NSApp.mainMenu else { return false }
            SelfTest.updateMenu(main)
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: unmodified ?? characters, isARepeat: false,
                                           keyCode: code) else { return false }
            let handled = main.performKeyEquivalent(with: e)
            await SelfTest.settle(250)
            return handled
        }

        func menuItem(_ title: String) -> NSMenuItem? {
            guard let main = NSApp.mainMenu else { return nil }
            SelfTest.updateMenu(main)
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == title { return item }
                    if let sub = item.submenu, let found = find(sub) { return found }
                }
                return nil
            }
            return find(main)
        }

        func click(_ tab: DocumentTab) async {
            _ = window.makeFirstResponder(tab.container.textView)
            await SelfTest.settle(150)
        }
    }

    // MARK: The stage

    static func splitStage(_ original: NSWindow) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-split-test-\(getpid())")
            .standardizedFileURL
        let root = dir.appendingPathComponent("project")
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in SplitFixture.contents { try? text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        // A folder window, as `kiri <folder>` opens it.
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        KiriCLI.open(KiriCLI.Request(entries: [.folder(root)]))
        var found: DocumentNSWindow?
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .seconds(5) {
            found = NSApp.windows.compactMap { $0 as? DocumentNSWindow }
                .first { !before.contains(ObjectIdentifier($0)) && $0.isVisible && FolderSessions.session(for: $0) != nil }
            if found?.editorSlot != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let window = found, window.editorSlot != nil else { report(false, "a folder window opens for the split checks"); return }
        let f = SplitFixture(root: root.standardizedFileURL, window: window)
        FrontEditor.shared.selfTestMain(window)
        defer {
            window.performClose(nil)
            original.orderFront(nil)
            FrontEditor.shared.selfTestMain(original)
        }
        await settle(300)

        // Three kept tabs: a, c, d (the empty untitled one is taken over).
        for name in ["a.swift", "c.txt", "d.swift"] { await f.open(name) }
        report(f.tabs.list.count == 3 && !f.tabs.isSplit && f.layout == "d.swift*",
               "three files open as tabs of the folder window, one panel showing (\(f.tabs.list.map(f.name)), \(f.layout))")

        await splitEditorChecks(f)
        await focusChecks(f)
        await tabChecks(f)
        await closeChecks(f)
        await sidebarChecks(f)
        await paletteChecks(f)
        await optionReturnChecks(f)
        await dragChecks(f)
        await roomChecks(f)
        await movingOutChecks(f)
        await restoreChecks(f)
        await dirtyCloseChecks(f)
        await previewBesideChecks(f)
        shortcutsChecks()
    }

    /// ⌘\: the tab that showed before beside this one, on the right, the
    /// keyboard staying; the menu item says Close Split then, and ⌘\ again
    /// leaves the keyboard's side alone.
    private static func splitEditorChecks(_ f: SplitFixture) async {
        // (macOS moves ⌘\\ for some layouts, as it does ⌘/: on a Swedish
        // one it is the key in the same place, ⌘'. The key is read from the item.)
        let item = f.menuItem(KiriCommands.splitEditorTitle)
        let key = item?.keyEquivalent ?? "\\"
        report(item?.isEnabled == true && ["\\", "'"].contains(key) && item?.keyEquivalentModifierMask == .command,
               "View ▸ Split Editor is on, on ⌘\\ (\(item?.isEnabled ?? false), ⌘\(key) on this layout)")
        let made = TabEditorSlot.made
        let kept = f.window.editorSlot
        let pressed = await f.press(key, .command, code: 42)
        let shown = await f.wait { f.slotsShowTheirTabs && f.tabs.panels.count == 2 }
        await settle(600)
        report(TabEditorSlot.made == made + 1 && f.window.slot(for: f.tabs.selectedTab!) === kept,
               "the side that stays keeps its slot, and the new side gets one (\(TabEditorSlot.made - made) made)")
        report(pressed && shown && f.layout == "d.swift* | c.txt",
               "⌘\\ shows the tab that showed before on the right, the keyboard staying on the left (\(f.layout), pressed \(pressed), in their slots \(f.slotsShowTheirTabs))")
        let strip = f.tabs.tabs
        report(strip.first { $0.title == "c.txt" }?.beside == true && strip.filter(\.beside).count == 1
               && f.tabs.items.first { $0.title == "d.swift" }.map { $0.id == f.tabs.selected } == true,
               "the strip marks the tab beside, and the selection is the keyboard's tab (\(strip.map { $0.title + ($0.beside ? " (beside)" : "") }))")
        report(f.menuItem(KiriCommands.closeSplitTitle) != nil && f.menuItem(KiriCommands.splitEditorTitle) == nil,
               "the menu item says Close Split while the window is split")
        let close = f.menuItem(KiriCommands.closeSplitTitle)
        let again = await f.press(close?.keyEquivalent ?? key, .command, code: 42)
        _ = await f.wait { !f.tabs.isSplit }
        report(!f.tabs.isSplit && f.layout == "d.swift*" && f.slotsShowTheirTabs,
               "⌘\\ again closes the split, the side with the keyboard staying (\(f.layout), pressed \(again), ⌘\(close?.keyEquivalent ?? "-"))")
    }

    /// The keyboard moves to the other side by a click in its text, ⌥⌘←
    /// and ⌥⌘→, and the tab beside clicked in the strip; nothing moves,
    /// and the title, the menus' document and Save follow it.
    private static func focusChecks(_ f: SplitFixture) async {
        guard let d = f.tab("d.swift"), let c = f.tab("c.txt") else { report(false, "the tabs for the focus checks"); return }
        _ = f.tabs.splitEditor(source: .menu)
        _ = await f.wait { f.slotsShowTheirTabs && f.tabs.panels.count == 2 }
        let leftSlot = f.tabs.panels.first?.slot
        await f.click(c)
        report(f.layout == "d.swift | c.txt*" && f.tabs.selected == c.id && f.tabs.panels.first?.slot == leftSlot,
               "a click in the other side's text moves the keyboard there; nothing moves (\(f.layout))")
        report(FrontEditor.shared.document === c.document && f.window.windowController?.document === c.document
               && f.window.title.contains("c.txt"),
               "the window's title and the menus' document follow the keyboard (\(f.window.title), \(f.name(FrontEditor.shared.document.flatMap { DocumentWindow.tab(of: $0) })))")
        report(f.window.firstResponder === c.container.textView, "the keyboard is in that side's text")
        let left = f.menuItem("Focus Left Side")
        report(left?.isEnabled == true && left?.keyEquivalentModifierMask == [.option, .command],
               "View ▸ Focus Left Side is on, on ⌥⌘← (\(left?.isEnabled ?? false))")
        _ = await f.press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.option, .command, .function, .numericPad], code: 123)
        report(f.layout == "d.swift* | c.txt" && f.window.firstResponder === d.container.textView,
               "⌥⌘← moves the keyboard to the left side's text (\(f.layout))")
        _ = await f.press(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.option, .command, .function, .numericPad], code: 124)
        report(f.layout == "d.swift | c.txt*", "⌥⌘→ moves it to the right side (\(f.layout))")
        // The tab beside clicked in the strip: the keyboard goes to it, no swap.
        f.tabs.select(d.id)
        await settle(150)
        report(f.layout == "d.swift* | c.txt" && f.window.firstResponder === d.container.textView,
               "clicking the tab beside in the strip moves the keyboard to it, without a swap (\(f.layout))")
        // The palette is the keyboard's: on the side it leaves, it closes.
        d.model.palette.open()
        await settle(200)
        await f.click(c)
        report(!d.model.palette.isOpen && f.tabs.selected == c.id,
               "the palette on the side the keyboard leaves closes (\(d.model.palette.isOpen))")
        // The other side's status bar rests; its panel has no accent edge.
        report(f.tabs.panels.filter(\.keyboard).count == 1, "one side at a time has the keyboard")
        // The other side's find bar taking the keyboard: it stays there.
        f.tabs.select(d)
        await settle(150)
        c.model.find.perform(.show)
        let inField = await f.wait {
            (f.window.firstResponder as? NSTextView)?.isFieldEditor == true && f.tabs.selected == c.id
        }
        await settle(300)
        report(inField && (f.window.firstResponder as? NSTextView)?.isFieldEditor == true && f.tabs.selected == c.id,
               "the other side's find field taking the keyboard makes that side the keyboard's, and the keyboard stays in the field (\(f.layout), \(type(of: f.window.firstResponder as Any)))")
        c.model.find.close()
        await settle(200)
    }

    /// Swap Sides; Move Tab to Other Side; ⌃⇥, ⌘1–9 and the tab beside.
    private static func tabChecks(_ f: SplitFixture) async {
        guard let a = f.tab("a.swift"), let c = f.tab("c.txt"), let d = f.tab("d.swift") else { report(false, "the tabs for the tab checks"); return }
        f.tabs.select(d)
        await settle(100)
        let slots = Dictionary(uniqueKeysWithValues: f.tabs.panels.map { ($0.tab.id, $0.slot) })
        f.menuItem("Swap Sides").map { _ = $0.menu?.performActionForItem(at: $0.menu!.index(of: $0)) }
        await settle(300)
        report(f.layout == "c.txt | d.swift*" && f.tabs.panels.allSatisfy { slots[$0.tab.id] == $0.slot } && f.slotsShowTheirTabs,
               "View ▸ Swap Sides swaps them, each editor staying in its slot (\(f.layout))")
        f.tabs.swapSides()
        await settle(200)
        // ⌃⇥ on the keyboard's side passes over the tab beside: d → a (c is beside).
        f.tabs.selectNext()
        await settle(150)
        report(f.layout == "a.swift* | c.txt" && f.slotsShowTheirTabs,
               "the next tab on the keyboard's side passes over the tab beside (\(f.layout))")
        f.tabs.selectNext()
        await settle(150)
        report(f.layout == "d.swift* | c.txt", "and round to the first, passing over it again (\(f.layout))")
        // ⌘1–9: a tab that isn't shown comes to the keyboard's side; the
        // one beside takes the keyboard.
        if let index = f.tabs.list.firstIndex(where: { $0 === a }) { f.tabs.select(position: index) }
        await settle(150)
        report(f.layout == "a.swift* | c.txt", "⌘ and a number shows that tab on the keyboard's side (\(f.layout))")
        if let index = f.tabs.list.firstIndex(where: { $0 === c }) { f.tabs.select(position: index) }
        await settle(150)
        report(f.layout == "a.swift | c.txt*", "⌘ and the beside tab's number moves the keyboard to it (\(f.layout))")
        // Move Tab to Other Side: the keyboard's tab goes over, with the keyboard.
        let move = f.menuItem(KiriCommands.moveToOtherSideTitle)
        report(move?.isEnabled == true, "Window ▸ Move Tab to Other Side is on")
        _ = f.tabs.moveToOtherSide(source: .menu)
        await settle(300)
        report(f.layout == "c.txt* | a.swift" && f.slotsShowTheirTabs, "Move Tab to Other Side takes the tab and the keyboard over (\(f.layout))")
        f.tabs.closeSplit()
        await settle(200)
        report(f.layout == "c.txt*", "Close Split leaves the keyboard's side (\(f.layout))")
        _ = d
    }

    /// ⌘W closes the keyboard's tab: that side shows its neighbour, never
    /// the tab beside; with only that one left, the split ends. The tab
    /// beside closing ends it too.
    private static func closeChecks(_ f: SplitFixture) async {
        await f.open("e.txt")
        await f.open("f.txt")
        guard let e = f.tab("e.txt"), let fTab = f.tab("f.txt") else { report(false, "the tabs for the close checks"); return }
        // Order: a c d e f (each after the one that showed). f with the keyboard, e beside.
        f.tabs.openToSide(e, source: .tab)
        await settle(300)
        f.tabs.select(fTab)
        await settle(150)
        let order = f.tabs.list.map(f.name)
        let neighbour = SplitLayout.neighbour(of: fTab.id, in: f.tabs.list.map(\.id), beside: e.id).flatMap(f.tabs.tab(id:))
        let side = f.tabs.keyboardSide
        f.window.performCloseTab(nil)
        _ = await f.wait { f.tab("f.txt") == nil }
        await settle(200)
        report(f.tab("f.txt") == nil && f.tabs.isSplit && f.tabs.selectedTab === neighbour && f.tabs.besideTab === e
               && f.tabs.keyboardSide == side && f.slotsShowTheirTabs,
               "⌘W closes the keyboard's tab and that side shows its neighbour, not the tab beside (\(order) → \(f.layout))")
        // The tab beside closes (its close button): the split ends.
        f.tabs.close(e.id)
        _ = await f.wait { f.tab("e.txt") == nil }
        await settle(200)
        report(!f.tabs.isSplit && f.tab("e.txt") == nil && f.slotsShowTheirTabs, "the tab beside closing ends the split (\(f.layout))")
        // Only the tab beside left on its side: it gets the window.
        await f.open("g.txt")
        await f.open("h.txt")
        guard let g = f.tab("g.txt"), let h = f.tab("h.txt") else { return }
        // Close all but g and h.
        for other in f.tabs.list where other !== g && other !== h { other.document.close() }
        _ = await f.wait { f.tabs.list.count == 2 }
        f.tabs.select(h)
        f.tabs.openToSide(g, source: .tab)
        await settle(300)
        report(f.tabs.isSplit && f.tabs.selectedTab === g, "two tabs side by side (\(f.layout))")
        f.window.performCloseTab(nil)
        _ = await f.wait { f.tab("g.txt") == nil }
        await settle(200)
        report(!f.tabs.isSplit && f.tabs.selectedTab === h && f.window.isVisible && f.slotsShowTheirTabs,
               "⌘W with only the tab beside left gives it the window (\(f.layout))")
    }

    /// From the sidebar: ⌥-click (a kept tab, to the side, the keyboard
    /// with it), the file's menu, the preview tab coming to the keyboard's
    /// side, and a file that shows already getting the keyboard.
    private static func sidebarChecks(_ f: SplitFixture) async {
        await f.open("a.swift", toSide: .sidebar)
        report(f.tabs.isSplit && f.layout == "h.txt | a.swift*" && f.tab("a.swift")?.preview == false && f.slotsShowTheirTabs,
               "⌥-click on a sidebar file opens it to stay on the side without the keyboard, the keyboard with it (\(f.layout))")
        let menu = SidebarMenu.groups(for: .file(f.file("b.md")), session: FolderSessions.session(for: f.window)!, window: f.window)
        report(menu.first?.first?.title == SidebarMenu.openToSide, "a sidebar file's menu starts with Open to the Side")
        menu.first?.first?.action()
        _ = await f.wait { f.tab("b.md") != nil }
        await settle(300)
        report(f.layout == "b.md* | a.swift" && f.slotsShowTheirTabs,
               "its menu's Open to the Side shows it on the side without the keyboard (\(f.layout))")
        // A plain click: the preview tab, on the keyboard's side.
        await f.open("c.txt", keep: false)
        let preview = f.tabs.list.first { $0.preview }
        report(preview != nil && f.name(preview) == "c.txt" && f.layout == "c.txt* | a.swift",
               "a click shows the file on the keyboard's side, in the preview tab (\(f.layout))")
        // The keyboard to the other side; the next click: the preview tab comes over.
        f.tabs.focus(.right)
        await settle(150)
        await f.open("d.swift", keep: false)
        report(f.tabs.list.filter(\.preview).count == 1 && f.layout == "a.swift | d.swift*" && f.tabs.selectedTab?.preview == true
               && f.slotsShowTheirTabs,
               "with the keyboard on the other side, the next click brings the preview tab there (\(f.layout))")
        // A file that shows already: the keyboard goes to it.
        await f.open("a.swift")
        report(f.layout == "a.swift* | d.swift" && f.tabs.list.filter { $0.document.fileURL?.lastPathComponent == "a.swift" }.count == 1,
               "opening a file that shows already moves the keyboard to it, without a second tab (\(f.layout))")
        // From the strip: ⌥-click and its context menu.
        guard let h = f.tab("h.txt") else { return }
        let items = f.tabs.menu(for: h.id).flatMap { $0 }.map(\.title)
        report(items == [WindowTabs.openToSideTitle, "Move Tab to New Window", "Close Tab"],
               "a tab's context menu has Open to the Side, Move Tab to New Window and Close Tab (\(items))")
        f.tabs.menu(for: h.id).first?.first?.action()
        await settle(300)
        report(f.layout == "a.swift | h.txt*", "a tab's Open to the Side shows it on the side without the keyboard (\(f.layout))")
        f.tabs.closeSplit()
        await settle(200)
    }

    /// The palette: ⌥↩ on a file or a tab opens it to the side; Split
    /// Editor in a window with one tab opens Go to File for the side,
    /// and Escape leaves it as it was.
    private static func paletteChecks(_ f: SplitFixture) async {
        guard let model = f.tabs.selectedTab?.model else { return }
        let palette = model.palette
        palette.open(with: "e.tx")
        _ = await f.wait { palette.selectedRow.map { if case .file = $0.action { true } else { false } } == true }
        report(palette.selectedOpensToSide, "the palette's file row can open to the side")
        palette.commit(toSide: true)
        _ = await f.wait(4) { f.tab("e.txt") != nil && f.tabs.isSplit }
        await settle(300)
        report(f.tabs.isSplit && f.tabs.selectedTab.map(f.name) == "e.txt" && f.tabs.keyboardSide == .right,
               "⌥↩ on a file in the palette opens it to the side (\(f.layout))")
        f.tabs.closeSplit()
        await settle(150)

        // A window with one tab: Go to File, for the side.
        guard let e = f.tab("e.txt") else { return }
        DocumentWindow.moveToNewWindow(e)
        await settle(400)
        guard let lone = e.window, lone !== f.window else { report(false, "a window of its own for the one-tab checks"); return }
        defer { if let back = e.window { DocumentWindow.mergeAll(into: f.window); _ = back } }
        FrontEditor.shared.selfTestMain(lone)
        SplitAction.splitEditor()
        await settle(300)
        report(e.model.palette.isOpen && e.model.palette.toSide && !lone.tabs.isSplit,
               "Split Editor with one tab opens Go to File for the side (\(e.model.palette.isOpen), \(e.model.palette.toSide))")
        e.model.palette.cancel()
        await settle(200)
        report(!lone.tabs.isSplit && !e.model.palette.isOpen, "Escape leaves the window with its one tab")
        RecentDocuments.shared.selfTestShow([f.file("g.txt")])
        defer { RecentDocuments.shared.selfTestShow([]) }
        SplitAction.splitEditor()
        await settle(200)
        e.model.palette.text = "g.tx"
        _ = await f.wait { e.model.palette.selectedOpensToSide }
        e.model.palette.commit()
        _ = await f.wait(4) { lone.tabs.isSplit }
        await settle(300)
        report(lone.tabs.isSplit && lone.tabs.panels.count == 2 && lone.tabs.keyboardSide == .right,
               "and Return opens the file chosen to the side (\(lone.tabs.panels.map { f.name($0.tab) }))")
        FrontEditor.shared.selfTestMain(f.window)
        DocumentWindow.mergeAll(into: f.window)
        await settle(300)
        report(!lone.isVisible && f.window.tabs.list.contains { $0 === e }, "Merge All Windows brings them back")
    }

    /// ⌥↩ as a key, in the palette's field and on a sidebar row: the file
    /// opens to the side. (Keys reach SwiftUI's views only where it is
    /// drawing the window: elsewhere this is skipped.)
    private static func optionReturnChecks(_ f: SplitFixture) async {
        guard f.window.occlusionState.contains(.visible) || UserDefaults.standard.bool(forKey: "KiriAssumeDrawn") else {
            print("SELFTEST info ⌥↩ as a key skipped: the window isn't drawn")
            return
        }
        func optionReturn() async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .option,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber,
                                            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            await settle(300)
        }
        f.tabs.closeSplit()
        for name in ["f.txt", "h.txt"] { f.tab(name)?.document.close() }
        await settle(300)
        guard let model = f.tabs.selectedTab?.model else { return }
        // The palette's field.
        model.palette.open(with: "f.tx")
        let row = await f.wait { model.palette.selectedRow.map { if case .file = $0.action { true } else { false } } == true
            && (f.window.firstResponder as? NSTextView)?.isFieldEditor == true }
        await optionReturn()
        let opened = await f.wait(4) { f.tab("f.txt") != nil && f.tabs.isSplit }
        await settle(300)
        report(row && opened && f.tabs.selectedTab.map(f.name) == "f.txt" && f.tabs.keyboardSide == .right
               && f.tab("f.txt")?.document.fileURL.map { _ in true } == true,
               "⌥↩ pressed in the palette's field opens its file to the side (\(f.layout))")
        f.tabs.closeSplit()
        await settle(200)
        // A sidebar row.
        guard let session = FolderSessions.session(for: f.window), let tab = f.tabs.selectedTab else { return }
        session.cursor = f.file("h.txt")
        tab.model.sidebarFocusRequest += 1
        let focused = await f.wait { tab.model.sidebarHasFocus }
        await optionReturn()
        let fromSidebar = await f.wait(4) { f.tab("h.txt") != nil && f.tabs.isSplit }
        await settle(300)
        report(focused && fromSidebar && f.tabs.selectedTab.map(f.name) == "h.txt" && f.tab("h.txt")?.preview == false,
               "⌥↩ pressed on a sidebar row opens its file to the side, to stay (\(f.layout), sidebar had the keyboard \(focused))")
        f.tabs.closeSplit()
        await settle(200)
    }

    /// A tab dragged onto a half of the editors shows there; files from
    /// Finder only from the outer thirds (the middle opens them as tabs);
    /// the drop zone shows while it is over a side.
    private static func dragChecks(_ f: SplitFixture) async {
        f.tabs.closeSplit()
        await settle(200)
        guard let slot = f.window.editorSlot, let a = f.tab("a.swift") else { report(false, "the editors for the drag checks"); return }
        let row = slot.convert(slot.bounds, to: nil)
        let leftPoint = NSPoint(x: row.minX + row.width * 0.15, y: row.midY)
        let middle = NSPoint(x: row.midX, y: row.midY)
        if f.tabs.selectedTab === a, let other = f.tabs.list.first(where: { $0 !== a }) { f.tabs.select(other) }
        await settle(150)
        // A tab of this window, dragged onto the left half.
        let board = TabDrag.selfTestPasteboard(dragging: a)
        let drag = TestDrag(board, on: f.window, at: leftPoint)
        let operation = f.window.draggingUpdated(drag)
        report(!operation.isEmpty && f.tabs.dropZone == .left, "a tab over the left half shows the drop zone there (\(f.tabs.dropZone.map(\.rawValue) ?? "none"))")
        _ = f.window.performDragOperation(drag)
        await settle(400)
        report(f.tabs.dropZone == nil && f.layout.hasPrefix("a.swift*") && f.tabs.isSplit && f.slotsShowTheirTabs,
               "let go there, it shows on the left with the keyboard (\(f.layout))")
        board.releaseGlobally()
        f.tabs.closeSplit()
        await settle(200)
        // Files from Finder: the middle third opens a tab; the right third splits.
        let files = pasteboard(files: [f.file("b.md")])
        let mid = TestDrag(files, on: f.window, at: middle)
        _ = f.window.draggingUpdated(mid)
        report(f.tabs.dropZone == nil, "a file over the middle third shows no drop zone (it opens as a tab)")
        f.window.draggingExited(mid)
        let right = TestDrag(files, on: f.window, at: NSPoint(x: row.minX + row.width * 0.9, y: row.midY))
        _ = f.window.draggingUpdated(right)
        report(f.tabs.dropZone == .right, "over the right third, the right half's zone (\(f.tabs.dropZone.map(\.rawValue) ?? "none"))")
        // Through the text view, as a real drop on the text goes.
        let target = dropTarget(in: f.window, at: right.draggingLocation, for: files)
        report(target is KiriTextView, "the text takes the drag and hands it to the window (\(target.map { "\(type(of: $0))" } ?? "none"))")
        let taken = target?.performDragOperation?(right) ?? false
        _ = await f.wait(4) { f.tabs.isSplit }
        await settle(300)
        report(taken && f.tabs.dropZone == nil && f.layout.hasSuffix("b.md*"), "let go there, the file shows on the right (\(f.layout))")
        files.releaseGlobally()
        f.tabs.closeSplit()
        await settle(200)
    }

    /// A window too narrow for two editors grows to hold them.
    private static func roomChecks(_ f: SplitFixture) async {
        var frame = f.window.frame
        frame.size.width = 520
        f.window.setFrame(frame, display: true)
        await settle(400)
        let narrow = f.window.frame.width
        _ = f.tabs.splitEditor(source: .key)
        // (Once the new side has sprung into place.)
        await settle(1200)
        let needed = SplitLayout.minimumRow(gap: Honey.gap) + SidebarLayout.widths.lowerBound + 3 * Honey.gap
        report(f.tabs.isSplit && f.window.frame.width >= needed - 1 && f.window.frame.width > narrow,
               "a window too narrow for two editors grows to hold them (\(Int(narrow)) → \(Int(f.window.frame.width)), needs \(Int(needed)))")
        let widths = f.tabs.panels.compactMap { f.window.slot(identity: $0.slot)?.bounds.width }
        report(widths.count == 2 && widths.allSatisfy { $0 >= SplitLayout.editorMinimum - 1 },
               "each side has the editor's minimum at least (\(widths.map { Int($0) }))")
        f.tabs.closeSplit()
        frame = f.window.frame
        frame.size.width = DocumentWindow.defaultSize.width
        f.window.setFrame(frame, display: true)
        await settle(300)
    }

    /// A tab that shows, moved to a window of its own, ends its window's split.
    private static func movingOutChecks(_ f: SplitFixture) async {
        guard f.tabs.splitEditor(source: .key), let beside = f.tabs.besideTab else { report(false, "a split for the moving-out checks"); return }
        await settle(300)
        DocumentWindow.moveToNewWindow(beside)
        await settle(400)
        report(!f.tabs.isSplit && beside.window !== f.window, "moving the tab beside to a window of its own ends the split (\(f.layout))")
        DocumentWindow.mergeAll(into: f.window)
        await settle(300)
    }

    /// What a split window keeps for the next launch, and a window
    /// restored with it showing its two sides again.
    private static func restoreChecks(_ f: SplitFixture) async {
        guard f.tabs.splitEditor(source: .key), let beside = f.tabs.besideTab, let main = f.tabs.selectedTab else { return }
        f.tabs.splitFraction = 0.4
        f.tabs.swapSides()
        await settle(200)
        let records = TabRestoration.records(of: f.tabs)
        let split = TabRestoration.split(of: f.tabs)
        let besideRecord = records.first { $0["beside"] as? Bool == true }
        report(besideRecord?["path"] as? String == beside.document.fileURL?.path && split?["besideIsLeft"] as? Bool == true
               && split?["fraction"] as? Double == 0.4,
               "a split window keeps its tab beside, its sides and its edge for the next launch (\(split ?? [:]))")
        // A window restored with one of them, and the records: the other comes back beside it.
        f.tabs.closeSplit()
        await settle(150)
        DocumentWindow.moveToNewWindow(main)
        await settle(400)
        guard let restored = main.window, restored !== f.window else { return }
        let only = records.filter { $0["selected"] as? Bool == true || $0["beside"] as? Bool == true }
        TabRestoration.restore(only, in: restored, split: split)
        _ = await f.wait(4) { restored.tabs.isSplit }
        await settle(300)
        report(restored.tabs.isSplit && restored.tabs.besideTab === beside && restored.tabs.besideIsLeft
               && abs(restored.tabs.splitFraction - 0.4) < 0.001 && restored.tabs.selectedTab === main,
               "restored, the window shows the same two tabs side by side, on the same sides (\(restored.tabs.panels.map { f.name($0.tab) }))")
        FrontEditor.shared.selfTestMain(f.window)
        DocumentWindow.mergeAll(into: f.window)
        await settle(300)
        f.tabs.closeSplit()
        f.tabs.splitFraction = SplitLayout.defaultFraction
    }

    /// A side with unsaved changes asks before it closes: Cancel keeps both
    /// sides as they were; Don't Save on the tab beside ends the split.
    private static func dirtyCloseChecks(_ f: SplitFixture) async {
        f.tabs.closeSplit()
        await settle(150)
        guard f.tabs.splitEditor(source: .key), let beside = f.tabs.besideTab, let main = f.tabs.selectedTab else {
            report(false, "a split for the unsaved-changes checks"); return
        }
        await settle(300)
        func press(_ title: String) async -> Bool {
            func buttons(_ view: NSView?) -> [NSButton] {
                guard let view else { return [] }
                return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
            }
            guard let sheet = f.window.attachedSheet, let button = buttons(sheet.contentView).first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return await f.wait { f.window.attachedSheet == nil }
        }
        for tab in [beside, main] {
            tab.container.textView.setSelectedRange(NSRange(location: 0, length: 0))
            tab.container.textView.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
            // (No event closes the undo group in a background test: the change is counted by hand.)
            if !tab.document.isDocumentEdited { tab.document.updateChangeCount(.changeDone) }
        }
        _ = await f.wait { beside.document.isDocumentEdited && main.document.isDocumentEdited }
        let layout = f.layout
        // The tab beside's close button.
        f.tabs.close(beside.id)
        let asked = await f.wait { f.window.attachedSheet != nil }
        let during = f.layout
        let cancelled = await press("Cancel")
        await settle(200)
        report(asked && cancelled && f.tabs.isSplit && f.tabs.isShown(beside) && f.tabs.isShown(main),
               "closing the tab beside with unsaved changes asks; Cancel keeps both sides (\(layout) → \(during) → \(f.layout))")
        // ⌘W on the keyboard's side, Cancel.
        f.tabs.select(main)
        await settle(150)
        f.window.performCloseTab(nil)
        let asked2 = await f.wait { f.window.attachedSheet != nil }
        let cancelled2 = await press("Cancel")
        await settle(200)
        report(asked2 && cancelled2 && f.tabs.isSplit && f.tabs.selectedTab === main && f.tabs.isShown(beside),
               "⌘W on a side with unsaved changes asks; Cancel keeps it and the split (\(f.layout))")
        // Don't Save on the tab beside: it closes, and the split with it.
        f.tabs.close(beside.id)
        _ = await f.wait { f.window.attachedSheet != nil }
        let discarded = await press("Don’t Save")
        _ = await f.wait { !f.tabs.list.contains { $0 === beside } }
        await settle(200)
        report(discarded && !f.tabs.isSplit && f.tabs.list.allSatisfy { $0 !== beside } && f.tabs.selectedTab === main && f.window.isVisible,
               "Don't Save on the tab beside closes it and ends the split (\(f.layout))")
        main.container.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 8), with: "")
        main.document.updateChangeCount(.changeCleared)
    }

    /// View ▸ Preview to the Side: a Markdown tab's text on the left and
    /// its preview on the right, following what is typed; ⌃⌘P then shows
    /// the preview in the text's place, and the split ends.
    private static func previewBesideChecks(_ f: SplitFixture) async {
        await f.open("b.md")
        guard let b = f.tab("b.md"), f.tabs.selectedTab === b else { report(false, "the Markdown tab for Preview to the Side"); return }
        let item = f.menuItem(KiriCommands.previewToSideTitle)
        report(item?.isEnabled == true && item?.keyEquivalentModifierMask == [.option, .control, .command],
               "View ▸ Preview to the Side is on for a Markdown tab, on ⌥⌃⌘P (\(item?.isEnabled ?? false))")
        _ = await f.press("\u{10}", unmodified: "p", [.option, .control, .command], code: 35)
        let ready = await f.wait(6) { f.slotsShowTheirTabs && f.tabs.beside == .preview }
        report(ready && f.layout == "b.md* | b.md (preview)" && !b.showsMarkdownPreview,
               "⌥⌃⌘P shows the text on the left and its preview on the right (\(f.layout), drawn \(f.slotsShowTheirTabs))")
        guard let web = b.markdownPreview?.webView else { return }
        func pageText() async -> String {
            (try? await web.evaluateJavaScript("document.body.innerText") as? String) ?? ""
        }
        // Typed into the text: the preview follows.
        b.container.textView.setSelectedRange(NSRange(location: (b.container.textView.string as NSString).length, length: 0))
        b.container.textView.insertText("\nA swarm of honeybees.\n", replacementRange: b.container.textView.selectedRange())
        var followed = false
        for _ in 0..<60 {
            if (await pageText()).contains("swarm of honeybees") { followed = true; break }
            await settle(50)
        }
        report(followed, "the preview beside the text follows what is typed")
        // The keyboard into the preview, and back.
        f.tabs.focus(.right)
        await settle(150)
        report(f.tabs.keyboardInPreview && f.tabs.keyboardSide == .right && f.window.firstResponder === web,
               "⌥⌘→ moves the keyboard into the preview (\(f.layout))")
        f.tabs.focus(.left)
        await settle(150)
        report(!f.tabs.keyboardInPreview && f.window.firstResponder === b.container.textView, "and ⌥⌘← back to the text")
        // ⌃⌘P: the preview in the text's place, the split gone.
        b.setMarkdownPreview(true)
        let inPlace = await f.wait(4) { b.markdownPreview?.webView.superview === f.window.editorSlot }
        report(inPlace && !f.tabs.isSplit && b.showsMarkdownPreview, "⌃⌘P then shows the preview in the text's place and ends the split (\(f.layout))")
        b.setMarkdownPreview(false)
        await settle(200)
        // Another tab ends it too.
        _ = f.tabs.togglePreviewBeside(source: .menu)
        await settle(300)
        if let a = f.tab("a.swift") { f.tabs.select(a) }
        await settle(200)
        report(!f.tabs.isSplit, "showing another tab ends the preview beside the text (\(f.layout))")
        // A plain text file has no preview to show.
        report(f.tabs.togglePreviewBeside(source: .menu) == false && !f.tabs.isSplit, "a Swift file has no preview to show beside it")
        b.document.updateChangeCount(.changeCleared)
    }

    /// Keyboard Shortcuts lists them.
    private static func shortcutsChecks() {
        let group = ShortcutGroup.all.first { $0.title == "Side by side" }
        report(group?.items.contains { $0.keys == Keys.splitEditor.glyphs } == true
               && group?.items.contains { $0.keys == Keys.previewToSide.glyphs } == true
               && Keys.splitEditor.spoken == "Command Backslash",
               "Keyboard Shortcuts has a Side by side group with ⌘\\ and ⌥⌃⌘P (\(group?.items.count ?? 0) items, \(Keys.splitEditor.spoken))")
    }
}
#endif
