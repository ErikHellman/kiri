import AppKit
import KiriKit
import Observation
import SwiftUI

/// One row of the command palette.
struct PaletteRow: Equatable, Identifiable {
    enum Action: Equatable {
        /// A tab of this window comes forward (its window's number).
        case tab(Int)
        /// A file opens in a tab of this window, to stay.
        case file(URL)
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
        case .tab(let id): "tab:\(id)"
        case .file(let url): "file:" + url.path
        case .command(let command): "command:" + command.id
        }
    }

    /// What VoiceOver hears: "Save, Command S", "Greeter.swift, tab,
    /// Sources/Tidepool".
    var spoken: String {
        var parts = [title]
        switch action {
        case .tab: parts.append("tab")
        case .file: break
        case .command(let command): if command.isOn { parts.append("checked") }
        }
        if !detail.isEmpty, shortcut == nil { parts.append(detail) }
        if let shortcut { parts.append(shortcut.spoken) }
        return parts.joined(separator: ", ")
    }

    /// A row for a file or a tab at `path` (as it is matched and shown:
    /// from the folder, or from the home folder): the name is the title
    /// and the folders the detail, each with its share of the marks.
    static func file(_ action: Action, path: String, marks: [Range<Int>] = [], tab: Bool = false) -> PaletteRow {
        let units = path.utf16
        let nameStart = (units.lastIndex(of: 0x2F).map { units.distance(from: units.startIndex, to: $0) + 1 }) ?? 0
        let name = String(path[String.Index(utf16Offset: nameStart, in: path)...])
        let folder = nameStart > 1 ? String(path[..<String.Index(utf16Offset: nameStart - 1, in: path)]) : nameStart == 1 ? "/" : ""
        let match = FuzzyMatch(score: 0, ranges: marks)
        let icon = FileIcon.forFile(named: name)
        return PaletteRow(action: action, symbol: tab ? "rectangle.stack" : icon.symbol, tint: tab ? nil : icon.tint, title: name,
                          titleMarks: match.ranges(in: nameStart..<units.count), detail: folder,
                          detailMarks: nameStart > 1 ? match.ranges(in: 0..<(nameStart - 1)) : [])
    }
}

/// The command palette (⌘K) of one window: what `CommandPalette` shows.
/// One field over the editor finds a file anywhere in the folder, a tab,
/// a recent file or a command by a few of its letters, and shows the key
/// a command has, so neither the tree nor the menus need be searched.
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
        didSet { if text != oldValue, isOpen { textChanged() } }
    }
    private(set) var rows: [PaletteRow] = []
    /// The row Return runs: an index into `rows`.
    private(set) var selection = 0

    /// What the palette is looking through.
    enum Mode: Equatable {
        case everything
        /// `>`: commands only.
        case commands
        /// `:`: a line of this document (`:42`, `:42:7` for a column),
        /// shown as it is typed. Go to Line (`GoToLineController`).
        case line
    }

    var mode: Mode { text.hasPrefix(">") ? .commands : text.hasPrefix(":") ? .line : .everything }

    /// What is looked for: the text without the prefix that says where.
    var query: String {
        let typed = mode == .everything ? text : String(text.dropFirst())
        return typed.trimmingCharacters(in: .whitespaces)
    }

    /// In `:` mode, what the one line under the field says: where Return
    /// will go, what to type, or that what is typed is not a line.
    struct LineStatus: Equatable {
        let text: String
        /// Return goes there.
        var isTarget = false
        /// "Not a line".
        var isProblem = false
    }

    var lineStatus: LineStatus? {
        #if DEBUG || KIRI_SELFTEST
        if let sampleLineStatus { return sampleLineStatus }
        #endif
        guard isOpen, mode == .line, let goToLine = model?.goToLine else { return nil }
        if let target = goToLine.target {
            return LineStatus(text: target.column > 1 ? "Go to line \(target.line), column \(target.column)" : "Go to line \(target.line)",
                              isTarget: true)
        }
        return query.isEmpty ? LineStatus(text: "Type a line number, or line:column") : LineStatus(text: "Not a line", isProblem: true)
    }

    /// What the list says in place of rows when nothing matches.
    var emptyMessage: String? {
        guard rows.isEmpty, isOpen, mode != .line else { return nil }
        if query.isEmpty { return "Nothing to show yet." }
        return mode == .commands ? "No command matches “\(query)”. Fewer letters may find it."
            : "No file, tab or command matches “\(query)”. Fewer letters may find it."
    }

    /// The folder is being read for the first time: its files are not
    /// in the list yet.
    var isReadingFolder: Bool { isOpen && folder?.isReading == true }

    /// The most rows that are matched and shown for a query.
    static let rowLimit = 60

    /// The commands the menus had when the palette opened.
    @ObservationIgnored private var commands: [MenuCommand] = []
    @ObservationIgnored private var commandCandidates: [FuzzyCandidate] = []
    /// The window's other tabs and the recent files, as they were then:
    /// each with the path it is matched and shown by.
    @ObservationIgnored private var tabs: [(id: Int, path: String, url: URL?)] = []
    @ObservationIgnored private var tabCandidates: [FuzzyCandidate] = []
    @ObservationIgnored private var recents: [(url: URL, path: String)] = []
    @ObservationIgnored private var recentCandidates: [FuzzyCandidate] = []
    /// The folder's files (`FolderIndex`), if this is a folder window.
    @ObservationIgnored private var folder: FolderIndex?
    @ObservationIgnored private var folderObserver: NSObjectProtocol?

    private var controller: EditorController? { model?.controller }

    // MARK: Previews

    /// What a row shows while the selection is on it: "Theme: Tide" shows
    /// Tide, "Appearance: Dark" the dark look, "Language: Rust" this
    /// document highlighted as Rust. Moving off the row or Escape puts
    /// back what was there, and Return keeps it.
    enum Preview: Equatable {
        /// In every window, held in memory (`ThemePreview`): the setting
        /// is written only when it is kept.
        case look(ThemePreview.Look)
        /// This document's language (which is no setting: it is the
        /// editor's, until the file is opened again).
        case language(Language)
    }

    /// A text longer than this (UTF-16 units) is not highlighted anew for
    /// every language the selection passes: its row applies on Return.
    static var languagePreviewLimit = 1_000_000

    /// What `command` would show: one of the choices of View ▸ Theme,
    /// View ▸ Appearance or Format ▸ Language, found by where it is in
    /// the menu bar and what it is called there.
    static func preview(for command: MenuCommand) -> Preview? {
        guard command.path.count == 3, let name = command.path.last else { return nil }
        switch Array(command.path.dropLast()) {
        case KiriCommands.themeMenu: return Honey.Theme.all.first { $0.name == name }.map { .look(.theme($0)) }
        case KiriCommands.appearanceMenu: return HoneyTheme.allCases.first { $0.label == name }.map { .look(.appearance($0)) }
        case KiriCommands.languageMenu: return Language.all.first { $0.name == name }.map { .language($0) }
        default: return nil
        }
    }

    /// What this palette has put up, to take down again.
    @ObservationIgnored private var previewing: Preview?
    /// The document's language before one was previewed.
    @ObservationIgnored private var languageBefore: Language?
    @ObservationIgnored private var languageWork: DispatchWorkItem?
    @ObservationIgnored private var mainObservers: [NSObjectProtocol] = []

    /// The selected row's preview shows, and one the selection has left
    /// is taken down. (While the window is not the one in front, nothing
    /// is previewed: a theme is every window's.)
    private func updatePreview() {
        var wanted: Preview?
        if isOpen, !inBackground, case .command(let command)? = selectedRow?.action { wanted = Self.preview(for: command) }
        if case .language = wanted, (controller?.textView?.textStorage?.length ?? 0) > Self.languagePreviewLimit { wanted = nil }
        show(wanted)
    }

    private func show(_ wanted: Preview?) {
        guard wanted != previewing else { return }
        // What is up comes down, unless one of its own kind takes its place.
        switch (previewing, wanted) {
        case (.look, .look), (.language, .language), (nil, _): break
        case (.look, _): ThemePreview.shared.end()
        case (.language, _): restoreLanguage()
        }
        previewing = wanted
        switch wanted {
        case .look(let look):
            ThemePreview.shared.show(look)
        case .language(let language):
            if languageBefore == nil { languageBefore = model?.language }
            // Not at every row an arrow key passes on its way: the text
            // is highlighted anew for the row it stops on.
            languageWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setLanguage(language) } }
            languageWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.languagePause, execute: work)
        case nil:
            break
        }
    }

    static let languagePause = 0.12

    private func setLanguage(_ language: Language) {
        languageWork?.cancel()
        languageWork = nil
        guard let model, model.language != language else { return }
        model.language = language
        // (At once, also in a window SwiftUI is not drawing just now.)
        controller?.setLanguage(language)
    }

    private func restoreLanguage() {
        languageWork?.cancel()
        languageWork = nil
        if let languageBefore { setLanguage(languageBefore) }
        languageBefore = nil
    }

    /// Return on a row with a preview: what it shows is kept. A theme or
    /// an appearance becomes the setting (`ThemePreview.keep`, which is
    /// what writes it: the menu item is not chosen as well).
    private func keep(_ preview: Preview) {
        switch preview {
        case .look(let look):
            if case .language = previewing { restoreLanguage() }
            ThemePreview.shared.show(look)
            ThemePreview.shared.keep()
        case .language(let language):
            if case .look = previewing { ThemePreview.shared.end() }
            setLanguage(language)
            languageBefore = nil
        }
        previewing = nil
    }

    /// The palette's window is not the one in front (another tab, another
    /// app): what it previews is every window's, so it comes down until
    /// the window is in front again.
    @ObservationIgnored private var inBackground = false

    private func watchWindow() {
        guard let window = controller?.textView?.window else { return }
        let center = NotificationCenter.default
        for (name, away) in [(NSWindow.didResignMainNotification, true), (NSWindow.didBecomeMainNotification, false)] {
            mainObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inBackground = away
                    self.updatePreview()
                }
            })
        }
    }

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
            // The menus are read while the editor has the keyboard: what
            // Edit has on and off is then what it will be when a command
            // runs, with the keyboard back there.
            controller.focus()
            commands = MenuCommands.all()
            commandCandidates = commands.map { FuzzyCandidate($0.title) }
            gatherFiles()
            inBackground = false
            watchWindow()
            isOpen = true
            model.overlayChanged()
        }
        if text != prefill { text = prefill } else { textChanged() }
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

    /// Escape, or ⌘K again: closes it and gives the keyboard back to the
    /// editor, which is where it was before a line was typed.
    func cancel() {
        close()
    }

    func close(focusEditor: Bool = true) {
        guard isOpen else { return }
        // A line that was only being looked at is gone back from, and a
        // theme or a language that was only being looked at comes down.
        model?.goToLine.cancel(focusEditor: false)
        isOpen = false
        show(nil)
        mainObservers.forEach(NotificationCenter.default.removeObserver)
        mainObservers = []
        rows = []
        selection = 0
        commands = []
        commandCandidates = []
        tabs = []
        tabCandidates = []
        recents = []
        recentCandidates = []
        folder = nil
        if let folderObserver { NotificationCenter.default.removeObserver(folderObserver) }
        folderObserver = nil
        model?.overlayChanged()
        if focusEditor { controller?.focus() }
    }

    /// Another document takes the editor (the folder sidebar's preview
    /// tab): what the palette listed was listed for the other one.
    func documentReplaced() {
        guard isOpen else { return }
        // (A line that was being typed was a line of the other document:
        // it is not gone back from.)
        model?.goToLine.documentReplaced()
        let window = controller?.textView?.window
        let inField = (window?.firstResponder as? NSTextView)?.isFieldEditor == true
        close(focusEditor: inField)
    }

    /// The tabs, the recent files and the folder, as the palette opens.
    private func gatherFiles() {
        guard let window = controller?.textView?.window else { return }
        let home = NSHomeDirectory()
        let session = FolderSessions.session(for: window)
        let root = session?.root.url.path
        /// A file's path as it is shown: from the folder for a file in
        /// it, from the home folder (~) otherwise.
        func shown(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            if let root, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
            return TabNames.abbreviatingHome(path, home: home)
        }
        tabs = (FrontEditor.shared.tabs(in: window)?.items ?? []).filter { $0.id != window.windowNumber }.map { item in
            let url = item.path.map { URL(fileURLWithPath: $0).standardizedFileURL }
            return (item.id, url.map(shown) ?? item.title, url)
        }
        tabCandidates = tabs.map { FuzzyCandidate($0.path, isPath: $0.url != nil) }
        // A recent file that is in a tab already is listed as the tab,
        // and the file this window shows is not somewhere to go.
        let current = (NSDocumentController.shared.document(for: window)?.fileURL).map { $0.standardizedFileURL }
        let open = Set(tabs.compactMap(\.url) + [current].compactMap { $0 })
        recents = RecentDocuments.shared.urls.map(\.standardizedFileURL).filter { !open.contains($0) }.map { ($0, shown($0)) }
        recentCandidates = recents.map { FuzzyCandidate($0.path, isPath: true) }
        // The folder is read again for what has changed in it; until
        // that is in, the reading before it is searched.
        folder = session?.index
        if let folder {
            folderObserver = NotificationCenter.default.addObserver(forName: FolderIndex.didChange, object: folder, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.search(keepingSelection: true) }
            }
            folder.refresh()
        }
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
        updatePreview()
        announce(rowsChanged: false)
    }

    var selectedRow: PaletteRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// Return: runs the selected row, or in `:` mode keeps the line (what
    /// is not a line number keeps the palette open, and says so).
    func commit() {
        if mode == .line {
            guard isOpen, let goToLine = model?.goToLine else { return }
            // The line is kept and the keyboard is the editor's; then
            // the palette goes, with nothing left to go back from.
            if goToLine.commit() { close() } else { announce(rowsChanged: true) }
        } else if let row = selectedRow {
            run(row)
        }
    }

    /// Runs a row (Return, or a click on it): the palette closes and the
    /// keyboard goes back to the editor first, and the command runs in
    /// the next turn of the run loop. While the palette is open its field
    /// has the keyboard, and Copy, Undo or Make Upper Case would otherwise
    /// act on the field.
    func run(_ row: PaletteRow) {
        guard isOpen else { return }
        // A theme, an appearance or a language: what the row shows stays.
        if case .command(let command) = row.action, let preview = Self.preview(for: command) {
            keep(preview)
            close()
            return
        }
        #if DEBUG || KIRI_SELFTEST
        if Self.selfTestRunsFirst { perform(row); close(); return }
        #endif
        close()
        DispatchQueue.main.async { [self] in perform(row) }
    }

    private func perform(_ row: PaletteRow) {
        let window = controller?.textView?.window
        #if DEBUG || KIRI_SELFTEST
        selfTestRan = (row.id, window?.firstResponder)
        #endif
        switch row.action {
        case .tab(let id):
            if let window { FrontEditor.shared.tabs(in: window)?.select(id) }
        case .file(let url):
            // As a file opened by name: a tab of this window, to stay,
            // with the keyboard in its editor.
            if let window { SidebarOpen.open(url, keep: true, from: window, keyboard: .editor) }
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

    /// The field's text changed: a line is shown (`:`), or the list filled.
    private func textChanged() {
        guard isOpen, let goToLine = model?.goToLine else { return }
        if mode == .line {
            // From the first colon on, where the editor was is kept to go back to.
            goToLine.begin()
            goToLine.text = String(text.dropFirst())
            rows = []
            selection = 0
            updatePreview()
            announce(rowsChanged: true)
        } else {
            // The colon was taken away: back to where the editor was.
            goToLine.cancel(focusEditor: false)
            search()
        }
    }

    /// Fills the list for what is typed. With nothing typed: the other
    /// tabs, the recent files, then every command. Otherwise what matches,
    /// best first, a file or a tab ahead of a command that matches as well.
    private func search(keepingSelection: Bool = false) {
        guard isOpen else { return }
        let selected = keepingSelection ? selectedRow?.id : nil
        let fuzzy = FuzzyQuery(query)
        var found: [PaletteRow] = []
        if fuzzy.isEmpty {
            if mode == .everything {
                found += tabs.map { tabRow($0) }
                found += recents.map { .file(.file($0.url), path: $0.path) }
            }
            found += commands.map { Self.row(for: $0) }
        } else {
            // Each kind's best, then all of them in one order.
            var ranked: [(score: Int, kind: Int, row: PaletteRow)] = []
            let limit = Self.rowLimit
            if mode == .everything {
                // A file shows once: as its tab if it has one, else as
                // the folder's file, else as a recent one.
                var listed = Set(tabs.compactMap(\.url))
                for entry in fuzzy.rank(tabCandidates, limit: limit) ?? [] {
                    ranked.append((entry.match.score, 0, tabRow(tabs[entry.index], marks: entry.match.ranges)))
                }
                if let folder {
                    let paths = folder.paths
                    for entry in fuzzy.rank(folder.candidates, limit: limit + listed.count) ?? [] where entry.index < paths.count {
                        let url = folder.url(for: paths[entry.index])
                        guard listed.insert(url).inserted else { continue }
                        ranked.append((entry.match.score, 1, .file(.file(url), path: paths[entry.index], marks: entry.match.ranges)))
                    }
                }
                for entry in fuzzy.rank(recentCandidates, limit: limit) ?? [] {
                    let recent = recents[entry.index]
                    guard listed.insert(recent.url).inserted else { continue }
                    ranked.append((entry.match.score, 1, .file(.file(recent.url), path: recent.path, marks: entry.match.ranges)))
                }
            }
            for entry in fuzzy.rank(commandCandidates, limit: limit) ?? [] {
                var row = Self.row(for: commands[entry.index])
                row.titleMarks = entry.match.ranges
                ranked.append((entry.match.score, 2, row))
            }
            // (A stable order: equal scores of a kind stay as they were ranked.)
            let order = ranked.enumerated().sorted { a, b in
                if a.element.score != b.element.score { return a.element.score > b.element.score }
                if a.element.kind != b.element.kind { return a.element.kind < b.element.kind }
                return a.offset < b.offset
            }
            found = order.prefix(limit).map(\.element.row)
        }
        rows = found
        // A reading of the folder that comes in while the list shows
        // leaves the selection on the row it was on, if that is still there.
        selection = selected.flatMap { id in found.firstIndex { $0.id == id } } ?? 0
        updatePreview()
        if !keepingSelection { announce(rowsChanged: true) }
    }

    private func tabRow(_ tab: (id: Int, path: String, url: URL?), marks: [Range<Int>] = []) -> PaletteRow {
        guard tab.url != nil else {
            // A document that has no file yet: its title is all it has.
            return PaletteRow(action: .tab(tab.id), symbol: "rectangle.stack", title: tab.path, titleMarks: marks, detail: "")
        }
        return .file(.tab(tab.id), path: tab.path, marks: marks, tab: true)
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
        if let lineStatus {
            parts.append(lineStatus.text)
        } else if rowsChanged {
            parts.append(rows.isEmpty ? (emptyMessage ?? "No results") : rows.count == 1 ? "1 result" : "\(rows.count) results")
        }
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
    static func sample(text: String, rows: [PaletteRow], selection: Int = 0, line: LineStatus? = nil) -> PaletteController {
        let palette = PaletteController()
        palette.text = text
        palette.rows = rows
        palette.selection = selection
        palette.sampleLineStatus = line
        palette.isOpen = true
        return palette
    }

    @ObservationIgnored private var sampleLineStatus: LineStatus?
    #endif
}
