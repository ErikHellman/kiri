import SwiftUI

/// Kiri's own key equivalents, shared by the menus and the Keyboard
/// Shortcuts window so the two can't drift apart.
enum Keys {
    /// File ▸ Open… is `DocumentGroup`'s own; its key is here for the
    /// places that name it (the first-run hint, the Keyboard Shortcuts window).
    static let open = KeyboardShortcut("o", modifiers: .command)
    static let settings = KeyboardShortcut(",", modifiers: .command)
    static let newTab = KeyboardShortcut("t", modifiers: .command)
    static let find = KeyboardShortcut("f", modifiers: .command)
    static let findAndReplace = KeyboardShortcut("f", modifiers: [.option, .command])
    static let findNext = KeyboardShortcut("g", modifiers: .command)
    static let findPrevious = KeyboardShortcut("g", modifiers: [.shift, .command])
    static let useSelectionForFind = KeyboardShortcut("e", modifiers: .command)
    static let jumpToSelection = KeyboardShortcut("j", modifiers: .command)
    static let goToLine = KeyboardShortcut("l", modifiers: .command)
    static let shiftRight = KeyboardShortcut("]", modifiers: .command)
    static let shiftLeft = KeyboardShortcut("[", modifiers: .command)
    static let bigger = KeyboardShortcut("+", modifiers: .command)
    static let smaller = KeyboardShortcut("-", modifiers: .command)
    static let actualSize = KeyboardShortcut("0", modifiers: .command)
    static let wrapLines = KeyboardShortcut("w", modifiers: [.control, .command])
    static let nextTab = KeyboardShortcut("]", modifiers: [.shift, .command])
    static let previousTab = KeyboardShortcut("[", modifiers: [.shift, .command])
    static let shortcuts = KeyboardShortcut("/", modifiers: .command)
    static let openFolder = KeyboardShortcut("o", modifiers: [.shift, .command])
    static let toggleSidebar = KeyboardShortcut("s", modifiers: [.control, .command])
    static let focusSidebar = KeyboardShortcut("e", modifiers: [.shift, .command])

    /// ⌘1 … ⌘9 pick a tab by position.
    static func tab(_ n: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
    }
}

extension KeyboardShortcut {
    /// How the menu bar writes it, such as "⇧⌘]".
    var glyphs: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.glyph
    }

    /// How VoiceOver should say it, such as "Shift Command O".
    var spoken: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        return (words + [key.spoken]).joined(separator: " ")
    }
}

extension KeyEquivalent {
    var glyph: String {
        switch self {
        case .tab: "⇥"
        case .return: "↩"
        case .escape: "⎋"
        case .space: "Space"
        case .delete: "⌫"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        default: String(character).uppercased()
        }
    }

    var spoken: String {
        switch self {
        case .tab: "Tab"
        case .return: "Return"
        case .escape: "Escape"
        case .space: "Space"
        case .delete: "Delete"
        case .upArrow: "Up Arrow"
        case .downArrow: "Down Arrow"
        case .leftArrow: "Left Arrow"
        case .rightArrow: "Right Arrow"
        default:
            switch character {
            case "/": "Slash"
            case ",": "Comma"
            case ".": "Period"
            case "[": "Left Bracket"
            case "]": "Right Bracket"
            case "+": "Plus"
            case "-": "Minus"
            case "`": "Backtick"
            default: String(character).uppercased()
            }
        }
    }
}

/// The Keyboard Shortcuts window's contents: every feature and how to reach
/// it, Kiri's own keys and the macOS ones Kiri gets from AppKit.
struct ShortcutGroup: Identifiable {
    struct Item: Identifiable {
        let title: String
        let keys: String
        var id: String { title }

        init(_ title: String, _ keys: String) {
            self.title = title
            self.keys = keys
        }

        init(_ title: String, _ shortcut: KeyboardShortcut) {
            self.init(title, shortcut.glyphs)
        }
    }

    let title: String
    let systemImage: String
    let items: [Item]
    var id: String { title }

    static let all: [ShortcutGroup] = [
        ShortcutGroup(title: "Files", systemImage: "doc", items: [
            Item("New document", "⌘N"),
            Item("New tab", Keys.newTab),
            Item("Open…", Keys.open),
            Item("Open folder…", Keys.openFolder),
            Item("Save", "⌘S"),
            Item("Duplicate", "⇧⌘S"),
            Item("Save as…", "⌥⇧⌘S"),
            Item("Close tab", "⌘W"),
            Item("Settings…", Keys.settings),
            Item("Quit", "⌘Q"),
        ]),
        ShortcutGroup(title: "Tabs", systemImage: "rectangle.stack", items: [
            Item("Next tab", Keys.nextTab),
            Item("Previous tab", Keys.previousTab),
            Item("Next / previous tab", "⌃⇥  ⌃⇧⇥"),
            Item("Go to tab 1 – 9", "⌘1 – ⌘9"),
            Item("Cycle windows", "⌘`"),
        ]),
        ShortcutGroup(title: "Editing", systemImage: "pencil", items: [
            Item("Undo", "⌘Z"),
            Item("Redo", "⇧⌘Z"),
            Item("Cut, copy, paste", "⌘X  ⌘C  ⌘V"),
            Item("Select all", "⌘A"),
            Item("Shift lines right", Keys.shiftRight),
            Item("Shift lines left", Keys.shiftLeft),
            Item("Emoji & symbols", "⌃⌘Space"),
        ]),
        ShortcutGroup(title: "Folder sidebar", systemImage: "sidebar.left", items: [
            Item("Show / hide sidebar", Keys.toggleSidebar),
            Item("Jump between sidebar and editor", Keys.focusSidebar),
            Item("Move up / down", "↑  ↓"),
            Item("First / last row", "Home  End"),
            Item("Page up / down", "PgUp  PgDn"),
            Item("Close folder / go to parent", "←"),
            Item("Open folder / go inside", "→"),
            Item("Open file and edit it", "↩"),
            Item("Open file or folder, stay here", "Space"),
            Item("Jump to a name", "Type its first letters"),
            Item("Back to the editor", "⎋"),
        ]),
        ShortcutGroup(title: "Find", systemImage: "magnifyingglass", items: [
            Item("Find", Keys.find),
            Item("Find and replace", Keys.findAndReplace),
            Item("Find next", Keys.findNext),
            Item("Find previous", Keys.findPrevious),
            Item("Next / previous match, in the find field", "↩  ⇧↩"),
            Item("Replace and find the next, in the replace field", "↩"),
            Item("Between the find and replace fields", "⇥  ⇧⇥"),
            Item("Use selection for find", Keys.useSelectionForFind),
            Item("Jump to selection", Keys.jumpToSelection),
            Item("Close find bar", "⎋"),
        ]),
        ShortcutGroup(title: "Moving around", systemImage: "arrow.up.and.down.text.horizontal", items: [
            Item("Go to line (or line:column)", Keys.goToLine),
            Item("Keep the line / go back, in Go to Line", "↩  ⎋"),
            Item("Start / end of line", "⌘←  ⌘→"),
            Item("Start / end of document", "⌘↑  ⌘↓"),
            Item("Word left / right", "⌥←  ⌥→"),
            Item("Extend selection", "⇧ + any move"),
        ]),
        ShortcutGroup(title: "View", systemImage: "textformat.size", items: [
            Item("Bigger text", Keys.bigger),
            Item("Smaller text", Keys.smaller),
            Item("Actual size", Keys.actualSize),
            Item("Wrap lines", Keys.wrapLines),
            Item("Full screen", "⌃⌘F"),
            Item("Keyboard shortcuts", Keys.shortcuts),
        ]),
        ShortcutGroup(title: "Menus", systemImage: "menubar.rectangle", items: [
            Item("Language, encoding, line endings", "Format menu"),
            Item("Theme, appearance, motion, typing animations", "View menu"),
            Item("Open the menu bar", "⌃F2"),
            Item("Search all menus", "⇧⌘/"),
        ]),
    ]
}
