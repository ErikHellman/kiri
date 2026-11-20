import Foundation

/// The Honey design language (docs/DESIGN.md), adapted from Ting. Plain values
/// here so they test on Linux; the SwiftUI side is in HoneyUI.swift and the
/// Liquid Glass layer in HoneyGlass.swift.
public enum Honey {
    /// A color token: its light and dark values as 0xRRGGBB, and the values
    /// used while the system asks for more contrast (7:1 text, WCAG 1.4.6).
    public struct Token: Sendable, Equatable {
        public let light: UInt32
        public let dark: UInt32
        public let hcLight: UInt32
        public let hcDark: UInt32

        public init(light: UInt32, dark: UInt32, hcLight: UInt32? = nil, hcDark: UInt32? = nil) {
            self.light = light
            self.dark = dark
            self.hcLight = hcLight ?? light
            self.hcDark = hcDark ?? dark
        }

        /// The value for a dark and high-contrast setting.
        public func value(dark isDark: Bool, highContrast: Bool) -> UInt32 {
            switch (isDark, highContrast) {
            case (false, false): light
            case (true, false): dark
            case (false, true): hcLight
            case (true, true): hcDark
            }
        }
    }

    // MARK: Colors (§3), the same values as Ting.

    public static let canvas = Token(light: 0xF5EEE1, dark: 0x16120E, hcLight: 0xFAF6EE, hcDark: 0x000000)
    public static let surface = Token(light: 0xFFFCF6, dark: 0x251F18, hcLight: 0xFFFFFF, hcDark: 0x0B0907)
    public static let surface2 = Token(light: 0xF2E8D6, dark: 0x30281F, hcLight: 0xF2EBDF, hcDark: 0x1A1510)
    public static let surface3 = Token(light: 0xEADCC4, dark: 0x3B3127, hcLight: 0xE6DCCB, hcDark: 0x262019)
    public static let line = Token(light: 0xE8DAC3, dark: 0x3A3027, hcLight: 0x6B5A4E, hcDark: 0xA89684)
    public static let fg = Token(light: 0x3B2A2F, dark: 0xF6ECE0, hcLight: 0x1A0F12, hcDark: 0xFFFFFF)
    public static let fgMuted = Token(light: 0x76615A, dark: 0xB5A492, hcLight: 0x3F302B, hcDark: 0xE5D8C8)
    public static let accent = Token(light: 0xE09A2D, dark: 0xF2A93B)
    public static let accentFg = Token(light: 0x2A1A08, dark: 0x2A1A08, hcLight: 0x1A0F04, hcDark: 0x1A0F04)
    public static let accentInk = Token(light: 0x995A05, dark: 0xF5B656, hcLight: 0x6B3E00, hcDark: 0xFFC978)
    public static let accentSoft = Token(light: 0xFBE7C2, dark: 0x47331A)
    public static let focus = Token(light: 0xB8700E, dark: 0xF2A93B, hcLight: 0x6B3E00, hcDark: 0xFFC978)
    public static let danger = Token(light: 0xC2412D, dark: 0xFF8A70, hcLight: 0x8A2412, hcDark: 0xFFB3A0)
    public static let dangerFill = Token(light: 0xC2381C, dark: 0xC8432A, hcLight: 0x8E2410, hcDark: 0x8E2410)
    public static let ok = Token(light: 0x357A4E, dark: 0x7FD09A, hcLight: 0x1F5634, hcDark: 0xA6E8BC)

    // MARK: Editor colors (new in Kiri)

    /// Selected text background; `fg` on it stays ≥ 7:1.
    public static let selection = Token(light: 0xF6D9A0, dark: 0x5C4220, hcLight: 0xF2C97A, hcDark: 0x6B4A1C)
    /// The line with the caret, a step between `surface` and `surface-2`.
    public static let currentLine = Token(light: 0xFAF3E6, dark: 0x2C251D, hcLight: 0xF7F0E2, hcDark: 0x16120E)
    /// Line numbers: incidental text, ≥ 3:1 on `surface` and `currentLine`;
    /// with more contrast they use the `fg-muted` values.
    public static let gutter = Token(light: 0x9A8478, dark: 0x7E6E60, hcLight: 0x3F302B, hcDark: 0xE5D8C8)
    /// The caret is the `focus` color (≥ 3:1 on `surface`).
    public static let caret = focus

    /// Every color token by its DESIGN.md name, for the gallery and tests.
    public static let allTokens: [(name: String, token: Token)] = [
        ("canvas", canvas), ("surface", surface), ("surface-2", surface2), ("surface-3", surface3),
        ("line", line), ("fg", fg), ("fg-muted", fgMuted), ("accent", accent), ("accent-fg", accentFg),
        ("accent-ink", accentInk), ("accent-soft", accentSoft), ("focus", focus), ("danger", danger),
        ("danger-fill", dangerFill), ("ok", ok), ("selection", selection), ("current-line", currentLine),
        ("gutter", gutter),
    ]

    /// WCAG contrast ratio of two 0xRRGGBB colors.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ c: UInt32) -> Double {
            func ch(_ s: UInt32) -> Double {
                let v = Double((c >> s) & 0xFF) / 255
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch(16) + 0.7152 * ch(8) + 0.0722 * ch(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: Shape (§5)

    /// Corner radii: 20 panels, 16 cards, 12 controls, 8 small; pills use `Capsule`.
    public enum Radius: Sendable, CaseIterable {
        case panel, card, control, small

        public var value: Double {
            switch self {
            case .panel: 20
            case .card: 16
            case .control: 12
            case .small: 8
            }
        }
    }

    /// Space between floating panels and around the window edge.
    public static let gap = 10.0

    // MARK: Motion (§7)

    /// Color, opacity and hover fills.
    public static let quick = 0.14
    /// Small movement: toolbars, tooltips, chips.
    public static let medium = 0.24
    /// Shape changes, panels, dialogs.
    public static let shape = 0.38
    /// Spring response and damping that match cubic-bezier(.34, 1.56, .64, 1).
    public static let springResponse = 0.38
    public static let springDamping = 0.72
    /// How long a "Saved" confirmation stays before the button returns (§7.2).
    public static let doneHold = 1.5

    // MARK: Type (§4)

    /// Type scale in points: caption, meta, body, panel title, view title, heading.
    public static let typeScale: [Double] = [12, 13, 15, 17, 20, 26]
    /// The editor's default monospace size.
    public static let editorFontSize = 13.0
}

/// How much the interface animates. `system` follows the OS reduce-motion switch.
public enum HoneyMotionLevel: String, CaseIterable, Sendable {
    case system, full, reduced, off
    public var label: String { rawValue.capitalized }
}

/// Light, dark, or whatever the OS uses.
public enum HoneyTheme: String, CaseIterable, Sendable {
    case system, light, dark
    public var label: String { rawValue.capitalized }
}

/// The person's appearance preferences.
public struct HoneyAppearance: Equatable, Sendable {
    public var theme: HoneyTheme
    public var motion: HoneyMotionLevel

    public init(theme: HoneyTheme = .system, motion: HoneyMotionLevel = .system) {
        self.theme = theme
        self.motion = motion
    }

    /// Whether to cut animation down, given the OS reduce-motion setting.
    public func reduced(systemReduceMotion: Bool) -> Bool {
        switch motion {
        case .full: false
        case .reduced, .off: true
        case .system: systemReduceMotion
        }
    }
}
