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
@MainActor enum FeedbackWindow {
    enum Mode: Equatable {
        case general
        /// The last run crashed: the crash's report, to link the words to.
        case afterCrash(eventId: String)
    }

    static let windowID = "feedback"
    private static var window: NSWindow?
    private static var model: FeedbackModel?

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

    @MainActor static func ofFrontDocumentWindow() -> WindowShot? {
        let window: DocumentNSWindow? = (NSApp.keyWindow as? DocumentNSWindow)
            ?? FrontEditor.shared.tabs?.window
            ?? NSApp.orderedWindows.lazy.compactMap { $0 as? DocumentNSWindow }.first { $0.isVisible }
        guard let window, window.isVisible, !window.isMiniaturized else { return nil }
        return of(window)
    }

    /// The window's frame view (its title bar band and tabs too), drawn
    /// by the app itself: no screen recording permission, and nothing of
    /// other apps' windows.
    @MainActor static func of(_ window: NSWindow) -> WindowShot? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              let attachment = Vaka.Attachment.image(png, maxPixels: 2400),
              let preview = NSImage(data: attachment.data) else { return nil }
        return WindowShot(attachment: attachment, preview: preview)
    }
}

@MainActor @Observable final class FeedbackModel {
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
        .padding(.top, 38) // clear of the traffic lights
        .padding([.horizontal, .bottom], 22)
        .frame(width: Self.width)
        .honeyCanvas()
        .ignoresSafeArea(.container, edges: .top)
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
            Image(nsImage: shot.preview)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 132, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
                    .strokeBorder(Color.honeyLine, lineWidth: 1))
                .opacity(model.includeScreenshot ? 1 : 0.45)
                .onTapGesture { ScreenshotPreview.show(shot.preview) }
                .help("Click to see it larger")
                .accessibilityLabel("Screenshot of the Kiri window")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { ScreenshotPreview.show(shot.preview) }
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
@MainActor enum ScreenshotPreview {
    private static var window: NSWindow?

    static func show(_ image: NSImage) {
        window?.close()
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        var size = image.size
        let fit = min(1, screen.width * 0.8 / size.width, screen.height * 0.8 / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Screenshot"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
