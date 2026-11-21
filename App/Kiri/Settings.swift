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
    /// Letter fade-in: off, and not in Settings yet. TextKit 2 doesn't redraw
    /// the fading letter's fragment every frame (the behaviour self-test
    /// fails), so a letter could stay faint. `defaults write se.hellsoft.kiri
    /// letterFade -bool YES` turns it on for development.
    static let letterFadeKey = "letterFade"

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
    @AppStorage(Prefs.letterFadeKey) private var letterFade = false

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
                ThemePicker(selection: $colorTheme)
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
        }
        .padding(24)
        .frame(width: 600)
        .honeyPanel()
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

/// The color themes as small previews of the editor, in their own colors.
struct ThemePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Honey.Theme.all) { theme in
                ThemeSwatch(theme: theme, selected: theme.id == selection) { selection = theme.id }
            }
        }
    }
}

private struct ThemeSwatch: View {
    let theme: Honey.Theme
    let selected: Bool
    let action: () -> Void
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    private func c(_ t: Honey.Token) -> Color { Color(nsColor: .honeyFixed(theme[t])) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .frame(width: 80, height: 58)
                    .overlay {
                        RoundedRectangle(cornerRadius: Honey.Radius.control.value + 3, style: .continuous)
                            .strokeBorder(selected ? Color.honeyFocus : Color.clear, lineWidth: 2.5)
                            .padding(-4)
                    }
                Text(theme.name)
                    .font(.honey(.caption, weight: selected ? .heavy : .semibold))
                    .foregroundStyle(selected ? Color.honeyFg : Color.honeyMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(HoneyMotion(appearance, systemReduced: reduce).quick, value: selected)
        .accessibilityLabel(theme.name)
        .accessibilityHint(theme.blurb)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(theme.blurb)
    }

    /// A tiny window: canvas, the accent Save pill and a page of code.
    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.control.value, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Capsule().fill(c(Honey.accentSoft)).frame(width: 22, height: 7)
                Spacer(minLength: 0)
                Capsule().fill(c(Honey.accent)).frame(width: 14, height: 7)
            }
            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 3) { bar(Honey.synKeyword, 12); bar(Honey.synType, 18) }
                HStack(spacing: 3) { bar(Honey.synFunction, 16); bar(Honey.synString, 20) }
                HStack(spacing: 3) { bar(Honey.synComment, 26) }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(c(Honey.surface), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(5)
        .background(c(Honey.canvas), in: shape)
        .overlay(shape.strokeBorder(c(Honey.line), lineWidth: 1))
    }

    private func bar(_ t: Honey.Token, _ w: CGFloat) -> some View {
        Capsule().fill(c(t)).frame(width: w, height: 4)
    }
}
