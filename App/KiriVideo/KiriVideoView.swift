import AppKit
import AVFoundation
import AVKit

// Kiri's video player: AVKit's player view, in a framework of its own that
// the app embeds but doesn't link, so AVKit is never loaded at launch. The
// app loads this the first time a video opens and talks to it by name only
// (App/Kiri/VideoViewer.swift): `openURL:` and `stopPlayback`, `keyView`,
// and the `KiriVideoInfo` notification it posts once it knows the file.
// Nothing here knows the app's own code.

@objc(KiriVideoView) public final class KiriVideoView: NSView {
    private let playerView = AVPlayerView()
    private var loading: Task<Void, Never>?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        playerView.frame = bounds
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        addSubview(playerView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// What takes the keyboard: Space plays and pauses, the arrows step.
    @objc public var keyView: NSView { playerView }

    /// Shows the movie or sound at `url`, paused at its start, and posts
    /// `KiriVideoInfo` once it knows whether it plays, its size and length.
    @objc(openURL:) public func open(_ url: NSURL) {
        loading?.cancel()
        let asset = AVURLAsset(url: url as URL)
        playerView.player?.pause()
        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        loading = Task { @MainActor [weak self] in
            var info: [String: Any] = [:]
            do {
                let (playable, duration) = try await asset.load(.isPlayable, .duration)
                info["playable"] = playable
                if duration.isNumeric { info["duration"] = duration.seconds }
                let tracks = try await asset.loadTracks(withMediaType: .video)
                info["hasVideo"] = !tracks.isEmpty
                if let track = tracks.first {
                    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                    let shown = CGRect(origin: .zero, size: size).applying(transform)
                    info["width"] = Double(abs(shown.width))
                    info["height"] = Double(abs(shown.height))
                }
            } catch {
                info["playable"] = false
                info["error"] = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            NotificationCenter.default.post(name: Notification.Name("KiriVideoInfo"), object: self, userInfo: info)
        }
    }

    /// The tab is going: it stops, and lets the file go.
    @objc public func stopPlayback() {
        loading?.cancel()
        loading = nil
        playerView.player?.pause()
        playerView.player = nil
    }

    /// Put away (another tab shows): it pauses.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { playerView.player?.pause() }
    }
}
