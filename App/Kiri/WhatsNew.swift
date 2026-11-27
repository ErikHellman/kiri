import AppKit
import KiriKit
import Observation
import SwiftUI

/// What's new: once after an update, the new version's release notes on
/// the paper of the first editor that shows, where the first-run hint
/// would be and in its look (`WhatsNewNotice`); and Help ▸ What's New in
/// Kiri, any time.
///
/// The notes are the repo's `docs/release-notes/<version>.md`, which the
/// release workflow also makes the GitHub release and Sparkle's update
/// window of, bundled as `release-notes` in the app's resources
/// (`App/project.yml`). Which to show is `WhatsNewPlan`'s: the versions
/// after the last one shown, up to this one. A version is shown once:
/// it counts as seen as soon as an editor shows it, and when there is
/// nothing to show or notices are off it is seen as well, so turning them
/// back on later never brings back an old one.
///
/// A test launch (`-Kiri…` arguments) never reads or writes any of it:
/// the Debug build shares the person's preferences. `-KiriShowWhatsNew
/// <file or folder>` shows those notes instead, for pictures and tests.
@Observable final class WhatsNew {
    static let shared = WhatsNew()

    /// The notes to show, newest first; empty when there are none.
    private(set) var notes: [ReleaseNotes] = []
    /// The tab (its editor) showing them: one, the first to appear. (Held
    /// weakly: a tab closed with them showing ends them.)
    @ObservationIgnored private weak var owner: EditorModel?
    /// Bumped when `owner` changes, which the views follow.
    private var ownerChanges = 0
    /// A tab took them and hasn't given them back: with `owner` gone, the
    /// tab closed while they showed.
    @ObservationIgnored private var hadOwner = false
    @ObservationIgnored private weak var ownerDocument: NSDocument?
    /// `Prefs.whatsNewSeenKey` before this launch's notes were shown, to
    /// put back if their tab turns out not to be one to show them in.
    @ObservationIgnored private var seenBefore: String?
    /// Showing them records them as seen (this launch's, after an update).
    @ObservationIgnored private var recordsSeen = false
    /// They were recorded as seen when a tab took them.
    @ObservationIgnored private var markedSeen = false

    /// The version that is running, "0.3.2".
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// Whether notices show after updates (Settings, and the notice's box).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Prefs.whatsNewKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.whatsNewKey) }
    }

    // MARK: At launch

    /// Before any window: what this launch shows, if anything. (Before
    /// Sparkle starts too, which leaves its own keys behind on a first run.)
    static func launch() {
        #if DEBUG || KIRI_SELFTEST
        if SelfTest.isTestLaunch {
            if let path = UserDefaults.standard.string(forKey: "KiriShowWhatsNew") {
                shared.notes = Self.notes(at: URL(fileURLWithPath: path))
            }
            return
        }
        #endif
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: Prefs.whatsNewSeenKey)
        let available = bundled.keys.sorted()
        let versions = WhatsNewPlan.versions(current: current, lastSeen: seen, ranBefore: ranBefore(defaults),
                                             available: available)
        let notes = versions.compactMap { bundled[$0] }.map(load).filter { !$0.isEmpty }
        if notes.isEmpty || !enabled {
            markSeen(defaults, over: seen)
        } else {
            shared.seenBefore = seen
            shared.recordsSeen = true
            shared.notes = notes
        }
    }

    /// An earlier Kiri ran on this Mac: it left a window's place, a
    /// setting or Sparkle's own record of a launch. With no version seen,
    /// this is an update from before What's new, not a fresh install.
    private static func ranBefore(_ defaults: UserDefaults) -> Bool {
        let keys = ["SUHasLaunchedBefore", "SULastCheckTime", "NSWindow Frame KiriDocumentWindow",
                    Prefs.themeKey, Prefs.colorThemeKey, Prefs.textScaleKey, Prefs.wrapLinesKey]
        return keys.contains { defaults.object(forKey: $0) != nil }
    }

    /// This version's notes count as seen (never going back to an older
    /// one: a downgrade leaves the newer record alone).
    private static func markSeen(_ defaults: UserDefaults, over seen: String?) {
        if let seen, let old = ReleaseVersion(seen), let now = ReleaseVersion(current), old >= now { return }
        guard !current.isEmpty else { return }
        defaults.set(current, forKey: Prefs.whatsNewSeenKey)
    }

    // MARK: The notes files

    /// The bundled notes files by version.
    static var bundled: [String: URL] {
        guard let folder = Bundle.main.url(forResource: "release-notes", withExtension: nil) else { return [:] }
        return files(in: folder)
    }

    private static func files(in folder: URL) -> [String: URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var byVersion: [String: URL] = [:]
        for url in urls where url.pathExtension == "md" {
            let version = url.deletingPathExtension().lastPathComponent
            if ReleaseVersion(version) != nil { byVersion[version] = url }
        }
        return byVersion
    }

    private static func load(_ url: URL) -> ReleaseNotes {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return ReleaseNotes(version: url.deletingPathExtension().lastPathComponent, markdown: text)
    }

    /// A notes file, or the newest few of a folder of them.
    private static func notes(at url: URL) -> [ReleaseNotes] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
        guard isFolder.boolValue else { return [load(url)].filter { !$0.isEmpty } }
        let files = files(in: url)
        let newest = files.keys.compactMap(ReleaseVersion.init).sorted(by: >).prefix(WhatsNewPlan.mostVersions)
        return newest.compactMap { files[$0.description] }.map(load).filter { !$0.isEmpty }
    }

    // MARK: Which editor shows them

    /// Whether `model`'s tab shows the notes.
    func shows(in model: EditorModel) -> Bool {
        _ = ownerChanges
        return !notes.isEmpty && owner === model
    }

    private func setOwner(_ model: EditorModel?) {
        owner = model
        hadOwner = model != nil
        ownerChanges += 1
    }

    /// A tab came up in a window: the first takes the notes, and from then
    /// on they count as seen.
    func offer(_ model: EditorModel, document: NSDocument?) {
        // Their tab closed without closing them: they were shown.
        if owner == nil, hadOwner { close() }
        guard !notes.isEmpty, owner == nil else { return }
        setOwner(model)
        ownerDocument = document
        Telemetry.screen("What's New")
        if recordsSeen {
            recordsSeen = false
            markedSeen = true
            Self.markSeen(.standard, over: seenBefore)
        }
    }

    /// `model`'s tab came forward in the window where `previous`'s, which
    /// shows the notes, was: they go with it.
    func follow(from previous: EditorModel, to model: EditorModel, document: NSDocument?) {
        guard owner === previous, previous !== model, !notes.isEmpty else { return }
        setOwner(model)
        ownerDocument = document
    }

    /// `documents` are a `kiri -w` request's (a commit message, say): the
    /// tab of one of them gives the notes back, for the next tab that appears
    /// or the next launch.
    func waiting(on documents: [NSDocument]) {
        guard owner != nil, let ownerDocument, documents.contains(where: { $0 === ownerDocument }) else { return }
        setOwner(nil)
        self.ownerDocument = nil
        guard markedSeen else { return }
        markedSeen = false
        recordsSeen = true
        if let seenBefore {
            UserDefaults.standard.set(seenBefore, forKey: Prefs.whatsNewSeenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Prefs.whatsNewSeenKey)
        }
    }

    /// The notice's Close, Escape in its editor, or the first edit there.
    func close() {
        notes = []
        setOwner(nil)
        ownerDocument = nil
    }

    /// Something was typed, pasted or dropped into `model`'s document: the
    /// notice goes, as the first-run hint does.
    func edited(_ model: EditorModel) {
        if shows(in: model) { close() }
    }

    #if DEBUG || KIRI_SELFTEST
    @ObservationIgnored private var selfTestNotes: [ReleaseNotes] = []
    /// Gives the notes to `model`'s tab as if it had come up first.
    func selfTestHandOver(to model: EditorModel) {
        selfTestNotes = notes
        setOwner(model)
    }
    /// Puts the notes back in `model`'s tab.
    func selfTestRestore(notesOf model: EditorModel) {
        notes = selfTestNotes
        setOwner(model)
    }
    #endif

    // MARK: Help ▸ What's New in Kiri

    /// The notes of the newest version up to this one, if the app has any.
    static var latest: URL? {
        #if DEBUG || KIRI_SELFTEST
        // A test launch's own notes file stands in for the app's.
        if SelfTest.isTestLaunch, let path = UserDefaults.standard.string(forKey: "KiriShowWhatsNew"),
           path.hasSuffix(".md") { return URL(fileURLWithPath: path) }
        #endif
        let files = bundled
        let now = ReleaseVersion(current)
        let versions = files.keys.compactMap(ReleaseVersion.init).filter { now == nil || $0 <= now! }
        return versions.max().flatMap { files[$0.description] }
    }

    /// Shows them in the front window's tab, or a new one.
    static func showLatest() {
        guard let url = latest else { return }
        let notes = load(url)
        guard !notes.isEmpty else { return }
        shared.recordsSeen = false
        shared.markedSeen = false
        shared.setOwner(nil)
        shared.ownerDocument = nil
        shared.notes = [notes]
        if let model = FrontEditor.shared.editor {
            shared.offer(model, document: FrontEditor.shared.document)
        } else {
            NSDocumentController.shared.newDocument(nil)
        }
    }
}

// MARK: The notice

/// The release notes, drawn as the first-run hint is: quiet words on the
/// editor's paper, centred above the status capsule, and lines that are
/// buttons with the key that does the same. Over a document with text in
/// it, they sit on a panel of their own so the words stay readable.
struct WhatsNewNotice: View {
    let notes: [ReleaseNotes]
    /// On the paper of an empty document (the hint's place), or over text.
    var onPaper: Bool
    /// Draws that line as hovered, for pictures.
    var hovered: Int?
    var close: () -> Void = { WhatsNew.shared.close() }
    @AppStorage(Prefs.whatsNewKey) private var enabled = true

    var body: some View {
        // Long notes in a panel too short for them scroll, above lines
        // that stay put. (ViewThatFits takes the last one when none fits.)
        ViewThatFits(in: .vertical) {
            card(scrolls: false)
            card(scrolls: true)
        }
        .padding(.horizontal, 16)
        // Clear of line 1 and its number, and of the status capsule.
        .padding(.top, 40)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func card(scrolls: Bool) -> some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            if scrolls {
                ScrollView { notesText.padding(.bottom, 12) }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: .infinity)
                    // The words fade out above the lines, not cut off.
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                        }
                    }
            } else {
                notesText
            }
            VStack(spacing: 2) {
                StartHintLine("Close", shortcut: KeyboardShortcut(.escape, modifiers: []), hovered: hovered == 0, action: close)
                StartHintCheckLine("Don't show after updates", isOn: !enabled, hovered: hovered == 1) { enabled.toggle() }
            }
            .padding(.horizontal, -8) // the lines' own inset, level with the text
        }
        .frame(maxWidth: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What's new")
        if onPaper {
            content.padding(.horizontal, 2)
        } else {
            content.padding(18).honeyPanel(radius: .card)
        }
    }

    private var notesText: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(notes) { version in
                VStack(alignment: .leading, spacing: 8) {
                    // The newest under the title; earlier ones under their number.
                    if version.version == notes.first?.version {
                        Text("What's new in Kiri \(version.version)")
                            .font(.honey(.headline, weight: .heavy))
                            .foregroundStyle(Color.honeyFg)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        HoneySectionLabel("Kiri \(version.version)")
                            .padding(.top, 4)
                            .accessibilityLabel("Kiri \(version.version)")
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(version.blocks.indices, id: \.self) { i in
                        block(version.blocks[i])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 2)
    }

    @ViewBuilder private func block(_ block: ReleaseNotes.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Self.text(text)
        case .item(let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(Color.honeyAccent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    .accessibilityHidden(true)
                Self.text(text)
            }
        }
    }

    /// A line of notes: muted, as the hint's words are, with its **bold**
    /// in the text's own color and links in the accent's ink.
    private static func text(_ markdown: String) -> some View {
        var text = (try? AttributedString(markdown: markdown,
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in text.runs {
            if run.link != nil {
                text[run.range].foregroundColor = Color.honeyAccentInk
                text[run.range].underlineStyle = .single
            } else if let intent = run.inlinePresentationIntent,
                      intent.contains(.stronglyEmphasized) || intent.contains(.code) {
                text[run.range].foregroundColor = Color.honeyFg
            }
        }
        return Text(text)
            .font(.honey(.subheadline))
            .foregroundStyle(Color.honeyMuted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .tint(Color.honeyAccentInk)
    }
}
