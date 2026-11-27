import AppKit
import KiriKit
import SwiftUI

/// Find in the folder sidebar: Edit ▸ Find… (⌘F), Find Next (⌘G) and Find
/// Previous (⇧⌘G) while the sidebar has the keyboard. A field at the top
/// of the sidebar takes a few letters of a name, and the keyboard's row
/// goes to the first file or folder with them in its name, anywhere under
/// the folder: the folders above it open to show it.
///
/// The query is the sidebar's own, kept from one ⌘F to the next (and for
/// ⌘G after the field has closed): the editor's find bar and the find
/// pasteboard have theirs. One per folder session, shown in one window's
/// sidebar at a time, as a name typed in place is.
@Observable final class SidebarFind {
    @ObservationIgnored private unowned let session: FolderSession

    /// What is looked for. Typing it goes to the first match from the row
    /// the find began on.
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    /// The field is up.
    private(set) var isOpen = false
    /// The files and folders found, in the sidebar's order.
    private(set) var found: [SidebarSearch.Entry] = []
    /// The one the keyboard's row is on, in `found`.
    private(set) var current: Int?
    /// The field has the keyboard (the sidebar itself then has not).
    var fieldHasFocus = false
    /// Bumped to put the keyboard in the field with all of it selected.
    private(set) var focusRequest = 0
    /// Bumped when the field closes and gives the keyboard back to the
    /// rows (Return, Escape).
    private(set) var treeFocusRequest = 0
    /// Bumped when the keyboard's row has moved to a match (or back): the
    /// list scrolls it into view.
    private(set) var scrollRequest = 0

    /// The window whose sidebar shows the field (or did, last).
    @ObservationIgnored private weak var window: NSWindow?
    /// The keyboard's row when ⌘F opened the field: where typing looks
    /// from, and where Escape goes back to.
    @ObservationIgnored private var origin: URL?
    /// ⌘G or an arrow moved on from where typing went: a new reading of
    /// the folder then leaves the row where it is.
    @ObservationIgnored private var stepped = false
    /// The index's files and the folders above them, in the sidebar's
    /// order: put in order off the main thread after each reading of the
    /// folder (20 000 files take a moment), and until then none.
    @ObservationIgnored private var indexed: [SidebarSearch.Entry]?
    /// Which reading of the folder `indexed` is being made for.
    @ObservationIgnored private var ordering: Int?
    @ObservationIgnored private var readings = 0
    /// What VoiceOver was told last, so a count is said when it changes.
    @ObservationIgnored private var announced = ""

    init(session: FolderSession) {
        self.session = session
        NotificationCenter.default.addObserver(forName: FolderIndex.didChange, object: session.index, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.indexChanged() }
        }
    }

    /// Whether the field shows in the sidebar of `window`.
    func isOpen(in window: NSWindow?) -> Bool { isOpen && belongs(to: window) }

    /// Whether the find is (or was last) in the sidebar of `window`.
    func belongs(to window: NSWindow?) -> Bool { self.window == nil || self.window === window }

    /// "2 of 5", "No matches", or nothing while there is no query.
    var label: String {
        guard !query.isEmpty else { return "" }
        guard !found.isEmpty else { return "No matches" }
        return current.map { "\($0 + 1) of \(found.count)" } ?? "\(found.count) found"
    }

    /// The widest count `label` gives for what is found now, so its place
    /// keeps one width while the count changes.
    var widestLabel: String { "\(found.count) of \(found.count)" }

    // MARK: The menu items

    /// Edit ▸ Find…, Find Next or Find Previous, while the sidebar (or its
    /// field) has the keyboard. False for the others, which stay the
    /// editor's (Find and Replace, Use Selection for Find).
    func perform(_ action: FindController.Action, in window: NSWindow?) -> Bool {
        switch action {
        case .show:
            open(in: window)
        case .next, .previous:
            // With nothing looked for yet, the field to type it in.
            if query.isEmpty { open(in: window) } else { step(forward: action == .next) }
        default:
            return false
        }
        return true
    }

    /// ⌘F: the field, with the last query in it, all of it selected.
    func open(in window: NSWindow?) {
        let wasOpen = isOpen
        if !wasOpen {
            origin = session.cursor
            stepped = false
            Telemetry.track("sidebar_find_open")
        }
        self.window = window
        isOpen = true
        focusRequest += 1
        // Files made since it was last read; until it is in, what was read before.
        session.index.refresh()
        // (⌘F again while it is up only selects the query: the row stays.)
        if !query.isEmpty { search(jump: !wasOpen) }
    }

    /// ⌘G / ⇧⌘G (and ↓ / ↑ in the field): the next match below the
    /// keyboard's row, or above it, going round at the ends.
    func step(forward: Bool) {
        guard !query.isEmpty else { return }
        if !session.index.hasRead { session.index.refresh() }
        search(jump: false)
        if go(from: entry(at: session.cursor), forward ? .after : .before) { stepped = true }
        announce()
    }

    /// Return in the field: it closes, and the rows have the keyboard on
    /// the match (a second Return opens it, Space shows it).
    func commit() {
        guard isOpen else { return }
        close()
        treeFocusRequest += 1
    }

    /// Escape in the field: it closes, and the keyboard is back on the row
    /// it was on before ⌘F.
    func cancel() {
        guard isOpen else { return }
        if let origin, session.cursor != origin {
            session.cursor = origin
            scrollRequest += 1
        }
        close()
        treeFocusRequest += 1
    }

    /// The keyboard went elsewhere (a click in the editor, ⇧⌘E): the field
    /// closes and the row stays on the match.
    func fieldLostFocus() {
        guard isOpen else { return }
        close()
    }

    private func close() {
        isOpen = false
        fieldHasFocus = false
        announced = ""
    }

    // MARK: Finding

    private func queryChanged() {
        guard isOpen else { return }
        stepped = false
        search(jump: true)
    }

    private func indexChanged() {
        readings += 1
        indexed = nil
        // (Only for a find that is in use: the palette reads the folder too.)
        if isOpen || !query.isEmpty { orderIndex() }
    }

    /// Puts the index's files and their folders in the sidebar's order, off
    /// the main thread, and finds the query in them once they are.
    private func orderIndex() {
        guard indexed == nil, ordering != readings, session.index.hasRead else { return }
        let reading = readings
        ordering = reading
        let paths = session.index.paths
        // The names the tree never shows (a `.git` file in a worktree or a
        // submodule): nothing to go to.
        let hidden = FileNode.hidden
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = paths.filter { !$0.split(separator: "/").contains { hidden.contains(String($0)) } }
            let ordered = SidebarSearch.ordered(files.map { SidebarSearch.Entry(path: $0, isFolder: false) }
                + SidebarSearch.folders(above: files).map { SidebarSearch.Entry(path: $0, isFolder: true) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.readings == reading else { return }
                    self.ordering = nil
                    self.indexed = ordered
                    if self.isOpen, !self.query.isEmpty { self.search(jump: !self.stepped) }
                }
            }
        }
    }

    /// Finds the query again in the folder as it is now: the index's files
    /// and folders, and the rows that show, which have the folders the
    /// index leaves out ("build", empty ones) and files made since. With
    /// `jump`, the row goes to the first match at or after the row the
    /// find began on.
    private func search(jump: Bool) {
        orderIndex()
        let shown = SidebarSearch.ordered(session.visibleRows().compactMap { row in
            relativePath(row.node.url).map { SidebarSearch.Entry(path: $0, isFolder: row.node.isDirectory) }
        })
        found = SidebarSearch.merged(SidebarSearch.find(query, inOrdered: indexed ?? []),
                                     SidebarSearch.find(query, inOrdered: shown))
        if !jump || !go(from: entry(at: origin), .atOrAfter) {
            current = entry(at: session.cursor).flatMap { found.firstIndex(of: $0) }
        }
        if isOpen { announce() }
    }

    /// The row at `url` as an entry, if it is one under the folder.
    private func entry(at url: URL?) -> SidebarSearch.Entry? {
        guard let url, let path = relativePath(url) else { return nil }
        let isFolder = session.visibleRows().first { $0.node.url == url }?.node.isDirectory
            ?? ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        return SidebarSearch.Entry(path: path, isFolder: isFolder)
    }

    private func relativePath(_ url: URL) -> String? {
        let root = session.root.url.path, path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// The keyboard's row goes to the match `direction` of the row `from`,
    /// the folders above it opened. A match that is no longer there (gone
    /// since the folder was read) is let go of, and the next one taken.
    /// False when there is none.
    @discardableResult private func go(from: SidebarSearch.Entry?, _ direction: SidebarSearch.Direction) -> Bool {
        while let i = SidebarSearch.index(in: found, from: from, direction) {
            if let url = reveal(found[i]) {
                current = i
                if session.cursor != url { session.cursor = url }
                scrollRequest += 1
                return true
            }
            found.remove(at: i)
        }
        current = nil
        return false
    }

    /// Opens the folders above `entry` in the tree, as a click on each
    /// would, and gives its row's URL. Nil if it is no longer there.
    private func reveal(_ entry: SidebarSearch.Entry) -> URL? {
        guard FileManager.default.fileExists(atPath: session.root.url.appendingPathComponent(entry.path).path) else { return nil }
        var node = session.root
        let names = entry.path.split(separator: "/").map(String.init)
        for (depth, name) in names.enumerated() {
            var child = node.children.first { $0.name == name }
            if child == nil {
                // Made since the folder was last read in the tree.
                node.reload()
                child = node.children.first { $0.name == name }
            }
            guard let child else { return nil }
            if depth < names.count - 1 {
                guard child.isDirectory else { return nil }
                if !session.expanded.contains(child.url) { session.toggle(child) }
            }
            node = child
        }
        return node.url
    }

    /// VoiceOver hears the count when it changes ("2 of 5", "No matches").
    private func announce() {
        let text = label
        guard !text.isEmpty, text != announced else { return }
        announced = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// The field at the top of the sidebar that a name is found with: a
/// paper-colored well with a magnifying glass, the Honey focus ring while
/// it has the keyboard, and the count at its end.
struct SidebarFindField: View {
    @Bindable var find: SidebarFind
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(focused ? Color.honeyAccentInk : Color.honeyMuted)
                .frame(width: 16)
                .accessibilityHidden(true)
            TextField("Find in folder", text: $find.query)
                .textFieldStyle(.plain)
                .font(.honey(.subheadline, weight: .semibold))
                .foregroundStyle(Color.honeyFg)
                .focused($focused)
                .accessibilityLabel("Find in folder")
                // Return: the rows get the keyboard, on the match. (As the
                // field's submit, so a Return that ends typing in an input
                // method stays the input method's.)
                .onSubmit { find.commit() }
                // The arrows go from match to match, as ⌘G and ⇧⌘G do;
                // Escape goes back. Taken here, before the rows' own keys
                // see them.
                .onKeyPress(.downArrow) { find.step(forward: true); return .handled }
                .onKeyPress(.upArrow) { find.step(forward: false); return .handled }
                .onKeyPress(.escape) { find.cancel(); return .handled }
            count
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(Color.honeySurface.opacity(0.7), in: shape)
        // A hairline says where the field is; the focus ring, that it has the keyboard.
        .overlay { shape.strokeBorder(focused ? Color.honeyFocus : Color.honeyLine, lineWidth: focused ? 2 : 1) }
        .onExitCommand { find.cancel() }
        // The keyboard comes here as the field appears (a turn later: in
        // the turn it is made, the rows may still be taking it back), and
        // again with each ⌘F while it is up.
        .onAppear { DispatchQueue.main.async { takeKeyboard() } }
        .onChange(of: find.focusRequest) { takeKeyboard() }
        .onChange(of: focused) { was, now in
            find.fieldHasFocus = now
            if was, !now { find.fieldLostFocus() }
        }
        .onDisappear { find.fieldHasFocus = false }
    }

    private func takeKeyboard() {
        focused = true
        // All of the last query selected, so typing replaces it (only ever
        // in a field: never the document's text).
        DispatchQueue.main.async {
            guard focused, let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.isFieldEditor else { return }
            field.selectAll(nil)
        }
    }

    /// "2 of 5", in a width that stays put while the count changes.
    private var count: some View {
        ZStack(alignment: .trailing) {
            Text("No matches").hidden()
            Text(find.widestLabel).hidden()
            Text(find.label)
        }
        .font(.honey(.caption, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        // The words carry the state; the color only underlines it.
        .foregroundStyle(find.label == "No matches" ? Color.honeyDanger : Color.honeyMuted)
        .opacity(find.label.isEmpty ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(find.label)
        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
        .accessibilityHidden(find.label.isEmpty)
    }
}
