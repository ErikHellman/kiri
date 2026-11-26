import SwiftUI

/// The menus' keys, as they are now: what Kiri comes with
/// (`ShortcutCommand.defaults`) or what was set in Settings ▸ Shortcuts
/// (`ShortcutStore`). The menus, the tooltips and the Keyboard Shortcuts
/// window all read them here, so they can't drift apart. Nil: the command
/// has no key.
@MainActor enum Keys {
    static var settings: KeyboardShortcut? { ShortcutStore.shared.shortcut(.settings) }
    static var installCommandLineTool: KeyboardShortcut? { ShortcutStore.shared.shortcut(.installCommandLineTool) }
    static var checkForUpdates: KeyboardShortcut? { ShortcutStore.shared.shortcut(.checkForUpdates) }
    static var new: KeyboardShortcut? { ShortcutStore.shared.shortcut(.new) }
    static var newTab: KeyboardShortcut? { ShortcutStore.shared.shortcut(.newTab) }
    static var open: KeyboardShortcut? { ShortcutStore.shared.shortcut(.open) }
    static var openFolder: KeyboardShortcut? { ShortcutStore.shared.shortcut(.openFolder) }
    static var goToFile: KeyboardShortcut? { ShortcutStore.shared.shortcut(.goToFile) }
    static var close: KeyboardShortcut? { ShortcutStore.shared.shortcut(.close) }
    static var closeWindow: KeyboardShortcut? { ShortcutStore.shared.shortcut(.closeWindow) }
    static var closeAll: KeyboardShortcut? { ShortcutStore.shared.shortcut(.closeAll) }
    static var save: KeyboardShortcut? { ShortcutStore.shared.shortcut(.save) }
    static var saveAs: KeyboardShortcut? { ShortcutStore.shared.shortcut(.saveAs) }
    static var revertToSaved: KeyboardShortcut? { ShortcutStore.shared.shortcut(.revertToSaved) }
    static var find: KeyboardShortcut? { ShortcutStore.shared.shortcut(.find) }
    static var findAndReplace: KeyboardShortcut? { ShortcutStore.shared.shortcut(.findAndReplace) }
    static var findNext: KeyboardShortcut? { ShortcutStore.shared.shortcut(.findNext) }
    static var findPrevious: KeyboardShortcut? { ShortcutStore.shared.shortcut(.findPrevious) }
    static var useSelectionForFind: KeyboardShortcut? { ShortcutStore.shared.shortcut(.useSelectionForFind) }
    static var jumpToSelection: KeyboardShortcut? { ShortcutStore.shared.shortcut(.jumpToSelection) }
    static var makeUpperCase: KeyboardShortcut? { ShortcutStore.shared.shortcut(.makeUpperCase) }
    static var makeLowerCase: KeyboardShortcut? { ShortcutStore.shared.shortcut(.makeLowerCase) }
    static var capitalize: KeyboardShortcut? { ShortcutStore.shared.shortcut(.capitalize) }
    static var goToLine: KeyboardShortcut? { ShortcutStore.shared.shortcut(.goToLine) }
    static var palette: KeyboardShortcut? { ShortcutStore.shared.shortcut(.palette) }
    static var toggleSidebar: KeyboardShortcut? { ShortcutStore.shared.shortcut(.toggleSidebar) }
    static var focusSidebar: KeyboardShortcut? { ShortcutStore.shared.shortcut(.focusSidebar) }
    static var refreshFolder: KeyboardShortcut? { ShortcutStore.shared.shortcut(.refreshFolder) }
    static var bigger: KeyboardShortcut? { ShortcutStore.shared.shortcut(.bigger) }
    static var smaller: KeyboardShortcut? { ShortcutStore.shared.shortcut(.smaller) }
    static var actualSize: KeyboardShortcut? { ShortcutStore.shared.shortcut(.actualSize) }
    static var wrapLines: KeyboardShortcut? { ShortcutStore.shared.shortcut(.wrapLines) }
    static var markdownPreview: KeyboardShortcut? { ShortcutStore.shared.shortcut(.markdownPreview) }
    static var splitEditor: KeyboardShortcut? { ShortcutStore.shared.shortcut(.splitEditor) }
    static var previewToSide: KeyboardShortcut? { ShortcutStore.shared.shortcut(.previewToSide) }
    static var swapSides: KeyboardShortcut? { ShortcutStore.shared.shortcut(.swapSides) }
    static var focusLeftSide: KeyboardShortcut? { ShortcutStore.shared.shortcut(.focusLeftSide) }
    static var focusRightSide: KeyboardShortcut? { ShortcutStore.shared.shortcut(.focusRightSide) }
    static var typingAnimations: KeyboardShortcut? { ShortcutStore.shared.shortcut(.typingAnimations) }
    static var chooseLanguage: KeyboardShortcut? { ShortcutStore.shared.shortcut(.chooseLanguage) }
    static var byteOrderMark: KeyboardShortcut? { ShortcutStore.shared.shortcut(.byteOrderMark) }
    static var shiftRight: KeyboardShortcut? { ShortcutStore.shared.shortcut(.shiftRight) }
    static var shiftLeft: KeyboardShortcut? { ShortcutStore.shared.shortcut(.shiftLeft) }
    static var toggleComment: KeyboardShortcut? { ShortcutStore.shared.shortcut(.toggleComment) }
    static var nextTab: KeyboardShortcut? { ShortcutStore.shared.shortcut(.nextTab) }
    static var previousTab: KeyboardShortcut? { ShortcutStore.shared.shortcut(.previousTab) }
    static var moveTabToNewWindow: KeyboardShortcut? { ShortcutStore.shared.shortcut(.moveTabToNewWindow) }
    static var moveToOtherSide: KeyboardShortcut? { ShortcutStore.shared.shortcut(.moveToOtherSide) }
    static var mergeAllWindows: KeyboardShortcut? { ShortcutStore.shared.shortcut(.mergeAllWindows) }
    static var bringAllToFront: KeyboardShortcut? { ShortcutStore.shared.shortcut(.bringAllToFront) }
    static var shortcuts: KeyboardShortcut? { ShortcutStore.shared.shortcut(.shortcuts) }
    static var commandLineHelp: KeyboardShortcut? { ShortcutStore.shared.shortcut(.commandLineHelp) }
    static var whatsNew: KeyboardShortcut? { ShortcutStore.shared.shortcut(.whatsNew) }
    static var sendFeedback: KeyboardShortcut? { ShortcutStore.shared.shortcut(.sendFeedback) }

    /// ⌘1 … ⌘9 pick a tab by position. (Not changeable: `FixedKey.kiri`.)
    static func tab(_ n: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
    }

    /// "Go to Line (⌘L)", or the name alone for a command with no key.
    static func help(_ text: String, _ command: ShortcutCommand) -> String {
        ShortcutStore.shared[command].map { "\(text) (\($0.glyphs))" } ?? text
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
            case "?": "Question Mark"
            case ",": "Comma"
            case ".": "Period"
            case "[": "Left Bracket"
            case "]": "Right Bracket"
            case "+": "Plus"
            case "-": "Minus"
            case "`": "Backtick"
            case "\\": "Backslash"
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

        /// A command's key, or a note that it has none (set one in Settings ▸ Shortcuts).
        init(_ title: String, _ shortcut: KeyboardShortcut?) {
            self.init(title, shortcut?.glyphs ?? "No key")
        }
    }

    let title: String
    let systemImage: String
    let items: [Item]
    var id: String { title }

    /// Built when asked, from the keys as they are now.
    @MainActor static var all: [ShortcutGroup] {
        [
        ShortcutGroup(title: "Files", systemImage: "doc", items: [
            Item("New document", Keys.new),
            Item("New tab", Keys.newTab),
            Item("Open…", Keys.open),
            Item("Open folder…", Keys.openFolder),
            Item("Save", Keys.save),
            Item("Save as…", Keys.saveAs),
            Item("Close tab", Keys.close),
            Item("Close window", Keys.closeWindow),
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
        ShortcutGroup(title: "Side by side", systemImage: "rectangle.split.2x1", items: [
            Item("Split editor / close split", Keys.splitEditor),
            Item("Open a file or tab to the side", "⌥-click it"),
            Item("Open the sidebar's or the palette's file to the side", "⌥↩"),
            Item("Open to the side by dragging", "Drag a tab or a file to a side"),
            Item("Keyboard to the left / right side", "\(g(Keys.focusLeftSide))  \(g(Keys.focusRightSide))"),
            Item("Markdown or SVG preview beside its text", Keys.previewToSide),
            Item("Swap sides", "View menu"),
            Item("Move tab to the other side", "Window menu"),
            Item("Half and half", "Double-click the gap"),
        ]),
        ShortcutGroup(title: "Editing", systemImage: "pencil", items: [
            Item("Undo", "⌘Z"),
            Item("Redo", "⇧⌘Z"),
            Item("Cut, copy, paste", "⌘X  ⌘C  ⌘V"),
            Item("Select all", "⌘A"),
            Item("Shift lines right", Keys.shiftRight),
            Item("Shift lines left", Keys.shiftLeft),
            Item("Comment / uncomment lines", Keys.toggleComment),
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
            Item("Open file in a tab to stay, and edit it", "↩"),
            Item("Show file in the preview tab, stay here", "Space"),
            Item("Jump to a name", "Type its first letters"),
            Item("Find a file or folder anywhere in the folder", Keys.find),
            Item("Next / previous found, in the sidebar's find field", "↓  ↑"),
            Item("In the find field: keep the row found / go back", "↩  ⎋"),
            Item("Back to the editor", "⎋"),
        ]),
        ShortcutGroup(title: "Find", systemImage: "magnifyingglass", items: [
            Item("Find", Keys.find),
            Item("Find and replace", Keys.findAndReplace),
            Item("Find next", Keys.findNext),
            Item("Find previous", Keys.findPrevious),
            Item("Find in the sidebar, when it has the keyboard", Keys.find),
            Item("Next / previous file found, in the sidebar", "\(g(Keys.findNext))  \(g(Keys.findPrevious))"),
            Item("Next / previous match, in the find field", "↩  ⇧↩"),
            Item("Replace and find the next, in the replace field", "↩"),
            Item("Between the find and replace fields", "⇥  ⇧⇥"),
            Item("Use selection for find", Keys.useSelectionForFind),
            Item("Jump to selection", Keys.jumpToSelection),
            Item("Close find bar", "⎋"),
        ]),
        ShortcutGroup(title: "Command palette", systemImage: "command", items: [
            Item("Open / close the palette", Keys.palette),
            Item("Go to a file (the palette)", Keys.goToFile),
            Item("Choose a result", "↑  ↓"),
            Item("Run the chosen result", "↩"),
            Item("Commands only", "Type >"),
            Item("A line of the document (Go to Line)", "Type :42"),
            Item("Close the palette", "⎋"),
        ]),
        ShortcutGroup(title: "Language", systemImage: "chevron.left.forwardslash.chevron.right", items: [
            Item("Choose the document's language", Keys.chooseLanguage),
            Item("Find one by name or file extension", "Type rust, rs, yml…"),
            Item("Choose a language / keep it", "↑  ↓  ↩"),
            Item("Close, putting back the one before", "⎋"),
        ]),
        ShortcutGroup(title: "Moving around", systemImage: "arrow.up.and.down.text.horizontal", items: [
            Item("Go to line (or line:column)", Keys.goToLine),
            Item("Keep the line / go back, while a line is typed", "↩  ⎋"),
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
            Item("Markdown or SVG preview / text", Keys.markdownPreview),
            Item("Full screen", "⌃⌘F"),
            Item("Keyboard shortcuts", Keys.shortcuts),
        ]),
        ShortcutGroup(title: "Menus", systemImage: "menubar.rectangle", items: [
            Item("Language, encoding, line endings", "Format menu"),
            Item("Theme, appearance, motion, typing animations", "View menu"),
            Item("Open the menu bar", "⌃F2"),
            Item("Search all menus", "Help menu"),
            Item("The kiri command's options and examples", "Help menu"),
            Item("Send feedback", "Help menu"),
        ]),
        ]
    }

    /// A key in a line with others: "—" for one that has none.
    @MainActor private static func g(_ shortcut: KeyboardShortcut?) -> String { shortcut?.glyphs ?? "—" }
}
