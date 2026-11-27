import AppKit
import ImageIO
import KiriKit

/// A picture (`MediaKind.image`): JPEG, PNG, GIF, WebP, HEIC, TIFF and
/// whatever else ImageIO reads, on the paper. It opens at its own size,
/// or smaller to fit the panel, and zooms with a pinch, ⌘+ and ⌘− (⌘0
/// is the actual size; a double-click fits it again). An animated GIF,
/// PNG or WebP plays (`CGAnimateImageAtURLWithBlock`), while its tab shows.
///
/// The file is read off the main thread; EXIF orientation is applied, and
/// a picture's size is its pixels at its own resolution (a 144 dpi
/// screenshot shows pixel for pixel on a Retina display).
final class ImageViewer: MediaContent {
    private let scroll: NSScrollView
    private let canvas: ImageCanvas
    private let root: ViewerContainer
    var onDetails: (([String]) -> Void)?

    private var url: URL?
    private var generation = 0
    /// The picture's size in points.
    private var size = CGSize.zero
    private var pixels = (width: 0, height: 0)
    private var frames = 1
    private var animates = false
    private var animation: Token?
    /// Fitted to the panel (as it opens, and after a double-click): it
    /// fits again as the panel changes size.
    private var fitted = true
    /// Fitted, but the panel hasn't been laid out yet: the zoom isn't known.
    private var awaitingRoom = false

    #if DEBUG || KIRI_SELFTEST
    /// Frames drawn by the animation, for the self-test.
    private(set) var framesShown = 0
    var magnification: CGFloat { scroll.magnification }
    #endif

    init() {
        let scroll = NSScrollView()
        let canvas = ImageCanvas()
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 64
        scroll.documentView = canvas
        scroll.postsFrameChangedNotifications = true
        self.scroll = scroll
        self.canvas = canvas
        root = ViewerContainer(content: scroll)
        canvas.owner = self
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.image)
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fitted = false
                self?.awaitingRoom = false
                self?.zoomChanged()
            }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.panelResized() }
        }
    }

    var view: NSView { root }
    var keyView: NSView { canvas }

    // MARK: Reading

    func load(_ url: URL) {
        self.url = url
        generation += 1
        let generation = generation
        stopAnimation()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoded = DecodedImage(url: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.show(decoded)
                }
            }
        }
    }

    private func show(_ decoded: DecodedImage) {
        guard let image = decoded.image else {
            root.show(message: ViewerMessage(symbol: "photo.badge.exclamationmark", title: "Kiri can’t show this picture",
                                             detail: "Its file can’t be read as an image. It may be damaged, or in a format macOS doesn’t read.",
                                             url: url).hosted())
            onDetails?([])
            return
        }
        root.show(message: nil)
        let wasFitted = fitted || size == .zero
        let sameSize = size == decoded.size
        size = decoded.size
        pixels = decoded.pixels
        frames = decoded.frames
        animates = decoded.animates
        canvas.image = image
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.setAccessibilityLabel("Picture, \(MediaText.dimensions(pixels.width, pixels.height)) pixels")
        // The same picture again (it changed on disk): it stays where it was.
        if wasFitted || !sameSize { fit() }
        if animates, canvas.window != nil { startAnimation() }
        zoomChanged()
    }

    // MARK: Animation

    /// An animated picture plays while it is in a window.
    fileprivate func canvasMovedToWindow() {
        if canvas.window == nil {
            stopAnimation()
        } else if animates, animation == nil {
            startAnimation()
        }
    }

    private func startAnimation() {
        guard let url else { return }
        stopAnimation()
        let token = Token()
        animation = token
        // (ImageIO calls the block on the main queue.)
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, image, stop in
            if token.isCancelled {
                stop.pointee = true
                return
            }
            MainActor.assumeIsolated {
                guard let self, !token.isCancelled else { return }
                self.canvas.image = image
                #if DEBUG || KIRI_SELFTEST
                self.framesShown += 1
                #endif
            }
        }
        if status != noErr { animation = nil }
    }

    private func stopAnimation() {
        animation?.cancel()
        animation = nil
    }

    func stop() {
        generation += 1
        stopAnimation()
    }

    // MARK: Zoom

    /// Room kept around a fitted picture, and above the status bar.
    private static let margin: CGFloat = 20
    private static let statusRoom: CGFloat = 48

    /// The picture at its own size, or smaller to fit the panel.
    private func fit() {
        fitted = true
        guard size.width > 0, size.height > 0 else { return }
        let room = scroll.bounds.size
        // A tab that isn't laid out yet has no room: it fits when it gets
        // some (`panelResized`), instead of at the smallest zoom first.
        awaitingRoom = room.width <= 2 * Self.margin || room.height <= 2 * Self.statusRoom
        if awaitingRoom {
            zoomChanged()
            return
        }
        let scale = min(1, (room.width - 2 * Self.margin) / size.width, (room.height - 2 * Self.statusRoom) / size.height)
        scroll.magnification = max(scroll.minMagnification, scale)
        zoomChanged()
    }

    private func panelResized() {
        if fitted { fit() }
    }

    func zoom(_ step: MediaZoom) -> Bool {
        guard size != .zero else { return true }
        let now = scroll.magnification
        let to: CGFloat
        switch step {
        case .bigger: to = Self.steps.first { $0 > now * 1.01 } ?? scroll.maxMagnification
        case .smaller: to = Self.steps.last { $0 < now / 1.01 } ?? scroll.minMagnification
        case .actualSize:
            // At the actual size already: back to fitting.
            if abs(now - 1) < 0.001 {
                fit()
                return true
            }
            to = 1
        }
        fitted = false
        awaitingRoom = false
        let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(to, centeredAt: center)
        zoomChanged()
        return true
    }

    private static let steps: [CGFloat] = [0.02, 0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]

    /// A double-click: fit, or the actual size if it fits already.
    fileprivate func toggleFit() {
        if fitted, abs(scroll.magnification - 1) > 0.001 {
            _ = zoom(.actualSize)
        } else {
            fit()
        }
    }

    private func zoomChanged() {
        // Pixels show as pixels when they are large.
        canvas.layer?.magnificationFilter = scroll.magnification * (window?.backingScaleFactor ?? 2) >= 4 ? .nearest : .linear
        var details: [String] = []
        if pixels.width > 0 { details.append(MediaText.dimensions(pixels.width, pixels.height)) }
        if frames > 1 { details.append(animates ? "\(frames) frames" : "\(frames) images") }
        if size != .zero, !awaitingRoom { details.append("\(Int((scroll.magnification * 100).rounded()))%") }
        onDetails?(details)
    }

    private var window: NSWindow? { scroll.window }

    /// Says whether an animation is still wanted.
    nonisolated private final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}

/// A picture read from its file, off the main thread.
nonisolated private struct DecodedImage: @unchecked Sendable {
    var image: CGImage?
    var pixels = (width: 0, height: 0)
    var size = CGSize.zero
    var frames = 1
    var animates = false

    /// The most pixels across that are kept (a larger picture is scaled down to this).
    static let largest = 16_384

    /// Formats whose frames are an animation, not pages or sizes.
    static let animatedTypes: Set<String> = ["com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics",
                                             "public.avis"]

    init(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return }
        let type = CGImageSourceGetType(source) as String? ?? ""
        frames = count
        animates = count > 1 && Self.animatedTypes.contains(type)
        func properties(_ index: Int) -> [CFString: Any] {
            CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        }
        // An icon or a TIFF of several images: the largest.
        var index = 0
        if count > 1, !animates {
            index = (0..<count).max { (properties($0)[kCGImagePropertyPixelWidth] as? Int ?? 0)
                < (properties($1)[kCGImagePropertyPixelWidth] as? Int ?? 0) } ?? 0
        }
        let p = properties(index)
        let width = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = p[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(max(width, height), Self.largest)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // (Without a size to go by, the image as it is.)
        let thumbnail = width > 0 && height > 0 ? CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) : nil
        image = thumbnail ?? CGImageSourceCreateImageAtIndex(source, index, nil)
        guard let image else { return }
        // Turned as the camera says (orientations 5 to 8 are a quarter turn).
        let turned = orientation >= 5 && orientation <= 8
        pixels = width > 0 && height > 0 ? (turned ? (height, width) : (width, height)) : (image.width, image.height)
        let dpi = (p[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 >= 36 && $0 <= 1200 ? $0 : nil } ?? 72
        size = CGSize(width: CGFloat(pixels.width) * 72 / dpi, height: CGFloat(pixels.height) * 72 / dpi)
    }
}

/// The picture itself: a layer with the image as its contents, scaled to
/// the view's size (the scroll view's magnification zooms it).
private final class ImageCanvas: NSView {
    weak var owner: ImageViewer?

    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not made from a nib") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = image }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.canvasMovedToWindow()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { owner?.toggleFit() } else { super.mouseDown(with: event) }
    }

    // The arrows and the page keys scroll it.
    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) { scroll(by: NSPoint(x: 0, y: -40)) }
    override func moveDown(_ sender: Any?) { scroll(by: NSPoint(x: 0, y: 40)) }
    override func moveLeft(_ sender: Any?) { scroll(by: NSPoint(x: -40, y: 0)) }
    override func moveRight(_ sender: Any?) { scroll(by: NSPoint(x: 40, y: 0)) }
    override func scrollPageUp(_ sender: Any?) { scroll(by: NSPoint(x: 0, y: -visibleRect.height * 0.9)) }
    override func scrollPageDown(_ sender: Any?) { scroll(by: NSPoint(x: 0, y: visibleRect.height * 0.9)) }
    override func pageUp(_ sender: Any?) { scrollPageUp(sender) }
    override func pageDown(_ sender: Any?) { scrollPageDown(sender) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(NSPoint(x: visibleRect.minX, y: 0)) }
    override func scrollToEndOfDocument(_ sender: Any?) { scroll(NSPoint(x: visibleRect.minX, y: bounds.height)) }
    override func doCommand(by selector: Selector) {
        // Anything else (a letter) does nothing, without a beep.
        if responds(to: selector) { super.doCommand(by: selector) }
    }

    private func scroll(by delta: NSPoint) {
        scroll(NSPoint(x: visibleRect.minX + delta.x, y: visibleRect.minY + delta.y))
    }
}

/// Keeps a document view smaller than the scroll view in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
