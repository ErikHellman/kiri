import AppKit
import KiriKit
@preconcurrency import Vaka

/// Crash reports, usage analytics and feedback, with Vaka
/// (https://vaka.hellsoft.se). All of it is anonymous: Vaka gets a random
/// id made on this Mac (never a name, an account or an email), the Mac's
/// model, macOS and Kiri versions, and, for a crash, the stack. Never a
/// file's name, path or text: the events below say what kind of thing
/// happened, not to what. What is collected, and how to turn it off, is on
/// the website (site/privacy.html) and in Settings ▸ Privacy.
///
/// Crash reports and analytics have a switch each (`Prefs`), both on until
/// turned off. Feedback is sent only when the person sends it, so it
/// works with both off.
///
/// The SDK can't be stopped once started. A switch turned off stops
/// everything Kiri sends of that kind at once and drops what was waiting
/// to go out; the SDK's own handlers (crash and hang reports, sessions)
/// stay until Kiri quits, and the next launch drops what they wrote.
enum Telemetry {
    /// The Vaka project's ingest key: write-only, made to be shipped in an app.
    static let ingestKey = "vk_be95d83d8fd244a69f26743ff3882b06"
    static let endpoint = URL(string: "https://vaka.fly.dev")!
    /// What is collected and how to turn it off, in words.
    static let privacyPage = URL(string: "https://kiri.hellsoft.se/privacy.html")!

    private(set) static var started = false
    /// What the SDK was started with: what it does by itself this run
    /// (crash and hang handlers, sessions).
    private static var startedWith: (crashes: Bool, analytics: Bool) = (false, false)

    static var crashReportsOn: Bool { UserDefaults.standard.object(forKey: Prefs.crashReportsKey) as? Bool ?? true }
    static var analyticsOn: Bool { UserDefaults.standard.object(forKey: Prefs.analyticsKey) as? Bool ?? true }

    /// Whether this launch may send anything at all: never a test launch
    /// (`-Kiri…` arguments: the self-tests, screenshots, launch timing).
    static let allowed = !ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Kiri") }

    /// Where the SDK keeps its queue, crash report and scope: Kiri's own
    /// folder, as the SDK's default (Application Support/Vaka) is shared
    /// by every app that uses Vaka outside a sandbox.
    static let storage: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "se.hellsoft.kiri", isDirectory: true)
            .appendingPathComponent("Vaka", isDirectory: true)
    }()

    // MARK: Starting

    /// At launch, before anything else can crash: the SDK with what the
    /// switches allow. With both off it isn't started at all (until
    /// feedback is sent, or a switch is turned on).
    static func start() {
        guard allowed else { return }
        purge(crashes: !crashReportsOn, analytics: !analyticsOn)
        guard crashReportsOn || analyticsOn else { return }
        startSDK()
    }

    private static func startSDK() {
        guard !started, allowed else { return }
        let crashes = crashReportsOn, analytics = analyticsOn
        started = true
        startedWith = (crashes, analytics)
        Vaka.start(Vaka.Options(
            key: ingestKey,
            endpoint: endpoint,
            environment: {
                #if DEBUG
                "debug"
                #else
                "production"
                #endif
            }(),
            crashReporting: crashes,
            sessionTracking: analytics,
            appHangDetection: crashes,
            storageDirectory: storage
        ))
        if crashes { askAfterCrash() }
        if analytics { launched() }
    }

    /// A switch in Settings changed. On: sending starts now (the SDK's own
    /// handlers come with the next launch if it was already running
    /// without them). Off: nothing more of that kind is sent from Kiri,
    /// and what was waiting to go out is dropped.
    static func switchesChanged() {
        guard allowed else { return }
        purge(crashes: !crashReportsOn, analytics: !analyticsOn)
        if crashReportsOn || analyticsOn { startSDK() }
        Vaka.flush()
    }

    // MARK: Analytics

    /// A screen (a window that isn't a document's) came up.
    static func screen(_ name: String) {
        guard analyticsOn, started else { return }
        Vaka.screen(name)
    }

    /// Something was done. `props` say what kind of thing, never which
    /// file or what text: a language's id, a count, a setting.
    static func track(_ name: String, _ props: [String: Any] = [:]) {
        guard analyticsOn, started else { return }
        Vaka.track(name, props)
    }

    /// Once a launch: the settings people actually use.
    private static func launched() {
        let d = UserDefaults.standard
        track("launch", [
            "color_theme": d.string(forKey: Prefs.colorThemeKey) ?? Honey.Theme.honey.id,
            "appearance": d.string(forKey: Prefs.themeKey) ?? "system",
            "motion": d.string(forKey: Prefs.motionKey) ?? "system",
            "wrap_lines": d.object(forKey: Prefs.wrapLinesKey) as? Bool ?? true,
            "typing_animations": d.object(forKey: Prefs.typingAnimationsKey) as? Bool ?? true,
            "custom_font": !(d.string(forKey: Prefs.editorFontKey) ?? "").isEmpty,
            "text_scale": d.object(forKey: Prefs.textScaleKey) as? Double ?? 1,
        ])
    }

    /// A file opened: its language and roughly how big it is.
    static func fileOpened(language: Language, bytes: Int) {
        let size = switch bytes {
        case ..<10_000: "<10 KB"
        case ..<100_000: "10-100 KB"
        case ..<1_000_000: "100 KB-1 MB"
        case ..<10_000_000: "1-10 MB"
        default: ">10 MB"
        }
        track("file_open", ["language": language.id, "size": size])
    }

    // MARK: Crash reports

    /// After a crash, the next launch asks what happened, in Kiri's own
    /// feedback window. (Not after a hang: those can be many.)
    private static func askAfterCrash() {
        Vaka.onCrashOrHang { report in
            guard report.kind == .crash, report.previousRun else { return }
            MainActor.assumeIsolated {
                // Once a document window is up, so the question has a place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    FeedbackWindow.show(.afterCrash(eventId: report.eventId))
                }
            }
        }
    }

    // MARK: Feedback

    enum FeedbackOutcome { case sent, queued, failed(String) }

    /// Sends what the person wrote, and the screenshot if they kept it.
    static func sendFeedback(_ message: String, screenshot: Vaka.Attachment?, eventId: String?,
                             done: @escaping @MainActor (FeedbackOutcome) -> Void) {
        guard allowed else { done(.failed("Feedback is off in test launches.")); return }
        // Feedback needs the SDK, even with both switches off: started
        // then with nothing of its own (no handlers, no sessions).
        startSDK()
        let feedback = Vaka.Feedback(message: message, eventId: eventId,
                                     source: eventId == nil ? .widget : .crashPrompt,
                                     attachments: screenshot.map { [$0] } ?? [])
        Vaka.captureFeedback(feedback) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let r): done(r.queued ? .queued : .sent)
                case .failure(let error):
                    if case .rateLimited = error {
                        done(.failed("That's a lot of feedback for one hour. Please try again later."))
                    } else {
                        done(.failed("Kiri couldn't send it. Please try again in a moment."))
                    }
                }
            }
        }
    }

    // MARK: Dropping what a switch turned off

    /// Removes what the SDK keeps on disk of a kind that is switched off:
    /// the last run's crash report and session, and queued batches' items
    /// of that kind, so none of it goes out. (The files are the SDK's:
    /// JSON batches of `{"items": [{"type": …}]}` in `pending/`, the crash
    /// report in `crash.txt`, the last run's state in `scope.json`.)
    private static func purge(crashes: Bool, analytics: Bool) {
        guard crashes || analytics else { return }
        let fm = FileManager.default
        if crashes { try? fm.removeItem(at: storage.appendingPathComponent("crash.txt")) }

        let scopeURL = storage.appendingPathComponent("scope.json")
        if let data = try? Data(contentsOf: scopeURL),
           var scope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if crashes { scope["hang_since"] = nil; scope["hang_event_id"] = nil; scope["breadcrumbs"] = [] }
            if analytics { scope["session"] = nil }
            if let out = try? JSONSerialization.data(withJSONObject: scope) { try? out.write(to: scopeURL, options: .atomic) }
        }

        let dropped: Set<String> = Set((crashes ? ["error"] : []) + (analytics ? ["event", "session"] : []))
        let pending = storage.appendingPathComponent("pending", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var batch = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = batch["items"] as? [[String: Any]] else { continue }
            let kept = items.filter { !dropped.contains($0["type"] as? String ?? "") }
            if kept.count == items.count { continue }
            if kept.isEmpty {
                try? fm.removeItem(at: file)
            } else {
                batch["items"] = kept
                if let out = try? JSONSerialization.data(withJSONObject: batch) { try? out.write(to: file, options: .atomic) }
            }
        }
    }
}
