#if canImport(SwiftUI)
import AppKit
import SwiftUI

// Honey components for Kiri, built on the tokens, motion and glass layers.
// Each follows a DESIGN.md signature where one fits: shape tells state, the
// selection pill slides, busy squeezes into a circle and opens into "done".

// MARK: Tab strip

/// An item of a tab's context menu.
public struct HoneyTabAction: Identifiable {
    public let title: String
    public var enabled: Bool
    public let action: () -> Void
    public var id: String { title }

    public init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }
}

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
    /// A preview: the tab the next file looked at will take over. Its
    /// title slants until it is kept (a double-click, an edit, a save).
    public var preview: Bool
    /// It shows beside the selected tab, in the other side of a split
    /// window: a quieter fill than the selection's, and a small split
    /// glyph where the close button would be.
    public var beside: Bool

    public init(id: ID, title: String, detail: String? = nil, tooltip: String? = nil, dirty: Bool = false,
                preview: Bool = false, beside: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tooltip = tooltip
        self.dirty = dirty
        self.preview = preview
        self.beside = beside
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
    let onKeep: ((ID) -> Void)?
    let onDragOut: ((ID) -> Void)?
    let onOptionClick: ((ID) -> Void)?
    let menu: ((ID) -> [[HoneyTabAction]])?
    let scrollOffset: Binding<CGFloat>?
    @Namespace private var pill
    @FocusState private var focused: ID?
    // periphery:ignore - used as $position
    @State private var position = ScrollPosition(x: 0)
    @State private var scrolled = HoneyScrollOffset()
    /// The tab `onDragOut` was called for, in the drag under way.
    @GestureState private var dragging: ID?
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.honeyOffscreen) private var offscreen

    /// - Parameter scrollOffset: where a strip that scrolls is scrolled to,
    ///   kept by the owner, so that a strip that is made again starts where
    ///   the last one was.
    /// - Parameter onKeep: a preview tab was double-clicked (or VoiceOver's
    ///   Keep Open chosen): it is to become a tab like any other.
    /// - Parameter onDragOut: a tab is being pulled up or down out of the
    ///   strip, to be dragged to another window or out on its own. Called
    ///   once per drag, while the mouse is still down: the owner starts the
    ///   drag from there.
    /// - Parameter onOptionClick: a tab was clicked with Option held (in
    ///   place of selecting it).
    /// - Parameter menu: a tab's context menu, in groups (a divider
    ///   between two).
    public init(_ tabs: [HoneyTab<ID>], selection: Binding<ID>, scrollOffset: Binding<CGFloat>? = nil,
                onClose: ((ID) -> Void)? = nil, onKeep: ((ID) -> Void)? = nil, onDragOut: ((ID) -> Void)? = nil,
                onOptionClick: ((ID) -> Void)? = nil, menu: ((ID) -> [[HoneyTabAction]])? = nil) {
        self.tabs = tabs
        _selection = selection
        self.scrollOffset = scrollOffset
        self.onClose = onClose
        self.onKeep = onKeep
        self.onDragOut = onDragOut
        self.onOptionClick = onOptionClick
        self.menu = menu
    }

    /// How far a tab is pulled across the strip before it comes out of it.
    static var dragOutDistance: CGFloat { 18 }

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
        /// Where the strip has to be to show tab `id` whole, coming from `offset`.
        func offset(showing id: ID?, from offset: CGFloat) -> CGFloat {
            CGFloat(TabWidths.offset(showing: tabs.firstIndex { $0.id == id }, widths: layout.widths,
                                     spacing: Double(HoneyTabMetrics.spacing), viewport: Double(viewport),
                                     from: Double(offset)))
        }
        /// Scrolls there, at once.
        func reveal(_ id: ID?) {
            scrolled.go(to: offset(showing: id, from: scrollOffset?.wrappedValue ?? scrolled.x), with: $position)
        }
        // A strip that scrolls changes at once. A scroll view goes no
        // further than its content reaches at that moment, so while a
        // newly selected tab at the end was still growing to its width,
        // it could not be brought whole into view.
        let change = layout.overflows ? nil : motion.shape
        func settle(_ transaction: inout Transaction) {
            guard layout.overflows else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        return HStack(spacing: HoneyTabMetrics.spacing) {
            Group {
                if offscreen {
                    row(layout, motion)
                        .offset(x: -offset(showing: selection, from: 0))
                        .frame(width: viewport, alignment: .leading)
                        .clipped()
                } else {
                    ScrollView(.horizontal) { row(layout, motion) }
                        .scrollPosition($position)
                        .scrollIndicators(.hidden)
                        .scrollDisabled(!layout.overflows)
                        .frame(width: viewport)
                        .accessibilityLabel("Tabs")
                        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                            scrolled.x = x
                            scrollOffset?.wrappedValue = x
                        }
                        // The selected tab stays in view, and so does the
                        // one the keyboard is on. A strip that appears
                        // starts where the last one to show these tabs was.
                        .onAppear { reveal(selection) }
                        .onChange(of: selection) { reveal(selection) }
                        .onChange(of: ids) { reveal(selection) }
                        .onChange(of: viewport) { reveal(selection) }
                        .onChange(of: focused) { _, id in
                            if let id { reveal(id) }
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
        .animation(change, value: ids)
        .animation(change, value: selection)
        .transaction(value: ids) { settle(&$0) }
        .transaction(value: selection) { settle(&$0) }
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
                } keep: {
                    onKeep?(tab.id)
                }
                .simultaneousGesture(dragOut(tab.id), isEnabled: onDragOut != nil)
                .modifier(HoneyTabMenu(groups: menu.map { make in { make(tab.id) } }))
                .id(tab.id)
                // A new tab grows in from nothing and a closed one
                // collapses; with reduced motion they fade.
                .transition(motion.reduced ? .opacity : AnyTransition(HoneyTabGrow()))
            }
        }
    }

    private func select(_ id: ID, _ motion: HoneyMotion) {
        // ⌥-click: the owner's (Open to the Side), not a selection.
        if let onOptionClick, NSEvent.modifierFlags.contains(.option) {
            onOptionClick(id)
            return
        }
        withAnimation(motion.shape) { selection = id }
    }

    /// A tab pulled across the strip's edge (`onDragOut`).
    private func dragOut(_ id: ID) -> some Gesture {
        // Gesture state: it is reset however the drag ends, also when the
        // owner's drag takes the mouse from it.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragging) { value, state, _ in
                guard abs(value.translation.height) > Self.dragOutDistance, state != id else { return }
                state = id
                onDragOut?(id)
            }
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
            Toggle(tab.name(separator: TabText.detailSeparator) + (tab.dirty ? " •" : tab.preview ? " (preview)" : ""),
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

}

/// Where a strip's scroll view is, kept out of view state (following it
/// must not redraw the strip on every point scrolled), and where it was
/// last sent.
@MainActor private final class HoneyScrollOffset {
    var x: CGFloat = 0
    private var wanted: CGFloat?
    private var asked = 0

    /// Scrolls to `target`, and sees that it got there. A scroll view
    /// that isn't laid out yet (its window was just shown, or is still
    /// taking in its tabs) drops the request, and one for the same place
    /// as the last counts as no change: so each differs by a hair, and is
    /// made again for a moment until the scroll view is there.
    func go(to target: CGFloat, with position: Binding<ScrollPosition>, tries: Int = 0) {
        wanted = target
        guard abs(target - x) > 0.25 else { return }
        asked += 1
        position.wrappedValue.scrollTo(x: target + (asked.isMultiple(of: 2) ? 0.01 : 0))
        guard tries < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.wanted == target else { return }
            self.go(to: target, with: position, tries: tries + 1)
        }
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
    let keep: () -> Void
    @State private var hovering = false
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// The close button shows: on hover, and on the selected tab unless its
    /// place is taken by the dirty dot.
    private var closes: Bool { closable && (hovering || (selected && !tab.dirty)) }

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        let room = HoneyTabMetrics.titleRoom(width: width, slotInUse: closes || tab.dirty || tab.beside)
        let text = HoneyTabMetrics.text(tab, selected: selected, room: room)
        // A real button: Tab reaches it with Keyboard Navigation on, Space
        // or Return selects, and VoiceOver hears a button with its state.
        Button(action: select) {
            Text("\(title(text.title))\(folder(text.detail))")
                .font(.honey(.subheadline, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected || tab.beside ? Color.honeyFg : Color.honeyMuted)
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
                    } else if tab.beside {
                        // Shown, but the keyboard is on the other side: a
                        // quieter fill than the selection's.
                        Capsule().fill(Color.honeySurface2.opacity(hovering ? 1 : 0.85))
                    } else if hovering {
                        Capsule().fill(Color.honeySurface2.opacity(0.7))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(HoneyTabButtonStyle())
        // A double-click keeps a preview. Beside the button, not in its
        // place: the first click selects at once, as on any tab.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if tab.preview { keep() } })
        .focused(focused, equals: tab.id)
        .focusEffectDisabled()
        .onKeyPress(.return) { select(); return .handled }
        .accessibilityLabel(tab.name(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue([tab.beside ? "Beside" : nil, tab.dirty ? "Edited" : tab.preview ? "Preview" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: "Close") { close() }
        .modifier(HoneyTabKeepAction(preview: tab.preview, keep: keep))
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

    /// A preview's title slants: it is not here to stay.
    private func title(_ title: String) -> Text {
        tab.preview ? Text(title).font(.honeyOblique(.subheadline, weight: selected ? .bold : .semibold)) : Text(title)
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
        } else if tab.beside {
            // The other side of the split shows it.
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.honeyMuted)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// A tab's context menu, when the strip's owner gives one.
private struct HoneyTabMenu: ViewModifier {
    let groups: (() -> [[HoneyTabAction]])?

    func body(content: Content) -> some View {
        if let groups {
            content.contextMenu {
                let made = groups()
                ForEach(made.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    ForEach(made[index]) { item in
                        Button(item.title, action: item.action).disabled(!item.enabled)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// "Keep Open" for VoiceOver and Voice Control, on a preview tab only.
private struct HoneyTabKeepAction: ViewModifier {
    let preview: Bool
    let keep: () -> Void

    func body(content: Content) -> some View {
        if preview {
            content.accessibilityAction(named: "Keep Open", keep)
        } else {
            content
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

/// A primary button for async work such as saving. Shape tells state
/// (`HoneyTaskState.Look`): with nothing to do it rests as a chrome glass
/// circle with the icon alone; with work waiting (`pending`: unsaved
/// changes) it springs open into the amber pill; busy is a circle with a
/// spinner, done a green check with `doneLabel`. Set `.done` back to
/// `.idle` after `Honey.doneHold` seconds.
///
/// VoiceOver hears `title` in every state, with the state as its value
/// ("Unsaved changes", "No unsaved changes", "Saving", "Saved").
public struct HoneyTaskButton: View {
    let title: String
    let systemImage: String
    let doneLabel: String
    let busyLabel: String
    let pendingLabel: String
    let restingLabel: String
    let state: HoneyTaskState
    let pending: Bool
    let action: () -> Void
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// The height of every look, and the width of the round ones: the
    /// icon buttons' size, so a resting Save sits level with them.
    public static let height: CGFloat = 30

    /// - Parameter pending: there is work for the button to do. A button
    ///   that always has (the default) is the pill whenever it is idle.
    public init(_ title: String, systemImage: String, doneLabel: String = "Saved", busyLabel: String = "Saving",
                pendingLabel: String = "Unsaved changes", restingLabel: String = "No unsaved changes",
                state: HoneyTaskState, pending: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.doneLabel = doneLabel
        self.busyLabel = busyLabel
        self.pendingLabel = pendingLabel
        self.restingLabel = restingLabel
        self.state = state
        self.pending = pending
        self.action = action
    }

    public var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        let look = state.look(pending: pending)
        Button(action: action) {
            content(look).frame(height: Self.height)
        }
        .buttonStyle(HoneyTaskButtonStyle(look: look))
        .disabled(state == .busy)
        // The spring for the outline (a quick ease when reduced, nothing
        // when off); what is inside fades.
        .animation(motion.shape, value: look)
        .accessibilityLabel(title)
        .accessibilityValue(value(look))
    }

    private func value(_ look: HoneyTaskState.Look) -> String {
        switch look {
        case .resting: restingLabel
        case .pill: pendingLabel
        case .busy: busyLabel
        case .done: doneLabel
        case .failed: "Failed"
        }
    }

    @ViewBuilder private func content(_ look: HoneyTaskState.Look) -> some View {
        switch look {
        case .resting, .pill:
            // One icon for both, so it glides from the middle of the
            // circle to its place in the pill while the title fades in.
            HStack(spacing: HoneyTaskButtonStyle.labelSpacing) {
                Image(systemName: systemImage)
                    .font(look == .pill ? nil : .system(size: 13, weight: .semibold))
                if look == .pill { Text(title).fixedSize().transition(.opacity) }
            }
            .frame(minWidth: look == .pill ? nil : Self.height)
            .transition(.opacity)
        case .busy:
            ProgressView().controlSize(.small).tint(Color.honeyAccentFg).frame(width: Self.height).transition(.opacity)
        case .done:
            Label(doneLabel, systemImage: "checkmark").foregroundStyle(Color.honeyOK).transition(.opacity)
        case .failed:
            Label("Try again", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.honeyDanger)
                .transition(.opacity)
        }
    }
}

private struct HoneyTaskButtonStyle: ButtonStyle {
    let look: HoneyTaskState.Look
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// Between the pill's icon and its title, as a `Label` sets them.
    static let labelSpacing: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        let pressed = configuration.isPressed && !motion.reduced
        let idle = look == .pill || look == .resting
        // Resting and busy are circles, done a rounded rectangle, the pill a pill.
        let radius: CGFloat = switch look {
        case .busy: 15
        case .done, .failed: 10
        case .pill, .resting: pressed ? 11 : 15
        }
        // Amber is for work: waiting (the pill) or under way.
        let glass: HoneyGlass = look == .pill || look == .busy ? .prominent : .chrome
        configuration.label
            .font(.honey(.subheadline, weight: .bold))
            .foregroundStyle(glass.foreground)
            .padding(.horizontal, look == .busy || look == .resting ? 0 : 14)
            .honeyGlass(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: idle)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(motion.shape, value: configuration.isPressed)
    }
}

// MARK: Status bar

/// A floating glass status bar for the bottom of the editor. Its items
/// bring their own side padding (`HoneyStatusMetrics`), so those that can
/// be pressed have room for the capsule they show on hover.
///
/// `resting` fades it to `Honey.restOpacity`, glass and all, for while the
/// person works in the text it floats over. (The fade is done in here, on
/// the content and by swapping the glass for a faint fill: drawn offscreen,
/// an opacity put on the glass view from outside changed nothing.)
public struct HoneyStatusBar<Content: View>: View {
    let resting: Bool
    let content: Content

    public init(resting: Bool = false, @ViewBuilder content: () -> Content) {
        self.resting = resting
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { content }
            .font(.honey(.caption, weight: .semibold))
            .foregroundStyle(Color.honeyMuted)
            .padding(.horizontal, HoneyStatusMetrics.inset)
            .frame(height: HoneyStatusMetrics.barHeight)
            .opacity(resting ? Honey.restOpacity : 1)
            .honeyGlass(.chrome, in: Capsule(), resting: resting)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Status bar")
    }
}

/// The status bar's measures.
public enum HoneyStatusMetrics {
    public static let barHeight: CGFloat = 28
    /// Between the bar's capsule and an item's.
    static let inset: CGFloat = 2
    /// An item's height: the least a pointer target may be.
    static let itemHeight: CGFloat = 24
    /// Beside an item's text.
    static let side: CGFloat = 9
    /// A menu's chevron, the gap before it and the room after it. The room
    /// is always there, so the bar keeps its width when the chevron shows.
    static let chevron: CGFloat = 7
    static let chevronGap: CGFloat = 3
    static let chevronTrailing: CGFloat = 6
    static var menuTrailing: CGFloat { chevronGap + chevron + chevronTrailing }
    /// The pill of an accent item at rest: 20 pt high around its text.
    static let pillInset: CGFloat = 2
    static var pillTrailingInset: CGFloat { menuTrailing - (side - pillInset) }
}

/// What a status item that can be pressed shows while the pointer or the
/// keyboard is on it. Given to an item, it draws that state for a picture.
public enum HoneyStatusHighlight: Sendable {
    case hover, focus
}

/// An icon and a short value in the status bar's type, in the room of the
/// widest texts it may show (`reserving`), so its neighbours stay put.
private struct HoneyStatusText: View {
    let text: String
    var systemImage: String?
    var reserving: [String] = []
    var alignment = Alignment.leading

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
            ZStack(alignment: alignment) {
                ForEach(reserving, id: \.self) { Text($0).hidden().accessibilityHidden(true) }
                Text(text)
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// A muted status item that does nothing when pressed: an optional icon
/// and a short value.
public struct HoneyStatusItem: View {
    let text: String
    let systemImage: String?
    let reserving: [String]

    /// - Parameter reserving: the widest texts the item may come to show;
    ///   it keeps their room and centres `text` in it.
    public init(_ text: String, systemImage: String? = nil, reserving: [String] = []) {
        self.text = text
        self.systemImage = systemImage
        self.reserving = reserving
    }

    public var body: some View {
        HoneyStatusText(text: text, systemImage: systemImage, reserving: reserving, alignment: .center)
            .padding(.horizontal, HoneyStatusMetrics.side)
            .frame(height: HoneyStatusMetrics.itemHeight)
    }
}

/// A status item that opens a menu. On hover, and while the keyboard is on
/// it, it shows a `surface-2` capsule (the tabs' hover) and a chevron; an
/// `.accent` item is a small amber pill at rest, which grows to take the
/// chevron in. VoiceOver hears "`name`, `text`, menu button".
public struct HoneyStatusMenu<Items: View>: View {
    let text: String
    let name: String
    let tone: HoneyPill.Tone
    let showing: HoneyStatusHighlight?
    let onFocusChange: ((Bool) -> Void)?
    let items: Items
    @Environment(\.honeyOffscreen) private var offscreen

    /// - Parameters:
    ///   - text: the value shown, such as "UTF-8".
    ///   - name: what the value is, such as "Encoding".
    public init(_ text: String, name: String, tone: HoneyPill.Tone = .neutral, showing: HoneyStatusHighlight? = nil,
                onFocusChange: ((Bool) -> Void)? = nil, @ViewBuilder items: () -> Items) {
        self.text = text
        self.name = name
        self.tone = tone
        self.showing = showing
        self.onFocusChange = onFocusChange
        self.items = items()
    }

    public var body: some View {
        Group {
            if offscreen {
                // `ImageRenderer` can't draw a menu button: its label stands in.
                label
            } else {
                Menu { items } label: { label }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        // The capsule, chevron and ring are drawn around the menu button,
        // not in its label.
        .modifier(HoneyStatusChrome(tone: tone, chevron: true, showing: showing, onFocusChange: onFocusChange))
        // A menu button with a name: one whose label is a view of its own
        // has none, whatever label it is given.
        .accessibilityRepresentation {
            // (Its items are the menu's, not elements of the bar.)
            Menu("\(name), \(text)") { items }.accessibilityChildren { EmptyView() }
        }
    }

    private var label: some View {
        HoneyStatusText(text: text)
            .font(.honey(.caption, weight: tone == .accent ? .heavy : .semibold))
            .foregroundStyle(tone == .accent ? Color.honeyAccentInk : Color.honeyMuted)
            .padding(.leading, HoneyStatusMetrics.side)
            .padding(.trailing, HoneyStatusMetrics.menuTrailing)
            .frame(height: HoneyStatusMetrics.itemHeight)
            .contentShape(Capsule())
    }
}

/// A status item that does something when pressed, with the hover capsule
/// and focus ring of `HoneyStatusMenu`. With `chevron` it looks like a
/// menu (for an item that opens a picker of its own), and an `.accent` one
/// is the same small amber pill at rest.
public struct HoneyStatusButton: View {
    let text: String
    let systemImage: String?
    let reserving: [String]
    let tone: HoneyPill.Tone
    let chevron: Bool
    let showing: HoneyStatusHighlight?
    let onFocusChange: ((Bool) -> Void)?
    let action: () -> Void

    /// - Parameter reserving: the widest texts the item may come to show;
    ///   it keeps their room, with `text` at its leading edge.
    public init(_ text: String, systemImage: String? = nil, reserving: [String] = [], tone: HoneyPill.Tone = .neutral,
                chevron: Bool = false, showing: HoneyStatusHighlight? = nil, onFocusChange: ((Bool) -> Void)? = nil,
                action: @escaping () -> Void) {
        self.text = text
        self.systemImage = systemImage
        self.reserving = reserving
        self.tone = tone
        self.chevron = chevron
        self.showing = showing
        self.onFocusChange = onFocusChange
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            label
                .padding(.leading, HoneyStatusMetrics.side)
                .padding(.trailing, chevron ? HoneyStatusMetrics.menuTrailing : HoneyStatusMetrics.side)
                .frame(height: HoneyStatusMetrics.itemHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(HoneyStatusButtonStyle())
        .modifier(HoneyStatusChrome(tone: tone, chevron: chevron, showing: showing, onFocusChange: onFocusChange))
    }

    @ViewBuilder private var label: some View {
        let value = HoneyStatusText(text: text, systemImage: systemImage, reserving: reserving)
        if tone == .accent {
            value.font(.honey(.caption, weight: .heavy)).foregroundStyle(Color.honeyAccentInk)
        } else {
            value
        }
    }
}

/// The hover capsule says the item can be pressed; pressing dims its text.
private struct HoneyStatusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Around a status item that can be pressed: the capsule and (for a menu)
/// the chevron on hover and keyboard focus, and the Honey focus ring.
private struct HoneyStatusChrome: ViewModifier {
    let tone: HoneyPill.Tone
    let chevron: Bool
    let showing: HoneyStatusHighlight?
    let onFocusChange: ((Bool) -> Void)?
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let active = hovering || focused || showing != nil
        content
            .focused($focused)
            .focusEffectDisabled()
            .background { fill(active: active) }
            .overlay(alignment: .trailing) {
                if chevron {
                    Image(systemName: "chevron.down").font(.system(size: HoneyStatusMetrics.chevron, weight: .heavy))
                        .foregroundStyle(tone == .accent ? Color.honeyAccentInk : Color.honeyMuted)
                        .frame(width: HoneyStatusMetrics.chevron)
                        .padding(.trailing, HoneyStatusMetrics.chevronTrailing)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                Capsule().strokeBorder(Color.honeyFocus, lineWidth: focused || showing == .focus ? 2 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .onChange(of: focused) { _, now in onFocusChange?(now) }
            // An item that goes away with the keyboard on it (the bar laid
            // out anew for a narrower panel) gives it up.
            .onDisappear { if focused { onFocusChange?(false) } }
            .animation(HoneyMotion(appearance, systemReduced: reduce).quick, value: active)
    }

    @ViewBuilder private func fill(active: Bool) -> some View {
        if tone == .accent {
            // The pill it is at rest grows into the hover capsule.
            Capsule().fill(Color.honeyAccentSoft)
                .padding(.leading, active ? 0 : HoneyStatusMetrics.pillInset)
                .padding(.trailing, active ? 0 : HoneyStatusMetrics.pillTrailingInset)
                .padding(.vertical, active ? 0 : HoneyStatusMetrics.pillInset)
        } else if active {
            // On a bar that is solid `surface-2` (reduce transparency,
            // increase contrast) the hover is a step darker.
            Capsule().fill(reduceTransparency || contrast == .increased ? Color.honeySurface3 : Color.honeySurface2.opacity(0.7))
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
    @FocusState private var ownFocus: Bool
    /// The caller's, to put the keyboard in the field (Settings ▸ Shortcuts).
    private let externalFocus: FocusState<Bool>.Binding?
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
        externalFocus = nil
    }

    /// A field whose keyboard focus is the caller's `focused`.
    public init(_ prompt: String, text: Binding<String>, focused: FocusState<Bool>.Binding) {
        self.prompt = prompt
        _text = text
        externalFocus = focused
    }

    private var focusBinding: FocusState<Bool>.Binding { externalFocus ?? $ownFocus }
    private var focused: Bool { focusBinding.wrappedValue }

    public var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold))
                .foregroundStyle(focused ? Color.honeyAccentInk : Color.honeyMuted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.honey(.body))
                .focused(focusBinding)
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
