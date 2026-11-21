#if canImport(SwiftUI)
import AppKit
import SwiftUI

// Honey components for Kiri, built on the tokens, motion and glass layers.
// Each follows a DESIGN.md signature where one fits: shape tells state, the
// selection pill slides, busy squeezes into a circle and opens into "done".

// MARK: Tab strip

/// One open document in the tab strip.
public struct HoneyTab<ID: Hashable & Sendable>: Identifiable, Sendable {
    public let id: ID
    public var title: String
    /// What tells this tab from another with the same title, shown muted
    /// after it: the file's folder ("index.ts · api").
    public var detail: String?
    /// The tooltip: where the file is.
    public var tooltip: String?
    /// Unsaved changes: shows a dot that turns into the close button on hover.
    public var dirty: Bool

    public init(id: ID, title: String, detail: String? = nil, tooltip: String? = nil, dirty: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tooltip = tooltip
        self.dirty = dirty
    }

    /// The title and what tells it apart, for menus and VoiceOver.
    func name(separator: String) -> String {
        detail.map { title + separator + $0 } ?? title
    }
}

public extension EnvironmentValues {
    /// Set for pictures drawn with `ImageRenderer`, which leaves scroll
    /// views empty: the tab strip then lays its tabs out without one.
    @Entry var honeyOffscreen = false
}

/// Open documents as a glass strip, with an amber pill that slides to the
/// selected tab (§7.4).
///
/// The strip is as wide as its titles when there is room. With less, the
/// selected tab keeps its whole title and the others share the rest, their
/// names shortened in the middle; once they are down to their minimum the
/// strip scrolls inside its capsule and a button at its end lists every tab
/// (`TabWidths`, `TabText`).
public struct HoneyTabStrip<ID: Hashable & Sendable>: View {
    let tabs: [HoneyTab<ID>]
    @Binding var selection: ID
    let onClose: ((ID) -> Void)?
    @Namespace private var pill
    @FocusState private var focused: ID?
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.honeyOffscreen) private var offscreen

    public init(_ tabs: [HoneyTab<ID>], selection: Binding<ID>, onClose: ((ID) -> Void)? = nil) {
        self.tabs = tabs
        _selection = selection
        self.onClose = onClose
    }

    public var body: some View {
        let natural = tabs.map { HoneyTabMetrics.naturalWidth($0, selected: $0.id == selection) }
        let whole = natural.reduce(0) { $0 + min($1, HoneyTabMetrics.cap) }
            + HoneyTabMetrics.spacing * CGFloat(max(tabs.count - 1, 0)) + 2 * HoneyTabMetrics.inset
        // As wide as the titles, or as wide as there is room for.
        GeometryReader { geometry in
            strip(natural: natural, width: geometry.size.width)
        }
        .frame(maxWidth: whole)
        .frame(height: HoneyTabMetrics.height + 2 * HoneyTabMetrics.inset)
    }

    private func strip(natural: [CGFloat], width: CGFloat) -> some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        let layout = TabWidths.allocate(
            natural: natural.map(Double.init), minimum: tabs.map { Double(HoneyTabMetrics.minimumWidth($0)) },
            selected: tabs.firstIndex { $0.id == selection }, available: Double(width - 2 * HoneyTabMetrics.inset),
            spacing: Double(HoneyTabMetrics.spacing), cap: Double(HoneyTabMetrics.cap),
            overflowReserve: Double(HoneyTabMetrics.moreWidth + HoneyTabMetrics.spacing))
        let content = CGFloat(layout.contentWidth(spacing: Double(HoneyTabMetrics.spacing)))
        let viewport = layout.overflows ? CGFloat(layout.viewport) : content
        let ids = tabs.map(\.id)
        return HStack(spacing: HoneyTabMetrics.spacing) {
            Group {
                if offscreen {
                    row(layout, motion)
                        .offset(x: -HoneyTabMetrics.offsetShowing(tabs.firstIndex { $0.id == selection },
                                                                  widths: layout.widths, viewport: viewport))
                        .frame(width: viewport, alignment: .leading)
                        .clipped()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) { row(layout, motion) }
                            .scrollIndicators(.hidden)
                            .scrollDisabled(!layout.overflows)
                            .frame(width: viewport)
                            .accessibilityLabel("Tabs")
                            // The selected tab stays in view, and so does
                            // the one the keyboard is on.
                            .onChange(of: selection, initial: true) { old, new in
                                withAnimation(old == new ? nil : motion.shape) { proxy.scrollTo(new) }
                            }
                            .onChange(of: ids) { withAnimation(motion.shape) { proxy.scrollTo(selection) } }
                            .onChange(of: viewport) { proxy.scrollTo(selection) }
                            .onChange(of: focused) { _, id in
                                if let id { withAnimation(motion.quick) { proxy.scrollTo(id) } }
                            }
                    }
                }
            }
            // Tabs scrolled out of view end at the capsule's edge.
            .clipShape(Capsule())
            if layout.overflows {
                more(hidden: layout.hidden, motion)
            }
        }
        .padding(HoneyTabMetrics.inset)
        .honeyGlass(.chrome)
        // Tabs that open and close elsewhere (another window, a menu
        // command) move the strip as a click in it does.
        .animation(motion.shape, value: ids)
        .animation(motion.shape, value: selection)
    }

    private func row(_ layout: TabWidths.Result, _ motion: HoneyMotion) -> some View {
        HStack(spacing: HoneyTabMetrics.spacing) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                HoneyTabItem(tab: tab, width: index < layout.widths.count ? CGFloat(layout.widths[index]) : 0,
                             selected: tab.id == selection, pill: pill, closable: onClose != nil,
                             focused: $focused) {
                    select(tab.id, motion)
                } close: {
                    onClose?(tab.id)
                }
                .id(tab.id)
                // A new tab grows in from nothing and a closed one
                // collapses; with reduced motion they fade.
                .transition(motion.reduced ? .opacity : AnyTransition(HoneyTabGrow()))
            }
        }
    }

    private func select(_ id: ID, _ motion: HoneyMotion) {
        withAnimation(motion.shape) { selection = id }
    }

    /// "5 ⌄" at the end of a strip that scrolls: a menu of every tab, in
    /// order, for the ones out of view.
    private func more(hidden: Int, _ motion: HoneyMotion) -> some View {
        Menu {
            moreItems(motion)
        } label: {
            HStack(spacing: 3) {
                Text("\(hidden)").font(.honey(.caption, weight: .bold)).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(Color.honeyMuted)
            .frame(width: HoneyTabMetrics.moreWidth, height: HoneyTabMetrics.height)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(HoneyFocusRing())
        .help("All \(tabs.count) tabs")
        // A menu button with a name, in place of a bare number and arrow.
        .accessibilityRepresentation {
            Menu("All tabs, \(hidden) more") { moreItems(motion) }
        }
        .transition(.opacity)
    }

    /// Every tab, with a check on the selected one and a dot after the
    /// unsaved ones.
    private func moreItems(_ motion: HoneyMotion) -> some View {
        ForEach(tabs) { tab in
            Toggle(tab.name(separator: TabText.detailSeparator) + (tab.dirty ? " •" : ""),
                   isOn: Binding(get: { tab.id == selection }, set: { if $0 { select(tab.id, motion) } }))
        }
    }
}

/// The tab strip's measures, and its titles as they will be drawn.
@MainActor private enum HoneyTabMetrics {
    static let height: CGFloat = 26
    /// Between the capsule and the tabs.
    static let inset: CGFloat = 3
    static let spacing: CGFloat = 2
    /// Before the title, and after the trailing slot.
    static let leading: CGFloat = 12
    static let trailing: CGFloat = 8
    /// The dirty dot and the close button's glyph sit in a 14 pt slot after
    /// the title; the close button's hit area is 24 pt around the same centre.
    static let slot: CGFloat = 14
    static let slotGap: CGFloat = 6
    static let closeTarget: CGFloat = 24
    /// No tab's title makes it wider than this.
    static let cap: CGFloat = 220
    /// The narrowest a tab that isn't selected gets before the strip scrolls.
    static let minimum: CGFloat = 56
    static let moreWidth: CGFloat = 40

    /// Everything in a tab that isn't its title.
    static var chrome: CGFloat { leading + slotGap + slot + trailing }

    static func naturalWidth<ID>(_ tab: HoneyTab<ID>, selected: Bool) -> CGFloat {
        titleWidth(tab.title, selected: selected) + (tab.detail.map { detailWidth(TabText.detailSeparator + $0) } ?? 0) + chrome
    }

    /// A dirty tab keeps room for its dot beside the shortened title.
    static func minimumWidth<ID>(_ tab: HoneyTab<ID>) -> CGFloat {
        minimum + (tab.dirty ? slot + slotGap : 0)
    }

    /// The room for the title in a tab `width` wide. A tab with nothing in
    /// its trailing slot lends that room to a title that needs it.
    static func titleRoom(width: CGFloat, slotInUse: Bool) -> CGFloat {
        max(width - leading - (slotInUse ? slotGap + slot + trailing : leading), 0)
    }

    static func titleWidth(_ title: String, selected: Bool) -> CGFloat {
        HoneyText.width(title, weight: selected ? .bold : .semibold, size: 13)
    }

    /// The folder after a title is lighter than the title.
    static func detailWidth(_ detail: String) -> CGFloat {
        HoneyText.width(detail, weight: .regular, size: 13)
    }

    /// The title and its folder, shortened to `room` (`TabText`).
    static func text<ID>(_ tab: HoneyTab<ID>, selected: Bool, room: CGFloat) -> (title: String, detail: String?) {
        TabText.fit(title: tab.title, detail: tab.detail, width: Double(room),
                    measureTitle: { Double(titleWidth($0, selected: selected)) },
                    measureDetail: { Double(detailWidth($0)) })
    }

    /// How far a strip that can't scroll (an offscreen picture) is moved to
    /// show the selected tab: as little as a scroll view would.
    static func offsetShowing(_ selected: Int?, widths: [Double], viewport: CGFloat) -> CGFloat {
        guard let selected, selected < widths.count else { return 0 }
        let end = widths[...selected].reduce(0, +) + Double(spacing) * Double(selected)
        return max(CGFloat(end) - viewport, 0)
    }
}

/// Widths of Honey UI text, for layouts that have to know them before
/// SwiftUI lays the text out.
@MainActor enum HoneyText {
    private struct Key: Hashable {
        let text: String
        let weight: CGFloat
        let size: CGFloat
    }

    private static var widths: [Key: CGFloat] = [:]

    /// The width of `text` in Nunito at a Honey size (before `textScale`),
    /// rounded up to half a point, as SwiftUI sizes text on a Retina display.
    static func width(_ text: String, weight: NSFont.Weight, size: CGFloat) -> CGFloat {
        let size = size * Honey.textScale
        let key = Key(text: text, weight: weight.rawValue, size: size)
        if let known = widths[key] { return known }
        let family = NSFontDescriptor(fontAttributes: [.family: "Nunito"])
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        let font = NSFont(descriptor: family, size: size) ?? .systemFont(ofSize: size, weight: weight)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width * 2) / 2
        if widths.count > 4096 { widths.removeAll(keepingCapacity: true) }
        widths[key] = width
        return width
    }
}

private struct HoneyTabItem<ID: Hashable & Sendable>: View {
    let tab: HoneyTab<ID>
    let width: CGFloat
    let selected: Bool
    let pill: Namespace.ID
    let closable: Bool
    let focused: FocusState<ID?>.Binding
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// The close button shows: on hover, and on the selected tab unless its
    /// place is taken by the dirty dot.
    private var closes: Bool { closable && (hovering || (selected && !tab.dirty)) }

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        let room = HoneyTabMetrics.titleRoom(width: width, slotInUse: closes || tab.dirty)
        let text = HoneyTabMetrics.text(tab, selected: selected, room: room)
        // A real button: Tab reaches it with Keyboard Navigation on, Space
        // or Return selects, and VoiceOver hears a button with its state.
        Button(action: select) {
            Text("\(Text(text.title))\(folder(text.detail))")
                .font(.honey(.subheadline, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Color.honeyFg : Color.honeyMuted)
                .lineLimit(1)
                // Already shortened to fit, with the extension kept;
                // SwiftUI must not shorten it again its own way.
                .fixedSize()
                .padding(.leading, HoneyTabMetrics.leading)
                .frame(width: width, height: HoneyTabMetrics.height, alignment: .leading)
                .background {
                    if selected {
                        Capsule().fill(Color.honeyAccentSoft)
                            .matchedGeometryEffect(id: "selection", in: pill)
                    } else if hovering {
                        Capsule().fill(Color.honeySurface2.opacity(0.7))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(HoneyTabButtonStyle())
        .focused(focused, equals: tab.id)
        .focusEffectDisabled()
        .onKeyPress(.return) { select(); return .handled }
        .accessibilityLabel(tab.name(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(tab.dirty ? "Edited" : "")
        .accessibilityAction(named: "Close") { close() }
        .overlay {
            Capsule().strokeBorder(Color.honeyFocus, lineWidth: focused.wrappedValue == tab.id ? 2 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            trailing
                .frame(width: HoneyTabMetrics.closeTarget, height: HoneyTabMetrics.closeTarget)
                // Centred where the 14 pt slot is.
                .padding(.trailing, HoneyTabMetrics.trailing + HoneyTabMetrics.slot / 2 - HoneyTabMetrics.closeTarget / 2)
        }
        .onHover { h in withAnimation(motion.quick) { hovering = h } }
        .help(tab.tooltip ?? "")
    }

    /// " · api" after the title: lighter and muted, also on the selected tab.
    private func folder(_ detail: String?) -> Text {
        Text(detail.map { TabText.detailSeparator + $0 } ?? "")
            .font(.honey(.subheadline, weight: .regular))
            .foregroundStyle(Color.honeyMuted)
    }

    /// Dirty dot, or the close button on hover (shape tells state, §1).
    /// The glyph is 9 pt; the button takes clicks in the whole 24 pt square.
    @ViewBuilder private var trailing: some View {
        if closes {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.honeyMuted)
                    .frame(width: HoneyTabMetrics.closeTarget, height: HoneyTabMetrics.closeTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The tab itself carries the Close action, for VoiceOver and
            // the keyboard (⌘W); this one is for the pointer.
            .focusable(false)
            .accessibilityHidden(true)
            .transition(.scale.combined(with: .opacity))
            .help("Close")
        } else if tab.dirty {
            Circle().fill(Color.honeyAccent).frame(width: 7, height: 7)
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// A tab draws its own states (selected, hover, focus); pressing adds none.
private struct HoneyTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// A tab opening or closing: revealed from its leading edge while its
/// neighbours make room, so it reads as growing in from zero width.
private struct HoneyTabGrow: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .mask { Rectangle().scaleEffect(x: phase.isIdentity ? 1 : 0, anchor: .leading) }
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// The Honey focus ring (§12) around a capsule control, in place of the
/// system's, while the keyboard is on it.
private struct HoneyFocusRing: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                Capsule().strokeBorder(Color.honeyFocus, lineWidth: focused ? 2 : 0).allowsHitTesting(false)
            }
    }
}

// MARK: Segmented picker

/// A Honey segmented control: a glass capsule with a sliding amber pill (§7.4).
/// To VoiceOver it is a radio group; give it a name with `accessibilityLabel`.
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
            }
        }
        .padding(3)
        .fixedSize()
        .honeyGlass(.chrome)
        // VoiceOver and other assistive apps get the system's own radio
        // group in place of the hand-drawn segments: its buttons say their
        // label and whether they are selected, and pressing one selects it.
        .accessibilityRepresentation {
            Picker("", selection: Binding(get: { selection },
                                          set: { new in withAnimation(motion.shape) { selection = new } })) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].label).tag(options[i].value)
                }
            }
            .pickerStyle(.radioGroup)
            // In a row from the leading edge, so each button's frame (where
            // VoiceOver draws its cursor) lies roughly over its segment.
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .fixedSize()
        }
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
