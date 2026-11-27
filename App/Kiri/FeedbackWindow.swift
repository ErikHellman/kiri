import AppKit
import KiriKit
import SwiftUI
@preconcurrency import Vaka

/// Help ▸ Send Feedback…: a few words to Kiri's maker, and, if the person
/// wants, a screenshot of the Kiri window they were in. Sent anonymously
/// through Vaka (`Telemetry.sendFeedback`): no name or email is asked for.
///
/// The next launch after a crash opens it too, asking what happened
/// (with crash reports on).
///
/// A window of its own rather than a sheet, so the document stays free to
/// look at (or copy from) while writing, with the hidden title bar every
/// Kiri window has.
enum FeedbackWindow {
    enum Mode: Equatable {
        case general
        /// The last run crashed: the crash's report, to link the words to.
        case afterCrash(eventId: String)
    }

    static let windowID = "feedback"
    private static var window: NSWindow?
    private(set) static var model: FeedbackModel?

    static func show(_ mode: Mode = .general) {
        // Open already: it comes forward with what was typed. (A crash
        // question on top of a half-written note links the note to it.)
        if let window, window.isVisible, let model {
            if case .afterCrash = mode, model.mode == .general { model.mode = mode }
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Taken before this window opens, of the document window in front.
        let model = FeedbackModel(mode: mode, screenshot: WindowShot.ofFrontDocumentWindow())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: FeedbackView.width, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let host = NSHostingController(rootView: AppearanceRoot { FeedbackView(model: model) })
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.title = "Send Feedback"
        window.identifier = NSUserInterfaceItemIdentifier(windowID)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // At its own size before centering, so it is centered as it shows.
        window.setContentSize(host.view.fittingSize)
        window.center()
        model.close = { [weak window] in window?.close() }
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
        Telemetry.screen("Feedback")
    }
}

/// A picture of a Kiri window, as Vaka will get it (a JPEG at most
/// 2400 px wide, no metadata), and the same picture to show first.
struct WindowShot {
    let attachment: Vaka.Attachment
    let preview: NSImage

    static func ofFrontDocumentWindow() -> WindowShot? {
        let window: DocumentNSWindow? = (NSApp.keyWindow as? DocumentNSWindow)
            ?? FrontEditor.shared.tabs?.window
            ?? NSApp.orderedWindows.lazy.compactMap { $0 as? DocumentNSWindow }.first { $0.isVisible }
        guard let window, window.isVisible, !window.isMiniaturized else { return nil }
        return of(window)
    }

    /// The window as it is on screen, glass, tabs and status bar too: the
    /// window server's picture of this one window of Kiri's own (no screen
    /// recording permission is needed for that, and nothing of other apps'
    /// windows is in it). Where the window server won't give one, the
    /// editor's text and line numbers, drawn by the app itself. (Drawing
    /// the whole window that way leaves it blank: SwiftUI and the glass
    /// aren't drawn through `cacheDisplay`.)
    static func of(_ window: NSWindow) -> WindowShot? {
        guard let png = windowServerPicture(of: window) ?? editorPicture(in: window),
              let attachment = Vaka.Attachment.image(png, maxPixels: 2400),
              let preview = NSImage(data: attachment.data) else { return nil }
        // In points, as the window is: the preview opens at the window's size.
        preview.size = window.frame.size
        return WindowShot(attachment: attachment, preview: preview)
    }

    /// `CGWindowListCreateImage` for the window alone. The SDK marks it
    /// obsolete (for ScreenCaptureKit, which asks for screen recording
    /// permission even for an app's own windows), so it is looked up when
    /// needed; nil if it is gone or gives nothing.
    private static func windowServerPicture(of window: NSWindow) -> Data? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard window.windowNumber > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        let includingWindow = CGWindowListOption.optionIncludingWindow.rawValue
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        guard let image = create(.null, includingWindow, UInt32(window.windowNumber), options)?.takeRetainedValue(),
              image.width > 1, image.height > 1 else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The editor (text and line numbers: AppKit views, which draw through
    /// `cacheDisplay`).
    private static func editorPicture(in window: NSWindow) -> Data? {
        func editor(in view: NSView) -> NSView? {
            if view is EditorContainerView { return view }
            for child in view.subviews { if let found = editor(in: child) { return found } }
            return nil
        }
        guard let root = window.contentView?.superview ?? window.contentView, let view = editor(in: root) else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

@Observable final class FeedbackModel {
    enum State: Equatable {
        case writing
        case sending
        case sent(queued: Bool)
        case failed(String)
    }

    var mode: FeedbackWindow.Mode
    let screenshot: WindowShot?
    var message = ""
    /// Off until asked for: the picture shows the text in the window.
    var includeScreenshot = false
    var state = State.writing
    @ObservationIgnored var close: () -> Void = {}

    init(mode: FeedbackWindow.Mode, screenshot: WindowShot?) {
        self.mode = mode
        self.screenshot = screenshot
    }

    var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .sending
    }

    func send() {
        guard canSend else { return }
        state = .sending
        var eventId: String?
        if case .afterCrash(let id) = mode { eventId = id }
        let shot = includeScreenshot ? screenshot?.attachment : nil
        Telemetry.sendFeedback(message, screenshot: shot, eventId: eventId) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .sent: self.state = .sent(queued: false)
            case .queued: self.state = .sent(queued: true)
            case .failed(let why): self.state = .failed(why)
            }
            if case .sent = self.state {
                Telemetry.track("feedback_sent", ["screenshot": shot != nil, "after_crash": eventId != nil])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.close() }
            }
        }
    }
}

/// The form: what happened (or what would be better), the screenshot
/// to attach or not, and what is sent with it.
struct FeedbackView: View {
    static let width: CGFloat = 540
    @Bindable var model: FeedbackModel
    @FocusState private var editing: Bool
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .sent(let queued) = model.state {
                thanks(queued: queued).transition(.opacity)
            } else {
                form
            }
        }
        // Below the band of the hidden title bar (the top safe area), where
        // the traffic lights are. (Drawn into it, the window kept the band's
        // height as a strip of plain window under the canvas.)
        .padding(.top, 6)
        .padding([.horizontal, .bottom], 22)
        .frame(width: Self.width)
        .honeyCanvas()
        .animation(HoneyMotion(appearance, systemReduced: reduce).quick, value: model.state)
        .onAppear { editing = true }
    }

    private var isAfterCrash: Bool {
        if case .afterCrash = model.mode { return true }
        return false
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isAfterCrash ? "Sorry, Kiri quit unexpectedly" : "Send Feedback")
                    .font(.honey(.title2, weight: .heavy))
                    .accessibilityAddTraits(.isHeader)
                Text(isAfterCrash
                     ? "What were you doing just before? A few words help find the cause."
                     : "Something not working, or an idea to make Kiri better? Every note is read.")
                    .font(.honey(.subheadline)).foregroundStyle(Color.honeyMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            messageField

            if let shot = model.screenshot { screenshotRow(shot) }

            Label {
                Text("Sent anonymously, with Kiri's version, the macOS version and the Mac's model. Nothing that says who you are.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.honey(.caption)).foregroundStyle(Color.honeyMuted)

            HStack(spacing: 10) {
                if case .failed(let why) = model.state {
                    Text(why).font(.honey(.caption, weight: .semibold)).foregroundStyle(Color.honeyDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Cancel") { model.close() }
                    .buttonStyle(.honeyGlass)
                    .keyboardShortcut(.cancelAction)
                Button { model.send() } label: {
                    if model.state == .sending {
                        ProgressView().controlSize(.small).frame(width: 44)
                    } else {
                        Text("Send")
                    }
                }
                .buttonStyle(.honeyProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
                .help("Send (⌘Return)")
            }
        }
    }

    private var messageField: some View {
        ZStack(alignment: .topLeading) {
            if model.message.isEmpty {
                Text(isAfterCrash ? "I was…" : "What happened, or what would you like to see?")
                    .font(.honey(.body)).foregroundStyle(Color.honeyMuted.opacity(0.8))
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $model.message)
                .font(.honey(.body))
                .scrollContentBackground(.hidden)
                .focused($editing)
                .accessibilityLabel("Feedback")
        }
        .padding(12)
        .frame(height: 150)
        .honeyPanel(radius: .control)
        .overlay {
            RoundedRectangle(cornerRadius: Honey.Radius.control.value, style: .continuous)
                .strokeBorder(editing ? Color.honeyFocus : Color.clear, lineWidth: 2)
        }
    }

    private func screenshotRow(_ shot: WindowShot) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attach a screenshot").font(.honey(.body, weight: .bold))
                Text("Of the Kiri window behind this one. It shows the text that is in it, so look before you send.")
                    .font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // A button, so a click lands even before the window is key.
            Button { ScreenshotPreview.show(shot.preview) } label: {
                Image(nsImage: shot.preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
                        .strokeBorder(Color.honeyLine, lineWidth: 1))
                    .frame(width: 132, height: 84)
                    .opacity(model.includeScreenshot ? 1 : 0.45)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Click to see it larger")
            .accessibilityLabel("Screenshot of the Kiri window")
            Toggle("Attach a screenshot", isOn: $model.includeScreenshot)
                .toggleStyle(.switch).labelsHidden()
        }
    }

    private func thanks(queued: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.honeyOK)
            Text("Thank you!").font(.honey(.title2, weight: .heavy))
            Text(queued ? "Kiri is offline, so it will send your note as soon as it can." : "Your note is on its way.")
                .font(.honey(.subheadline)).foregroundStyle(Color.honeyMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// The screenshot at full size, in a window of its own, to look at before
/// sending.
enum ScreenshotPreview {
    private static var window: NSWindow?

    static func show(_ image: NSImage) {
        window?.close()
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        var size = image.size
        let fit = min(1, screen.width * 0.8 / size.width, screen.height * 0.8 / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)
        // Honey like the feedback window: the canvas around the picture,
        // the hidden title bar's band above it.
        let host = NSHostingController(rootView: AppearanceRoot {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
                    .strokeBorder(Color.honeyLine, lineWidth: 1))
                .padding([.horizontal, .bottom], 16)
                .padding(.top, 4)
                .honeyCanvas()
                .accessibilityLabel("Screenshot of the Kiri window")
        })
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: size.width + 32, height: size.height + 20)),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "Screenshot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(host.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
