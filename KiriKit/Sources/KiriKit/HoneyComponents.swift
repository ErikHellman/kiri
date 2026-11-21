#if canImport(SwiftUI)
import SwiftUI

// Honey components for Kiri, built on the tokens, motion and glass layers.
// Each follows a DESIGN.md signature where one fits: shape tells state, the
// selection pill slides, busy squeezes into a circle and opens into "done".

// MARK: Tab strip

/// One open document in the tab strip.
public struct HoneyTab<ID: Hashable & Sendable>: Identifiable, Sendable {
    public let id: ID
    public var title: String
    /// Unsaved changes: shows a dot that turns into the close button on hover.
    public var dirty: Bool

    public init(id: ID, title: String, dirty: Bool = false) {
        self.id = id
        self.title = title
        self.dirty = dirty
    }
}

/// Open documents as a glass strip, with an amber pill that slides to the
/// selected tab (§7.4).
public struct HoneyTabStrip<ID: Hashable & Sendable>: View {
    let tabs: [HoneyTab<ID>]
    @Binding var selection: ID
    let onClose: ((ID) -> Void)?
    @Namespace private var pill
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(_ tabs: [HoneyTab<ID>], selection: Binding<ID>, onClose: ((ID) -> Void)? = nil) {
        self.tabs = tabs
        _selection = selection
        self.onClose = onClose
    }

    public var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                HoneyTabItem(tab: tab, selected: tab.id == selection, pill: pill, closable: onClose != nil) {
                    withAnimation(motion.shape) { selection = tab.id }
                } close: {
                    onClose?(tab.id)
                }
            }
        }
        .padding(3)
        .honeyGlass(.chrome)
    }
}

private struct HoneyTabItem<ID: Hashable & Sendable>: View {
    let tab: HoneyTab<ID>
    let selected: Bool
    let pill: Namespace.ID
    let closable: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        HStack(spacing: 6) {
            Text(tab.title)
                .font(.honey(.subheadline, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Color.honeyFg : Color.honeyMuted)
                .lineLimit(1)
            trailing
                .frame(width: 14, height: 14)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background {
            if selected {
                Capsule().fill(Color.honeyAccentSoft)
                    .matchedGeometryEffect(id: "selection", in: pill)
            } else if hovering {
                Capsule().fill(Color.honeySurface2.opacity(0.7))
            }
        }
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(motion.quick) { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(tab.dirty ? "Edited" : "")
        .accessibilityAction(named: "Close") { close() }
    }

    /// Dirty dot, or the close button on hover (shape tells state, §1).
    @ViewBuilder private var trailing: some View {
        if closable && (hovering || (selected && !tab.dirty)) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.honeyMuted)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .help("Close")
        } else if tab.dirty {
            Circle().fill(Color.honeyAccent).frame(width: 7, height: 7)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: Segmented picker

/// A Honey segmented control: a glass capsule with a sliding amber pill (§7.4).
public struct HoneySegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var pill
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(_ options: [(value: Value, label: String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Text(option.label)
                    .font(.honey(.subheadline, weight: .bold))
                    .foregroundStyle(selected ? Color.honeyAccentFg : Color.honeyMuted)
                    // Segments always fit their labels; never truncate.
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        if selected {
                            Capsule().fill(Color.honeyAccent).matchedGeometryEffect(id: "selection", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(motion.shape) { selection = option.value } }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .fixedSize()
        .honeyGlass(.chrome)
        // Keyboard: Tab focuses it with Keyboard Navigation on, as it does a
        // button, and ← → move. (Plain `focusable()` would also take focus,
        // and show its ring, on a click or when its window opens.)
        .focusable(interactions: .activate)
        .onKeyPress(.leftArrow) { step(-1, motion) }
        .onKeyPress(.rightArrow) { step(1, motion) }
    }

    private func step(_ by: Int, _ motion: HoneyMotion) -> KeyPress.Result {
        guard let i = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = min(max(i + by, 0), options.count - 1)
        guard next != i else { return .handled }
        withAnimation(motion.shape) { selection = options[next].value }
        return .handled
    }
}

public extension HoneySegmentedPicker where Value: CaseIterable & RawRepresentable, Value.RawValue == String {
    /// A picker over every case of a string enum, labelled with its capitalized raw value.
    init(selection: Binding<Value>) {
        self.init(Value.allCases.map { (value: $0, label: $0.rawValue.capitalized) }, selection: selection)
    }
}

// MARK: Busy → done button

/// The state of an action that does async work (§7.2).
public enum HoneyTaskState: Sendable, Equatable {
    case idle, busy, done, failed
}

/// A primary button for async work such as saving: an amber pill while idle,
/// a circle with a spinner while busy, a green check with `doneLabel` when
/// done. Set `.done` back to `.idle` after `Honey.doneHold` seconds.
public struct HoneyTaskButton: View {
    let title: String
    let systemImage: String
    let doneLabel: String
    let state: HoneyTaskState
    let action: () -> Void
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(_ title: String, systemImage: String, doneLabel: String = "Saved", state: HoneyTaskState,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.doneLabel = doneLabel
        self.state = state
        self.action = action
    }

    public var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        Button(action: action) {
            content.frame(height: 30)
        }
        .buttonStyle(HoneyTaskButtonStyle(state: state))
        .disabled(state == .busy)
        .animation(motion.shape, value: state)
        .accessibilityLabel(state == .done ? doneLabel : title)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            Label(title, systemImage: systemImage).transition(.opacity)
        case .busy:
            ProgressView().controlSize(.small).tint(Color.honeyAccentFg).frame(width: 30).transition(.opacity)
        case .done:
            Label(doneLabel, systemImage: "checkmark").foregroundStyle(Color.honeyOK).transition(.opacity)
        case .failed:
            Label("Try again", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.honeyDanger)
                .transition(.opacity)
        }
    }
}

private struct HoneyTaskButtonStyle: ButtonStyle {
    let state: HoneyTaskState
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        let pressed = configuration.isPressed && !motion.reduced
        // Busy is a circle, done a rounded rectangle, idle a pill.
        let radius: CGFloat = switch state {
        case .busy: 15
        case .done, .failed: 10
        case .idle: pressed ? 11 : 15
        }
        let glass: HoneyGlass = state == .idle || state == .busy ? .prominent : .chrome
        configuration.label
            .font(.honey(.subheadline, weight: .bold))
            .foregroundStyle(glass.foreground)
            .padding(.horizontal, state == .busy ? 0 : 14)
            .honeyGlass(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: state == .idle)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(motion.shape, value: configuration.isPressed)
    }
}

// MARK: Status bar

/// A floating glass status bar for the bottom of the editor.
public struct HoneyStatusBar<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: 14) { content }
            .font(.honey(.caption, weight: .semibold))
            .foregroundStyle(Color.honeyMuted)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .honeyGlass(.chrome)
    }
}

/// A muted status item: an optional icon and a short value.
public struct HoneyStatusItem: View {
    let text: String
    let systemImage: String?

    public init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
            Text(text).monospacedDigit()
        }
    }
}

// MARK: Pill

/// A small label pill: a file type, a badge, a state.
public struct HoneyPill: View {
    public enum Tone: Sendable { case accent, neutral, ok, danger }

    let text: String
    let systemImage: String?
    let tone: Tone

    public init(_ text: String, systemImage: String? = nil, tone: Tone = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .heavy)) }
            Text(text).font(.honey(.caption, weight: .heavy))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .accent: .honeyAccentInk
        case .neutral: .honeyMuted
        case .ok: .honeyOK
        case .danger: .honeyDanger
        }
    }

    private var background: Color {
        switch tone {
        case .accent: .honeyAccentSoft
        case .neutral, .ok, .danger: .honeySurface2
        }
    }
}

// MARK: Search field

/// A glass search field with the Honey focus ring (§12), for find and the
/// quick-open palette.
public struct HoneySearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    public var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold))
                .foregroundStyle(focused ? Color.honeyAccentInk : Color.honeyMuted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.honey(.body))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.honeyMuted)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .honeyGlass(.chrome, radius: .control)
        .overlay {
            RoundedRectangle(cornerRadius: Honey.Radius.control.value, style: .continuous)
                .strokeBorder(Color.honeyFocus, lineWidth: focused ? 2 : 0)
        }
        .animation(motion.quick, value: focused)
        .animation(motion.shape, value: text.isEmpty)
    }
}

// MARK: Toast

/// A short floating message, such as "Saved to Desktop".
public struct HoneyToast: View {
    let text: String
    let systemImage: String

    public init(_ text: String, systemImage: String = "checkmark.circle.fill") {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(Color.honeyAccentInk)
            Text(text).font(.honey(.subheadline, weight: .bold))
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .honeyGlass(.chrome)
    }
}

public extension AnyTransition {
    /// Toasts and popovers: rise and scale in with the spring.
    static var honeyPop: AnyTransition {
        .scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: 8))
    }
}

// MARK: Empty state

/// A friendly empty state: a honey drop, a heading and one line of help (§9).
public struct HoneyEmptyState: View {
    let title: String
    let message: String
    @State private var twinkle = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Ellipse().fill(Color.honeySurface2).frame(width: 96, height: 12).offset(y: 48)
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.honeySurface3)
                    .frame(width: 64, height: 80).rotationEffect(.degrees(-8)).offset(x: -14)
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.honeySurface)
                    .frame(width: 64, height: 80).rotationEffect(.degrees(6)).offset(x: 10)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                Image(systemName: "drop.fill").font(.system(size: 30)).foregroundStyle(Color.honeyAccent)
                    .offset(x: 10, y: 6)
                Image(systemName: "sparkle").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.honeyAccent)
                    .offset(x: -58, y: -36).scaleEffect(twinkle ? 0.7 : 1)
                Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.honeyAccent)
                    .offset(x: 56, y: -30).scaleEffect(twinkle ? 1 : 0.7)
            }
            .frame(width: 160, height: 120)
            .accessibilityHidden(true)
            Text(title).font(.honey(.largeTitle, weight: .heavy)).multilineTextAlignment(.center)
            Text(message).font(.honey(.body)).foregroundStyle(Color.honeyMuted).multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding()
        .onAppear {
            guard !HoneyMotion(appearance, systemReduced: reduce).reduced else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever()) { twinkle = true }
        }
    }
}

// MARK: Section label

/// An uppercase section label (§4): 11.5 pt, heavy, tracked.
public struct HoneySectionLabel: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.honeySectionLabel)
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(Color.honeyMuted)
    }
}
#endif
