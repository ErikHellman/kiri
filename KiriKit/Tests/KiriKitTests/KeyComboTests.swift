import Testing
@testable import KiriKit

@Suite struct KeyComboTests {
    private enum Command: String, Sendable, CaseIterable {
        case save, find, findNext, swap, palette
    }

    private let defaults: [Command: KeyCombo] = [
        .save: KeyCombo("s", .command),
        .find: KeyCombo("f", .command),
        .findNext: KeyCombo("g", .command),
        .palette: KeyCombo("k", .command),
    ]

    @Test func writesAndSaysKeysAsTheMenuBarDoes() {
        #expect(KeyCombo("]", [.shift, .command]).glyphs == "⇧⌘]")
        #expect(KeyCombo("p", [.command, .control, .option]).glyphs == "⌃⌥⌘P")
        #expect(KeyCombo(.left, [.option, .command]).glyphs == "⌥⌘←")
        #expect(KeyCombo(.function(5), []).glyphs == "F5")
        #expect(KeyCombo("o", [.shift, .command]).spoken == "Shift Command O")
        #expect(KeyCombo("\\", .command).spoken == "Command Backslash")
        #expect(KeyCombo(.right, [.option, .command]).spoken == "Option Command Right Arrow")
    }

    @Test func aCapitalIsTheLetterWithShift() {
        let combo = KeyCombo("S", .command)
        #expect(combo == KeyCombo("s", [.shift, .command]))
        #expect(combo.glyphs == "⇧⌘S")
    }

    @Test func storedFormRoundTrips() {
        let combos = [
            KeyCombo("s", [.shift, .command]), KeyCombo("+", .command), KeyCombo("-", .command),
            KeyCombo(.left, [.option, .command]), KeyCombo(.function(12), []), KeyCombo(.space, [.control, .option]),
            KeyCombo("p", [.control, .option, .shift, .command]), KeyCombo(.forwardDelete, .command), KeyCombo("?", .command),
        ]
        for combo in combos {
            #expect(KeyCombo(stored: combo.stored) == combo, "\(combo.stored)")
        }
        #expect(KeyCombo("s", [.shift, .command]).stored == "shift+cmd+s")
        #expect(KeyCombo("+", .command).stored == "cmd++")
        #expect(KeyCombo(stored: "cmd+opt+left") == KeyCombo(.left, [.option, .command]))
        #expect(KeyCombo(stored: "") == nil)
        #expect(KeyCombo(stored: "cmd+") == nil)
        #expect(KeyCombo(stored: "cmd+nosuchkey") == nil)
        #expect(KeyCombo(stored: "f99") == nil)
    }

    @Test func aShortcutNeedsCommandOrControlUnlessItIsAFunctionKey() {
        #expect(KeyCombo("a", []).needsCommandOrControl)
        #expect(KeyCombo("a", .shift).needsCommandOrControl)
        #expect(KeyCombo("e", .option).needsCommandOrControl)
        #expect(KeyCombo(.return, []).needsCommandOrControl)
        #expect(!KeyCombo("a", .control).needsCommandOrControl)
        #expect(!KeyCombo("a", .command).needsCommandOrControl)
        #expect(!KeyCombo(.function(3), []).needsCommandOrControl)
    }

    @Test func knowsWhatMacOSAndTextViewsDoWithAKey() {
        #expect(KeyCombo.systemWide[KeyCombo(.space, .command)] == "Spotlight")
        #expect(KeyCombo.systemWide[KeyCombo("k", .command)] == nil)
        #expect(KeyCombo.textEditing[KeyCombo("a", .control)] == "moves to the start of the line")
        #expect(KeyCombo.textEditing[KeyCombo(.left, [.shift, .command])] == "selects to the start of the line")
        // None of Kiri's own keys is one of them.
        for combo in defaults.values {
            #expect(KeyCombo.systemWide[combo] == nil && KeyCombo.textEditing[combo] == nil)
        }
    }

    @Test func aTableKeepsOnlyChanges() {
        var table = ShortcutTable(defaults: defaults)
        #expect(table[.save] == KeyCombo("s", .command))
        #expect(table[.swap] == nil)
        #expect(!table.hasChanges)

        table.set(.swap, KeyCombo("x", [.control, .command]))
        table.set(.save, nil)
        #expect(table[.swap] == KeyCombo("x", [.control, .command]))
        #expect(table[.save] == nil)
        #expect(table.isChanged(.save) && table.isChanged(.swap) && !table.isChanged(.find))

        // Setting the default back is no change at all.
        table.set(.save, KeyCombo("s", .command))
        #expect(!table.isChanged(.save))
        table.reset(.swap)
        #expect(table[.swap] == nil && !table.hasChanges)
    }

    @Test func aTableIsKeptAsStrings() {
        var table = ShortcutTable(defaults: defaults)
        table.set(.find, KeyCombo("f", [.shift, .command]))
        table.set(.palette, nil)
        let stored = table.stored
        #expect(stored == ["find": "shift+cmd+f", "palette": ""])
        let back = ShortcutTable(defaults: defaults, stored: stored)
        #expect(back == table)
        #expect(back[.palette] == nil)
        // A command that is gone, or a key that can't be read, is dropped.
        let odd = ShortcutTable(defaults: defaults, stored: ["gone": "cmd+g", "find": "cmd+what", "save": "cmd+s"])
        #expect(!odd.hasChanges)
    }

    @Test func conflictsAreTheCommandsThatShareAKey() {
        var table = ShortcutTable(defaults: defaults)
        #expect(table.conflicts(in: Command.allCases).isEmpty)
        table.set(.swap, KeyCombo("g", .command))
        let conflicts = table.conflicts(in: Command.allCases)
        #expect(conflicts[.findNext] == [.swap])
        #expect(conflicts[.swap] == [.findNext])
        #expect(conflicts[.save] == nil)
        #expect(table.commands(with: KeyCombo("g", .command), in: Command.allCases) == [.findNext, .swap])
        // A key nobody has is no conflict.
        table.set(.save, nil)
        table.set(.find, nil)
        #expect(table.conflicts(in: Command.allCases).count == 2)
    }
}
