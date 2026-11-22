import AppKit
import KiriKit
import Observation
import SwiftUI

/// One row of the command palette.
struct PaletteRow: Equatable, Identifiable {
    enum Action: Equatable {
        /// A menu item is chosen.
        case command(MenuCommand)
    }

    let action: Action
    /// An SF Symbol, and the syntax token it is tinted with (a file's
    /// icon); nil is the muted ink.
    let symbol: String
    var tint: SyntaxKind?
    let title: String
    /// The letters of the query in the title and the detail (UTF-16 offsets).
    var titleMarks: [Range<Int>] = []
    /// Muted, after the title: a command's menu, a file's folder.
    let detail: String
    var detailMarks: [Range<Int>] = []
    /// A command's key.
    var shortcut: KeyboardShortcut?

    var id: String {
        switch action {
        case .command(let command): "command:" + command.id
        }
    }

    /// What VoiceOver hears: "Save, Command S".
    var spoken: String {
        var parts = [title]
        if case .command(let command) = action, command.isOn { parts.append("checked") }
        if !detail.isEmpty, shortcut == nil { parts.append(detail) }
        if let shortcut { parts.append(shortcut.spoken) }
        return parts.joined(separator: ", ")
    }
}

/// The command palette (⌘K) of one window: what `CommandPalette` shows.
/// One field over the editor finds a command by a few of its letters, and
/// shows the key it has, so the menus need not be searched for it.
///
/// The view is only a view of this, as the find bar is of
/// `FindController`: everything works (and is tested) whether or not
/// SwiftUI is drawing the window.
@MainActor @Observable final class PaletteController {
    @ObservationIgnored weak var model: EditorModel?

    private(set) var isOpen = false
    /// Bumped to ask the field to take the keyboard.
    private(set) var focusRequest = 0
    /// What is typed in the field.
    var text = "" {
        didSet { if text != oldValue, isOpen { search() } }
    }
    private(set) var rows: [PaletteRow] = []
    /// The row Return runs: an index into `rows`.
    private(set) var selection = 0

    /// What the palette is looking through.
    enum Mode: Equatable {
        case everything
        /// `>`: commands only.
        case commands
    }

    var mode: Mode { text.hasPrefix(">") ? .commands : .everything }

    /// What is looked for: the text without the prefix that says where.
    var query: String {
        let typed = mode == .commands ? String(text.dropFirst()) : text
        return typed.trimmingCharacters(in: .whitespaces)
    }

    /// What the list says in place of rows when nothing matches.
    var emptyMessage: String? {
        guard rows.isEmpty, isOpen else { return nil }
        if query.isEmpty { return "Nothing to show yet." }
        return mode == .commands ? "No command matches “\(query)”. Fewer letters may find it."
            : "Nothing matches “\(query)”. Fewer letters may find it."
    }

    /// The most rows that are matched and shown for a query.
    static let rowLimit = 60

    /// The commands the menus had when the palette opened.
    @ObservationIgnored private var commands: [MenuCommand] = []
    @ObservationIgnored private var commandCandidates: [FuzzyCandidate] = []

    private var controller: EditorController? { model?.controller }

    // MARK: Opening and closing

    /// ⌘K: opens the palette with the keyboard in its field, or closes it.
    func toggle() {
        if isOpen { cancel() } else { open() }
    }

    /// Opens the palette, or with it open puts `prefill` in its field
    /// and the keyboard there.
    func open(with prefill: String = "") {
        guard let model, let controller, controller.textView != nil else { return }
        if !isOpen {
            // One bar at a time.
            model.find.close(focusEditor: false)
            model.goToLine.cancel(focusEditor: false)
            // The menus are read while the editor has the keyboard: what
            // Edit has on and off is then what it will be when a command
            // runs, with the keyboard back there.
            controller.focus()
            commands = MenuCommands.all()
            commandCandidates = commands.map { FuzzyCandidate($0.title) }
            isOpen = true
            model.overlayChanged()
        }
        if text != prefill { text = prefill } else { search() }
        focusRequest += 1
        placeCaret()
    }

    /// The caret goes after what is in the field, once the field has the
    /// keyboard. (A field that takes the keyboard selects its text, and
    /// the first key typed would then replace what the palette was opened
    /// with.) A field that has not taken the keyboard after a moment is
    /// asked again: what is typed must never land in the document.
    private func placeCaret() {
        caretRequest += 1
        waitForField(caretRequest, tries: 0)
    }

    @ObservationIgnored private var caretRequest = 0

    private func waitForField(_ request: Int, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 0 : 0.02)) { [weak self] in
            guard let self, isOpen, request == caretRequest else { return }
            if let field = controller?.textView?.window?.firstResponder as? NSTextView, field.isFieldEditor {
                field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
            } else if tries < 40 {
                if tries % 8 == 3 { focusRequest += 1 }
                waitForField(request, tries: tries + 1)
            }
        }
    }

    /// Escape, or ⌘K again: closes it and gives the keyboard back to the editor.
    func cancel() {
        close()
    }

    func close(focusEditor: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        rows = []
        selection = 0
        commands = []
        commandCandidates = []
        model?.overlayChanged()
        if focusEditor { controller?.focus() }
    }

    /// Another document takes the editor (the folder sidebar's preview
    /// tab): what the palette listed was listed for the other one.
    func documentReplaced() {
        guard isOpen else { return }
        let window = controller?.textView?.window
        let inField = (window?.firstResponder as? NSTextView)?.isFieldEditor == true
        close(focusEditor: inField)
    }

    // MARK: The list

    /// ↑ and ↓: the selection moves and stops at the ends.
    func move(by step: Int) {
        guard !rows.isEmpty else { return }
        select(min(max(selection + step, 0), rows.count - 1))
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index), index != selection else { return }
        selection = index
        announce(rowsChanged: false)
    }

    var selectedRow: PaletteRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// Return: runs the selected row.
    func commit() {
        if let row = selectedRow { run(row) }
    }

    /// Runs a row (Return, or a click on it): the palette closes and the
    /// keyboard goes back to the editor first, and the command runs in
    /// the next turn of the run loop. While the palette is open its field
    /// has the keyboard, and Copy, Undo or Make Upper Case would otherwise
    /// act on the field.
    func run(_ row: PaletteRow) {
        guard isOpen else { return }
        #if DEBUG || KIRI_SELFTEST
        if Self.selfTestRunsFirst { perform(row); close(); return }
        #endif
        close()
        DispatchQueue.main.async { [self] in perform(row) }
    }

    private func perform(_ row: PaletteRow) {
        #if DEBUG || KIRI_SELFTEST
        selfTestRan = (row.id, controller?.textView?.window?.firstResponder)
        #endif
        switch row.action {
        case .command(let command):
            MenuCommands.perform(command)
        }
    }

    #if DEBUG || KIRI_SELFTEST
    /// The row that ran last and who had the keyboard at that moment.
    @ObservationIgnored private(set) var selfTestRan: (id: String, responder: NSResponder?)?
    /// -KiriPaletteRunsFirst YES, for showing what the order above is
    /// for: runs a row while the palette is still open, with the keyboard
    /// in its field. The check that Return runs a command with the
    /// keyboard in the editor then fails.
    static var selfTestRunsFirst = UserDefaults.standard.bool(forKey: "KiriPaletteRunsFirst")
    #endif

    private func search() {
        guard isOpen else { return }
        let fuzzy = FuzzyQuery(query)
        var found: [PaletteRow] = []
        if fuzzy.isEmpty {
            found = commands.map { Self.row(for: $0) }
        } else {
            for entry in fuzzy.rank(commandCandidates, limit: Self.rowLimit) ?? [] {
                var row = Self.row(for: commands[entry.index])
                row.titleMarks = entry.match.ranges
                found.append(row)
            }
        }
        rows = found
        selection = 0
        announce(rowsChanged: true)
    }

    private static func row(for command: MenuCommand) -> PaletteRow {
        PaletteRow(action: .command(command), symbol: command.isOn ? "checkmark" : command.isChoice ? "circle" : "command",
                   title: command.title, detail: command.detail, shortcut: command.shortcut)
    }

    // MARK: VoiceOver

    /// What VoiceOver was last told. The keyboard stays in the field
    /// while the selection moves, so the row is said, not focused: how
    /// many results there are when they change, and the selected row.
    @ObservationIgnored private(set) var lastAnnouncement = ""

    private func announce(rowsChanged: Bool) {
        var parts: [String] = []
        if rowsChanged { parts.append(rows.isEmpty ? (emptyMessage ?? "No results") : rows.count == 1 ? "1 result" : "\(rows.count) results") }
        if let row = selectedRow {
            parts.append(rowsChanged ? row.spoken : "\(row.spoken), \(selection + 1) of \(rows.count)")
        }
        lastAnnouncement = parts.joined(separator: ". ")
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = controller?.textView?.window, !lastAnnouncement.isEmpty else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: lastAnnouncement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    #if DEBUG || KIRI_SELFTEST
    /// A palette in a given state with no editor behind it, for pictures
    /// drawn offscreen.
    static func sample(text: String, rows: [PaletteRow], selection: Int = 0) -> PaletteController {
        let palette = PaletteController()
        palette.text = text
        palette.rows = rows
        palette.selection = selection
        palette.isOpen = true
        return palette
    }
    #endif
}
