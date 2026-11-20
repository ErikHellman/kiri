import KiriKit
import SwiftUI

/// Persisted preferences (UserDefaults keys and helpers).
enum Prefs {
    static let themeKey = "theme"
    static let motionKey = "motion"
    static let textScaleKey = "textScale"
    static let wrapLinesKey = "wrapLines"
    static let typingAnimationsKey = "typingAnimations"
    /// Letter fade-in is off by default until it's been seen redrawing on a
    /// real display (see README).
    static let letterFadeKey = "letterFade"

    /// Text size steps for ⌘+ / ⌘-.
    static let textScales: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]

    static func bigger(_ s: Double) -> Double { textScales.first { $0 > s + 0.001 } ?? textScales.last! }
    static func smaller(_ s: Double) -> Double { textScales.last { $0 < s - 0.001 } ?? textScales.first! }
}

/// Kiri ▸ Settings…: appearance, motion and text size.
struct SettingsView: View {
    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true
    @AppStorage(Prefs.typingAnimationsKey) private var typingAnimations = true
    @AppStorage(Prefs.letterFadeKey) private var letterFade = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("Theme", detail: "Follow macOS, or always light or dark.") {
                HoneySegmentedPicker(selection: $theme)
            }
            row("Motion", detail: "System follows Reduce Motion. Reduced keeps fades only.") {
                HoneySegmentedPicker(selection: $motion)
            }
            row("Typing animations", detail: "Letters fade in and the caret glides. Off with Motion Off.") {
                Toggle("", isOn: $typingAnimations).toggleStyle(.switch).labelsHidden()
                    .disabled(motion == .off)
            }
            row("Letters fade in", detail: "Typed letters fade in and settle (experimental).") {
                Toggle("", isOn: $letterFade).toggleStyle(.switch).labelsHidden()
                    .disabled(motion == .off || !typingAnimations)
            }
            row("Text size", detail: "⌘+ and ⌘- change it from any window.") {
                HStack(spacing: 8) {
                    Button { textScale = Prefs.smaller(textScale) } label: { Label("Smaller", systemImage: "minus") }
                        .buttonStyle(.honeyIcon)
                    Text("\(Int((textScale * 100).rounded())) %")
                        .font(.honey(.subheadline, weight: .bold)).monospacedDigit().frame(width: 52)
                    Button { textScale = Prefs.bigger(textScale) } label: { Label("Bigger", systemImage: "plus") }
                        .buttonStyle(.honeyIcon)
                }
            }
            row("Wrap lines", detail: "Wrap long lines at the window edge.") {
                Toggle("", isOn: $wrapLines).toggleStyle(.switch).labelsHidden()
            }
        }
        .padding(24)
        .frame(width: 520)
        .honeyPanel()
        .padding(Honey.gap)
        .honeyCanvas()
    }

    private func row<C: View>(_ title: String, detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.honey(.body, weight: .bold))
                Text(detail).font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
