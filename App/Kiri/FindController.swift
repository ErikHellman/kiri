import AppKit
import KiriKit
import Observation

/// Find and replace for one window: what the Honey find bar (`FindBar`)
/// shows and what Edit ▸ Find does. The searching itself is `TextSearch` in
/// KiriKit; this keeps its results in step with the editor.
///
/// The bar is only a view of this, so everything works (and is tested)
/// whether or not SwiftUI is drawing the window.
@Observable final class FindController {
    enum Action {
        case show, showReplace, next, previous, useSelection, replace, replaceAll, hideReplace, close
    }

    enum Status: Equatable {
        /// Nothing to look for.
        case idle
        /// `current` is the match the editor is on, if it is on one.
        case found(current: Int?, total: Int, more: Bool)
        case none
        case invalid
    }

    @ObservationIgnored weak var model: EditorModel?

    /// The bar is showing.
    private(set) var isOpen = false
    /// The replace row is showing.
    var showsReplace = false {
        didSet { if showsReplace != oldValue { model?.overlayChanged() } }
    }
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    var replacement = ""
    var options = SearchOptions() {
        didSet { if options != oldValue { queryChanged() } }
    }
    private(set) var status = Status.idle
    /// What Replace All just did, shown in place of the count until the
    /// next search.
    private(set) var notice: String?
    /// Bumped to ask the bar to put the keyboard in its find field.
    private(set) var focusRequest = 0

    /// The shared find pasteboard, as system find bars use it: ⌘E in
    /// another app is the query here and the other way round.
    @ObservationIgnored var board = NSPasteboard(name: .find) {
        didSet { boardChange = board.changeCount }
    }
    @ObservationIgnored private var boardChange = -1

    /// The matches of `search`, in order. Edits move them at once; a new
    /// search then finds what an edit added (`needsSearch`).
    @ObservationIgnored private(set) var matches: [Range<Int>] = []
    @ObservationIgnored private var truncated = false
    @ObservationIgnored private var current: Int?
    @ObservationIgnored private var search: TextSearch?
    @ObservationIgnored private var needsSearch = true
    @ObservationIgnored private var quiet = false
    @ObservationIgnored private var settingSelection = false
    @ObservationIgnored private var replacing = false
    @ObservationIgnored private var refreshQueued = false

    // A search that is waiting to run or running off the main thread.
    @ObservationIgnored private var work: DispatchWorkItem?
    @ObservationIgnored private var token: Token?
    @ObservationIgnored private var pendingJump = false
    @ObservationIgnored private var pendingStep: Bool?
    private let queue = DispatchQueue(label: "se.hellsoft.kiri.find", qos: .userInitiated)

    /// Texts up to this long (UTF-16 units) are searched at once, on the
    /// main thread: under a millisecond or two. Longer ones are searched off
    /// it, `debounce` after the last change, so typing in the find field or
    /// the document never waits for a search.
    static let immediateLimit = 300_000
    static let debounce = 0.04

    /// Says whether a search off the main thread is still wanted.
    nonisolated private final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private var controller: EditorController? { model?.controller }
    private var textView: KiriTextView? { controller?.textView }
    /// The large file's viewer, when the tab shows one: it is searched in
    /// place of the editor's text, off the main thread and on every core.
    private var large: LargeFileViewer? { model?.large }
    /// The file is read-only: there is nothing to replace.
    var isReadOnly: Bool { model?.large != nil }

    // The search of a large file. `matches` holds the matches it keeps
    // (byte ranges) and this how many there are in all.
    @ObservationIgnored private var largeTotal = 0
    /// How far into the file the search has got.
    @ObservationIgnored private var largeSearchedTo = 0
    /// The query can't be used (an invalid regular expression).
    @ObservationIgnored private var largeInvalid = false
    /// Where the line of each of `matches` starts, in a large file.
    @ObservationIgnored private var largeLineStarts: [Int] = []
    /// A large file shows only the lines that match, while the bar is
    /// open: grep, in place.
    var onlyMatchingLines = false {
        didSet { if onlyMatchingLines != oldValue { publish() } }
    }

    private var selection: Range<Int> {
        if let large { return large.view.selectedBytes }
        let r = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        return r.location..<(r.location + r.length)
    }

    /// Whether the keyboard is in the editor (`editorFocusChanged`).
    @ObservationIgnored private var editorFocused = true
    /// With the bar open and the keyboard elsewhere (in the bar, mostly),
    /// the current match is a caret at its start and the highlight shows
    /// it: selected, it would be painted the grey of an unfocused selection.
    private var marksWithCaret: Bool { isOpen && !editorFocused }

    private var pending: Bool { work != nil || token != nil }
    /// A long text is being searched off the main thread (or is about to be).
    var isSearching: Bool { pending }
    private var listIsForQuery: Bool { search?.query == query && search?.options == options }

    // MARK: What the bar shows

    /// "3 of 12", "12 matches", "No matches", "Invalid pattern", or nothing
    /// while there is no query.
    var label: String {
        if let notice { return notice }
        switch status {
        case .idle: return ""
        case .none: return "No matches"
        case .invalid: return "Invalid pattern"
        case .found(let current, let total, let more):
            // Grouped, so a long count reads at a glance: "42 of 100,000+".
            let count = "\(total.formatted())\(more ? "+" : "")"
            if let current { return "\((current + 1).formatted()) of \(count)" }
            return total == 1 && !more ? "1 match" : "\(count) matches"
        }
    }

    /// The widest `label` gets while stepping through this result, so the
    /// bar keeps its width as the count changes.
    var widestLabel: String {
        guard case .found(_, let total, let more) = status else { return "" }
        let count = "\(total.formatted())\(more ? "+" : "")"
        return "\(total.formatted()) of \(count)"
    }

    /// The query finds nothing or can't be used.
    var hasProblem: Bool { notice == nil && (status == .none || status == .invalid) }
    var hasMatches: Bool { if case .found = status { true } else { false } }

    // MARK: Commands

    func perform(_ action: Action) {
        switch action {
        case .show: show()
        case .showReplace: show(replace: true)
        case .next: step(forward: true)
        case .previous: step(forward: false)
        case .useSelection: useSelection()
        case .replace: replaceCurrent()
        case .replaceAll: replaceAll()
        case .hideReplace: showsReplace = false
        case .close: close()
        }
    }

    /// ⌘F / ⌥⌘F: opens the bar with the keyboard in the find field. A
    /// selection within one line becomes the query.
    func show(replace: Bool = false) {
        if large != nil {
            showLarge()
            return
        }
        guard let textView else { return }
        model?.goToLine.cancel(focusEditor: false)
        model?.palette.close(focusEditor: false)
        adoptBoard()
        if let selected = selectedText(oneLine: true) { quietly { query = selected } }
        if replace { showsReplace = true }
        editorFocused = textView.window?.firstResponder === textView
        if isOpen {
            // Already in a field of the bar: select what is in it.
            if let editor = textView.window?.firstResponder as? NSTextView, editor.isFieldEditor { editor.selectAll(nil) }
        } else {
            isOpen = true
            model?.overlayChanged()
        }
        focusRequest += 1
        // Opening shows the matches but goes nowhere; Return or ⌘G does.
        refresh(jump: false)
    }

    /// Escape: closes the bar and gives the keyboard back to the editor,
    /// with the current match selected.
    func close(focusEditor: Bool = true) {
        guard isOpen else { return }
        let range = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        isOpen = false
        cancelPending()
        notice = nil
        textView?.marksIfLoaded?.clearMatches()
        model?.overlayChanged()
        if let large {
            large.view.show(matches: [], current: nil)
            // Every line again, at the match.
            large.view.setRows(nil)
            if let range { large.view.select(bytes: range) }
            if focusEditor { controller?.focus() }
            return
        }
        if let range, let textView {
            settingSelection = true
            textView.setSelectedRange(NSRange(location: range.lowerBound, length: range.count))
            settingSelection = false
        }
        if focusEditor { controller?.focus() }
    }

    /// ⌘G / ⇧⌘G, Return / ⇧Return in the field: the next or previous match
    /// from the caret, around the ends, with the bar open or not.
    func step(forward: Bool) {
        adoptBoard()
        notice = nil
        if large != nil {
            stepLarge(forward: forward)
            return
        }
        guard textView != nil else { return }
        guard !query.isEmpty else {
            if !isOpen { show() }
            return
        }
        // A long text whose search for this query is still running: go
        // when it has finished, instead of searching twice.
        if pending, !listIsForQuery {
            pendingStep = forward
            return
        }
        ensureSearched()
        let from = isOpen ? current : TextSearch.index(of: selection, in: matches)
        guard let i = TextSearch.step(from: from, selection: selection, forward: forward, in: matches) else {
            // Nothing to go to. The bar says so; nothing beeps.
            if isOpen { publish() } else { show() }
            return
        }
        select(i)
    }

    /// ⌘E: the selection becomes the query (and goes on the find
    /// pasteboard), without opening the bar.
    func useSelection() {
        guard let selected = selectedText(oneLine: false) else { return }
        notice = nil
        if selected == query {
            writeBoard()
        } else {
            quietly { query = selected }
        }
    }

    /// Replaces the current match and goes on to the next; without a
    /// current match it only finds one. One undo step.
    func replaceCurrent() {
        guard large == nil else { return }
        notice = nil
        ensureSearched()
        guard let search, let textView, let controller else { return }
        guard let i = current, matches.indices.contains(i) else {
            step(forward: true)
            return
        }
        let match = matches[i]
        guard let new = search.replacement(for: match, in: textView.string, with: replacement) else {
            needsSearch = true
            refresh(jump: false)
            return
        }
        replacing = true
        let done = controller.replaceText(in: NSRange(location: match.lowerBound, length: match.count), with: new,
                                          actionName: "Replace")
        replacing = false
        guard done else { return }
        // `textEdited` has taken the match out and moved the ones after it.
        if isOpen { refresh(jump: false) } else { ensureSearched() }
        // On from the end of what was put in, so a replacement that holds
        // the query again is not found again.
        let after = match.lowerBound + new.utf16.count
        if let next = TextSearch.index(startingAtOrAfter: after, in: matches) {
            select(next)
        } else {
            current = nil
            setCaret(after)
            publish()
        }
    }

    /// Replaces every match, as one undo step, and says how many.
    func replaceAll() {
        guard large == nil else { return }
        notice = nil
        guard let textView, let controller, !query.isEmpty,
              let search = try? TextSearch(query, options: options),
              let all = search.replaceAll(in: textView.string, with: replacement) else {
            if isOpen { refresh(jump: false) }
            return
        }
        let caret = textView.selectedRange().location
        replacing = true
        let done = controller.replaceText(in: NSRange(location: all.range.lowerBound, length: all.range.count),
                                          with: all.text, actionName: "Replace All")
        replacing = false
        guard done else { return }
        // The caret stays where it was in the text.
        let delta = all.text.utf16.count - all.range.count
        setCaret(caret <= all.range.lowerBound ? caret : caret >= all.range.upperBound ? caret + delta : all.range.lowerBound)
        current = nil
        notice = "Replaced \(all.count.formatted())"
        if isOpen { refresh(jump: false) }
        announce()
    }

    // MARK: From the editor

    /// The text changed: `old` (of the text before) is now `newLength` long.
    func textEdited(old: Range<Int>, newLength: Int) {
        needsSearch = true
        guard !matches.isEmpty else {
            if isOpen, !replacing { refreshSoon() }
            return
        }
        // What is known stays where it now is; what the edit touched is
        // gone until the search has run again. (In place, and only from
        // the edit on: there can be a hundred thousand.)
        let delta = newLength - old.count
        let currentRange = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        func firstIndex(where passes: (Range<Int>) -> Bool) -> Int {
            var lo = 0, hi = matches.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if passes(matches[mid]) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        let touched = firstIndex { $0.upperBound > old.lowerBound }
        let after = max(touched, firstIndex { $0.lowerBound >= old.upperBound })
        matches.removeSubrange(touched..<after)
        if delta != 0 {
            matches.withUnsafeMutableBufferPointer { buffer in
                for i in touched..<buffer.count {
                    buffer[i] = Range(uncheckedBounds: (buffer[i].lowerBound + delta, buffer[i].upperBound + delta))
                }
            }
        }
        if let currentRange, let i = current {
            current = i < touched ? i : currentRange.lowerBound >= old.upperBound ? i - (after - touched) : nil
        }
        guard isOpen else { return }
        publish()
        if !replacing { refreshSoon() }
    }

    /// The keyboard came to the editor or left it. A selected match turns
    /// system grey once the editor is not where the keyboard is, so the
    /// current match is then marked by a caret at its start (the highlight
    /// shows it), and selected again when the keyboard is back.
    func editorFocusChanged(hasFocus: Bool) {
        editorFocused = hasFocus
        guard isOpen, let textView, let i = current, matches.indices.contains(i) else { return }
        let match = matches[i], selection = selection
        settingSelection = true
        if hasFocus, selection.isEmpty, selection.lowerBound == match.lowerBound {
            textView.setSelectedRange(NSRange(location: match.lowerBound, length: match.count))
        } else if !hasFocus, selection == match {
            textView.setSelectedRange(NSRange(location: match.lowerBound, length: 0))
        }
        settingSelection = false
    }

    /// The selection changed (the person clicked or moved the caret).
    func selectionChanged() {
        guard isOpen, !settingSelection, !replacing else { return }
        let i = indexForSelection()
        if i != current {
            current = i
            publish()
        }
    }

    // MARK: Searching

    private func queryChanged() {
        notice = nil
        if !adopting { writeBoard() }
        needsSearch = true
        refresh(jump: !quiet)
    }

    /// Changes the query without going to a match (⌘F with a selection, ⌘E,
    /// the find pasteboard).
    private func quietly(_ change: () -> Void) {
        quiet = true
        change()
        quiet = false
    }

    @ObservationIgnored private var adopting = false

    /// Takes the find pasteboard's string as the query if another app (or
    /// another Kiri window) has put one there since this one last looked.
    private func adoptBoard() {
        guard board.changeCount != boardChange else { return }
        boardChange = board.changeCount
        guard let string = board.string(forType: .string), !string.isEmpty, string != query else { return }
        adopting = true
        quietly { query = string }
        adopting = false
    }

    private func writeBoard() {
        guard !query.isEmpty else { return }
        board.clearContents()
        board.setString(query, forType: .string)
        boardChange = board.changeCount
    }

    private func cancelPending() {
        work?.cancel()
        work = nil
        token?.cancel()
        token = nil
        pendingJump = false
        pendingStep = nil
    }

    /// After an edit: search again once the edit is over.
    private func refreshSoon() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                if self.isOpen, self.needsSearch { self.refresh(jump: false) }
            }
        }
    }

    /// Searches for the query as it is now, while the bar is open. `jump`
    /// goes to the first match at or after the caret (typing in the field).
    private func refresh(jump: Bool) {
        let jumpWanted = pendingJump || jump
        let stepWanted = pendingStep
        cancelPending()
        if large != nil {
            refreshLarge(jump: jumpWanted, step: stepWanted)
            return
        }
        guard isOpen, let textView, let storage = textView.textStorage else { return }
        guard !query.isEmpty else {
            store(TextSearch.Matches(), for: nil)
            status = .idle
            return
        }
        guard let search = try? TextSearch(query, options: options) else {
            store(TextSearch.Matches(), for: nil)
            status = .invalid
            announce()
            return
        }
        if storage.length <= Self.immediateLimit {
            apply(search.matches(in: storage.string) ?? TextSearch.Matches(), for: search, jump: jumpWanted)
            return
        }
        pendingJump = jumpWanted
        pendingStep = stepWanted
        let token = Token()
        self.token = token
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !token.isCancelled, let storage = self.textView?.textStorage else { return }
                self.work = nil
                // An unchanging copy: the document goes on being edited.
                let snapshot = (storage.string as NSString).copy() as! NSString as String
                self.queue.async {
                    let found = search.matches(in: snapshot, isCancelled: { token.isCancelled })
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            // An edit or a new query since then has cancelled it.
                            guard let found, self.token === token, !token.isCancelled else { return }
                            self.token = nil
                            let jump = self.pendingJump, step = self.pendingStep
                            self.pendingJump = false
                            self.pendingStep = nil
                            self.apply(found, for: search, jump: jump)
                            if let step { self.step(forward: step) }
                        }
                    }
                }
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// The matches for the query in the text as it is now, found at once if
    /// they aren't known.
    private func ensureSearched() {
        // A large file is only ever searched off the main thread.
        if large != nil { return }
        guard needsSearch || !listIsForQuery else { return }
        // A long text that is being searched: the list as the edits left it
        // will do until the search is back.
        if pending, listIsForQuery { return }
        cancelPending()
        guard !query.isEmpty, let storage = textView?.textStorage,
              let search = try? TextSearch(query, options: options) else {
            store(TextSearch.Matches(), for: nil)
            if isOpen { status = query.isEmpty ? .idle : .invalid }
            return
        }
        store(search.matches(in: storage.string) ?? TextSearch.Matches(), for: search)
        current = indexForSelection()
        if isOpen { publish() }
    }

    private func store(_ found: TextSearch.Matches, for search: TextSearch?) {
        self.search = search
        matches = found.ranges
        truncated = found.truncated
        current = nil
        needsSearch = false
        if search == nil { textView?.marksIfLoaded?.clearMatches() }
    }

    private func apply(_ found: TextSearch.Matches, for search: TextSearch, jump: Bool) {
        store(found, for: search)
        if jump, let i = TextSearch.index(startingAtOrAfter: selection.lowerBound, in: matches) {
            select(i)
        } else {
            current = indexForSelection()
            publish()
        }
    }

    /// Which match the editor's selection is: the one it selects, or
    /// (`marksWithCaret`) the one its caret is at the start of.
    private func indexForSelection() -> Int? {
        let selection = selection
        if let i = TextSearch.index(of: selection, in: matches) { return i }
        if selection.isEmpty, marksWithCaret,
           let i = TextSearch.index(startingAtOrAfter: selection.lowerBound, in: matches),
           matches[i].lowerBound == selection.lowerBound {
            return i
        }
        return nil
    }

    /// Makes match `i` the current one and brings it into sight, clear of
    /// the bar. With the keyboard in the editor it is selected; while it is
    /// in the bar the caret waits at its start (`marksWithCaret`) and
    /// Escape selects it.
    private func select(_ i: Int) {
        current = i
        if let large {
            large.view.select(bytes: matches[i], caretOnly: marksWithCaret)
            publish()
            return
        }
        let range = NSRange(location: matches[i].lowerBound, length: matches[i].count)
        if let textView {
            settingSelection = true
            textView.setSelectedRange(marksWithCaret ? NSRange(location: range.location, length: 0) : range)
            settingSelection = false
            controller?.reveal(range)
        }
        publish()
    }

    private func setCaret(_ offset: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        settingSelection = true
        textView.setSelectedRange(NSRange(location: min(max(0, offset), storage.length), length: 0))
        settingSelection = false
    }

    /// The editor's selection as a query: nothing for no selection, a very
    /// long one, or (for ⌘F) one that spans lines.
    private func selectedText(oneLine: Bool) -> String? {
        if let large {
            let range = large.view.selectedBytes
            guard !range.isEmpty, range.count <= 1000 else { return nil }
            let text = String(decoding: large.file.read(range), as: UTF8.self)
            return oneLine && text.contains(where: \.isNewline) ? nil : text
        }
        guard let textView, let storage = textView.textStorage else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 1000, NSMaxRange(range) <= storage.length else { return nil }
        let text = (storage.string as NSString).substring(with: range)
        return oneLine && text.contains(where: \.isNewline) ? nil : text
    }

    /// Shows the matches and the count for the list as it is.
    private func publish() {
        guard isOpen else { return }
        if large != nil {
            publishLarge()
            return
        }
        let old = label
        status = matches.isEmpty ? (query.isEmpty ? .idle : search == nil ? .invalid : .none)
            : .found(current: current, total: matches.count, more: truncated)
        textView?.marks.show(matches: matches, current: current.flatMap { matches.indices.contains($0) ? matches[$0] : nil })
        if label != old { announce() }
    }

    #if DEBUG || KIRI_SELFTEST
    /// A bar in a given state with no editor behind it, for pictures drawn
    /// offscreen.
    static func sample(query: String, status: Status, replacement: String? = nil, options: SearchOptions = SearchOptions(),
                       notice: String? = nil) -> FindController {
        let find = FindController()
        find.board = NSPasteboard.withUniqueName()
        find.query = query
        find.options = options
        find.replacement = replacement ?? ""
        find.showsReplace = replacement != nil
        find.isOpen = true
        find.status = status
        find.notice = notice
        return find
    }
    #endif

    /// Tells VoiceOver the count, which changes without the keyboard moving.
    private func announce() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = large?.view.window ?? textView?.window,
              !label.isEmpty else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

// MARK: - Large files

extension FindController {
    /// ⌘F on a large file: the bar, without its replace row.
    fileprivate func showLarge() {
        model?.goToLine.cancel(focusEditor: false)
        model?.palette.close(focusEditor: false)
        adoptBoard()
        if let selected = selectedText(oneLine: true) { quietly { query = selected } }
        showsReplace = false
        editorFocused = large?.view.window?.firstResponder === large?.view
        if isOpen {
            if let editor = large?.view.window?.firstResponder as? NSTextView, editor.isFieldEditor { editor.selectAll(nil) }
        } else {
            isOpen = true
            model?.overlayChanged()
        }
        focusRequest += 1
        refresh(jump: false)
    }

    /// ⌘G / ⇧⌘G on a large file: from the matches found so far, while the
    /// search is still under way.
    fileprivate func stepLarge(forward: Bool) {
        guard !query.isEmpty else {
            if !isOpen { show() }
            return
        }
        if !isOpen {
            pendingStep = forward
            show()
            if token != nil || work != nil { pendingStep = forward }
            return
        }
        if matches.isEmpty, pending {
            pendingStep = forward
            return
        }
        guard let i = TextSearch.step(from: current, selection: selection, forward: forward, in: matches) else {
            publish()
            return
        }
        select(i)
    }

    /// Searches the large file for the query: all of it, or (`appending`)
    /// what was added to it since the last search.
    fileprivate func refreshLarge(jump: Bool, step: Bool?, appending: Bool = false) {
        guard isOpen, let large else { return }
        largeInvalid = false
        guard !query.isEmpty else {
            store(TextSearch.Matches(), for: nil)
            largeLineStarts = []
            largeTotal = 0
            large.view.setRows(nil)
            large.view.show(matches: [], current: nil)
            status = .idle
            return
        }
        guard let search = try? LargeFileSearch(query, options: options) else {
            store(TextSearch.Matches(), for: nil)
            largeLineStarts = []
            largeTotal = 0
            large.view.setRows(nil)
            largeInvalid = true
            large.view.show(matches: [], current: nil)
            status = .invalid
            announce()
            return
        }
        let file = large.file
        let end = file.currentSize
        // From a little before where the last search ended: a match may
        // have been cut short by the end of the file then.
        let start = appending ? max(0, largeSearchedTo - max(0, query.utf8.count - 1) - (options.regularExpression ? 4096 : 0)) : 0
        guard start < end || !appending else { return }
        if !appending {
            matches = []
            largeLineStarts = []
            largeTotal = 0
            current = nil
            truncated = false
            needsSearch = false
        }
        largeSearchedTo = end
        pendingJump = jump
        pendingStep = step
        let base = matches, baseStarts = largeLineStarts, baseTotal = largeTotal
        let token = Token()
        self.token = token
        let queue = self.queue
        let room = max(0, LargeFileSearch.defaultLimit - base.count)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !token.isCancelled else { return }
                self.work = nil
                self.publish()
                queue.async {
                    let last = base.last?.upperBound ?? -1
                    // (Matches the last search found again are left out.)
                    func merged(_ r: LargeFileSearch.Result) -> ([Range<Int>], [Int], Int) {
                        let skip = r.ranges.prefix { $0.lowerBound < last }.count
                        return (base + r.ranges.dropFirst(skip), baseStarts + r.lineStarts.dropFirst(skip), baseTotal + r.count - skip)
                    }
                    let found = search.run(in: file, range: start..<end, limit: room, isCancelled: { token.isCancelled }) { r, _ in
                        let (ranges, starts, total) = merged(r)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.largeFound(ranges, lineStarts: starts, total: total, done: false, token: token)
                            }
                        }
                    }
                    let (ranges, starts, total) = merged(found)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard !found.cancelled else { return }
                            self.largeFound(ranges, lineStarts: starts, total: total, done: true, token: token)
                        }
                    }
                }
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// What the search has found so far (or, `done`, in all).
    private func largeFound(_ ranges: [Range<Int>], lineStarts: [Int], total: Int, done: Bool, token: Token) {
        guard self.token === token, !token.isCancelled else { return }
        let currentRange = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        matches = ranges
        largeLineStarts = lineStarts
        largeTotal = total
        current = currentRange.flatMap { TextSearch.index(of: $0, in: matches) }
        if done { self.token = nil }
        if pendingJump {
            let caret = selection.lowerBound
            // Before the end, only a match after the caret will do.
            if let i = TextSearch.index(startingAtOrAfter: caret, in: matches), done || matches[i].lowerBound >= caret {
                pendingJump = false
                select(i)
            }
        }
        if let step = pendingStep, !matches.isEmpty || done {
            pendingStep = nil
            stepLarge(forward: step)
        }
        if done { pendingJump = false }
        publish()
    }

    /// The bar's count and the marks in the viewer, for a large file.
    fileprivate func publishLarge() {
        guard let large else { return }
        let old = label
        if query.isEmpty {
            status = .idle
        } else if largeInvalid {
            status = .invalid
        } else if matches.isEmpty && !pending {
            status = .none
        } else {
            status = .found(current: current, total: largeTotal, more: pending)
        }
        // Only the matching lines (once each), before the matches are
        // shown on them.
        if onlyMatchingLines, !query.isEmpty, !largeInvalid {
            var rows: [Int] = []
            rows.reserveCapacity(largeLineStarts.count)
            for start in largeLineStarts where start != rows.last { rows.append(start) }
            large.view.setRows(rows)
        } else {
            large.view.setRows(nil)
        }
        large.view.show(matches: matches, current: current.flatMap { matches.indices.contains($0) ? matches[$0] : nil })
        if label != old, !pending { announce() }
    }

    /// The large file grew: what was added is searched too.
    func largeFileGrew() {
        guard isOpen, large != nil, !query.isEmpty, !pending else { return }
        refreshLarge(jump: false, step: nil, appending: true)
    }

    /// The tab no longer shows the large file (closed, or the preview tab
    /// went on to another file): its search ends, and its matches, which
    /// were byte offsets, are no use to the editor.
    func largeFileGone() {
        cancelPending()
        store(TextSearch.Matches(), for: nil)
        largeLineStarts = []
        onlyMatchingLines = false
        largeTotal = 0
        largeSearchedTo = 0
        largeInvalid = false
        needsSearch = true
        if isOpen { refresh(jump: false) }
    }

    /// The large file was opened again: searched again from the top.
    func largeFileReplaced() {
        guard isOpen, large != nil else { return }
        cancelPending()
        refreshLarge(jump: false, step: nil)
    }
}

/// Go to Line (⌘L): the line shows as its number is typed, Return keeps it
/// and Escape goes back to where the editor was.
///
/// It has no bar of its own: it is what the command palette does with a
/// line number after a colon (`PaletteController`, its `:` mode), and ⌘L
/// opens the palette with the colon typed. This is the engine of that
/// mode: where the editor was, the preview and going back.
@Observable final class GoToLineController {
    @ObservationIgnored weak var model: EditorModel?

    /// A line is being typed: the palette is in its `:` mode.
    private(set) var isOpen = false
    /// "12", or "12:5" for a column too: what the palette has after its colon.
    var text = "" {
        didSet { if text != oldValue, isOpen { preview() } }
    }
    /// The text is not a line number.
    private(set) var isInvalid = false
    /// Where the text says to go, or nil for nothing typed or not a line.
    var target: LineTarget? {
        guard let controller, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LineTarget(text, lineCount: controller.lineCount)
    }

    /// Where the editor was when Go to Line opened.
    @ObservationIgnored private var before: (selection: [NSValue], origin: NSPoint)?
    /// Where the large file's viewer was then.
    @ObservationIgnored private var largeBefore: (anchor: LargePosition, caret: LargePosition, top: Double)?
    @ObservationIgnored private var previewing = false

    private var controller: EditorController? { model?.controller }

    #if DEBUG || KIRI_SELFTEST
    /// In a given state with no editor behind it, for pictures drawn offscreen.
    static func sample(text: String, invalid: Bool = false) -> GoToLineController {
        let goToLine = GoToLineController()
        goToLine.text = text
        goToLine.isInvalid = invalid
        goToLine.isOpen = true
        return goToLine
    }
    #endif

    /// ⌘L, Edit ▸ Go to Line…, the status bar's position: the palette,
    /// with the colon typed and the keyboard after it.
    func open() {
        model?.palette.open(with: ":")
    }

    /// The palette's field begins with a colon: from here on the line
    /// shows as its number is typed, and where the editor is now is where
    /// Escape goes back to.
    func begin() {
        guard !isOpen, let controller, let textView = controller.textView else { return }
        // Lines are the text's: a Markdown preview shows it.
        controller.tab?.setMarkdownPreview(false)
        text = ""
        isInvalid = false
        previewing = false
        before = (textView.selectedRanges, controller.scrollOrigin)
        largeBefore = model?.large?.view.place
        isOpen = true
        model?.overlayChanged()
    }

    /// Return: the caret stays on the line and the keyboard goes back to
    /// the editor. Text that isn't a line number keeps the field open
    /// (false); nothing typed is Escape.
    @discardableResult
    func commit() -> Bool {
        guard isOpen, let controller else { return false }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            cancel()
            return true
        }
        guard let target = LineTarget(text, lineCount: controller.lineCount) else {
            isInvalid = true
            return false
        }
        end()
        controller.goTo(line: target.line, column: target.column)
        return true
    }

    /// Escape: back to the selection and the scroll position from before.
    func cancel(focusEditor: Bool = true) {
        guard isOpen else { return }
        restore()
        end()
        if focusEditor { controller?.focus() }
    }

    /// Another document takes the editor (the folder sidebar's preview
    /// tab): the line was a line of the other one, and where the caret
    /// was in it is not gone back to. (The palette closes itself.)
    func documentReplaced() {
        guard isOpen else { return }
        end()
    }

    private func end() {
        isOpen = false
        before = nil
        largeBefore = nil
        previewing = false
        controller?.textView?.marksIfLoaded?.showLine(false)
        model?.large?.view.mark(line: nil)
        model?.overlayChanged()
    }

    private func preview() {
        guard let controller else { return }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            isInvalid = false
            restore()
            return
        }
        guard let target = LineTarget(text, lineCount: controller.lineCount) else {
            isInvalid = true
            return
        }
        isInvalid = false
        previewing = true
        controller.previewLine(target.line, column: target.column)
    }

    private func restore() {
        if let large = model?.large?.view, previewing, let largeBefore {
            previewing = false
            large.mark(line: nil)
            large.restore(largeBefore)
            return
        }
        guard previewing, let before, let controller, let textView = controller.textView else { return }
        previewing = false
        textView.marksIfLoaded?.showLine(false)
        textView.selectedRanges = before.selection
        controller.scrollOrigin = before.origin
    }
}
