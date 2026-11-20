#if canImport(SwiftUI)
import AppKit
import CoreText
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

// MARK: Colors

public extension Color {
    /// A Honey color token that follows light, dark and increased contrast.
    static func honey(_ t: Honey.Token) -> Color { Color(nsColor: .honey(t)) }

    static let honeyCanvas = honey(Honey.canvas)
    static let honeySurface = honey(Honey.surface)
    static let honeySurface2 = honey(Honey.surface2)
    static let honeySurface3 = honey(Honey.surface3)
    static let honeyLine = honey(Honey.line)
    static let honeyFg = honey(Honey.fg)
    static let honeyMuted = honey(Honey.fgMuted)
    static let honeyAccent = honey(Honey.accent)
    static let honeyAccentFg = honey(Honey.accentFg)
    static let honeyAccentInk = honey(Honey.accentInk)
    static let honeyAccentSoft = honey(Honey.accentSoft)
    static let honeyFocus = honey(Honey.focus)
    static let honeyDanger = honey(Honey.danger)
    static let honeyDangerFill = honey(Honey.dangerFill)
    static let honeyOK = honey(Honey.ok)
    static let honeySelection = honey(Honey.selection)
    static let honeyCurrentLine = honey(Honey.currentLine)
    static let honeyGutter = honey(Honey.gutter)
    static let honeyCaret = honey(Honey.caret)
}

public extension NSColor {
    /// A Honey color token that follows light, dark and increased contrast,
    /// for AppKit views such as the editor's text view.
    static func honey(_ t: Honey.Token) -> NSColor {
        NSColor(name: nil) { a in
            let match = a.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                           .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                           .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
            let dark: Set<NSAppearance.Name> = [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                                .accessibilityHighContrastVibrantDark]
            let high: Set<NSAppearance.Name> = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                                .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark]
            return NSColor(honeyRGB: t.value(dark: match.map(dark.contains) ?? false,
                                             highContrast: match.map(high.contains) ?? false))
        }
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
