import AppKit
import SwiftUI

/// A command, as the menu bar has it: what the command palette lists and
/// runs. There is no list of commands beside the menus to keep in step
/// with them: the palette reads the menu bar itself (`MenuCommands.all`),
/// so whatever is in a menu is in the palette, with the key the menu shows.
struct MenuCommand: Equatable, Identifiable {
    /// The titles from the menu bar down to the item: View, Theme, Tide.
    let path: [String]
    /// "Save", or for one choice of several "Theme: Tide".
    let title: String
    /// The menu it is in: "File", "View ▸ Theme".
    let detail: String
    /// Its key equivalent, as this keyboard has it.
    let shortcut: KeyboardShortcut?
    /// It has a checkmark in its menu: a setting that is on, or the
    /// choice in force.
    let isOn: Bool
    /// One choice of several (a menu of its own with one item checked).
    let isChoice: Bool

    var id: String { path.joined(separator: "\u{1F}") }

    /// "Save, Command S": what VoiceOver hears.
    var spoken: String { shortcut.map { "\(title), \($0.spoken)" } ?? title }
}

/// The menu bar as a list of commands, and running one of them.
@MainActor enum MenuCommands {
    /// What is left out because it is not a command to look for: the
    /// system's items for the app as a whole (Hide, Quit), what belongs to
    /// the pointer and the menu bar (the window list, and what macOS adds
    /// to the end of every Edit menu: dictation, AutoFill, Emoji & Symbols,
    /// whose keys are the keyboard's and not always the ones their items
    /// say) and macOS's own window tab bar, which Kiri replaces.
    private static let skippedActions: Set<String> = [
        "hide:", "hideOtherApplications:", "unhideAllApplications:", "terminate:", "makeKeyAndOrderFront:",
        "startDictation:", "orderFrontCharacterPalette:", "toggleTabBar:", "toggleTabOverview:",
    ]

    /// Menus whose items are not commands: recent files and tabs are in
    /// the palette as what they are.
    static let skippedMenus: Set<String> = ["Open Recent", "Go to Tab"]

    /// The palette's own items: it is open already.
    static let ownTitles: Set<String> = [KiriCommands.paletteTitle, KiriCommands.goToFileTitle]

    /// Every command that can be run now, in the menus' order.
    ///
    /// Asked while the editor has the keyboard (before the palette's field
    /// takes it): what is on or off in the Edit menu depends on who has it.
    static func all() -> [MenuCommand] {
        guard let main = NSApp.mainMenu else { return [] }
        MainMenu.refresh()
        var found: [MenuCommand] = []
        for (index, top) in main.items.enumerated() {
            guard let menu = top.submenu else { continue }
            // The app's own menu has no title to read.
            let name = index == 0 ? appName : top.title
            walk(menu, path: [name], into: &found)
        }
        // An item that is in two menus (Keyboard Shortcuts: the Window
        // menu lists the window, Help has the command) shows once, the
        // one with a key.
        var seen: [String: Int] = [:]
        var out: [MenuCommand] = []
        for command in found {
            if let at = seen[command.title] {
                if out[at].shortcut == nil, command.shortcut != nil { out[at] = command }
            } else {
                seen[command.title] = out.count
                out.append(command)
            }
        }
        return out
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    private static func walk(_ menu: NSMenu, path: [String], into found: inout [MenuCommand]) {
        guard menu !== NSApp.servicesMenu else { return }
        // AppKit's own items (Undo, Copy, …) are on or off by who has the keyboard.
        menu.update()
        let items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.isAlternate }
        // One choice of several: a menu with exactly one item checked and
        // no keys of its own. Its items read "Theme: Tide".
        let choices = path.count > 1 && items.count > 1 && items.filter { $0.state == .on }.count == 1
            && items.allSatisfy { $0.keyEquivalent.isEmpty && $0.submenu == nil }
        for item in items {
            let title = item.title
            if let submenu = item.submenu {
                if !skippedMenus.contains(title) { walk(submenu, path: path + [title], into: &found) }
                continue
            }
            guard item.isEnabled, !title.isEmpty, !ownTitles.contains(title) else { continue }
            if let action = item.action {
                let name = NSStringFromSelector(action)
                // (An underscore: AppKit's private items, such as AutoFill's.)
                if skippedActions.contains(name) || name.hasPrefix("_") { continue }
            } else if item.target == nil {
                continue
            }
            // "LF — macOS and Linux" is "Line Endings: LF" here.
            let short = title.components(separatedBy: " — ").first ?? title
            found.append(MenuCommand(path: path + [title], title: choices ? "\(path.last ?? ""): \(short)" : title,
                                     detail: path.joined(separator: " ▸ "), shortcut: shortcut(of: item),
                                     isOn: item.state == .on, isChoice: choices))
        }
    }

    /// The item's key as a `KeyboardShortcut`, so it is written and spoken
    /// as Kiri's own keys are.
    private static func shortcut(of item: NSMenuItem) -> KeyboardShortcut? {
        guard let character = item.keyEquivalent.first, item.keyEquivalent.count == 1 else { return nil }
        let mask = item.keyEquivalentModifierMask
        var modifiers: EventModifiers = []
        if mask.contains(.command) { modifiers.insert(.command) }
        if mask.contains(.shift) { modifiers.insert(.shift) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.control) { modifiers.insert(.control) }
        // A capital letter is the letter with Shift.
        var key = character
        if character.isLetter, character.isUppercase {
            modifiers.insert(.shift)
            key = Character(character.lowercased())
        }
        let special: [Character: KeyEquivalent] = [
            "\r": .return, "\t": .tab, "\u{1B}": .escape, " ": .space, "\u{8}": .delete, "\u{7F}": .delete,
            Character(UnicodeScalar(NSUpArrowFunctionKey)!): .upArrow, Character(UnicodeScalar(NSDownArrowFunctionKey)!): .downArrow,
            Character(UnicodeScalar(NSLeftArrowFunctionKey)!): .leftArrow, Character(UnicodeScalar(NSRightArrowFunctionKey)!): .rightArrow,
        ]
        return KeyboardShortcut(special[key] ?? KeyEquivalent(key), modifiers: modifiers)
    }

    /// The menu and the place in it of the item at `path`, as the menus
    /// are now. (An item is never held on to: SwiftUI makes its menus'
    /// items anew when it brings them up to date.)
    static func find(_ path: [String]) -> (menu: NSMenu, index: Int)? {
        guard var menu = NSApp.mainMenu, let first = path.first else { return nil }
        let top = menu.items.enumerated().first { index, item in (index == 0 ? appName : item.title) == first && item.submenu != nil }
        guard let start = top?.element.submenu else { return nil }
        menu = start
        for (depth, title) in path.dropFirst().enumerated() {
            guard let index = menu.items.firstIndex(where: { $0.title == title && !$0.isHidden && !$0.isSeparatorItem }) else { return nil }
            if depth == path.count - 2 { return (menu, index) }
            guard let next = menu.items[index].submenu else { return nil }
            menu = next
        }
        return nil
    }

    /// Chooses the command's menu item, as a click on it or its key does.
    /// False when it is no longer there or is off now.
    ///
    /// Call it with the keyboard where the command is to act: Copy and
    /// Undo go to whoever has it.
    @discardableResult
    static func perform(_ command: MenuCommand) -> Bool {
        MainMenu.refresh()
        guard let (menu, index) = find(command.path) else { return false }
        menu.update()
        guard menu.items[index].isEnabled else { return false }
        menu.performActionForItem(at: index)
        return true
    }
}
