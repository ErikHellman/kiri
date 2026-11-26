import AppKit
import KiriKit
import SwiftUI

/// The glass status capsule over the bottom of the editor panel: the
/// language, the caret's position, the indentation, the encoding and the
/// line endings.
///
/// The language opens the language picker (the palette with only the
/// languages, ⌃⌘L), encoding and line endings are menus, the position
/// opens Go to Line and the indentation is only a label; what can be pressed shows a
/// capsule (and a menu its chevron) on hover and keyboard focus. The bar
/// keeps its width as the caret moves (`StatusText.Reserve`), and in a panel
/// too narrow for all of it the indentation goes first, then the save
/// format, then the language.
struct EditorStatusBar: View {
    @Bindable var model: EditorModel
    let document: KiriDocument
    let encoding: Binding<TextEncoding>
    let lineEnding: Binding<LineEnding>
    let byteOrderMark: Binding<Bool>
    /// Draws that item as hovered or focused, for pictures.
    var showing: (item: Item, as: HoneyStatusHighlight)?
    /// It stays at rest: the other side of a split window, without the
    /// keyboard.
    var quiet = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    enum Item: Hashable, CaseIterable {
        case language, position, indent, encoding, lineEnding
    }

    /// From the bottom of the editor panel to the capsule, and the least
    /// it keeps to the panel's sides.
    static let bottomPadding: CGFloat = 8
    static let sideMargin: CGFloat = 8

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduceMotion)
        // At rest while the person types or scrolls (it still takes
        // clicks). Not with reduced motion, and not for someone who asked
        // for more contrast.
        let resting = StatusBarRest.opacity(resting: model.statusRest.isResting || quiet, reducedMotion: motion.reduced,
                                            increasedContrast: contrast == .increased) < 1
        ViewThatFits(in: .horizontal) {
            bar(Set(Item.allCases), resting)
            bar([.language, .position, .encoding, .lineEnding], resting)
            bar([.language, .position], resting)
            bar([.position], resting)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.statusRest.barWidth = $0 }
        // The pointer on the bar itself brings it back too (the editor's
        // tracking area sees it coming, 40 pt out).
        .onHover { if $0 { model.statusRest.pointerOnBar() } }
        .padding(.horizontal, Self.sideMargin)
        .padding(.bottom, Self.bottomPadding)
        .animation(resting ? motion.medium : motion.quick, value: resting)
    }

    private func bar(_ items: Set<Item>, _ resting: Bool) -> some View {
        HoneyStatusBar(resting: resting) {
            if let media = model.mediaStatus {
                // A picture, a video or an archive: what it is, and no more.
                mediaFile(media)
            } else if let large = model.largeStatus {
                // A large file: where the caret is, and the file itself.
                position
                if items.contains(.encoding) { largeFile(large) }
            } else {
                if items.contains(.language) { language }
                position
                if items.contains(.indent) { indent }
                if items.contains(.encoding) { encodingMenu }
                if items.contains(.lineEnding) { lineEndingMenu }
            }
        }
    }

    /// "Read-only · 3.7 GB", and how far the line count has got while it
    /// is still under way.
    private func largeFile(_ status: LargeFileStatus) -> some View {
        let counting = status.counting.map { "Counting lines \(Int($0 * 100))%" }
        let text = ["Read-only", status.size, counting].compactMap { $0 }.joined(separator: " · ")
        // While counting, room for "100%" so the bar keeps its width.
        let widest = status.counting == nil ? [] : [["Read-only", status.size, "Counting lines 100%"].joined(separator: " · ")]
        return HoneyStatusItem(text, systemImage: "lock", reserving: widest)
            .help("Large files open read-only, for reading and searching")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
    }

    /// "PNG · 1920 × 1080 · 100% · 2.4 MB".
    private func mediaFile(_ status: MediaStatus) -> some View {
        HoneyStatusItem(status.text, systemImage: status.symbol)
            .help(status.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.text.replacingOccurrences(of: " · ", with: ", "))
            .accessibilityAddTraits(.isStaticText)
    }

    private func highlight(_ item: Item) -> HoneyStatusHighlight? {
        #if DEBUG || KIRI_SELFTEST
        // Screenshot helper: -KiriStatusShow encoding:hover (or language,
        // position, lineEnding; hover or focus) draws that item so.
        if showing == nil, let wanted = UserDefaults.standard.string(forKey: "KiriStatusShow")?.split(separator: ":"), wanted.count == 2 {
            let items: [String: Item] = ["language": .language, "position": .position, "encoding": .encoding, "lineEnding": .lineEnding]
            return items[String(wanted[0])] == item ? (wanted[1] == "focus" ? .focus : .hover) : nil
        }
        #endif
        return showing?.item == item ? showing?.as : nil
    }

    /// The bar stays solid while the keyboard is on one of its items.
    private func focusChanged(_ focused: Bool) { model.statusRest.focusChanged(inside: focused) }

    /// The language picker: a field to search in and the languages under
    /// it, over the top of the editor (`PaletteController.chooseLanguage`).
    private var language: some View {
        HoneyStatusButton(model.language.name, tone: .accent, chevron: true, showing: highlight(.language),
                          onFocusChange: focusChanged) {
            model.palette.toggleLanguages()
        }
        .help("Language (\(Keys.chooseLanguage.glyphs))")
        .accessibilityLabel("Language")
        .accessibilityValue(model.language.name)
        .accessibilityHint("Opens the language picker, to search for a language")
    }

    private var position: some View {
        let text = StatusText.position(line: model.line, column: model.column, selected: model.selectedLength)
        // The same as Edit ▸ Go to Line…
        return HoneyStatusButton(text, systemImage: "text.cursor", reserving: model.positionReserve.texts,
                                 showing: highlight(.position), onFocusChange: focusChanged) {
            model.goToLine.open()
        }
        // Digits roll to their new values (a fade with Reduce Motion).
        .contentTransition(reduceMotion || appearance.motion != .full && appearance.motion != .system
            ? .opacity : .numericText())
        .animation(HoneyMotion(appearance, systemReduced: reduceMotion).quick, value: text)
        .help("Go to Line (\(Keys.goToLine.glyphs))")
        .accessibilityLabel("Go to Line")
        .accessibilityValue(StatusText.spokenPosition(line: model.line, lineCount: model.lineCount, column: model.column,
                                                      selected: model.selectedLength))
    }

    private var indent: some View {
        HoneyStatusItem(model.indent.label, reserving: [IndentStyle.widestLabel])
            .help("What Shift Right (\(Keys.shiftRight.glyphs)) indents with: the file's own indentation, or a tab when it has none")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Indentation, \(model.indent.spoken)")
            .accessibilityAddTraits(.isStaticText)
    }

    private var encodingMenu: some View {
        let label = document.encoding.label + (document.hasBOM && document.encoding.isUnicode ? " BOM" : "")
        return HoneyStatusMenu(label, name: "Encoding", showing: highlight(.encoding), onFocusChange: focusChanged) {
            Picker("Encoding", selection: encoding) {
                ForEach(TextEncoding.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("Byte Order Mark", isOn: byteOrderMark).disabled(!document.encoding.isUnicode)
        }
        .help("Text encoding used when saving")
    }

    private var lineEndingMenu: some View {
        HoneyStatusMenu(document.lineEnding.label, name: "Line endings", showing: highlight(.lineEnding),
                        onFocusChange: focusChanged) {
            Picker("Line Endings", selection: lineEnding) {
                ForEach(LineEnding.allCases, id: \.self) { Text($0.menuName).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("Line endings used when saving")
    }
}

/// The status bar at rest. It floats over the bottom lines of the text, so
/// while the person types or scrolls it fades to about a third, and comes
/// back after a pause, when the pointer moves near it, when the keyboard
/// goes to one of its items or when a menu opens. With reduced motion it
/// doesn't fade at all (`opacity(resting:reducedMotion:)`).
///
/// Driven from AppKit (the text view's edits, the scroll view, a tracking
/// area), so it is right whether or not SwiftUI is drawing the window.
@MainActor @Observable final class StatusBarRest {
    static let restingOpacity = Honey.restOpacity
    /// How long after the last key or scroll the bar comes back.
    static let pause = 1.0
    /// How near the pointer has to come to bring it back at once.
    static let reach: CGFloat = 40

    private(set) var isResting = false

    /// The capsule's width as last laid out, for telling how near the
    /// pointer is.
    @ObservationIgnored var barWidth: CGFloat = 340
    @ObservationIgnored private var focusedItems = 0
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var waiting = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// What the bar is drawn with. It doesn't fade with reduced motion,
    /// nor for someone who asked for more contrast.
    static func opacity(resting: Bool, reducedMotion: Bool, increasedContrast: Bool) -> Double {
        resting && !reducedMotion && !increasedContrast ? restingOpacity : 1
    }

    /// The person typed or scrolled.
    func activity() {
        observeMenus()
        guard focusedItems == 0, !menuOpen else { return }
        lastActivity = .now
        if !isResting { isResting = true }
        guard !waiting else { return }
        waiting = true
        check(after: Self.pause)
    }

    /// The pointer moved over the editor panel: `point` from the panel's
    /// bottom left corner, the panel `size` large. Only a pointer that
    /// moves brings the bar back; one left lying near it doesn't keep it
    /// solid through the typing that follows.
    func pointerMoved(to point: CGPoint, in size: CGSize) {
        guard isResting else { return }
        let bar = CGRect(x: (size.width - barWidth) / 2, y: EditorStatusBar.bottomPadding, width: barWidth,
                         height: HoneyStatusMetrics.barHeight)
        if bar.insetBy(dx: -Self.reach, dy: -Self.reach).contains(point) { comeBack() }
    }

    func pointerOnBar() { comeBack() }

    /// The keyboard went to one of the bar's items, or left it.
    func focusChanged(inside: Bool) {
        focusedItems = max(0, focusedItems + (inside ? 1 : -1))
        if focusedItems > 0 { comeBack() }
    }

    private func comeBack() {
        if isResting { isResting = false }
    }

    private func check(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let idle = ContinuousClock.now - self.lastActivity
            let left = Self.pause - Double(idle.components.seconds) - Double(idle.components.attoseconds) / 1e18
            if left > 0.01, self.isResting {
                self.check(after: left)
            } else {
                self.waiting = false
                self.comeBack()
            }
        }
    }

    /// A menu that is open (one of the bar's, or any other) keeps the bar
    /// solid. Watched from the first key or scroll on: a model that never
    /// rests has nothing to watch for.
    private func observeMenus() {
        guard observers.isEmpty else { return }
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuOpen = open
                    if open { self?.comeBack() }
                }
            })
        }
    }
}
