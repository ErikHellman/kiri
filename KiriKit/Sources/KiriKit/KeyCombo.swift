import Foundation

/// A key and the modifiers held with it: a keyboard shortcut, free of
/// AppKit and SwiftUI so it tests on Linux. The app turns it into a
/// `KeyboardShortcut` for its menus and reads one from a key press in
/// Settings ▸ Shortcuts.
///
/// A combo is kept as the menu bar matches it: a letter is lowercase, with
/// Shift as a modifier; any other character is the one the key types, so
/// ⇧⌘/ is "?" with ⌘ (the character carries the Shift).
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// In the order the menu bar writes them: ⌃⌥⇧⌘.
        static let ordered: [(Modifiers, glyph: String, name: String, word: String)] = [
            (.control, "⌃", "ctrl", "Control"), (.option, "⌥", "opt", "Option"),
            (.shift, "⇧", "shift", "Shift"), (.command, "⌘", "cmd", "Command"),
        ]
    }

    public enum Key: Hashable, Sendable {
        /// A key that types a character: a lowercase letter, a digit or
        /// punctuation, as the keyboard types it.
        case character(Character)
        case `return`, tab, space, delete, forwardDelete, escape
        case up, down, left, right, home, end, pageUp, pageDown
        /// F1 to F20.
        case function(Int)

        /// The names a combo is stored with, for the keys that type no character.
        static let names: [(Key, name: String, glyph: String, word: String)] = [
            (.return, "return", "↩", "Return"), (.tab, "tab", "⇥", "Tab"), (.space, "space", "Space", "Space"),
            (.delete, "delete", "⌫", "Delete"), (.forwardDelete, "fwddelete", "⌦", "Forward Delete"),
            (.escape, "escape", "⎋", "Escape"), (.up, "up", "↑", "Up Arrow"), (.down, "down", "↓", "Down Arrow"),
            (.left, "left", "←", "Left Arrow"), (.right, "right", "→", "Right Arrow"), (.home, "home", "↖", "Home"),
            (.end, "end", "↘", "End"), (.pageUp, "pageup", "⇞", "Page Up"), (.pageDown, "pagedown", "⇟", "Page Down"),
        ]

        public var isFunctionKey: Bool {
            if case .function = self { return true }
            return false
        }

        var name: String {
            switch self {
            case .character(let c): String(c)
            case .function(let n): "f\(n)"
            default: Self.names.first { $0.0 == self }!.name
            }
        }

        var glyph: String {
            switch self {
            case .character(let c): String(c).uppercased()
            case .function(let n): "F\(n)"
            default: Self.names.first { $0.0 == self }!.glyph
            }
        }

        var word: String {
            switch self {
            case .character(let c): Self.characterWords[c] ?? String(c).uppercased()
            case .function(let n): "F\(n)"
            default: Self.names.first { $0.0 == self }!.word
            }
        }

        static let characterWords: [Character: String] = [
            "/": "Slash", "?": "Question Mark", ",": "Comma", ".": "Period", "[": "Left Bracket", "]": "Right Bracket",
            "+": "Plus", "-": "Minus", "=": "Equals", "`": "Backtick", "\\": "Backslash", "'": "Apostrophe",
            ";": "Semicolon", "<": "Less Than", ">": "Greater Than",
        ]

        init?(name: String) {
            if name.count == 1, let c = name.first {
                self = .character(c)
            } else if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...20).contains(n) {
                self = .function(n)
            } else if let found = Self.names.first(where: { $0.name == name }) {
                self = found.0
            } else {
                return nil
            }
        }
    }

    public var key: Key
    public var modifiers: Modifiers

    /// A capital letter becomes the lowercase one with Shift, as the menu
    /// bar has it.
    public init(_ key: Key, _ modifiers: Modifiers) {
        if case .character(let c) = key, c.isLetter, c.isUppercase {
            self.key = .character(Character(c.lowercased()))
            self.modifiers = modifiers.union(.shift)
        } else {
            self.key = key
            self.modifiers = modifiers
        }
    }

    public init(_ character: Character, _ modifiers: Modifiers) {
        self.init(.character(character), modifiers)
    }

    /// How the menu bar writes it, such as "⇧⌘]".
    public var glyphs: String {
        Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.glyph).joined() + key.glyph
    }

    /// How VoiceOver should say it, such as "Shift Command O".
    public var spoken: String {
        (Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.word) + [key.word]).joined(separator: " ")
    }

    public var description: String { glyphs }

    // MARK: Storage

    /// How it is kept in the preferences: the modifiers' names, each with a
    /// "+", then the key, such as "shift+cmd+s", "opt+cmd+left" or "cmd++".
    public var stored: String {
        Modifiers.ordered.filter { modifiers.contains($0.0) }.map { $0.name + "+" }.joined() + key.name
    }

    /// A combo read back from `stored`; nil for anything else.
    public init?(stored: String) {
        var rest = Substring(stored)
        var modifiers: Modifiers = []
        var matched = true
        while matched {
            matched = false
            for (modifier, _, name, _) in Modifiers.ordered where rest.count > name.count + 1 && rest.hasPrefix(name + "+") {
                modifiers.insert(modifier)
                rest = rest.dropFirst(name.count + 1)
                matched = true
            }
        }
        guard let key = Key(name: String(rest)) else { return nil }
        self.init(key, modifiers)
    }

    // MARK: What makes a shortcut

    /// Why this can't be a shortcut on its own: a key without ⌘ or ⌃ types
    /// in the text (⌥ makes letters like å and é, ⇧ capitals), so only a
    /// function key may go without them.
    public var needsCommandOrControl: Bool {
        !key.isFunctionKey && modifiers.isDisjoint(with: [.command, .control])
    }

    /// Keys macOS keeps for itself before any app sees them, or that every
    /// Mac app answers the same way, with what they do there.
    public static let systemWide: [KeyCombo: String] = [
        KeyCombo(.space, .command): "Spotlight",
        KeyCombo(.tab, .command): "switching apps",
        KeyCombo(.tab, [.shift, .command]): "switching apps",
        KeyCombo("`", .command): "cycling through Kiri's windows",
        KeyCombo(.space, [.control, .command]): "Emoji & Symbols",
        KeyCombo("q", [.control, .command]): "Lock Screen",
        KeyCombo("3", [.shift, .command]): "screenshots",
        KeyCombo("4", [.shift, .command]): "screenshots",
        KeyCombo("5", [.shift, .command]): "screenshots",
        KeyCombo("#", .command): "screenshots",
        KeyCombo("$", .command): "screenshots",
        KeyCombo("%", .command): "screenshots",
        KeyCombo(.tab, .control): "the next tab",
        KeyCombo(.tab, [.shift, .control]): "the previous tab",
        KeyCombo(.function(2), .control): "the menu bar",
    ]

    /// Keys a text view on the Mac moves or edits with. A menu item on one
    /// of them is chosen in place of the move, so taking one is a choice
    /// to make knowingly.
    public static let textEditing: [KeyCombo: String] = {
        var keys: [KeyCombo: String] = [
            KeyCombo("a", .control): "moves to the start of the line",
            KeyCombo("e", .control): "moves to the end of the line",
            KeyCombo("b", .control): "moves back a character",
            KeyCombo("f", .control): "moves forward a character",
            KeyCombo("p", .control): "moves up a line",
            KeyCombo("n", .control): "moves down a line",
            KeyCombo("d", .control): "deletes the next character",
            KeyCombo("h", .control): "deletes the character before",
            KeyCombo("k", .control): "deletes to the end of the line",
            KeyCombo("y", .control): "pastes what ⌃K deleted",
            KeyCombo("t", .control): "swaps two characters",
            KeyCombo("o", .control): "opens a new line",
            KeyCombo("l", .control): "centers the caret's line",
            KeyCombo("v", .control): "scrolls down a page",
            KeyCombo(.delete, .command): "deletes to the start of the line",
            KeyCombo(.delete, .option): "deletes a word",
            KeyCombo(.up, .command): "goes to the start of the document",
            KeyCombo(.down, .command): "goes to the end of the document",
            KeyCombo(.left, .command): "goes to the start of the line",
            KeyCombo(.right, .command): "goes to the end of the line",
        ]
        for (combo, what) in keys where combo.key != .delete && combo.modifiers == .command {
            keys[KeyCombo(combo.key, [.shift, .command])] = what.replacingOccurrences(of: "goes", with: "selects")
        }
        return keys
    }()
}

/// Every command's shortcut: the defaults, and what the person changed.
/// Free of AppKit so it tests on Linux; `ShortcutStore` in the app keeps
/// one in the preferences and gives the menus their keys from it.
///
/// Only the changes are kept, so a command whose default changes in a
/// later version gets the new one, unless it was changed.
public struct ShortcutTable<ID: Hashable & Sendable & RawRepresentable>: Sendable, Equatable where ID.RawValue == String {
    /// The keys commands come with; a command missing here has none.
    public let defaults: [ID: KeyCombo]
    /// A command given another key, or none (nil).
    public private(set) var changes: [ID: KeyCombo?]

    public init(defaults: [ID: KeyCombo], changes: [ID: KeyCombo?] = [:]) {
        self.defaults = defaults
        self.changes = [:]
        for (id, combo) in changes { set(id, combo) }
    }

    /// The table as the preferences keep it: each changed command's id with
    /// its key as `KeyCombo.stored`, or "" for none. Entries for commands
    /// that are gone, or keys that can't be read, are dropped.
    public init(defaults: [ID: KeyCombo], stored: [String: String]) {
        var changes: [ID: KeyCombo?] = [:]
        for (raw, value) in stored {
            guard let id = ID(rawValue: raw) else { continue }
            if value.isEmpty {
                changes[id] = .some(nil)
            } else if let combo = KeyCombo(stored: value) {
                changes[id] = combo
            }
        }
        self.init(defaults: defaults, changes: changes)
    }

    public var stored: [String: String] {
        var out: [String: String] = [:]
        for (id, combo) in changes { out[id.rawValue] = combo?.stored ?? "" }
        return out
    }

    /// The command's key now.
    public subscript(id: ID) -> KeyCombo? {
        if let changed = changes[id] { return changed }
        return defaults[id]
    }

    public func isChanged(_ id: ID) -> Bool { changes[id] != nil }
    public var hasChanges: Bool { !changes.isEmpty }

    /// Gives the command `combo` (nil: no key). The default again is no change.
    public mutating func set(_ id: ID, _ combo: KeyCombo?) {
        if combo == defaults[id] { changes[id] = nil } else { changes[id] = .some(combo) }
    }

    public mutating func reset(_ id: ID) { changes[id] = nil }
    public mutating func resetAll() { changes = [:] }

    /// The commands whose key is `combo`, in `order`.
    public func commands(with combo: KeyCombo, in order: [ID]) -> [ID] {
        order.filter { self[$0] == combo }
    }

    /// Each command that shares its key with another, with the others.
    public func conflicts(in order: [ID]) -> [ID: [ID]] {
        var byCombo: [KeyCombo: [ID]] = [:]
        for id in order { if let combo = self[id] { byCombo[combo, default: []].append(id) } }
        var out: [ID: [ID]] = [:]
        for ids in byCombo.values where ids.count > 1 {
            for id in ids { out[id] = ids.filter { $0 != id } }
        }
        return out
    }
}
