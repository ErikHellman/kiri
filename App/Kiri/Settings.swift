import KiriKit
import SwiftUI

/// Persisted preferences (UserDefaults keys and helpers).
enum Prefs {
    /// Light, dark or system (`HoneyTheme`); shown as "Appearance".
    static let themeKey = "theme"
    /// The color theme's id (`Honey.Theme`), e.g. "honey" or "tide".
    static let colorThemeKey = "colorTheme"
    static let motionKey = "motion"
    static let textScaleKey = "textScale"
    static let wrapLinesKey = "wrapLines"
    static let typingAnimationsKey = "typingAnimations"
    /// The editor's font family (`EditorFont`), absent for SF Mono.
    static let editorFontKey = "editorFont"
    /// How wide the folder sidebar is, in points (`SidebarWidth`): set by
    /// dragging its edge, absent until then.
    static let sidebarWidthKey = "sidebarWidth"

    /// Editor text size steps for ⌘+ / ⌘- (the interface keeps its size).
    static let textScales: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]

    static func bigger(_ s: Double) -> Double { textScales.first { $0 > s + 0.001 } ?? textScales.last! }
    static func smaller(_ s: Double) -> Double { textScales.last { $0 < s - 0.001 } ?? textScales.first! }
}

/// Kiri ▸ Settings…: appearance, motion and the editor's text size.
struct SettingsView: View {
    static let windowID = "settings"

    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.colorThemeKey) private var colorTheme = Honey.Theme.honey.id
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true
    @AppStorage(Prefs.typingAnimationsKey) private var typingAnimations = true
    @State private var commandLineTool = CommandLineTool.shared
    @State private var editorFont = EditorFont.shared

    var body: some View {
        panel
            .padding([.horizontal, .bottom], Honey.gap)
            .honeyCanvas()
            // Honey on macOS (DESIGN.md §5): no title bar. The title sits on
            // the canvas in the band the hidden title bar leaves (the top
            // safe area), level with the traffic lights, the panel below it.
            .overlay {
                GeometryReader { window in
                    // Without a band (an offscreen render) there is no room for it.
                    if window.safeAreaInsets.top > 0 {
                        Text("Settings")
                            .font(.honey(.headline, weight: .heavy))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.leading, 84) // the traffic lights
                            .frame(height: window.safeAreaInsets.top)
                            .offset(y: -window.safeAreaInsets.top)
                    }
                }
                .allowsHitTesting(false) // the band still drags the window
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Theme").font(.honey(.body, weight: .bold))
                    Text("Colors for the window, the text and the Dock icon.")
                        .font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
                }
                ThemePicker(chosen: colorTheme)
            }
            row("Appearance", detail: "Follow macOS, or always light or dark.") {
                HoneySegmentedPicker(selection: $theme).accessibilityLabel("Appearance")
            }
            row("Motion", detail: "System follows Reduce Motion. Reduced keeps fades only.") {
                HoneySegmentedPicker(selection: $motion).accessibilityLabel("Motion")
            }
            row("Typing animations", detail: "The caret glides, lines and brackets glow. Off with Motion Off.") {
                Toggle("Typing animations", isOn: $typingAnimations).toggleStyle(.switch).labelsHidden()
                    .disabled(motion == .off)
            }
            fontRow
            row("Editor text size", detail: "The text and line numbers. ⌘+ and ⌘- change it from any window.") {
                HStack(spacing: 8) {
                    Button { textScale = Prefs.smaller(textScale) } label: { Label("Smaller Text", systemImage: "minus") }
                        .buttonStyle(.honeyIcon)
                    Text("\(Int((textScale * 100).rounded()))%")
                        .font(.honey(.subheadline, weight: .bold)).monospacedDigit().frame(width: 52)
                    Button { textScale = Prefs.bigger(textScale) } label: { Label("Bigger Text", systemImage: "plus") }
                        .buttonStyle(.honeyIcon)
                }
            }
            row("Wrap lines", detail: "Wrap long lines at the window edge.") {
                Toggle("Wrap lines", isOn: $wrapLines).toggleStyle(.switch).labelsHidden()
            }
            commandLineToolRow
        }
        .padding(24)
        .frame(width: 600)
        .honeyPanel()
    }

    /// The editor's typeface: a menu of the installed monospaced families,
    /// each in its own face, and a line of code in the chosen one at the
    /// editor's size, under it.
    private var fontRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Font", detail: "The editor's typeface. The size is the text size's.") {
                Picker("Font", selection: Binding(get: { editorFont.shown }, set: { editorFont.choose($0) })) {
                    Text(EditorFont.systemName).font(Font(EditorFont.font("", size: 13))).tag("")
                    Divider()
                    ForEach(EditorFont.families, id: \.self) { family in
                        Text(family).font(Font(EditorFont.font(family, size: 13))).tag(family)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            FontSample(family: editorFont.shown, scale: textScale)
        }
    }

    /// The `kiri` command: whether a terminal has it, and where; a button
    /// to install it until it is this copy's.
    @ViewBuilder private var commandLineToolRow: some View {
        switch commandLineTool.status {
        case .installed:
            row("Command line tool", detail: "kiri opens files and folders from a terminal. It is at \(CLIInstaller.linkPath).") {
                Label("Installed", systemImage: "checkmark")
                    .font(.honey(.subheadline, weight: .semibold)).foregroundStyle(Color.honeyMuted)
            }
        case .missing:
            row("Command line tool", detail: "Not installed. kiri opens files and folders from a terminal; installing links \(CLIInstaller.linkPath) to this app.") {
                Button("Install") { CLIInstaller.install() }.buttonStyle(.honeyGlass)
                    .accessibilityLabel("Install Command Line Tool")
            }
        case .other(let path):
            // The app the script is in, not the script.
            let app = path.hasSuffix("/Contents/Resources/kiri") ? String(path.dropLast("/Contents/Resources/kiri".count)) : path
            row("Command line tool", detail: "\(CLIInstaller.linkPath) opens another copy of Kiri (\(TabNames.abbreviatingHome(app, home: NSHomeDirectory()))). Install links it to this one.") {
                Button("Install") { CLIInstaller.install() }.buttonStyle(.honeyGlass)
                    .accessibilityLabel("Install Command Line Tool")
            }
        }
    }

    private func row<C: View>(_ title: String, detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.honey(.body, weight: .bold))
                Text(detail).font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(0)
            Spacer(minLength: 12)
            // Controls keep their natural size; the text column wraps instead.
            control().fixedSize().layoutPriority(1)
        }
    }
}


/// A line of code in the editor's font, size and colors: what the text
/// will look like.
private struct FontSample: View {
    let family: String
    let scale: Double

    var body: some View {
        let font = EditorFont.font(family, size: Honey.editorFontSize * scale)
        Text(sample)
            .font(Font(font))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.honeyCurrentLine, in: RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous).strokeBorder(Color.honeyLine, lineWidth: 1))
            .accessibilityLabel("Sample in \(family.isEmpty ? "SF Mono" : family)")
    }

    /// `let greeting = "Hello, Kiri" // 0O 1lI {}`: the letters people tell
    /// fonts apart by, in the syntax colors.
    private var sample: AttributedString {
        func part(_ text: String, _ token: Honey.Token) -> AttributedString {
            var a = AttributedString(text)
            a.foregroundColor = Color.honey(token)
            return a
        }
        return part("let ", Honey.synKeyword) + part("greeting", Honey.fg) + part(" = ", Honey.synPunctuation)
            + part("\"Hello, Kiri\"", Honey.synString) + part(" // 0O 1lI {}", Honey.synComment)
    }
}

/// The color themes as swatches, each in its own colors (`ThemeSwatchArt`).
/// The pointer on a swatch, or the keyboard moved onto one, shows that
/// theme in every window (`SwatchPreview`); a click, or Space, chooses it.
struct ThemePicker: View {
    /// The theme in the settings.
    let chosen: String
    /// The theme just clicked. A test launch keeps its choice among the
    /// launch's arguments, which nothing announces, so the ring follows
    /// the click from here until the setting says something else.
    @State private var clicked: String?
    @FocusState private var focus: String?

    private var selection: String { clicked ?? chosen }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Honey.Theme.all) { theme in
                ThemeSwatch(theme: theme, selected: theme.id == selection, focused: focus == theme.id) {
                    SwatchPreview.choose(theme)
                    clicked = theme.id
                } hover: { inside in
                    SwatchPreview.pointer(inside ? theme : nil, leaving: theme)
                }
                .focused($focus, equals: theme.id)
            }
        }
        // ← and → go from swatch to swatch (with keyboard navigation on,
        // Tab reaches the first one).
        .onMoveCommand { direction in
            guard let focus, let i = Honey.Theme.all.firstIndex(where: { $0.id == focus }) else { return }
            let step = direction == .left ? -1 : direction == .right ? 1 : 0
            let j = min(max(i + step, 0), Honey.Theme.all.count - 1)
            if j != i { self.focus = Honey.Theme.all[j].id }
        }
        .onChange(of: focus) { _, id in
            SwatchPreview.keyboard(id.map(Honey.Theme.named), byKey: SwatchPreview.keyMovedFocus)
        }
        .onChange(of: chosen) { clicked = nil }
        // The window going to the back, or closing, puts the chosen theme
        // back (a pointer that was on a swatch never says it left).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue == SettingsView.windowID { SwatchPreview.keyboard(nil, byKey: false) }
        }
        .onDisappear { SwatchPreview.reset() }
    }
}

/// What the theme swatches show in the windows: the theme under the
/// pointer, or else the one the keyboard is on, through `ThemePreview`
/// (held in memory: nothing is written); with neither, the chosen theme
/// again. Choosing goes through `ThemePreview.keep`, as Return in the
/// command palette does, so a test launch writes no saved preference.
@MainActor enum SwatchPreview {
    private(set) static var pointer: Honey.Theme?
    private(set) static var keyboard: Honey.Theme?
    /// A preview of the swatches' is up: ending it must not end one that
    /// the command palette began.
    private static var showing = false

    /// The pointer came onto a swatch (`theme`), or left `leaving`. (The
    /// next swatch can say it was entered before the last says it was left.)
    static func pointer(_ theme: Honey.Theme?, leaving: Honey.Theme? = nil) {
        if theme == nil, let leaving, pointer != leaving { return }
        pointer = theme
        update()
    }

    /// The keyboard came onto a swatch, or left them. Only a key that moved
    /// it there shows the theme: a window that opens with the keyboard on
    /// a swatch, or a click that leaves it there, shows nothing.
    static func keyboard(_ theme: Honey.Theme?, byKey: Bool) {
        if theme != nil, !byKey { return }
        keyboard = theme
        update()
    }

    /// The event being handled is a key pressed in the Settings window (Tab,
    /// an arrow): not the ⌘, that opened it, which another window got.
    static var keyMovedFocus: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.window?.identifier?.rawValue == SettingsView.windowID
    }

    /// A click (or Space, or VoiceOver's press) on a swatch: that theme is
    /// the setting from now on.
    static func choose(_ theme: Honey.Theme) {
        ThemePreview.shared.show(.theme(theme))
        ThemePreview.shared.keep()
        showing = false
    }

    /// Nothing is on a swatch any more.
    static func reset() {
        pointer = nil
        keyboard = nil
        update()
    }

    private static func update() {
        if let theme = pointer ?? keyboard {
            ThemePreview.shared.show(.theme(theme))
            showing = true
        } else if showing {
            ThemePreview.shared.end()
            showing = false
        }
    }
}

private struct ThemeSwatch: View {
    let theme: Honey.Theme
    let selected: Bool
    /// The keyboard is on it.
    let focused: Bool
    let action: () -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let lifted = hovering || focused
        Button(action: action) {
            VStack(spacing: 7) {
                ThemeSwatchArt(theme: theme)
                    .frame(height: 60)
                    .overlay {
                        RoundedRectangle(cornerRadius: Honey.Radius.control.value + 4, style: .continuous)
                            .strokeBorder(selected ? Color.honeyFocus : lifted ? Color.honeyMuted.opacity(0.6) : .clear,
                                          lineWidth: selected ? 2.5 : 2)
                            .padding(-4)
                    }
                    .scaleEffect(lifted ? 1.04 : 1)
                Text(theme.name)
                    .font(.honey(.caption, weight: selected ? .heavy : .semibold))
                    .foregroundStyle(selected ? Color.honeyFg : Color.honeyMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Its own rings say where the keyboard is (the system's would sit
        // on top of the selected one).
        .focusEffectDisabled()
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .animation(HoneyMotion(appearance, systemReduced: reduce).quick, value: selected)
        .animation(HoneyMotion(appearance, systemReduced: reduce).quick, value: lifted)
        .accessibilityLabel(theme.name)
        .accessibilityHint(theme.blurb)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(theme.blurb)
    }
}

/// A theme at a glance, in its own colors: its accent at full strength
/// over its canvas, and a corner of the editor's paper with a few lines of
/// code in its syntax colors. The light version is above the diagonal and
/// the dark one below it, so one swatch shows both.
struct ThemeSwatchArt: View {
    let theme: Honey.Theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.control.value, style: .continuous)
        ZStack {
            version(dark: false)
            version(dark: true).clipShape(BelowDiagonal())
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.honeyFg.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func version(dark: Bool) -> some View {
        let high = contrast == .increased
        func c(_ t: Honey.Token) -> Color { Color(nsColor: NSColor(honeyRGB: theme[t].value(dark: dark, highContrast: high))) }
        func bar(_ t: Honey.Token, _ width: CGFloat) -> some View { Capsule().fill(c(t)).frame(width: width, height: 4) }
        return GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                c(Honey.canvas)
                c(Honey.accent).frame(height: h * 0.5)
                VStack(alignment: .leading, spacing: 4.5) {
                    HStack(spacing: 3) { bar(Honey.synKeyword, 10); bar(Honey.synType, 17) }
                    HStack(spacing: 3) { bar(Honey.synFunction, 15); bar(Honey.synString, 20) }
                    HStack(spacing: 3) { bar(Honey.synComment, 24) }
                }
                .padding(.leading, 7)
                .padding(.top, 7)
                .frame(width: w * 0.82, height: h * 0.64, alignment: .topLeading)
                .background(c(Honey.surface), in: UnevenRoundedRectangle(topLeadingRadius: 6, style: .continuous))
                .offset(x: w * 0.18, y: h * 0.36)
            }
        }
    }
}

/// The half of a rectangle below the line from its bottom-left corner to
/// its top-right one.
private struct BelowDiagonal: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
