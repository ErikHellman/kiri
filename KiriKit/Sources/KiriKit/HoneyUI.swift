#if canImport(SwiftUI)
import AppKit
import CoreText
import Observation
import SwiftUI

// The SwiftUI side of Honey (docs/DESIGN.md): colors, type, motion and the
// solid surfaces. Liquid Glass lives in HoneyGlass.swift.

public extension Honey {
    /// Registers the bundled Nunito faces. Call once, at app start.
    @MainActor static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    /// In-app text size, 1 = 100%. macOS has no Dynamic Type, so the app sets
    /// this from its settings and rebuilds its views.
    nonisolated(unsafe) static var textScale: CGFloat = 1
}

@MainActor private var fontsRegistered = false

extension Honey.Token {
    /// The value for an appearance (dark and high-contrast variants).
    func value(appearance a: NSAppearance) -> UInt32 {
        let match = a.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                       .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                       .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
        let dark: Set<NSAppearance.Name> = [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                            .accessibilityHighContrastVibrantDark]
        let high: Set<NSAppearance.Name> = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                            .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark]
        return value(dark: match.map(dark.contains) ?? false, highContrast: match.map(high.contains) ?? false)
    }
}

// MARK: Colors

/// The color theme in use. Views read it through the `honey…` colors, so
/// SwiftUI redraws them when it changes (Observation tracks the read).
@Observable public final class HoneyThemeState: @unchecked Sendable {
    public static let shared = HoneyThemeState()
    public var theme: Honey.Theme = .honey
}

public extension Honey {
    /// The color theme in use; setting it recolors every window.
    static var theme: Theme {
        get { HoneyThemeState.shared.theme }
        set {
            guard newValue != HoneyThemeState.shared.theme else { return }
            HoneyThemeState.shared.theme = newValue
            NotificationCenter.default.post(name: .honeyThemeDidChange, object: nil)
        }
    }
}

public extension Notification.Name {
    /// Posted after `Honey.theme` changes. AppKit views that cache colors
    /// (layers, rendered text) redraw on it.
    static let honeyThemeDidChange = Notification.Name("HoneyThemeDidChange")
}

public extension Color {
    /// A Honey color token in the current theme, following light, dark and
    /// increased contrast.
    static func honey(_ t: Honey.Token) -> Color { Color(nsColor: .honeyFixed(Honey.theme[t])) }

    static var honeyCanvas: Color { honey(Honey.canvas) }
    static var honeySurface: Color { honey(Honey.surface) }
    static var honeySurface2: Color { honey(Honey.surface2) }
    static var honeySurface3: Color { honey(Honey.surface3) }
    static var honeyLine: Color { honey(Honey.line) }
    static var honeyFg: Color { honey(Honey.fg) }
    static var honeyMuted: Color { honey(Honey.fgMuted) }
    static var honeyAccent: Color { honey(Honey.accent) }
    static var honeyAccentFg: Color { honey(Honey.accentFg) }
    static var honeyAccentInk: Color { honey(Honey.accentInk) }
    static var honeyAccentSoft: Color { honey(Honey.accentSoft) }
    static var honeyFocus: Color { honey(Honey.focus) }
    static var honeyDanger: Color { honey(Honey.danger) }
    static var honeyDangerFill: Color { honey(Honey.dangerFill) }
    static var honeyOK: Color { honey(Honey.ok) }
    static var honeySelection: Color { honey(Honey.selection) }
    static var honeyCurrentLine: Color { honey(Honey.currentLine) }
    static var honeyGutter: Color { honey(Honey.gutter) }
    static var honeyCaret: Color { honey(Honey.caret) }
}

public extension NSColor {
    /// A Honey color token that follows the current theme, light, dark and
    /// increased contrast, for AppKit views such as the editor's text view.
    /// The theme is looked up when the color is drawn.
    static func honey(_ t: Honey.Token) -> NSColor {
        NSColor(name: nil) { a in NSColor(honeyRGB: Honey.theme[t].value(appearance: a)) }
    }

    /// A token as given (no theme lookup), following light, dark and contrast.
    static func honeyFixed(_ t: Honey.Token) -> NSColor {
        NSColor(name: nil) { a in NSColor(honeyRGB: t.value(appearance: a)) }
    }

    /// An sRGB color from 0xRRGGBB.
    convenience init(honeyRGB rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Type

public extension Font {
    /// Nunito at a text style's Honey size (§4).
    static func honey(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .custom("Nunito", size: honeySize(style) * Honey.textScale, relativeTo: style).weight(weight)
    }

    /// Section labels: 11.5 pt, heavy; pair with `.textCase(.uppercase)` and `.tracking(0.7)`.
    static var honeySectionLabel: Font {
        .custom("Nunito", size: 11.5 * Honey.textScale).weight(.heavy)
    }

    /// The editor and code font: the platform monospace (SF Mono).
    static func honeyMono(size: CGFloat = Honey.editorFontSize, weight: Font.Weight = .regular) -> Font {
        .system(size: size * Honey.textScale, weight: weight, design: .monospaced)
    }

    private static func honeySize(_ s: Font.TextStyle) -> CGFloat {
        switch s {
        case .largeTitle: 26
        case .title: 20
        case .title2, .title3, .headline: 17
        case .body, .callout: 15
        case .subheadline, .footnote: 13
        case .caption, .caption2: 12
        default: 15
        }
    }
}

// MARK: Motion

public extension Animation {
    /// The Honey spring: settles fast with a little overshoot.
    static let honeySpring = Animation.spring(response: Honey.springResponse, dampingFraction: Honey.springDamping)
    /// Color, opacity and hover changes.
    static let honeyQuick = Animation.easeOut(duration: Honey.quick)
}

public extension EnvironmentValues {
    /// The person's theme and motion preferences.
    @Entry var honeyAppearance = HoneyAppearance()
}

/// Resolves the motion preference against the OS reduce-motion switch.
public struct HoneyMotion: Sendable {
    public let appearance: HoneyAppearance
    public let systemReduced: Bool

    public init(_ appearance: HoneyAppearance, systemReduced: Bool) {
        self.appearance = appearance
        self.systemReduced = systemReduced
    }

    public var reduced: Bool { appearance.reduced(systemReduceMotion: systemReduced) }
    public var off: Bool { appearance.motion == .off }
    /// Shape changes: the spring, a quick fade when reduced, nothing when off.
    public var shape: Animation? { off ? nil : reduced ? .honeyQuick : .honeySpring }
    /// Color and hover changes: quick, or nothing when off.
    public var quick: Animation? { off ? nil : .honeyQuick }
}

public extension HoneyTheme {
    /// The scheme to force, or nil to follow the OS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public extension View {
    /// The root of a Honey window: preferences in the environment, the chosen
    /// theme, Nunito as the default font and amber as the control tint.
    /// Motion Off turns every animation below it off.
    func honeyRoot(_ appearance: HoneyAppearance = HoneyAppearance()) -> some View {
        environment(\.honeyAppearance, appearance)
            .preferredColorScheme(appearance.theme.colorScheme)
            .font(.honey())
            .foregroundStyle(Color.honeyFg)
            .tint(Color.honeyAccent)
            .transaction { if appearance.motion == .off { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// Animates `value` changes with the Honey spring, respecting the motion setting.
    func honeyAnimation<V: Equatable>(value: V) -> some View { modifier(HoneyAnimated(value: value)) }

    /// A solid floating panel: `surface` fill, rounded corners and the soft
    /// two-layer shadow; with increased contrast, an outline instead.
    /// Use it for content people read (the editor), and glass for chrome.
    func honeyPanel(radius: Honey.Radius = .panel) -> some View { modifier(HoneyPanel(radius: radius.value)) }

    /// The canvas behind floating panels, edge to edge.
    func honeyCanvas() -> some View {
        background(Color.honeyCanvas.ignoresSafeArea())
    }
}

private struct HoneyPanel: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if contrast == .increased {
            content.background(Color.honeySurface, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.honeyLine, lineWidth: 2))
        } else {
            // Warm brown in light mode, black in dark (§3 `shadow`).
            let ink = scheme == .dark ? Color.black.opacity(0.5) : Color(nsColor: NSColor(honeyRGB: 0x5A3A1A)).opacity(0.16)
            content.background(Color.honeySurface, in: shape)
                .clipShape(shape)
                .shadow(color: ink, radius: 15, y: 10)
                .shadow(color: ink.opacity(0.6), radius: 3, y: 2)
        }
    }
}

private struct HoneyAnimated<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.animation(HoneyMotion(appearance, systemReduced: reduce).shape, value: value)
    }
}
#endif
