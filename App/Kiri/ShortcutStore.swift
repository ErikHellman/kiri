import AppKit
import KiriKit
import SwiftUI

/// A command whose key can be changed in Settings ▸ Shortcuts: every item
/// of Kiri's own menus (`KiriCommands`), with a key or without one. The
/// raw value is what the preferences keep, so it never changes.
enum ShortcutCommand: String, CaseIterable, Identifiable, Sendable {
    case settings, installCommandLineTool, checkForUpdates
    case new, newTab, open, openFolder, goToFile, close, closeWindow, closeAll, save, saveAs, revertToSaved
    case find, findAndReplace, findNext, findPrevious, useSelectionForFind, jumpToSelection
    case makeUpperCase, makeLowerCase, capitalize, goToLine
    case palette, toggleSidebar, focusSidebar, refreshFolder, bigger, smaller, actualSize, wrapLines, markdownPreview
    case splitEditor, previewToSide, swapSides, focusLeftSide, focusRightSide, typingAnimations
    case chooseLanguage, byteOrderMark, shiftRight, shiftLeft, toggleComment
    case nextTab, previousTab, moveTabToNewWindow, moveToOtherSide, mergeAllWindows, bringAllToFront
    case shortcuts, commandLineHelp, whatsNew, sendFeedback

    var id: String { rawValue }

    /// The menus, in the menu bar's order: what the list is grouped by.
    enum Menu: String, CaseIterable, Sendable {
        case app = "Kiri", file = "File", edit = "Edit", view = "View", format = "Format", window = "Window", help = "Help"
    }

    struct Info {
        /// The name in Settings: the menu item's, or both of an item that
        /// changes its name ("Show / Hide Sidebar").
        let title: String
        let menu: Menu
        /// A submenu it is in: "Find" for Edit ▸ Find ▸ Find Next.
        var submenu: String?
        /// The menu item's names, as the menu bar has them.
        var menuTitles: [String] = []
        /// More words it is found by ("indent" for Shift Right).
        var keywords: String = ""

        /// Where it is: "Edit ▸ Find".
        var place: String { [menu.rawValue, submenu].compactMap(\.self).joined(separator: " ▸ ") }
        var titles: [String] { menuTitles.isEmpty ? [title] : menuTitles }
    }

    var info: Info {
        switch self {
        case .settings: Info(title: "Settings…", menu: .app, keywords: "preferences")
        case .installCommandLineTool: Info(title: "Install Command Line Tool…", menu: .app, keywords: "kiri terminal")
        case .checkForUpdates: Info(title: "Check for Updates…", menu: .app)
        case .new: Info(title: "New", menu: .file, keywords: "document untitled")
        case .newTab: Info(title: "New Tab", menu: .file)
        case .open: Info(title: "Open…", menu: .file, keywords: "file")
        case .openFolder: Info(title: "Open Folder…", menu: .file, keywords: "directory project")
        case .goToFile: Info(title: KiriCommands.goToFileTitle, menu: .file, keywords: "quick open palette")
        case .close: Info(title: "Close", menu: .file, keywords: "tab")
        case .closeWindow: Info(title: "Close Window", menu: .file)
        case .closeAll: Info(title: "Close All", menu: .file)
        case .save: Info(title: "Save", menu: .file)
        case .saveAs: Info(title: "Save As…", menu: .file)
        case .revertToSaved: Info(title: "Revert to Saved", menu: .file, keywords: "undo changes")
        case .find: Info(title: "Find…", menu: .edit, submenu: "Find", keywords: "search")
        case .findAndReplace: Info(title: "Find and Replace…", menu: .edit, submenu: "Find", keywords: "search")
        case .findNext: Info(title: "Find Next", menu: .edit, submenu: "Find", keywords: "search")
        case .findPrevious: Info(title: "Find Previous", menu: .edit, submenu: "Find", keywords: "search")
        case .useSelectionForFind: Info(title: "Use Selection for Find", menu: .edit, submenu: "Find")
        case .jumpToSelection: Info(title: "Jump to Selection", menu: .edit, submenu: "Find", keywords: "scroll")
        case .makeUpperCase: Info(title: "Make Upper Case", menu: .edit, submenu: "Transformations", keywords: "capitals")
        case .makeLowerCase: Info(title: "Make Lower Case", menu: .edit, submenu: "Transformations")
        case .capitalize: Info(title: "Capitalize", menu: .edit, submenu: "Transformations")
        case .goToLine: Info(title: "Go to Line…", menu: .edit, keywords: "jump number")
        case .palette: Info(title: KiriCommands.paletteTitle, menu: .view, keywords: "commands search")
        case .toggleSidebar: Info(title: "Show / Hide Sidebar", menu: .view, menuTitles: ["Hide Sidebar", "Show Sidebar"], keywords: "folder")
        case .focusSidebar: Info(title: "Focus Sidebar / Editor", menu: .view, menuTitles: ["Focus Sidebar", "Focus Editor"], keywords: "folder")
        case .refreshFolder: Info(title: "Refresh Folder", menu: .view, keywords: "sidebar reload")
        case .bigger: Info(title: "Bigger Text", menu: .view, keywords: "zoom in larger font size")
        case .smaller: Info(title: "Smaller Text", menu: .view, keywords: "zoom out font size")
        case .actualSize: Info(title: "Actual Size", menu: .view, keywords: "zoom reset font size")
        case .wrapLines: Info(title: "Wrap Lines", menu: .view, keywords: "soft wrap")
        case .markdownPreview: Info(title: "Markdown / SVG Preview", menu: .view, menuTitles: ["Markdown Preview", "SVG Preview"], keywords: "render")
        case .splitEditor: Info(title: "Split Editor / Close Split", menu: .view, menuTitles: [KiriCommands.splitEditorTitle, KiriCommands.closeSplitTitle], keywords: "side by side")
        case .previewToSide: Info(title: KiriCommands.previewToSideTitle, menu: .view, keywords: "side by side split markdown svg")
        case .swapSides: Info(title: "Swap Sides", menu: .view, keywords: "side by side split")
        case .focusLeftSide: Info(title: "Focus Left Side", menu: .view, keywords: "side by side split")
        case .focusRightSide: Info(title: "Focus Right Side", menu: .view, keywords: "side by side split")
        case .typingAnimations: Info(title: "Typing Animations", menu: .view, keywords: "caret motion")
        case .chooseLanguage: Info(title: KiriCommands.chooseLanguageTitle, menu: .format, keywords: "syntax")
        case .byteOrderMark: Info(title: "Byte Order Mark", menu: .format, keywords: "bom encoding")
        case .shiftRight: Info(title: "Shift Right", menu: .format, keywords: "indent")
        case .shiftLeft: Info(title: "Shift Left", menu: .format, keywords: "outdent unindent")
        case .toggleComment: Info(title: "Toggle Comment", menu: .format, keywords: "comment uncomment")
        case .nextTab: Info(title: "Select Next Tab", menu: .window)
        case .previousTab: Info(title: "Select Previous Tab", menu: .window)
        case .moveTabToNewWindow: Info(title: "Move Tab to New Window", menu: .window)
        case .moveToOtherSide: Info(title: KiriCommands.moveToOtherSideTitle, menu: .window, keywords: "side by side split")
        case .mergeAllWindows: Info(title: "Merge All Windows", menu: .window)
        case .bringAllToFront: Info(title: "Bring All to Front", menu: .window)
        case .shortcuts: Info(title: "Keyboard Shortcuts", menu: .help, keywords: "keys")
        case .commandLineHelp: Info(title: "Command Line Tool", menu: .help, keywords: "kiri terminal")
        case .whatsNew: Info(title: "What's New in Kiri", menu: .help, keywords: "release notes")
        case .sendFeedback: Info(title: "Send Feedback…", menu: .help, keywords: "bug report")
        }
    }

    /// The keys Kiri comes with. The commands missing here have none.
    static let defaults: [ShortcutCommand: KeyCombo] = [
        .settings: KeyCombo(",", .command),
        .new: KeyCombo("n", .command),
        .newTab: KeyCombo("t", .command),
        .open: KeyCombo("o", .command),
        .openFolder: KeyCombo("o", [.shift, .command]),
        // The palette too, by the key other editors find a file with.
        .goToFile: KeyCombo("p", .command),
        .close: KeyCombo("w", .command),
        .closeWindow: KeyCombo("w", [.shift, .command]),
        .closeAll: KeyCombo("w", [.option, .command]),
        .save: KeyCombo("s", .command),
        .saveAs: KeyCombo("s", [.shift, .command]),
        .find: KeyCombo("f", .command),
        .findAndReplace: KeyCombo("f", [.option, .command]),
        .findNext: KeyCombo("g", .command),
        .findPrevious: KeyCombo("g", [.shift, .command]),
        .useSelectionForFind: KeyCombo("e", .command),
        .jumpToSelection: KeyCombo("j", .command),
        .goToLine: KeyCombo("l", .command),
        .palette: KeyCombo("k", .command),
        .toggleSidebar: KeyCombo("s", [.control, .command]),
        .focusSidebar: KeyCombo("e", [.shift, .command]),
        .bigger: KeyCombo("+", .command),
        .smaller: KeyCombo("-", .command),
        .actualSize: KeyCombo("0", .command),
        .wrapLines: KeyCombo("w", [.control, .command]),
        // P for preview, with the Control of the other "how this
        // document shows" keys. (⌘P is Go to File.)
        .markdownPreview: KeyCombo("p", [.control, .command]),
        // Side by side: the tab before beside this one, and back to one.
        .splitEditor: KeyCombo("\\", .command),
        // The Markdown preview beside its text: the preview's key with Option.
        .previewToSide: KeyCombo("p", [.option, .control, .command]),
        .focusLeftSide: KeyCombo(.left, [.option, .command]),
        .focusRightSide: KeyCombo(.right, [.option, .command]),
        // L for language, with the Control the other "set how this
        // document shows" keys have (⌃⌘W, ⌃⌘S). ⌘L is Go to Line, and
        // ⇧⌘L is macOS's Search With Google service.
        .chooseLanguage: KeyCombo("l", [.control, .command]),
        .shiftRight: KeyCombo("]", .command),
        .shiftLeft: KeyCombo("[", .command),
        .toggleComment: KeyCombo("/", .command),
        // Safari's keys for its tabs.
        .nextTab: KeyCombo("]", [.shift, .command]),
        .previousTab: KeyCombo("[", [.shift, .command]),
        // ⌘?, the Help key (⇧⌘/ on the keyboard). Written as "?" with
        // Command, as AppKit's own Help items are: an item on "/" with
        // Shift and Command is not matched by the key press, whose
        // character is "?". (macOS has a shortcut of its own on this key,
        // "Show Help menu": where that is on, the key opens the Help menu,
        // whose one item this is.)
        .shortcuts: KeyCombo("?", .command),
    ]
}

/// Every command's key: what Kiri comes with, and what was changed in
/// Settings ▸ Shortcuts, kept in the preferences under `prefsKey` as a
/// dictionary of the changes alone (`ShortcutTable.stored`). The menus
/// read their keys from here (`Keys`), so a change is in the menu bar,
/// the palette and Help ▸ Keyboard Shortcuts at once.
@MainActor @Observable final class ShortcutStore {
    static let shared = ShortcutStore()
    static let prefsKey = "keyboardShortcuts"

    private(set) var table: ShortcutTable<ShortcutCommand>

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: String] ?? [:]
        table = ShortcutTable(defaults: ShortcutCommand.defaults, stored: stored)
    }

    subscript(command: ShortcutCommand) -> KeyCombo? { table[command] }

    /// The key for the command's menu item. A key that was changed is
    /// the one pressed on this keyboard, so macOS doesn't move it to
    /// another key for the layout, as it does the ones Kiri comes with.
    func shortcut(_ command: ShortcutCommand) -> KeyboardShortcut? {
        table[command].map { $0.keyboardShortcut(localized: !table.isChanged(command)) }
    }

    func isChanged(_ command: ShortcutCommand) -> Bool { table.isChanged(command) }
    var hasChanges: Bool { table.hasChanges }

    /// Each command that shares its key with another, with the others.
    var conflicts: [ShortcutCommand: [ShortcutCommand]] { table.conflicts(in: ShortcutCommand.allCases) }

    /// The commands that have `combo` now.
    func commands(with combo: KeyCombo) -> [ShortcutCommand] { table.commands(with: combo, in: ShortcutCommand.allCases) }

    /// Gives the command `combo`, or no key with nil.
    func set(_ command: ShortcutCommand, _ combo: KeyCombo?) {
        table.set(command, combo)
        changed(command, combo == nil ? "none" : "set")
    }

    func reset(_ command: ShortcutCommand) {
        table.reset(command)
        changed(command, "reset")
    }

    func resetAll() {
        table.resetAll()
        changed(nil, "reset_all")
    }

    private func changed(_ command: ShortcutCommand?, _ kind: String) {
        save(table.stored)
        var props: [String: Any] = ["kind": kind]
        if let command { props["command"] = command.rawValue }
        Telemetry.track("shortcut_change", props)
        // SwiftUI gives a menu item its new key when the menu is brought
        // up to date, which a key press alone doesn't do (`FrontEditor`
        // does it only for keys with ⌘ or ⌃): do it now, once the menus'
        // body has seen the change.
        DispatchQueue.main.async { MainMenu.refresh() }
    }

    private func save(_ stored: [String: String]) {
        #if DEBUG || KIRI_SELFTEST
        // A test launch leaves the person's preferences as they are: its
        // keys are kept among the launch's arguments, where a setting
        // given on the command line lives.
        if SelfTest.isTestLaunch { SelfTest.setArgument(Self.prefsKey, plist: stored.isEmpty ? nil : stored); return }
        #endif
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.prefsKey)
        } else {
            UserDefaults.standard.set(stored, forKey: Self.prefsKey)
        }
    }

    #if DEBUG || KIRI_SELFTEST
    /// For a test: the table as it was, put back.
    func selfTestRestore(_ table: ShortcutTable<ShortcutCommand>) {
        self.table = table
        changed(nil, "restore")
    }
    #endif
}

/// Keys that Settings ▸ Shortcuts shows but can't change: macOS's own
/// items in Kiri's menus (Copy, Quit), and the keys Kiri answers outside
/// its menus. A command can't be given one of them.
struct FixedKey: Identifiable, Equatable {
    let title: String
    /// Whose it is: "macOS" or "Kiri".
    let owner: String
    /// What the key caps show: "⌘C", or "⌘1 – ⌘9".
    let keys: String
    /// The keys themselves, for the conflict check.
    let combos: [KeyCombo]
    var id: String { title + keys }

    /// The keys Kiri answers that are not in a menu of their own.
    static let kiri: [FixedKey] = [
        FixedKey(title: "Go to Tab 1 – 9", owner: "Kiri", keys: "⌘1 – ⌘9",
                 combos: (1...9).map { KeyCombo(Character(String($0)), .command) }),
        FixedKey(title: "Next / Previous Tab", owner: "Kiri", keys: "⌃⇥  ⌃⇧⇥",
                 combos: [KeyCombo(.tab, .control), KeyCombo(.tab, [.shift, .control])]),
        FixedKey(title: "Open to the Side, in the sidebar and the palette", owner: "Kiri", keys: "⌥↩",
                 combos: [KeyCombo(.return, .option)]),
    ]

    /// macOS's items in the menu bar that have a key (Undo, Copy, Quit,
    /// Minimize, Enter Full Screen…): every item with a key that is not
    /// one of Kiri's commands.
    @MainActor static func menuBar() -> [FixedKey] {
        guard let main = NSApp.mainMenu else { return [] }
        MainMenu.refresh()
        let ours = Set(ShortcutCommand.allCases.flatMap(\.info.titles))
        var found: [FixedKey] = []
        func walk(_ menu: NSMenu) {
            guard menu !== NSApp.servicesMenu else { return }
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let sub = item.submenu {
                    if !MenuCommands.skippedMenus.contains(item.title) { walk(sub) }
                    continue
                }
                guard !ours.contains(item.title), let combo = KeyCombo(menuItem: item) else { continue }
                // One of each (Keyboard Shortcuts is in the Window menu too).
                guard !found.contains(where: { $0.combos == [combo] }) else { continue }
                found.append(FixedKey(title: item.title, owner: "macOS", keys: combo.glyphs, combos: [combo]))
            }
        }
        for top in main.items { if let menu = top.submenu { walk(menu) } }
        return found
    }
}

extension KeyCombo {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let c): KeyEquivalent(c)
        case .return: .return
        case .tab: .tab
        case .space: .space
        case .delete: .delete
        case .forwardDelete: .deleteForward
        case .escape: .escape
        case .up: .upArrow
        case .down: .downArrow
        case .left: .leftArrow
        case .right: .rightArrow
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .function(let n): KeyEquivalent(Character(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!))
        }
    }

    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        if modifiers.contains(.control) { out.insert(.control) }
        return out
    }

    /// For a menu item. `localized`: macOS may move it to another key on a
    /// keyboard layout that has the character elsewhere (Kiri's own keys);
    /// a key someone pressed stays where they pressed it.
    func keyboardShortcut(localized: Bool) -> KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers, localization: localized ? .automatic : .custom)
    }

    /// AppKit's function-key characters (`NSUpArrowFunctionKey`…) and the
    /// control characters of Return, Tab, Delete and Escape.
    private static let specialCharacters: [Int: Key] = [
        NSUpArrowFunctionKey: .up, NSDownArrowFunctionKey: .down, NSLeftArrowFunctionKey: .left,
        NSRightArrowFunctionKey: .right, NSHomeFunctionKey: .home, NSEndFunctionKey: .end,
        NSPageUpFunctionKey: .pageUp, NSPageDownFunctionKey: .pageDown, NSDeleteFunctionKey: .forwardDelete,
        0x0D: .return, 0x03: .return, 0x09: .tab, 0x19: .tab, 0x20: .space, 0x7F: .delete, 0x08: .delete, 0x1B: .escape,
    ]

    private static func key(of character: Character) -> Key {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return .character(character) }
        let value = Int(scalar.value)
        if let special = specialCharacters[value] { return special }
        if (NSF1FunctionKey...NSF20FunctionKey).contains(value) { return .function(value - NSF1FunctionKey + 1) }
        return .character(character)
    }

    /// A menu item's key; nil when it has none.
    init?(menuItem item: NSMenuItem) {
        guard let character = item.keyEquivalent.first, item.keyEquivalent.count == 1 else { return nil }
        self.init(Self.key(of: character), Self.modifiers(item.keyEquivalentModifierMask))
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
        var out: Modifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.control) { out.insert(.control) }
        return out
    }

    /// What a key press could mean as a shortcut, the likelier first: for
    /// a key that Shift gives another character (⇧/ is ?), the character
    /// typed without Shift as a modifier, as the menu bar matches it ("?"
    /// with ⌘), then the key's own character with Shift ("/" with ⇧⌘),
    /// which is how some of Kiri's own keys are written (⇧⌘] is Select
    /// Next Tab). Empty for a key that is only a modifier.
    static func candidates(_ event: NSEvent) -> [KeyCombo] {
        guard event.type == .keyDown else { return [] }
        let flags = modifiers(event.modifierFlags)
        // Keys that type no character are told by their key code, since
        // ⌥ and ⌃ change what some of them say.
        let byCode: [UInt16: Key] = [36: .return, 76: .return, 48: .tab, 49: .space, 51: .delete, 117: .forwardDelete, 53: .escape,
                                     126: .up, 125: .down, 123: .left, 124: .right, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown]
        if let key = byCode[event.keyCode] { return [KeyCombo(key, flags)] }
        guard let typed = event.charactersIgnoringModifiers?.first else { return [] }
        let key = Self.key(of: typed)
        if case .function = key { return [KeyCombo(key, flags)] }
        // A letter: lowercase, with Shift (`init`).
        if typed.isLetter { return [KeyCombo(key, flags)] }
        guard flags.contains(.shift), let plain = event.characters(byApplyingModifiers: [])?.first, plain != typed else {
            return [KeyCombo(key, flags)]
        }
        return [KeyCombo(key, flags.subtracting(.shift)), KeyCombo(.character(plain), flags)]
    }
}
