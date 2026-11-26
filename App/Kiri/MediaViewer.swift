import AppKit
import KiriKit
import SwiftUI

/// A file Kiri shows instead of editing it (`KiriDocument.media`): what it
/// is, where, and how large.
struct MediaFile: Equatable {
    let url: URL
    let kind: MediaKind
    let size: Int
}

/// What the status bar says about a file in a viewer: "PNG · 1920 × 1080 · 2.4 MB".
struct MediaStatus: Equatable {
    var symbol: String
    var text: String
    var help: String
}

/// ⌘+, ⌘− and ⌘0 (View ▸ Bigger Text, Smaller Text, Actual Size), which
/// zoom a picture instead of the text.
enum MediaZoom { case bigger, smaller, actualSize }

/// One kind of viewer: a picture (`ImageViewer`), a video (`VideoViewer`),
/// an archive's contents (`ArchiveViewer`).
@MainActor protocol MediaContent: AnyObject {
    /// What goes in the editor's place.
    var view: NSView { get }
    /// What takes the keyboard (to scroll, or play and pause).
    var keyView: NSView { get }
    /// Called with what the status bar adds about the file, as it is
    /// learned ("1920 × 1080", "36 frames").
    var onDetails: (([String]) -> Void)? { get set }
    /// Shows the file at `url`: when it opens, and again when it changes on disk.
    func load(_ url: URL)
    /// The tab is going, or shows another file.
    func stop()
    /// False when it doesn't zoom (the text size changes instead).
    func zoom(_ step: MediaZoom) -> Bool
}

/// The read-only viewer of one tab's picture, video or archive, in the
/// editor's place (`TabEditorSlot`), as `LargeFileViewer` is for a large
/// text file. Made when the tab shows such a file, never at launch: the
/// video player and its frameworks load only when a video opens
/// (`VideoPlugin`).
@MainActor final class MediaViewer {
    let view: ViewerContainer
    let kind: MediaKind
    private(set) weak var document: KiriDocument?
    private weak var model: EditorModel?
    private let content: MediaContent
    private var file: MediaFile
    private var details: [String] = []

    init(document: KiriDocument, media: MediaFile, model: EditorModel) {
        self.document = document
        self.model = model
        file = media
        kind = media.kind
        switch media.kind {
        case .image: content = ImageViewer()
        case .video: content = VideoViewer()
        case .archive(let format): content = ArchiveViewer(format: format)
        }
        view = ViewerContainer(content: content.view)
        content.onDetails = { [weak self] details in
            self?.details = details
            self?.publish()
        }
        model.media = self
        document.mediaViewer = self
        publish()
        content.load(media.url)
    }

    var keyView: NSView { content.keyView }

    /// The file changed on disk (or was renamed): it shows again.
    func reload(_ new: MediaFile) {
        file = new
        publish()
        content.load(new.url)
    }

    func stop() {
        content.stop()
        if model?.media === self {
            model?.media = nil
            model?.mediaStatus = nil
        }
        if document?.mediaViewer === self { document?.mediaViewer = nil }
    }

    func zoom(_ step: MediaZoom) -> Bool { content.zoom(step) }

    #if DEBUG || KIRI_SELFTEST
    /// For the self-test.
    var contentForTests: MediaContent { content }
    #endif

    private func publish() {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        let text = ([kind.name] + details + [size]).joined(separator: " · ")
        let status = MediaStatus(symbol: symbol, text: text, help: help)
        if model?.mediaStatus != status { model?.mediaStatus = status }
    }

    private var symbol: String {
        switch kind {
        case .image: FileIcon.image.symbol
        case .video: FileIcon.video.symbol
        case .archive: FileIcon.archive.symbol
        }
    }

    private var help: String {
        switch kind {
        case .image: "Read-only. Zoom with ⌘+ and ⌘−, ⌘0 for the actual size; double-click to fit."
        case .video: "Read-only. Space plays and pauses."
        case .archive: "Read-only: what the archive holds, with each file’s size unpacked."
        }
    }
}

/// Where a viewer sits in the editor's place: its content, inset (a video
/// is a card on the paper, clear of the status bar), a message over it
/// when the file can't be shown, and files dropped on it opening as they
/// do anywhere on the window.
final class ViewerContainer: NSView {
    let content: NSView
    /// Around `content`; a corner radius rounds it.
    var insets = NSEdgeInsets() { didSet { needsLayout = true } }
    private var message: NSView?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        registerForDraggedTypes(FileDrop.types)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        content.frame = NSRect(x: insets.left, y: insets.top, width: max(0, bounds.width - insets.left - insets.right),
                               height: max(0, bounds.height - insets.top - insets.bottom))
        message?.frame = bounds
    }

    /// Shows `view` over the content (nil takes it away), and hides the content under it.
    func show(message view: NSView?) {
        message?.removeFromSuperview()
        message = view
        content.isHidden = view != nil
        if let view {
            view.frame = bounds
            addSubview(view)
        }
    }

    // Files dropped on a picture, a video or an archive open, as anywhere else on the window.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { FileDrop.operation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { FileDrop.operation(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !FileDrop.operation(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let window else { return false }
        return FileDrop.perform(sender, in: window)
    }
}

/// What a viewer says when it can't show its file: what went wrong in a
/// line or two on the paper, and a way to open the file elsewhere.
struct ViewerMessage: View {
    let symbol: String
    let title: String
    let detail: String
    /// Offers "Open in <app>" for this file.
    var url: URL?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.honeyMuted)
                .accessibilityHidden(true)
            Text(title).font(.honey(.title3, weight: .heavy)).multilineTextAlignment(.center)
            Text(detail).font(.honey(.body)).foregroundStyle(Color.honeyMuted).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let url, let app = NSWorkspace.shared.urlForApplication(toOpen: url),
               app.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
                Button("Open in \(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))") {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
                .buttonStyle(.honeyGlass)
                .padding(.top, 6)
            }
        }
        .padding(24)
        .padding(.bottom, 40) // clear of the status bar
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// As a view for a `ViewerContainer`.
    func hosted() -> NSView {
        let host = NSHostingView(rootView: self)
        host.sizingOptions = []
        return host
    }
}

// MARK: The tab's side

extension DocumentTab {
    /// The tab shows a picture, a video or an archive (read-only), not text.
    var showsMedia: Bool { mediaViewer != nil }
}

extension Telemetry {
    /// A picture, video or archive opened in a viewer: which kind, and its format.
    static func mediaOpened(_ kind: MediaKind, bytes: Int) {
        track("viewer_open", ["kind": kind.family, "format": kind.name])
        fileOpened(language: .plainText, bytes: bytes)
    }
}
