#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

extension SelfTest {
    /// Settings ▸ Shortcuts and the keys it changes (`ShortcutStore`,
    /// `ShortcutsPaneModel`): the list of commands is the menu bar's, a
    /// key changed there is the menu item's at once (the old one does
    /// nothing, the new one runs it), the Help window and the tooltips
    /// follow, and recording takes every key, refuses the ones that can't
    /// be a shortcut, asks before taking one another command has, and
    /// puts things back. None of it may write a saved preference.
    ///
    /// Keys are handed to the pane's event handler as the monitor would
    /// hand them, since a background launch gets no key presses.
    /// `-KiriShortcutsTest YES` runs these alone (part of
    /// `-KiriBehaviorTest` too).
    static func shortcutsStage(_ original: NSWindow) async {
        let store = ShortcutStore.shared, model = ShortcutsPaneModel.shared, navigation = SettingsNavigation.shared
        let domain = Bundle.main.bundleIdentifier ?? ""
        func savedPrefs() -> String {
            (UserDefaults.standard.persistentDomain(forName: domain)?[ShortcutStore.prefsKey]).map { "\($0)" } ?? "none"
        }
        let prefsBefore = savedPrefs()
        let before = store.table
        let paneBefore = navigation.pane
        FrontEditor.shared.selfTestMain(original)
        defer {
            store.selfTestRestore(before)
            model.selfTestReset()
            navigation.pane = paneBefore
            original.orderFront(nil)
            FrontEditor.shared.selfTestMain(original)
        }

        // The commands are the menu bar's: each is an item there, with the
        // key the store gives it.
        func items() -> [(top: String, item: NSMenuItem)] {
            guard let main = NSApp.mainMenu else { return [] }
            updateMenu(main)
            var found: [(String, NSMenuItem)] = []
            func walk(_ menu: NSMenu, _ top: String) {
                for item in menu.items where !item.isSeparatorItem {
                    if let sub = item.submenu { walk(sub, top) } else { found.append((top, item)) }
                }
            }
            for (i, top) in main.items.enumerated() {
                if let menu = top.submenu { walk(menu, i == 0 ? ShortcutCommand.Menu.app.rawValue : top.title) }
            }
            return found
        }
        func item(_ command: ShortcutCommand) -> NSMenuItem? {
            items().first { $0.top == command.info.menu.rawValue && command.info.titles.contains($0.item.title) }?.item
        }
        let all = items()
        var missing: [String] = [], wrong: [String] = []
        for command in ShortcutCommand.allCases {
            guard let found = all.first(where: { $0.top == command.info.menu.rawValue && command.info.titles.contains($0.item.title) })?.item else {
                missing.append(command.rawValue)
                continue
            }
            if KeyCombo(menuItem: found) != store[command] { wrong.append("\(command.rawValue) \(found.keyEquivalent.debugDescription)") }
        }
        report(missing.isEmpty && wrong.isEmpty,
               "every command in Settings ▸ Shortcuts (\(ShortcutCommand.allCases.count)) is a menu item with the key the store gives it (missing \(missing), wrong \(wrong))")
        // And every item of Kiri's with a key is one of them, or macOS's own.
        let fixed = FixedKey.menuBar()
        let macOSTitles = Set(fixed.map(\.title))
        let expectedMacOS: Set<String> = ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"]
        report(expectedMacOS.isSubset(of: macOSTitles) && fixed.allSatisfy { !ShortcutCommand.allCases.flatMap(\.info.titles).contains($0.title) },
               "the keys Settings can't change are macOS's items (Undo, Copy, Paste…: \(fixed.map { "\($0.title) \($0.keys)" }))")

        // A new key is the menu item's at once: the old one does nothing,
        // the new one runs it.
        let palette = FrontEditor.shared.editor?.palette
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16, in window: NSWindow) async -> Bool {
            guard let main = NSApp.mainMenu, let e = keyEvent(characters, flags, code, window) else { return false }
            let handled = main.performKeyEquivalent(with: e)
            await settle(100)
            return handled
        }
        store.set(.palette, KeyCombo("9", [.control, .command]))
        await settle(150)
        let paletteItem = item(.palette)
        let shown = paletteItem?.keyEquivalent == "9" && paletteItem?.keyEquivalentModifierMask == [.control, .command]
        let oldKey = await press("k", .command, 40, in: original)
        let oldOpened = palette?.isOpen == true
        if palette?.isOpen == true { palette?.toggle() }
        let newKey = await press("9", [.control, .command], 25, in: original)
        let newOpened = palette?.isOpen == true
        if palette?.isOpen == true { palette?.toggle() }
        report(shown && !oldKey && !oldOpened && newKey && newOpened,
               "View ▸ Command Palette… given ⌃⌘9 shows it in the menu, ⌘K no longer opens the palette and ⌃⌘9 does (shown \(shown), ⌘K \(oldKey)/\(oldOpened), ⌃⌘9 \(newKey)/\(newOpened))")
        // The Help window and the tooltips say the new key.
        let helpSays = ShortcutGroup.all.flatMap(\.items).contains { $0.title == "Open / close the palette" && $0.keys == "⌃⌘9" }
        store.set(.goToLine, nil)
        let tooltip = Keys.help("Go to Line", .goToLine)
        report(helpSays && tooltip == "Go to Line",
               "Help ▸ Keyboard Shortcuts says ⌃⌘9 for the palette, and a tooltip of a command with no key has no key in it (\(helpSays), “\(tooltip)”)")
        store.set(.palette, nil)
        await settle(150)
        let none = item(.palette)?.keyEquivalent.isEmpty == true
        let noneKey = await press("9", [.control, .command], 25, in: original)
        if palette?.isOpen == true { palette?.toggle() }
        store.reset(.palette)
        store.reset(.goToLine)
        await settle(150)
        let back = item(.palette)?.keyEquivalent == "k" && item(.goToLine)?.keyEquivalent == "l"
        report(none && !noneKey && back, "with no key the item has none and ⌃⌘9 does nothing; reset gives back ⌘K and ⌘L (\(none), \(noneKey), \(back))")

        // A command that comes with no key can be given one.
        store.set(.swapSides, KeyCombo("x", [.control, .command]))
        await settle(150)
        let swap = item(.swapSides)
        report(swap?.keyEquivalent == "x" && swap?.keyEquivalentModifierMask == [.control, .command] && store.isChanged(.swapSides),
               "View ▸ Swap Sides, which has no key, can be given ⌃⌘X (\(swap?.keyEquivalent.debugDescription ?? "no item"))")
        // A changed key stays where it was pressed; Kiri's own move with the layout.
        let localized = swap?.allowsAutomaticKeyEquivalentLocalization == false && item(.save)?.allowsAutomaticKeyEquivalentLocalization == true
        report(localized, "a changed key is the key pressed on this keyboard; the ones Kiri comes with follow the layout (\(swap?.allowsAutomaticKeyEquivalentLocalization ?? true), \(item(.save)?.allowsAutomaticKeyEquivalentLocalization ?? false))")
        store.reset(.swapSides)

        // Settings: the Shortcuts pane, the keyboard in its search field.
        guard let settings = await openSettings() else { report(false, "Settings opens"); return }
        await settle(300)
        navigation.pane = .general
        await settle(200)
        let generalNothingFocused = settings.firstResponder === settings
        func handle(_ characters: String, _ flags: NSEvent.ModifierFlags = [], _ code: UInt16) -> Bool {
            guard let e = keyEvent(characters, flags, code, settings) else { return false }
            return model.handle(e) == nil
        }
        let toShortcuts = handle("2", .command, 19)
        await settle(300)
        let searchHasKeyboard = (settings.firstResponder as? NSTextView)?.isFieldEditor == true
        report(generalNothingFocused && toShortcuts && navigation.pane == .shortcuts && searchHasKeyboard,
               "⌘2 in Settings shows Shortcuts with the keyboard in its search field, and General opens with nothing focused (\(generalNothingFocused), \(toShortcuts), \(navigation.pane), \(settings.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")
        await wakeAccessibility()
        let elements = accessibilityElements(of: settings)
        let headings = elements.filter { $0.role == "AXHeading" && $0.name != "Settings" }.map(\.name)
        // (The list makes its rows as they scroll into view: the first menus.)
        report(headings.starts(with: ["Kiri", "File", "Edit"]) && !headings.contains("Appearance"),
               "VoiceOver hears the Shortcuts pane's menus as headings, and nothing of the hidden General pane (\(headings))")
        let saveCap = elements.first { $0.name == "Shortcut for Save" }
        report(saveCap?.value == "Command S", "the Save row's key is a button VoiceOver hears as “Shortcut for Save, Command S” (\(saveCap.map { "\($0.role) \($0.value)" } ?? "none"))")

        // The search: words anywhere in the name, the menu or the key.
        model.query = "split"
        await settle(60)
        let split = Set(model.order)
        model.query = "⌘k"
        await settle(60)
        let byKey = model.order
        model.query = "edit find"
        await settle(60)
        let inMenu = model.order
        model.query = "zqzq"
        await settle(60)
        let nothing = model.order.isEmpty && model.fixedShown.isEmpty
        model.query = "copy"
        await settle(60)
        let fixedFound = model.fixedShown.contains { $0.title == "Copy" }
        report(split.isSuperset(of: [.splitEditor, .previewToSide, .swapSides, .moveToOtherSide, .focusLeftSide]) && byKey == [.palette]
               && inMenu.contains(.findNext) && !inMenu.contains(.save) && nothing && fixedFound,
               "the search finds by name, menu and key: “split” the side-by-side commands, “⌘k” the palette, “edit find” the Find menu, “copy” macOS's Copy (\(split.count), \(byKey), \(inMenu.count), \(nothing), \(fixedFound))")
        model.query = ""
        await settle(60)

        // The arrows choose a row; Return records it.
        let down1 = handle("\u{F701}", [], 125), first = model.selected
        _ = handle("\u{F701}", [], 125)
        let second = model.selected
        _ = handle("\u{F700}", [], 126)
        let up = model.selected
        let enter = handle("\r", [], 36)
        report(down1 && first == model.order.first && second == model.order.dropFirst().first && up == first && enter && model.recording == first,
               "↓ and ↑ go from row to row, Return records the row (\(String(describing: first)), \(String(describing: second)), recording \(String(describing: model.recording)))")
        model.cancel()

        // Recording takes every key: one nobody has is the command's at once.
        model.startRecording(.save)
        let swallowed = handle("j", [.control, .command], 38)
        await settle(150)
        let saveItem = item(.save)
        report(swallowed && model.recording == nil && store[.save] == KeyCombo("j", [.control, .command])
               && saveItem?.keyEquivalent == "j" && saveItem?.keyEquivalentModifierMask == [.control, .command],
               "recording Save, ⌃⌘J is Save's key, in the File menu too (\(String(describing: store[.save])), \(saveItem?.keyEquivalent.debugDescription ?? "-"))")
        // Another command's key: asked first; Return gives it, the other has none.
        model.startRecording(.save)
        _ = handle("g", .command, 5)
        let asked = model.pending?.owners == [.findNext] && store[.save] == KeyCombo("j", [.control, .command]) && model.recording == .save
        _ = handle("\r", [], 36)
        report(asked && store[.save] == KeyCombo("g", .command) && store[.findNext] == nil && store.conflicts.isEmpty,
               "⌘G, Find Next's, is asked about first; Return gives it to Save and Find Next has none (\(asked), \(String(describing: store[.findNext])))")
        store.reset(.findNext)
        store.reset(.save)

        // Keys that can't be a shortcut are refused, and the recording goes on.
        model.startRecording(.save)
        var refusedAll = true
        var said: [String] = []
        for (characters, flags, code) in [("a", NSEvent.ModifierFlags(), UInt16(0)), ("q", .command, 12), ("3", .command, 20), (" ", .command, 49)] {
            let refusals = model.refusals
            _ = handle(characters, flags, code)
            if case .refused(let why) = model.message { said.append(why) }
            refusedAll = refusedAll && model.refusals == refusals + 1 && model.recording == .save && store[.save] == KeyCombo("s", .command)
        }
        report(refusedAll && said.count == 4, "A alone, ⌘Q (Quit), ⌘3 (Go to Tab) and ⌘Space (Spotlight) are refused and the recording goes on (\(said))")
        // A key text views use is asked about; Escape cancels it all.
        _ = handle("a", .control, 0)
        let textAsked = model.pending != nil && model.pending?.owners.isEmpty == true
        let escape = handle("\u{1B}", [], 53)
        report(textAsked && escape && model.recording == nil && store[.save] == KeyCombo("s", .command) && settings.isVisible,
               "⌃A (start of the line in text) is asked about; Escape cancels the recording, not the window, and Save keeps ⌘S (\(textAsked), \(escape), visible \(settings.isVisible))")
        // ⌘W while recording is the recording's, not Close's.
        model.startRecording(.newTab)
        _ = handle("w", .command, 13)
        let closeAsked = model.pending?.owners == [.close] && settings.isVisible
        _ = handle("\u{1B}", [], 53)
        report(closeAsked, "⌘W while recording is a key for the command (Close's, so asked about), and the window stays open")
        // The same through the event loop, as the keyboard and the pointer
        // send them: the monitor gets Escape before the window's Cancel
        // key, and a click outside the row ends a recording.
        func post(_ event: NSEvent?) async {
            guard let event else { return }
            NSApp.postEvent(event, atStart: false)
            await settle(250)
        }
        model.startRecording(.save)
        await settle(150)
        await post(keyEvent("w", .command, 13, settings))
        let postedW = model.pending?.owners == [.close] && settings.isVisible
        await post(keyEvent("\u{1B}", [], 53, settings))
        let postedEscape = model.recording == nil && settings.isVisible && store[.save] == KeyCombo("s", .command)
        model.startRecording(.save)
        await settle(150)
        // A click on the row's own name (not its buttons) keeps it recording.
        let row = model.recordingFrame
        let inside = NSPoint(x: row.minX + 30, y: settings.frame.height - row.midY)
        await post(NSEvent.mouseEvent(with: .leftMouseDown, location: inside, modifierFlags: [], timestamp: 0,
                                      windowNumber: settings.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        await post(NSEvent.mouseEvent(with: .leftMouseUp, location: inside, modifierFlags: [], timestamp: 0,
                                      windowNumber: settings.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let clickedInside = model.recording == .save && row.height > 0
        let corner = NSPoint(x: 20, y: 20) // the window's bottom left: the footer, not the row
        await post(NSEvent.mouseEvent(with: .leftMouseDown, location: corner, modifierFlags: [], timestamp: 0,
                                      windowNumber: settings.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        await post(NSEvent.mouseEvent(with: .leftMouseUp, location: corner, modifierFlags: [], timestamp: 0,
                                      windowNumber: settings.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let clickedAway = model.recording == nil
        model.cancel()
        report(postedW && postedEscape && clickedInside && clickedAway,
               "through the event loop, ⌘W is recorded and Escape cancels without closing Settings; a click on the recording row keeps it, one outside ends it (\(postedW), \(postedEscape), \(clickedInside) \(row), \(clickedAway))")

        // Delete: no key; Return: back to the default.
        model.startRecording(.save)
        _ = handle("\u{7F}", [], 51)
        let cleared = store[.save] == nil && store.isChanged(.save)
        model.startRecording(.save)
        _ = handle("\r", [], 36)
        report(cleared && store[.save] == KeyCombo("s", .command) && !store.isChanged(.save) && model.recording == nil,
               "Delete leaves Save with no key, and Return while recording puts ⌘S back (\(cleared))")
        // A key two ways (⇧⌘] is also ⌘}): the command's own is kept.
        model.startRecording(.nextTab)
        model.press([KeyCombo("}", .command), KeyCombo("]", [.shift, .command])])
        let s = keyEvent("S", [.shift, .command], 1, settings).map(KeyCombo.candidates) ?? []
        report(model.recording == nil && !store.isChanged(.nextTab) && s == [KeyCombo("s", [.shift, .command])],
               "⇧⌘] for Select Next Tab is its own key, no change; ⇧⌘S is read as S with Shift and Command (\(s))")

        // A conflict left over shows on both rows, and the count filters to them.
        store.set(.swapSides, KeyCombo("g", .command))
        await settle(200)
        await wakeAccessibility()
        // (Find Next's row is on screen; the list makes rows as they come into view.)
        let warned = accessibilityElements(of: settings).contains { $0.value.contains("Same key as Swap Sides") || $0.name.contains("Same key as Swap Sides") }
        model.conflictsOnly = true
        await settle(60)
        let onlyThem = Set(model.order) == [.findNext, .swapSides]
        model.conflictsOnly = false
        report(warned && onlyThem, "a key two commands share is marked on their rows, and the conflicts button shows just them (\(warned), \(model.order.count))")

        // Reset all.
        store.set(.open, KeyCombo("o", [.control, .command]))
        model.resetAll()
        await settle(150)
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[ShortcutStore.prefsKey]
        report(!store.hasChanges && argument == nil && item(.open)?.keyEquivalent == "o",
               "Reset All puts every key back (\(store.hasChanges), \(argument.map { "\($0)" } ?? "nothing kept"))")

        // ⌘1 back to General; the keyboard leaves the search.
        _ = handle("1", .command, 18)
        await settle(200)
        report(navigation.pane == .general && settings.firstResponder === settings,
               "⌘1 goes back to General, with nothing focused (\(navigation.pane), \(settings.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")

        report(savedPrefs() == prefsBefore, "the person's saved shortcuts are untouched (\(savedPrefs()))")
        settings.performClose(nil)
        await settle(200)
    }

    /// A key press in `window`, as the keyboard sends it.
    private static func keyEvent(_ characters: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16, _ window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// Picture flags, once Settings is up (-KiriShowSettings YES with
    /// -KiriSettingsPane shortcuts): -KiriShortcutsSelect <command>,
    /// -KiriShortcutsRecord <command> and then -KiriShortcutsPress
    /// <key as stored, such as cmd+g>.
    static func shortcutsPictureFlags() {
        let defaults = UserDefaults.standard
        let model = ShortcutsPaneModel.shared
        if let raw = defaults.string(forKey: "KiriShortcutsSelect"), let command = ShortcutCommand(rawValue: raw) {
            model.selected = command
        }
        if let raw = defaults.string(forKey: "KiriShortcutsRecord"), let command = ShortcutCommand(rawValue: raw) {
            model.startRecording(command)
            if let stored = defaults.string(forKey: "KiriShortcutsPress"), let combo = KeyCombo(stored: stored) {
                model.press([combo])
            }
        }
    }
}
#endif
