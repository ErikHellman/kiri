import AppKit
import KiriKit
import SwiftUI

/// A folder opened with `kiri <folder>` (or File ▸ Open Folder…), shared by
/// every tab of its window: the tree, which folders are expanded and
/// whether the sidebar shows.
@MainActor @Observable final class FolderSession {
    let root: FileNode
    var sidebarVisible = true
    var expanded: Set<URL> = []
    /// The keyboard's row in the sidebar (↑ ↓ move it, Return opens it).
    var cursor: URL?
    /// Bumped by Refresh, so rows reread their folders.
    private(set) var generation = 0

    init(root url: URL) {
        root = FileNode(url: url.standardizedFileURL, isDirectory: true)
    }

    var name: String { root.name }

    func toggle(_ node: FileNode) {
        if expanded.contains(node.url) {
            expanded.remove(node.url)
        } else {
            node.reload() // pick up files made since it was last open
            expanded.insert(node.url)
        }
    }

    func refresh() {
        root.reload()
        generation += 1
    }

    struct Row {
        let node: FileNode
        let parent: URL?
    }

    /// The rows as shown, top to bottom: the root's children and the
    /// contents of every expanded folder.
    func visibleRows() -> [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [FileNode], parent: URL?) {
            for node in nodes {
                rows.append(Row(node: node, parent: parent))
                if node.isDirectory, expanded.contains(node.url) { walk(node.children, parent: node.url) }
            }
        }
        walk(root.children, parent: nil)
        return rows
    }
}

/// Which window shows which folder. Tabs dragged into or opened in a
/// folder window share its session.
@MainActor enum FolderSessions {
    private static var byWindow: [ObjectIdentifier: (window: WeakWindow, session: FolderSession)] = [:]
    private static var observing = false

    struct WeakWindow { weak var window: NSWindow? }

    static func set(_ session: FolderSession, for window: NSWindow) {
        observe()
        byWindow[ObjectIdentifier(window)] = (WeakWindow(window: window), session)
    }

    static func session(for window: NSWindow) -> FolderSession? {
        if let entry = byWindow[ObjectIdentifier(window)], entry.window.window === window { return entry.session }
        // A new tab in a folder window takes the folder.
        for sibling in window.tabbedWindows ?? [] where sibling !== window {
            if let entry = byWindow[ObjectIdentifier(sibling)], entry.window.window === sibling {
                set(entry.session, for: window)
                return entry.session
            }
        }
        return nil
    }

    private static func observe() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            let id = ObjectIdentifier(window)
            MainActor.assumeIsolated { _ = byWindow.removeValue(forKey: id) }
        }
    }

    /// File ▸ Open Folder…
    static func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        KiriCLI.open(KiriCLI.Request(entries: [.folder(url)]))
    }
}

/// A file or folder in the sidebar. Folders read their contents when first
/// expanded.
@MainActor final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    private var loaded: [FileNode]?

    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var children: [FileNode] {
        guard isDirectory else { return [] }
        if let loaded { return loaded }
        let list = Self.list(url)
        loaded = list
        return list
    }

    func reload() { loaded = nil }

    /// Hidden files show (quick edits often target dotfiles), except the
    /// noise nobody edits by hand.
    private static let skipped: Set<String> = [".git", ".DS_Store", ".build", "node_modules", "DerivedData", ".svn", ".hg"]

    private static func list(_ url: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        return items
            .filter { !skipped.contains($0.lastPathComponent) }
            .map { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                let dir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                return FileNode(url: item.standardizedFileURL, isDirectory: dir)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}

/// The file browser beside the editor in a folder window.
struct FolderSidebar: View {
    let session: FolderSession
    let model: EditorModel
    let currentFile: URL?
    let open: (URL) -> Void
    @FocusState private var focused: Bool
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Color.honeyAccentInk)
                    .font(.system(size: 12, weight: .bold))
                Text(session.name)
                    .font(.honey(.subheadline, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    session.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.honeyMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityLabel("Refresh folder")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)
            .help(session.root.url.path)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let _ = session.generation
                        ForEach(session.root.children) { node in
                            FileRow(node: node, depth: 0, session: session, currentFile: currentFile,
                                    keyboardFocus: focused, open: open)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: session.cursor) { _, url in
                    guard let url, focused else { return }
                    withAnimation(HoneyMotion(appearance, systemReduced: reduce).quick) { proxy.scrollTo(url) }
                }
            }
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .honeyGlass(.chrome, radius: .panel)
        .overlay {
            RoundedRectangle(cornerRadius: Honey.Radius.panel.value, style: .continuous)
                .strokeBorder(Color.honeyFocus, lineWidth: focused ? 2 : 0)
                .allowsHitTesting(false)
        }
        // Keyboard: ⇧⌘E (View ▸ Focus Sidebar) moves here and back.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.home) { jump(toEnd: false) }
        .onKeyPress(.end) { jump(toEnd: true) }
        .onKeyPress(.pageUp) { move(-12) }
        .onKeyPress(.pageDown) { move(12) }
        .onKeyPress(.leftArrow) { collapseOrParent() }
        .onKeyPress(.rightArrow) { expandOrChild() }
        .onKeyPress(.return) { activate(thenEdit: true) }
        .onKeyPress(.space) { activate(thenEdit: false) }
        .onKeyPress(.escape) {
            model.controller?.focus()
            return .handled
        }
        .onKeyPress(phases: .down) { press in typeSelect(press) }
        .onChange(of: focused) { _, now in
            model.sidebarHasFocus = now
            if now, session.cursor == nil || !rows.contains(where: { $0.node.url == session.cursor }) {
                session.cursor = rows.first(where: { $0.node.url == currentFile })?.node.url ?? rows.first?.node.url
            }
        }
        .onChange(of: model.sidebarFocusRequest, initial: true) {
            guard model.sidebarFocusRequest > 0, !focused else { return }
            focused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files in \(session.name)")
    }

    // MARK: Keyboard

    private var rows: [FolderSession.Row] { session.visibleRows() }

    private var cursorIndex: Int? { rows.firstIndex { $0.node.url == session.cursor } }

    private func move(_ by: Int) -> KeyPress.Result {
        let rows = rows
        guard !rows.isEmpty else { return .handled }
        let i = cursorIndex.map { min(max($0 + by, 0), rows.count - 1) } ?? 0
        session.cursor = rows[i].node.url
        return .handled
    }

    private func jump(toEnd: Bool) -> KeyPress.Result {
        session.cursor = (toEnd ? rows.last : rows.first)?.node.url
        return .handled
    }

    /// ←: closes an open folder, or steps out to the parent folder.
    private func collapseOrParent() -> KeyPress.Result {
        guard let i = cursorIndex else { return move(0) }
        let row = rows[i]
        if row.node.isDirectory, session.expanded.contains(row.node.url) {
            withAnimation(HoneyMotion(appearance, systemReduced: reduce).quick) { session.toggle(row.node) }
        } else if let parent = row.parent {
            session.cursor = parent
        }
        return .handled
    }

    /// →: opens a closed folder, or steps into an open one.
    private func expandOrChild() -> KeyPress.Result {
        guard let i = cursorIndex else { return move(0) }
        let node = rows[i].node
        guard node.isDirectory else { return .handled }
        if !session.expanded.contains(node.url) {
            withAnimation(HoneyMotion(appearance, systemReduced: reduce).quick) { session.toggle(node) }
        } else if let first = node.children.first {
            session.cursor = first.url
        }
        return .handled
    }

    /// Return and Space: a folder opens or closes, a file opens. Return
    /// also moves the keyboard to the editor.
    private func activate(thenEdit: Bool) -> KeyPress.Result {
        guard let i = cursorIndex else { return move(0) }
        let node = rows[i].node
        if node.isDirectory {
            withAnimation(HoneyMotion(appearance, systemReduced: reduce).quick) { session.toggle(node) }
        } else {
            open(node.url)
            if thenEdit { EditorController.focusKeyWindowEditor() }
        }
        return .handled
    }

    /// Typing a name's first letters jumps to the next row that starts with
    /// them, as in Finder.
    private func typeSelect(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
              press.characters.count == 1, let c = press.characters.first,
              c.isLetter || c.isNumber || c.isPunctuation else { return .ignored }
        let now = Date()
        typed = now.timeIntervalSince(typedAt) < 1 ? typed + String(c) : String(c)
        typedAt = now
        let rows = rows
        guard !rows.isEmpty else { return .handled }
        let start = cursorIndex ?? 0
        // A fresh letter looks past the current row; more letters refine it.
        let offset = typed.count == 1 ? 1 : 0
        for k in 0..<rows.count {
            let row = rows[(start + offset + k) % rows.count]
            if row.node.name.lowercased().hasPrefix(typed.lowercased()) {
                session.cursor = row.node.url
                break
            }
        }
        return .handled
    }
}

private struct FileRow: View {
    let node: FileNode
    let depth: Int
    let session: FolderSession
    let currentFile: URL?
    let keyboardFocus: Bool
    let open: (URL) -> Void
    @State private var hovering = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let expanded = session.expanded.contains(node.url)
        let current = node.url == currentFile
        let cursor = keyboardFocus && node.url == session.cursor
        VStack(alignment: .leading, spacing: 1) {
            Button {
                session.cursor = node.url
                if node.isDirectory {
                    withAnimation(HoneyMotion(appearance, systemReduced: reduce).quick) { session.toggle(node) }
                } else {
                    open(node.url)
                }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if node.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .heavy))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(Color.honeyMuted)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 10)
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(node.isDirectory ? Color.honeyAccentInk : Color.honeyMuted)
                        .frame(width: 14)
                    Text(node.name)
                        .font(.honey(.subheadline, weight: current ? .bold : .semibold))
                        .foregroundStyle(current ? Color.honeyFg : Color.honeyFg.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6 + CGFloat(depth) * 14)
                .padding(.trailing, 6)
                .frame(height: 26)
                .background {
                    if cursor {
                        Capsule().fill(current ? Color.honeyAccentSoft : Color.honeySurface2)
                            .overlay { Capsule().strokeBorder(Color.honeyFocus, lineWidth: 1.5) }
                    } else if current {
                        Capsule().fill(Color.honeyAccentSoft)
                    } else if hovering {
                        Capsule().fill(Color.honeySurface2.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false) // the sidebar takes the keys, not each row
            .id(node.url)
            .onHover { hovering = $0 }
            .help(node.url.path)
            .accessibilityLabel(node.isDirectory ? "\(node.name), folder, \(expanded ? "expanded" : "collapsed")" : node.name)

            if node.isDirectory, expanded {
                let _ = session.generation
                ForEach(node.children) { child in
                    FileRow(node: child, depth: depth + 1, session: session, currentFile: currentFile,
                            keyboardFocus: keyboardFocus, open: open)
                }
            }
        }
    }
}
