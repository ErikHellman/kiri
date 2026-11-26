import AppKit
import KiriKit

/// A video or a sound (`MediaKind.video`): MPEG-4, QuickTime, MPEG and
/// whatever else AVFoundation plays, in the system's player view, as a
/// card on the paper. Space plays and pauses; it pauses when its tab is
/// put away.
///
/// The player is AVKit's, and AVKit is never loaded at launch: it lives in
/// `KiriVideo.framework` (App/KiriVideo), which the app embeds but doesn't
/// link, and loads the first time a video opens (`VideoPlugin`).
@MainActor final class VideoViewer: MediaContent {
    private let root: ViewerContainer
    private let card: NSView
    private var player: NSView?
    private var url: URL?
    var onDetails: (([String]) -> Void)?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        self.card = card
        root = ViewerContainer(content: card)
        // A card on the paper, clear of the status bar.
        root.insets = NSEdgeInsets(top: 14, left: 14, bottom: 54, right: 14)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var view: NSView { root }
    var keyView: NSView { player.flatMap { $0.value(forKey: "keyView") as? NSView } ?? root }

    func load(_ url: URL) {
        self.url = url
        guard let player = player ?? makePlayer() else {
            failed("Kiri’s video player is missing from the app. Installing Kiri again puts it back.")
            return
        }
        root.show(message: nil)
        player.perform(NSSelectorFromString("openURL:"), with: url as NSURL)
    }

    private func makePlayer() -> NSView? {
        guard let type = VideoPlugin.viewClass else { return nil }
        let view = type.init(frame: card.bounds)
        view.autoresizingMask = [.width, .height]
        card.addSubview(view)
        player = view
        observer = NotificationCenter.default.addObserver(forName: VideoPlugin.infoNotification, object: view, queue: .main) {
            [weak self] note in
            let info = note.userInfo ?? [:]
            let playable = info["playable"] as? Bool ?? false
            let width = info["width"] as? Double ?? 0, height = info["height"] as? Double ?? 0
            let duration = info["duration"] as? Double
            let hasVideo = info["hasVideo"] as? Bool ?? false
            MainActor.assumeIsolated {
                self?.received(playable: playable, size: hasVideo ? (Int(width.rounded()), Int(height.rounded())) : nil,
                               duration: duration)
            }
        }
        return view
    }

    private func received(playable: Bool, size: (Int, Int)?, duration: Double?) {
        guard playable else {
            let name = url?.pathExtension.uppercased() ?? ""
            failed("macOS doesn’t play this \(name.isEmpty ? "file" : name + " file"). Another app may.")
            return
        }
        var details: [String] = []
        if let size, size.0 > 0 { details.append(MediaText.dimensions(size.0, size.1)) }
        if let duration, duration > 0 { details.append(MediaText.duration(duration)) }
        onDetails?(details)
    }

    private func failed(_ why: String) {
        player?.perform(NSSelectorFromString("stopPlayback"))
        root.show(message: ViewerMessage(symbol: "film", title: "Kiri can’t play this", detail: why, url: url).hosted())
        onDetails?([])
    }

    func stop() {
        player?.perform(NSSelectorFromString("stopPlayback"))
    }

    func zoom(_ step: MediaZoom) -> Bool { false }

    #if DEBUG || KIRI_SELFTEST
    /// For the self-test: the plugin's player view, once one is made.
    var playerView: NSView? { player }
    #endif
}

/// `KiriVideo.framework`: the video player, with AVKit. The app doesn't
/// link it, so neither it nor AVKit loads at launch; the first video loads it.
@MainActor enum VideoPlugin {
    /// What the player posts when it knows what the file is (its object
    /// the player view): "playable", "hasVideo", "width", "height", "duration".
    static let infoNotification = Notification.Name("KiriVideoInfo")

    static let bundleURL: URL? = Bundle.main.privateFrameworksURL?.appendingPathComponent("KiriVideo.framework")

    /// The player view's class (`KiriVideoView`), nil if the framework
    /// isn't there or doesn't load.
    static let viewClass: NSView.Type? = {
        guard let bundleURL, let bundle = Bundle(url: bundleURL), bundle.load() else { return nil }
        return NSClassFromString("KiriVideoView") as? NSView.Type
    }()

    /// The framework has been loaded (for the self-test: not at launch).
    static var isLoaded: Bool { bundleURL.flatMap { Bundle(url: $0)?.isLoaded } ?? false }
}
