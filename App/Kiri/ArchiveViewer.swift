import AppKit
import KiriKit
import SwiftUI

/// What a zip, tar or tar.gz holds (`MediaKind.archive`), as a tree of
/// folders and files with each one's size unpacked (a folder's is all that
/// is in it). Nothing is unpacked: a zip's list is read from its end, a
/// tar's by reading it through (`ArchiveReader`), off the main thread, with
/// how far it has got showing meanwhile. A click opens and closes a folder,
/// Option-click everything in it too.
@MainActor final class ArchiveViewer: MediaContent {
    private let format: MediaKind.ArchiveFormat
    private let model: ArchiveModel
    private let host: NSHostingView<ArchiveView>
    var onDetails: (([String]) -> Void)?
    private var reading: Token?
    private let queue = DispatchQueue(label: "se.hellsoft.kiri.archive", qos: .userInitiated)

    init(format: MediaKind.ArchiveFormat) {
        self.format = format
        let model = ArchiveModel()
        self.model = model
        host = NSHostingView(rootView: ArchiveView(model: model))
        host.sizingOptions = []
    }

    var view: NSView { host }
    var keyView: NSView { host }

    func load(_ url: URL) {
        reading?.cancel()
        let token = Token()
        reading = token
        model.url = url
        if model.tree == nil { model.state = .reading(0) }
        let format = format
        queue.async { [weak self] in
            var last = 0.0
            let result = Result {
                try ArchiveReader.listing(of: url, format: format, isCancelled: { token.isCancelled }) { fraction in
                    // A hundred steps at most.
                    guard fraction - last >= 0.01 else { return }
                    last = fraction
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.reading === token, self.model.tree == nil else { return }
                            self.model.state = .reading(fraction)
                        }
                    }
                }
            }
            let tree = (try? result.get()).map { ArchiveTree(entries: $0.entries) }
            let truncated = (try? result.get())?.truncated ?? false
            let failure = result.failureMessage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.reading === token else { return }
                    self.reading = nil
                    if let tree {
                        self.model.show(tree, truncated: truncated)
                        self.onDetails?([MediaText.files(tree.fileCount),
                                         ByteCountFormatter.string(fromByteCount: tree.totalSize, countStyle: .file) + " unpacked"])
                    } else if let failure {
                        self.model.state = .failed(failure)
                        self.onDetails?([])
                    }
                }
            }
        }
    }

    func stop() {
        reading?.cancel()
        reading = nil
    }

    func zoom(_ step: MediaZoom) -> Bool { false }

    #if DEBUG || KIRI_SELFTEST
    /// For the self-test.
    var tree: ArchiveTree? { model.tree }
    var rows: [ArchiveTree.Row] { model.rows }
    func toggle(_ node: ArchiveTree.Node, all: Bool = false) { model.toggle(node, all: all) }
    #endif

    private final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}

private extension Result where Failure == any Error {
    /// What the viewer says when the list can't be read (nothing, if it was stopped).
    var failureMessage: String? {
        guard case .failure(let error) = self else { return nil }
        if error is CancellationError { return nil }
        if let archive = error as? ArchiveError { return archive.description }
        return error.localizedDescription
    }
}

/// The archive viewer's state.
@MainActor @Observable final class ArchiveModel {
    enum State: Equatable {
        case reading(Double)
        case shown
        case failed(String)
    }

    var state = State.reading(0)
    var url: URL?
    private(set) var tree: ArchiveTree?
    private(set) var truncated = false
    /// Open folders, by node id.
    private(set) var expanded: Set<Int> = []
    /// What shows: the open folders' contents.
    private(set) var rows: [ArchiveTree.Row] = []

    func show(_ new: ArchiveTree, truncated: Bool) {
        // The same archive again (it changed on disk): the same folders
        // stay open, where they still are.
        let open = tree.map { old in Set(old.rows(expanded: old.folderIDs).filter { expanded.contains($0.id) }.map(\.node.path)) }
        tree = new
        self.truncated = truncated
        if let open {
            expanded = Set(new.rows(expanded: new.folderIDs).filter { open.contains($0.node.path) }.map(\.id))
        } else {
            expanded = new.initiallyExpanded
        }
        rows = new.rows(expanded: expanded)
        state = .shown
    }

    /// Opens or closes a folder; `all` does the same to every folder in it.
    func toggle(_ node: ArchiveTree.Node, all: Bool = false) {
        guard let tree, node.isDirectory else { return }
        let opening = !expanded.contains(node.id)
        var ids = [node.id]
        if all {
            func folders(_ n: ArchiveTree.Node) { for c in n.children where c.isDirectory { ids.append(c.id); folders(c) } }
            folders(node)
        }
        if opening { expanded.formUnion(ids) } else { expanded.subtract(ids) }
        rows = tree.rows(expanded: expanded)
    }

    func expandAll() {
        guard let tree else { return }
        expanded = tree.folderIDs
        rows = tree.rows(expanded: expanded)
    }

    func collapseAll() {
        guard let tree else { return }
        expanded = []
        rows = tree.rows(expanded: expanded)
    }
}

struct ArchiveView: View {
    let model: ArchiveModel
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        switch model.state {
        case .reading(let fraction):
            VStack(spacing: 12) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Color.honeyAccent)
                    .frame(width: 220)
                Text("Reading the archive…").font(.honey(.subheadline, weight: .semibold)).foregroundStyle(Color.honeyMuted)
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let why):
            ViewerMessage(symbol: "doc.zipper", title: "Kiri can’t read this archive", detail: why, url: model.url)
        case .shown:
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            if model.truncated {
                Label("The archive ends early, so this may not be all of it (is it still being written or downloaded?).",
                      systemImage: "exclamationmark.triangle")
                    .font(.honey(.footnote, weight: .semibold))
                    .foregroundStyle(Color.honeyMuted)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.rows.isEmpty {
                Text("The archive is empty.").font(.honey(.body)).foregroundStyle(Color.honeyMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.rows) { row in
                            ArchiveRow(row: row, expanded: model.expanded.contains(row.id)) { all in
                                withAnimation(HoneyMotion(appearance, systemReduced: reduce).quick) { model.toggle(row.node, all: all) }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    // Clear of the status bar.
                    .padding(.bottom, 52)
                }
                .scrollIndicators(.automatic)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Contents of the archive")
    }

    /// Name and Size over the columns, and Expand All and Collapse All.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Name")
            Spacer(minLength: 0)
            if !(model.tree?.folderIDs.isEmpty ?? true) {
                Button { model.expandAll() } label: {
                    Image(systemName: "plus.square").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Expand All")
                .accessibilityLabel("Expand All")
                Button { model.collapseAll() } label: {
                    Image(systemName: "minus.square").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse All")
                .accessibilityLabel("Collapse All")
            }
            Text("Size").frame(width: ArchiveRow.sizeWidth, alignment: .trailing)
        }
        .font(.honeySectionLabel)
        .textCase(.uppercase)
        .tracking(0.7)
        .foregroundStyle(Color.honeyMuted)
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// A folder or a file of the archive: as the folder sidebar draws its rows.
private struct ArchiveRow: View {
    let row: ArchiveTree.Row
    let expanded: Bool
    /// Opens or closes a folder; true for everything in it (Option-click).
    let toggle: (Bool) -> Void
    @State private var hovering = false

    static let sizeWidth: CGFloat = 84

    var body: some View {
        let node = row.node
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
            let icon = node.isDirectory ? nil : node.isLink ? FileIcon(symbol: "arrow.turn.up.right") : FileIcon.forFile(named: node.name)
            Image(systemName: icon?.symbol ?? "folder.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(node.isDirectory ? Color.honeyAccentInk : icon?.tint.map { Color.honey($0.token) } ?? Color.honeyMuted)
                .frame(width: 16)
            Text(node.name)
                .font(.honey(.subheadline, weight: node.isDirectory ? .bold : .semibold))
                .foregroundStyle(Color.honeyFg.opacity(node.isDirectory ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if node.isDirectory {
                Text(MediaText.files(node.fileCount))
                    .font(.honey(.footnote))
                    .foregroundStyle(Color.honeyMuted)
                    .lineLimit(1)
            }
            Text(node.isLink ? "link" : ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                .font(.honey(.subheadline, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(node.isDirectory ? Color.honeyFg : Color.honeyMuted)
                .lineLimit(1)
                .frame(width: Self.sizeWidth, alignment: .trailing)
        }
        .padding(.leading, 6 + CGFloat(row.depth) * 14)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background {
            if hovering, node.isDirectory { Capsule().fill(Color.honeySurface2.opacity(0.7)) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if node.isDirectory { toggle(NSEvent.modifierFlags.contains(.option)) } }
        .onHover { hovering = $0 }
        .help(node.path)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.isDirectory ? "\(node.name), folder" : node.name)
        .accessibilityValue(spoken)
        .accessibilityAddTraits(node.isDirectory ? .isButton : [])
        .accessibilityAction { if node.isDirectory { toggle(false) } }
    }

    private var spoken: String {
        let node = row.node
        let size = ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)
        var parts = node.isDirectory ? [expanded ? "open" : "closed", MediaText.files(node.fileCount), size] : [size]
        if row.depth > 0 { parts.append("level \(row.depth + 1)") }
        return parts.joined(separator: ", ")
    }
}
