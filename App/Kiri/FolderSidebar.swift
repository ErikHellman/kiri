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
    let currentFile: URL?
    let open: (URL) -> Void

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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let _ = session.generation
                    ForEach(session.root.children) { node in
                        FileRow(node: node, depth: 0, session: session, currentFile: currentFile, open: open)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .honeyGlass(.chrome, radius: .panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files in \(session.name)")
    }
}

private struct FileRow: View {
    let node: FileNode
    let depth: Int
    let session: FolderSession
    let currentFile: URL?
    let open: (URL) -> Void
    @State private var hovering = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let expanded = session.expanded.contains(node.url)
        let current = node.url == currentFile
        VStack(alignment: .leading, spacing: 1) {
            Button {
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
                    if current {
                        Capsule().fill(Color.honeyAccentSoft)
                    } else if hovering {
                        Capsule().fill(Color.honeySurface2.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(node.url.path)
            .accessibilityLabel(node.isDirectory ? "\(node.name), folder, \(expanded ? "expanded" : "collapsed")" : node.name)

            if node.isDirectory, expanded {
                let _ = session.generation
                ForEach(node.children) { child in
                    FileRow(node: child, depth: depth + 1, session: session, currentFile: currentFile, open: open)
                }
            }
        }
    }
}
