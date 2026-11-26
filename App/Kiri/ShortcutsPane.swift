import AppKit
import KiriKit
import SwiftUI

/// Settings' two panes: everything else, and the keys.
enum SettingsPane: String, CaseIterable, Sendable {
    case general = "General", shortcuts = "Shortcuts"

    /// ⌘1 and ⌘2 in the Settings window.
    var number: Int { self == .general ? 1 : 2 }
}

/// Which pane Settings shows, so other windows can open it at one
/// (Help ▸ Keyboard Shortcuts' Customize…).
@MainActor @Observable final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var pane: SettingsPane = {
        #if DEBUG || KIRI_SELFTEST
        // Pictures: -KiriSettingsPane shortcuts.
        if let raw = UserDefaults.standard.string(forKey: "KiriSettingsPane"), let pane = SettingsPane(rawValue: raw.capitalized) {
            return pane
        }
        #endif
        return .general
    }()
}

/// Settings ▸ Shortcuts' state, and the keyboard there: the search, the
/// row the keyboard is on, and recording a new key for one.
///
/// The keys are read by a local event monitor while the Settings window
/// is up, ahead of the menus: while a key is being recorded every key
/// press is the new shortcut's, ⌘Q and ⌘W too, and Escape cancels the
/// recording instead of closing the window.
@MainActor @Observable final class ShortcutsPaneModel {
    static let shared = ShortcutsPaneModel()

    /// What is typed in the search field.
    var query: String = {
        #if DEBUG || KIRI_SELFTEST
        // Pictures: -KiriShortcutsQuery <text>.
        if let text = UserDefaults.standard.string(forKey: "KiriShortcutsQuery") { return text }
        #endif
        return ""
    }()
    /// Only the commands that share a key with another.
    var conflictsOnly = false
    /// The row the keyboard is on (↑ ↓, Return records it).
    var selected: ShortcutCommand?
    /// The command a key is being recorded for.
    private(set) var recording: ShortcutCommand?
    /// The modifiers held down while recording, shown as they are pressed.
    private(set) var held: KeyCombo.Modifiers = []
    /// What the recording row says under it: how to finish, why a key
    /// can't be had, or a key to confirm.
    private(set) var message: Message?
    /// A key pressed that another command has, or that text views use:
    /// Return gives it to the recording command.
    private(set) var pending: Pending?
    /// Bumped when a key is refused: the recorder shakes.
    private(set) var refusals = 0
    /// The command that just got a key, and a count that changes each time,
    /// for the row's flash.
    private(set) var justSet: (command: ShortcutCommand, count: Int)?
    /// Asks the view to put the keyboard in the search field.
    private(set) var focusRequests = 0
    /// Where the recording row is, in the window (SwiftUI's global space):
    /// a click outside it ends the recording.
    var recordingFrame: CGRect = .zero
    /// The keys that can't be changed, read from the menu bar when the
    /// pane shows.
    private(set) var fixed: [FixedKey] = FixedKey.kiri

    struct Pending: Equatable {
        let combo: KeyCombo
        /// The commands that have it now, and lose it.
        let owners: [ShortcutCommand]
    }

    enum Message: Equatable {
        /// A key that can't be a shortcut, and why.
        case refused(String)
        /// A key to give with Return: what it does now.
        case confirm(String)
    }

    private var monitor: Any?
    private var resignObserver: Any?
    private let store = ShortcutStore.shared

    // MARK: The list

    struct Section: Identifiable {
        let title: String
        let commands: [ShortcutCommand]
        var id: String { title }
    }

    /// The commands that match the search (each word anywhere in the name,
    /// the menu, the key or a few more words), in their menus.
    var sections: [Section] {
        let conflicts = store.conflicts
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return ShortcutCommand.Menu.allCases.compactMap { menu in
            let commands = ShortcutCommand.allCases.filter { command in
                guard command.info.menu == menu else { return false }
                if conflictsOnly, conflicts[command] == nil { return false }
                return matches(command, words)
            }
            return commands.isEmpty ? nil : Section(title: menu.rawValue, commands: commands)
        }
    }

    /// The fixed keys that match the search.
    var fixedShown: [FixedKey] {
        guard !conflictsOnly else { return [] }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return fixed.filter { key in
            let haystack = ([key.title, key.owner, key.keys] + key.combos.map(\.spoken)).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func matches(_ command: ShortcutCommand, _ words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let info = command.info
        let combo = store[command]
        let haystack = [info.title, info.place, info.keywords, info.titles.joined(separator: " "),
                        combo?.glyphs ?? "", combo?.spoken ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The rows the arrows go through, in order.
    var order: [ShortcutCommand] { sections.flatMap(\.commands) }

    /// The search changed: the keyboard goes to the first row that matches.
    func queryChanged() {
        cancel()
        selected = query.isEmpty ? nil : order.first
    }

    func move(_ by: Int) {
        let rows = order
        guard !rows.isEmpty else { return }
        guard let current = selected, let i = rows.firstIndex(of: current) else {
            selected = by > 0 ? rows.first : rows.last
            return
        }
        selected = rows[min(max(i + by, 0), rows.count - 1)]
    }

    // MARK: Recording

    func startRecording(_ command: ShortcutCommand) {
        selected = command
        recording = command
        held = []
        pending = nil
        message = nil
        Telemetry.track("shortcut_record", ["command": command.rawValue])
        announce("Recording a shortcut for \(command.info.title). Press the keys, Escape to cancel, Delete for none.")
    }

    func cancel() {
        guard recording != nil else { return }
        recording = nil
        pending = nil
        message = nil
        held = []
    }

    /// No key for the command.
    func clear(_ command: ShortcutCommand) {
        store.set(command, nil)
        finish(command, said: "\(command.info.title) has no shortcut")
    }

    /// The command's own key again.
    func reset(_ command: ShortcutCommand) {
        store.reset(command)
        finish(command, said: store[command].map { "\(command.info.title) is back to \($0.spoken)" } ?? "\(command.info.title) has no shortcut again")
    }

    func resetAll() {
        cancel()
        store.resetAll()
        announce("Every shortcut is back to Kiri's own")
    }

    /// Return on a key to confirm: the recording command has it, and the
    /// commands that had it have none.
    func confirm() {
        guard let command = recording, let pending else { return }
        for owner in pending.owners { store.set(owner, nil) }
        give(pending.combo, to: command)
    }

    private func give(_ combo: KeyCombo, to command: ShortcutCommand) {
        store.set(command, combo)
        finish(command, said: "\(command.info.title) is now \(combo.spoken)")
    }

    private func finish(_ command: ShortcutCommand, said: String) {
        recording = nil
        pending = nil
        message = nil
        held = []
        justSet = (command, (justSet?.count ?? 0) + 1)
        announce(said)
    }

    private func refuse(_ why: String) {
        pending = nil
        message = .refused(why)
        refusals += 1
        announce(why)
    }

    /// A key pressed while recording: the new shortcut, if it can be one.
    func press(_ candidates: [KeyCombo]) {
        guard let command = recording, let first = candidates.first else { return }
        // A key two ways (⇧⌘] is also ⌘}): the way that is the command's
        // own, or another command's, or else the way the menu bar matches.
        let current = store[command], own = ShortcutCommand.defaults[command]
        let combo = candidates.first { $0 == current || $0 == own }
            ?? candidates.first { !store.commands(with: $0).isEmpty }
            ?? first
        if combo == current {
            finish(command, said: "\(command.info.title) stays \(combo.spoken)")
            return
        }
        if combo.needsCommandOrControl {
            refuse("Add ⌘ or ⌃: on its own, \(combo.glyphs) types in the text.")
            return
        }
        for candidate in candidates {
            if let what = KeyCombo.systemWide[candidate] {
                refuse("macOS keeps \(candidate.glyphs) for \(what).")
                return
            }
            if let key = fixed.first(where: { $0.combos.contains(candidate) }) {
                refuse(key.owner == "Kiri" ? "\(candidate.glyphs) is \(key.title), which stays as it is."
                                          : "\(candidate.glyphs) is \(key.title), which belongs to macOS.")
                return
            }
        }
        let owners = store.commands(with: combo).filter { $0 != command }
        if !owners.isEmpty {
            let names = owners.map(\.info.title).joined(separator: " and ")
            pending = Pending(combo: combo, owners: owners)
            message = .confirm("\(combo.glyphs) is \(names)'s. Return gives it to \(command.info.title) instead, and \(names) has none.")
            announce("\(combo.spoken) is \(names)'s. Press Return to give it to \(command.info.title), or Escape to cancel.")
            return
        }
        if let what = KeyCombo.textEditing[combo] {
            pending = Pending(combo: combo, owners: [])
            message = .confirm("In text, \(combo.glyphs) \(what). Return uses it for \(command.info.title) all the same.")
            announce("In text, \(combo.spoken) \(what). Press Return to use it anyway, or Escape to cancel.")
            return
        }
        give(combo, to: command)
    }

    // MARK: The keyboard

    /// The Settings window is up: its keys go through `handle` from now on.
    func appeared() {
        fixed = FixedKey.menuBar() + FixedKey.kiri
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { event in
            // (Local monitors are called on the main thread.)
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent?
            MainActor.assumeIsolated { result = ShortcutsPaneModel.shared.handle(event) }
            return result
        }
        // The window going to the back ends a recording: the keys are
        // the other window's then.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { note in
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if window?.identifier?.rawValue == SettingsView.windowID { ShortcutsPaneModel.shared.cancel() }
            }
        }
    }

    /// The Settings window closed: nothing is listened to any more.
    func disappeared() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// One event in any of the app's windows. Nil: it is used up here.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isSettings(event.window) else { return event }
        let navigation = SettingsNavigation.shared
        switch event.type {
        case .flagsChanged:
            if recording != nil { held = KeyCombo.modifiers(event.modifierFlags) }
            return event
        case .leftMouseDown, .rightMouseDown:
            if recording != nil, !recordingFrame.contains(swiftUIPoint(event)) { cancel() }
            return event
        case .keyDown:
            break
        default:
            return event
        }
        let flags = KeyCombo.modifiers(event.modifierFlags)
        if let command = recording {
            if flags.isEmpty {
                switch event.keyCode {
                case 53: // Escape
                    cancel()
                    announce("Cancelled")
                    return nil
                case 48: // Tab: on to the next control, as usual.
                    cancel()
                    return event
                case 51, 117: // Delete
                    clear(command)
                    return nil
                case 36, 76: // Return
                    if pending != nil {
                        confirm()
                    } else if store.isChanged(command) {
                        reset(command)
                    } else {
                        cancel()
                    }
                    return nil
                default:
                    break
                }
            }
            if event.isARepeat { return nil }
            press(KeyCombo.candidates(event))
            return nil
        }
        // ⌘1, ⌘2 and ⌃⇥ go from pane to pane.
        if flags == .command, let n = Int(event.charactersIgnoringModifiers ?? ""),
           let pane = SettingsPane.allCases.first(where: { $0.number == n }) {
            navigation.pane = pane
            return nil
        }
        if event.keyCode == 48, flags.subtracting(.shift) == .control {
            navigation.pane = navigation.pane == .general ? .shortcuts : .general
            return nil
        }
        guard navigation.pane == .shortcuts, flags.isEmpty else { return event }
        switch event.keyCode {
        case 125: // ↓
            move(1)
            return nil
        case 126: // ↑
            move(-1)
            return nil
        case 36, 76: // Return
            guard let selected else { return event }
            startRecording(selected)
            return nil
        default:
            return event
        }
    }

    private func isSettings(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == SettingsView.windowID
    }

    /// The event's place in the window, top-left first, as SwiftUI's
    /// global space has it.
    private func swiftUIPoint(_ event: NSEvent) -> CGPoint {
        guard let window = event.window else { return .zero }
        let p = event.locationInWindow
        return CGPoint(x: p.x, y: window.frame.height - p.y)
    }

    /// The search field takes the keyboard (the Shortcuts pane was chosen).
    func focusSearch() { focusRequests += 1 }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    #if DEBUG || KIRI_SELFTEST
    /// For a test: the state a picture or a check starts from.
    func selfTestReset() {
        cancel()
        query = ""
        conflictsOnly = false
        selected = nil
    }
    #endif
}

/// Settings ▸ Shortcuts: every command of Kiri's menus with its key, found
/// by a search, in groups by menu; the keys that can't be changed after
/// them. A click on a key, or Return on its row, records a new one.
struct ShortcutsPane: View {
    /// As tall as the General pane, so the window keeps its size.
    let height: CGFloat

    @State private var model = ShortcutsPaneModel.shared
    @State private var store = ShortcutStore.shared
    @State private var confirmingResetAll = false
    @FocusState private var searchFocused: Bool
    @State private var searchHadKeyboard = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var motion: HoneyMotion { HoneyMotion(appearance, systemReduced: reduce) }

    var body: some View {
        let conflicts = store.conflicts
        VStack(alignment: .leading, spacing: 0) {
            header(conflictCount: conflicts.count)
                .padding([.horizontal, .top], 18)
                .padding(.bottom, 12)
            Rectangle().fill(Color.honeyLine).frame(height: 1)
            list(conflicts: conflicts)
            Rectangle().fill(Color.honeyLine).frame(height: 1)
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .frame(width: 600, height: max(height, 420))
        .honeyPanel()
        .onChange(of: model.query) { model.queryChanged() }
        .onChange(of: model.conflictsOnly) { model.queryChanged() }
        .onChange(of: model.focusRequests) { searchFocused = true }
        // While a key is recorded the recorder has the only focus ring; the
        // keyboard comes back to the search after, if it was there.
        .onChange(of: model.recording) { old, new in
            if new != nil, old == nil {
                searchHadKeyboard = searchFocused
                searchFocused = false
            } else if new == nil, searchHadKeyboard {
                searchFocused = true
            }
        }
        .onChange(of: conflicts.isEmpty) { _, none in if none { model.conflictsOnly = false } }
        .confirmationDialog("Put every shortcut back to Kiri's own?", isPresented: $confirmingResetAll) {
            Button("Reset All", role: .destructive) { model.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The keys you changed go back to what Kiri comes with.")
        }
    }

    private func header(conflictCount: Int) -> some View {
        HStack(spacing: 10) {
            HoneySearchField("Search commands or keys", text: $model.query, focused: $searchFocused)
            if conflictCount > 0 {
                // Shape and words, not color alone: a triangle and a count,
                // and while only those show, the way back to all.
                Button { model.conflictsOnly.toggle() } label: {
                    if model.conflictsOnly {
                        Label("Show All", systemImage: "list.bullet")
                    } else {
                        Label("\(conflictCount) \(conflictCount == 1 ? "Conflict" : "Conflicts")", systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .buttonStyle(.honeyGlass)
                .help(model.conflictsOnly ? "Show every command" : "Show only the commands that share a key")
                .transition(motion.reduced ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
            Button("Reset All…") { confirmingResetAll = true }
                .buttonStyle(.honeyGlass)
                .disabled(!store.hasChanges)
                .help("Put every shortcut back to Kiri's own")
        }
        .animation(motion.shape, value: conflictCount > 0)
    }

    private func list(conflicts: [ShortcutCommand: [ShortcutCommand]]) -> some View {
        let sections = model.sections
        let fixed = model.fixedShown
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if sections.isEmpty, fixed.isEmpty {
                        Text("No command or key matches “\(model.query)”. Fewer letters may find it.")
                            .font(.honey(.body)).foregroundStyle(Color.honeyMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(sections) { section in
                        sectionTitle(section.title)
                        ForEach(section.commands) { command in
                            ShortcutRow(command: command, combo: store[command], changed: store.isChanged(command),
                                        conflict: conflicts[command], showsPlace: searching, model: model)
                                .id(command)
                        }
                    }
                    if !fixed.isEmpty {
                        sectionTitle("Fixed")
                        ForEach(fixed) { FixedRow(key: $0) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.selected) { _, command in
                // The list itself doesn't move, as the palette's doesn't:
                // only far enough to show the row.
                if let command { proxy.scrollTo(command) }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.localizedUppercase)
            .font(.honeySectionLabel)
            .tracking(0.7)
            .foregroundStyle(Color.honeyMuted)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        // In the Help window's key caps, so the keys read as keys.
        HStack(spacing: 6) {
            Text("Click a key to change it, or").foregroundStyle(Color.honeyMuted)
            KeyCaps("↑  ↓")
            Text("and").foregroundStyle(Color.honeyMuted)
            KeyCaps("↩")
            Spacer(minLength: 8)
            Text("System Settings ▸ Keyboard ▸ App Shortcuts goes first.")
                .foregroundStyle(Color.honeyMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .help("A key given to one of Kiri's menu items in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts is the one that works.")
        }
        .font(.honey(.caption, weight: .semibold))
        .accessibilityElement(children: .combine)
    }
}

/// A command, its key and, while recording, what to press.
private struct ShortcutRow: View {
    let command: ShortcutCommand
    let combo: KeyCombo?
    let changed: Bool
    let conflict: [ShortcutCommand]?
    /// The menu under the name: while searching, when the groups are few.
    let showsPlace: Bool
    let model: ShortcutsPaneModel

    @State private var hovering = false
    @State private var flashing = false
    /// Where the row is in the window, for `ShortcutsPaneModel.recordingFrame`.
    @State private var frame: CGRect = .zero
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var motion: HoneyMotion { HoneyMotion(appearance, systemReduced: reduce) }
    private var recording: Bool { model.recording == command }
    private var selected: Bool { model.selected == command }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.info.title).font(.honey(.body, weight: .semibold)).foregroundStyle(Color.honeyFg)
                    if showsPlace {
                        Text(command.info.place).font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
                    }
                    if let conflict, !recording {
                        Label("Same key as \(conflict.map(\.info.title).joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                            .font(.honey(.caption, weight: .bold))
                            .foregroundStyle(Color.honeyDanger)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 12)
                if changed, !recording {
                    Button { model.reset(command) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.honeyMuted)
                    .background(Circle().fill(Color.honeyFg.opacity(hovering ? 0.07 : 0)))
                    .help(ShortcutCommand.defaults[command].map { "Back to \($0.glyphs)" } ?? "Back to no shortcut")
                    .accessibilityLabel("Reset \(command.info.title)")
                    .accessibilityHint(ShortcutCommand.defaults[command].map { "Back to \($0.spoken)" } ?? "Back to no shortcut")
                    .transition(motion.reduced ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
                RecorderCap(command: command, combo: combo, changed: changed, recording: recording, model: model)
            }
            if recording {
                RecordingHint(command: command, model: model)
                    .transition(motion.reduced ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background {
            RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
                .fill(selected || recording ? Color.honeyAccentSoft
                      : flashing ? Color.honeyAccentSoft.opacity(0.8)
                      : hovering ? Color.honeySurface2 : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selected = command }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in
            frame = new
            if recording { model.recordingFrame = new }
        }
        .onChange(of: recording) { _, now in
            if now { model.recordingFrame = frame }
        }
        // Just given a key: the row glows once and fades, so the eye finds
        // what changed (Motion: Off shows nothing).
        .onChange(of: model.justSet?.count) {
            guard model.justSet?.command == command, !motion.off else { return }
            flashing = true
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { flashing = false }
        }
        .animation(motion.shape, value: recording)
        .animation(motion.quick, value: changed)
        .animation(motion.quick, value: conflict == nil)
        .animation(motion.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(command.info.title)
    }
}

/// The key, in the Help window's key caps, as a button: a click records a
/// new one. While recording it is a well with a breathing focus ring and
/// the modifiers as they are held.
private struct RecorderCap: View {
    let command: ShortcutCommand
    let combo: KeyCombo?
    let changed: Bool
    let recording: Bool
    let model: ShortcutsPaneModel

    @State private var breathing = false
    @State private var shake: CGFloat = 0
    @State private var popped = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var motion: HoneyMotion { HoneyMotion(appearance, systemReduced: reduce) }

    var body: some View {
        Button {
            if recording { model.cancel() } else { model.startRecording(command) }
        } label: {
            label
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .modifier(Shake(amount: shake))
        .help(recording ? "Press the new keys" : "Click to change the shortcut for \(command.info.title)")
        .accessibilityLabel("Shortcut for \(command.info.title)")
        .accessibilityValue(recording ? "Recording" : combo?.spoken ?? "None")
        .accessibilityHint(recording ? "Press the new keys. Escape cancels, Delete leaves it with none." : "Records a new shortcut")
        .onChange(of: model.refusals) {
            guard recording, !motion.reduced else { return }
            // Side to side and still, as a refused password shakes.
            shake = 0
            withAnimation(.linear(duration: 0.32)) { shake = 1 }
        }
        .onChange(of: model.justSet?.count) {
            // A small pop as the new key lands (no movement with reduced motion).
            guard model.justSet?.command == command, !motion.reduced else { return }
            popped = true
            withAnimation(motion.shape) { popped = false }
        }
        .onChange(of: recording, initial: true) { _, now in
            breathing = false
            guard now, !motion.reduced else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
        }
    }

    @ViewBuilder private var label: some View {
        if recording {
            let held = model.held
            let shown = KeyCombo.Modifiers.glyphs(held)
            Text(shown.isEmpty ? "Type the keys" : shown + "…")
                .font(shown.isEmpty ? .honey(.subheadline, weight: .semibold) : .system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(shown.isEmpty ? Color.honeyMuted : Color.honeyFg)
                .contentTransition(.opacity)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minWidth: 120, minHeight: 24)
                .background(Color.honeySurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.honeyFocus.opacity(breathing ? 0.45 : 1), lineWidth: 2)
                }
                .animation(motion.quick, value: held)
        } else if let combo {
            Text(combo.glyphs)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(changed ? Color.honeyAccentInk : Color.honeyFg)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(minWidth: 26, minHeight: 22)
                .background(changed ? Color.honeyAccentSoft : Color.honeySurface2,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    // A changed key has the accent's outline: shape, not
                    // only color, says it is not Kiri's own.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(changed ? Color.honeyAccent : Color.honeyLine, lineWidth: changed ? 1.5 : 1)
                }
                .scaleEffect(popped ? 1.18 : 1)
        } else {
            // No key: an empty, dashed cap that says what a click does.
            Text("Add")
                .font(.honey(.caption, weight: .bold))
                .foregroundStyle(Color.honeyMuted)
                .padding(.horizontal, 9)
                .frame(minWidth: 26, minHeight: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.honeyMuted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                }
                .contentShape(Rectangle())
        }
    }
}

/// Under the recording row: what the keys do, why a key was refused, or a
/// key to confirm with Return.
private struct RecordingHint: View {
    let command: ShortcutCommand
    let model: ShortcutsPaneModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch model.message {
            case .refused(let why):
                Label(why, systemImage: "nosign").foregroundStyle(Color.honeyDanger)
            case .confirm(let what):
                Label(what, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.honeyAccentInk)
            case nil:
                Text("Press the new keys.").foregroundStyle(Color.honeyMuted)
            }
            Spacer(minLength: 6)
            if model.pending != nil {
                hintButton("Use It", key: "↩") { model.confirm() }
            } else {
                if ShortcutStore.shared.isChanged(command) {
                    hintButton(ShortcutCommand.defaults[command].map { "Default \($0.glyphs)" } ?? "Default: none", key: "↩") {
                        model.reset(command)
                    }
                }
                hintButton("None", key: "⌫") { model.clear(command) }
            }
            hintButton("Cancel", key: "⎋") { model.cancel() }
        }
        .font(.honey(.caption, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 2)
    }

    /// A small button with its key: for the pointer what the key is for
    /// the keyboard.
    private func hintButton(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(key).font(.system(size: 11, weight: .semibold, design: .rounded))
                Text(title)
            }
            .foregroundStyle(Color.honeyFg)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Color.honeySurface2, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(title)
    }
}

/// A key that can't be changed: muted caps, and whose it is.
private struct FixedRow: View {
    let key: FixedKey

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(key.title).font(.honey(.body, weight: .semibold)).foregroundStyle(Color.honeyFg.opacity(0.8))
                Text(key.owner == "Kiri" ? "Kiri's, not changeable" : "macOS's").font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
            }
            Spacer(minLength: 12)
            KeyCaps(key.keys).opacity(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}

/// Side to side three times and still: a key that can't be had.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Fades out as it goes, so it ends where it began.
        let x = 5 * sin(amount * .pi * 6) * (1 - amount)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

extension KeyCombo.Modifiers {
    /// "⌃⌥⇧⌘" for the ones in `set`.
    static func glyphs(_ set: KeyCombo.Modifiers) -> String {
        var s = ""
        if set.contains(.control) { s += "⌃" }
        if set.contains(.option) { s += "⌥" }
        if set.contains(.shift) { s += "⇧" }
        if set.contains(.command) { s += "⌘" }
        return s
    }
}
