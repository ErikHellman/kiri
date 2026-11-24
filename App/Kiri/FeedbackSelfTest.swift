#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit
import SwiftUI

extension SelfTest {
    private static var shownFeedback = false

    /// Debug flags of the feedback window (`FeedbackWindow`), read when an
    /// editor comes up. A test launch never sends anything (`Telemetry.allowed`).
    ///
    /// - `-KiriShowFeedback general|crash`: the window, for a picture of it;
    ///   with `-KiriFeedbackText <text>` typed in, `-KiriFeedbackScreenshotOn YES`
    ///   the screenshot switched on, `-KiriFeedbackPreview YES` the screenshot's
    ///   larger preview open, `-KiriFeedbackThanks YES` in its "Thank you" state,
    ///   and `-KiriFeedbackShot <path>` writing the screenshot as Vaka would get it.
    /// - `-KiriFeedbackTest YES`: `feedbackStage` alone.
    static func feedbackFlags(_ textView: NSTextView) -> Bool {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "KiriShowFeedback"), !shownFeedback {
            shownFeedback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                FeedbackWindow.show(mode == "crash" ? .afterCrash(eventId: "selftest") : .general)
                guard let model = FeedbackWindow.model else { report(false, "the feedback window opens"); return }
                if let text = defaults.string(forKey: "KiriFeedbackText") { model.message = text }
                if defaults.bool(forKey: "KiriFeedbackScreenshotOn") { model.includeScreenshot = true }
                if defaults.bool(forKey: "KiriFeedbackThanks") { model.state = .sent(queued: false) }
                if let path = defaults.string(forKey: "KiriFeedbackShot"), let shot = model.screenshot {
                    try? shot.attachment.data.write(to: URL(fileURLWithPath: path))
                    print("SELFTEST info screenshot \(shot.attachment.contentType) \(shot.attachment.data.count) bytes, \(Int(shot.preview.size.width))×\(Int(shot.preview.size.height)) → \(path)")
                    fflush(stdout)
                }
                if defaults.bool(forKey: "KiriFeedbackPreview"), let shot = model.screenshot {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ScreenshotPreview.show(shot.preview) }
                }
            }
            return true
        }
        if defaults.bool(forKey: "KiriFeedbackTest"), !shownFeedback {
            shownFeedback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = textView.window else { report(false, "a window for the feedback checks"); quit(); return }
                FrontEditor.shared.selfTestMain(window)
                Task { @MainActor in
                    await feedbackStage()
                    reportStayedInTheBackground()
                    print("SELFTEST DONE feedback")
                    fflush(stdout)
                    quit()
                }
            }
            return true
        }
        return false
    }

    /// Help ▸ Send Feedback…: the window, its screenshot of the document
    /// window (drawn, not blank), the switch off until turned on, Send off
    /// with nothing written, ⌘Return sending, a click on the picture
    /// opening it larger, Escape and Cancel closing the window.
    static func feedbackStage() async {
        func wait(_ seconds: Double = 2, until done: () -> Bool) async -> Bool {
            for _ in 0..<Int(seconds * 40) {
                if done() { return true }
                await settle(25)
            }
            return done()
        }
        func feedbackWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == FeedbackWindow.windowID && $0.isVisible }
        }
        func previewWindow() -> NSWindow? { NSApp.windows.first { $0.title == "Screenshot" && $0.isVisible } }

        // From the Help menu, as a person would.
        guard let main = NSApp.mainMenu, let help = main.items.last?.submenu else { report(false, "a Help menu"); return }
        updateMenu(main)
        guard let i = help.items.firstIndex(where: { $0.title == "Send Feedback…" }) else {
            report(false, "Help ▸ Send Feedback… exists (\(help.items.map(\.title)))"); return
        }
        help.performActionForItem(at: i)
        guard await wait(until: { feedbackWindow() != nil }), let window = feedbackWindow(), let model = FeedbackWindow.model else {
            report(false, "Help ▸ Send Feedback… opens the feedback window"); return
        }
        report(true, "Help ▸ Send Feedback… opens the feedback window")
        await settle(300)

        // The picture: of the document window, with something drawn in it.
        if let shot = model.screenshot {
            let (spread, dark) = tones(of: shot.preview)
            report(spread > 0.04 && dark < 0.5,
                   "the screenshot shows the document window, not a blank or black picture (\(Int(shot.preview.size.width))×\(Int(shot.preview.size.height)), tones spread \(String(format: "%.3f", spread)), \(Int(dark * 100))% near black)")
        } else {
            report(false, "the feedback window has a screenshot of the document window")
        }
        report(!model.includeScreenshot, "the screenshot is off until switched on")

        // The window holds its content: no band of window background under it.
        if let content = window.contentView {
            let fitting = content.fittingSize.height
            report(abs(fitting - content.frame.height) < 1.5,
                   "the window is as tall as its content (\(Int(content.frame.height)) pt, the content \(Int(fitting)) pt)")
        }

        // ⌘Return: nothing with nothing written; sends once there is. As
        // AppKit hands a key equivalent to the key window (a test launch in
        // the background has none, so a posted key never gets there).
        func commandReturn() async {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                        isARepeat: false, keyCode: 36) {
                _ = window.performKeyEquivalent(with: e)
            }
            await settle(150)
        }
        await commandReturn()
        report(model.state == .writing, "⌘Return does nothing with nothing written (\(model.state))")
        model.message = "A note from the self-test"
        // (Once SwiftUI has turned Send on: under load that takes a moment.)
        await settle(500)
        // A test launch never sends: it says so, which shows the key sent it.
        func tried() -> Bool { if case .failed = model.state { return true } else { return false } }
        await commandReturn()
        let sent = await wait { tried() }
        report(sent, "⌘Return sends what is written (\(model.state))")
        model.state = .writing

        // A click on the picture: the larger preview.
        await wakeAccessibility()
        if let thumb = accessibilityElements(of: window).first(where: { $0.name == "Screenshot of the Kiri window" }) {
            let onScreen = NSPoint(x: thumb.frame.midX, y: thumb.frame.midY)
            let point = window.convertPoint(fromScreen: onScreen)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            let opened = await wait { previewWindow() != nil }
            let preview = previewWindow()
            report(opened && (preview?.frame.width ?? 0) > 400,
                   "a click on the screenshot opens it larger (\(preview.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "no window"))")
            preview?.close()
        } else {
            report(false, "the screenshot is an element VoiceOver can press")
        }

        // Escape closes the window; so does Cancel.
        await typeKeys("\u{1b}", in: window, anywhere: true)
        report(await wait { feedbackWindow() == nil }, "Escape closes the feedback window")
        FeedbackWindow.show()
        if await wait(until: { feedbackWindow() != nil }), let again = feedbackWindow() {
            report(FeedbackWindow.model?.message.isEmpty == true, "opened again, the window starts empty")
            await wakeAccessibility()
            accessibilityElements(of: again).first { $0.name == "Cancel" }?.press()
            report(await wait { feedbackWindow() == nil }, "Cancel closes the feedback window")
        } else {
            report(false, "the feedback window opens again")
        }
    }

    /// How far apart the picture's tones are (their standard deviation,
    /// 0 for one flat color) and how much of it is near black.
    private static func tones(of image: NSImage) -> (spread: Double, dark: Double) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide > 0 else { return (0, 1) }
        var values: [Double] = []
        let steps = 48
        for yi in 0..<steps {
            for xi in 0..<steps {
                let x = rep.pixelsWide * xi / steps, y = rep.pixelsHigh * yi / steps
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                values.append(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
        }
        guard !values.isEmpty else { return (0, 1) }
        let mean = values.reduce(0, +) / Double(values.count)
        let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        return (spread, Double(values.filter { $0 < 0.06 }.count) / Double(values.count))
    }
}
#endif
