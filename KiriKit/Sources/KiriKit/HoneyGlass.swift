#if canImport(SwiftUI)
import SwiftUI

// Liquid Glass in Honey (docs/DESIGN.md §2): chrome floats as warm glass over
// the canvas and the document, while the text people read stays on a solid
// `surface` panel. Glass is tinted from the Honey tokens so it reads cream in
// light mode and brown in dark, never cold grey.
//
// With "Reduce transparency" or "Increase contrast" on, every glass surface
// falls back to the solid Honey fill with a hairline, so nothing depends on
// blur to be legible.

/// The kinds of Honey glass.
public enum HoneyGlass: Sendable {
    /// Toolbars, tab strips, status bars: clear glass with a cream/brown tint.
    case chrome
    /// Something selected or active: glass with a soft amber tint.
    case honey
    /// Primary actions: amber glass, `accent-fg` text on top.
    case prominent
    /// Glass in any color, with the text color to use on it.
    case tinted(Color, foreground: Color)

    /// The Liquid Glass material.
    func glass(interactive: Bool) -> Glass {
        let tint: Color = switch self {
        case .chrome: Color.honeySurface.opacity(0.35)
        case .honey: Color.honeyAccent.opacity(0.32)
        case .prominent: Color.honeyAccent
        case .tinted(let c, _): c
        }
        return Glass.regular.tint(tint).interactive(interactive)
    }

    /// The solid fill used when transparency is reduced.
    var solid: Color {
        switch self {
        case .chrome: .honeySurface2
        case .honey: .honeyAccentSoft
        case .prominent: .honeyAccent
        case .tinted(let c, _): c
        }
    }

    /// The text and icon color on this glass.
    public var foreground: Color {
        switch self {
        case .chrome, .honey: .honeyFg
        case .prominent: .honeyAccentFg
        case .tinted(_, let fg): fg
        }
    }
}

public extension View {
    /// Puts this view on Honey glass in `shape`. `interactive` makes the glass
    /// react to the pointer and presses (use it for controls).
    func honeyGlass<S: Shape>(_ kind: HoneyGlass = .chrome, in shape: S, interactive: Bool = false) -> some View {
        modifier(HoneyGlassModifier(kind: kind, shape: shape, interactive: interactive))
    }

    /// Puts this view on Honey glass in a capsule.
    func honeyGlass(_ kind: HoneyGlass = .chrome, interactive: Bool = false) -> some View {
        honeyGlass(kind, in: Capsule(), interactive: interactive)
    }

    /// Honey glass in a rounded rectangle with a Honey radius.
    func honeyGlass(_ kind: HoneyGlass = .chrome, radius: Honey.Radius, interactive: Bool = false) -> some View {
        honeyGlass(kind, in: RoundedRectangle(cornerRadius: radius.value, style: .continuous), interactive: interactive)
    }
}

private struct HoneyGlassModifier<S: Shape>: ViewModifier {
    let kind: HoneyGlass
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(kind.solid, in: shape)
                .overlay(shape.stroke(Color.honeyLine, lineWidth: contrast == .increased ? 2 : 1))
        } else {
            content.glassEffect(kind.glass(interactive: interactive), in: shape)
        }
    }
}

/// Groups glass surfaces so they blend and morph into each other when they
/// come close (a `GlassEffectContainer` with the Honey gap as spacing).
public struct HoneyGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(spacing: CGFloat = Honey.gap, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) { content }
    }
}

// MARK: Buttons

/// Glass buttons with the Honey press squish (§7.3): pressed buttons scale to
/// 0.96 and their corners tighten; releasing springs back.
public struct HoneyGlassButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// A chrome glass pill.
        case chrome
        /// An amber glass pill for the primary action.
        case prominent
        /// A round chrome glass icon button.
        case icon
    }

    let kind: Kind

    public init(_ kind: Kind = .chrome) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        HoneyGlassButton(configuration: configuration, kind: kind)
    }
}

public extension ButtonStyle where Self == HoneyGlassButtonStyle {
    /// A chrome glass pill.
    static var honeyGlass: HoneyGlassButtonStyle { HoneyGlassButtonStyle(.chrome) }
    /// An amber glass pill for the primary action.
    static var honeyProminent: HoneyGlassButtonStyle { HoneyGlassButtonStyle(.prominent) }
    /// A round glass icon button.
    static var honeyIcon: HoneyGlassButtonStyle { HoneyGlassButtonStyle(.icon) }
}

private struct HoneyGlassButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: HoneyGlassButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    private static let height: CGFloat = 30

    /// An icon button shows its icon alone but keeps its title as its name:
    /// the system's icon-only style gives it to VoiceOver, where a style
    /// that just leaves the title out makes a button with no name.
    @ViewBuilder private var label: some View {
        if kind == .icon {
            configuration.label.labelStyle(.iconOnly).font(.system(size: 13, weight: .semibold))
        } else {
            configuration.label.labelStyle(HoneyButtonLabelStyle()).font(.honey(.subheadline, weight: .bold))
        }
    }

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        let pressed = configuration.isPressed && !motion.reduced
        let glass: HoneyGlass = kind == .prominent ? .prominent : .chrome
        // A pill is a rounded rectangle at half the height; pressing tightens it.
        let shape = RoundedRectangle(cornerRadius: pressed ? Self.height * 0.36 : Self.height / 2, style: .continuous)
        label
            .foregroundStyle(glass.foreground)
            .padding(.horizontal, kind == .icon ? 0 : 14)
            .frame(minWidth: Self.height, minHeight: Self.height)
            .contentShape(shape)
            .honeyGlass(glass, in: shape, interactive: isEnabled)
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(motion.shape, value: configuration.isPressed)
    }
}

/// Icon and title with Honey spacing.
private struct HoneyButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .bold))
            configuration.title
        }
    }
}
#endif
