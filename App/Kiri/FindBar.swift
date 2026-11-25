import KiriKit
import SwiftUI

// The bars that float over the top of the editor panel as warm glass, one
// at a time: find and replace (⌘F) here, and the command palette
// (`CommandPalette`, ⌘K; Go to Line, ⌘L, is its `:` mode). Chrome is glass
// and the document is paper (DESIGN.md §1), so neither pushes the text down;
// the editor scrolls what they point at clear of them instead (`reveal`).

/// What the bars share.
enum EditorBar {
    /// From the top of the editor panel to the bar.
    static let topPadding: CGFloat = 12
    /// Air between a bar and what the editor brings into sight below it.
    static let clearance: CGFloat = 8
    /// The least a bar keeps to the panel's sides.
    static let sideMargin: CGFloat = 12
}

/// Find and replace: a glass bar with the query, the count, match case and
/// regular expression, previous and next, and a chevron that opens the
/// replace row. All of it is `FindController`'s; this only shows it.
struct FindBar: View {
    @Bindable var find: FindController
    /// Draws that field as focused, for pictures made offscreen.
    var sampleFocus: Field?
    @FocusState private var focus: Field?
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Field: Hashable {
        case query, replacement
    }

    private static let rowHeight: CGFloat = 30
    private static let rowGap: CGFloat = 4
    private static let inset: CGFloat = 4

    static func height(replace: Bool) -> CGFloat {
        inset * 2 + rowHeight + (replace ? rowGap + rowHeight : 0)
    }

    /// How much of the editor's top the bar covers, with air below it.
    static func obstruction(replace: Bool) -> CGFloat {
        EditorBar.topPadding + height(replace: replace) + EditorBar.clearance
    }

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduceMotion)
        // Fields in one column and buttons in the next, so Tab goes from
        // the find field to the replace field and then to the buttons.
        HStack(alignment: .top, spacing: 4) {
            Color.clear.frame(width: BarButton.size, height: Self.rowHeight)
            VStack(spacing: Self.rowGap) {
                queryField
                if find.showsReplace { replacementField.transition(.opacity) }
            }
            VStack(alignment: .leading, spacing: Self.rowGap) {
                HStack(spacing: 2) {
                    Toggle(isOn: $find.options.matchCase) { Text("Aa") }
                        .toggleStyle(BarToggleStyle())
                        .help("Match case")
                        .accessibilityLabel("Match Case")
                    Toggle(isOn: $find.options.regularExpression) { Text(".*").font(.honeyMono(size: 12, weight: .bold)) }
                        .toggleStyle(BarToggleStyle())
                        .help("Regular expression")
                        .accessibilityLabel("Regular Expression")
                    Button { find.step(forward: false) } label: { Label("Previous Match", systemImage: "chevron.up") }
                        .buttonStyle(BarButtonStyle())
                        .modifier(BarFocusRing())
                        .disabled(!find.hasMatches)
                        .help("Previous match (⇧⌘G)")
                    Button { find.step(forward: true) } label: { Label("Next Match", systemImage: "chevron.down") }
                        .buttonStyle(BarButtonStyle())
                        .modifier(BarFocusRing())
                        .disabled(!find.hasMatches)
                        .help("Next match (⌘G)")
                    Button { find.close() } label: { Label("Close Find", systemImage: "xmark") }
                        .buttonStyle(BarButtonStyle())
                        .modifier(BarFocusRing())
                        .help("Close (esc)")
                }
                .frame(height: Self.rowHeight)
                if find.showsReplace {
                    HStack(spacing: 4) {
                        Button("Replace") { find.replaceCurrent() }
                            .buttonStyle(BarButtonStyle(filled: true))
                            .modifier(BarFocusRing())
                            .disabled(!find.hasMatches)
                            .help("Replace this match and find the next")
                        Button("Replace All") { find.replaceAll() }
                            .buttonStyle(BarButtonStyle(filled: true))
                            .modifier(BarFocusRing())
                            .disabled(!find.hasMatches)
                            .help("Replace every match")
                    }
                    .frame(height: Self.rowHeight)
                    .transition(.opacity)
                }
            }
            .fixedSize()
        }
        // The chevron sits before the fields but comes after them (and the
        // other buttons) for Tab and VoiceOver.
        .overlay(alignment: .topLeading) {
          if find.isReadOnly {
            // A large file, read-only: nothing to replace.
            Image(systemName: "lock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.honeyMuted)
                .frame(width: 26, height: Self.rowHeight)
                .help("Read-only: large files can be searched, not changed")
                .accessibilityLabel("Read-only")
          } else {
            Button { find.showsReplace.toggle() } label: {
                // The chevron turns; without motion it is simply the other one.
                Label(find.showsReplace ? "Hide Replace" : "Show Replace",
                      systemImage: motion.reduced && find.showsReplace ? "chevron.down" : "chevron.right")
                    .rotationEffect(.degrees(!motion.reduced && find.showsReplace ? 90 : 0))
            }
            .buttonStyle(BarButtonStyle())
            .modifier(BarFocusRing())
            .help(find.showsReplace ? "Hide replace" : "Show replace (⌥⌘F)")
            .frame(height: Self.rowHeight)
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, Self.inset)
        .frame(maxWidth: 560)
        .honeyGlass(.chrome, radius: .control)
        .padding(.horizontal, EditorBar.sideMargin)
        .animation(motion.shape, value: find.showsReplace)
        .onExitCommand { find.close() }
        .onChange(of: find.focusRequest, initial: true) { focus = .query }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
    }

    private var queryField: some View {
        well(.query) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold))
                .foregroundStyle(isFocused(.query) ? Color.honeyAccentInk : Color.honeyMuted)
                .accessibilityHidden(true)
            BarTextField(prompt: "Find", text: $find.query)
                .focused($focus, equals: .query)
                .onKeyPress(phases: .down) { press in tab(press, from: .query) }
                // Return finds the next match, ⇧Return the one before.
                .onSubmit { find.step(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true) }
                .accessibilityLabel("Find")
            count
        }
    }

    private var replacementField: some View {
        well(.replacement) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .bold))
                .foregroundStyle(isFocused(.replacement) ? Color.honeyAccentInk : Color.honeyMuted)
                .accessibilityHidden(true)
            BarTextField(prompt: "Replace", text: $find.replacement)
                .focused($focus, equals: .replacement)
                .onKeyPress(phases: .down) { press in tab(press, from: .replacement) }
                .onSubmit { find.replaceCurrent() }
                .accessibilityLabel("Replace with")
        }
    }

    /// "3 of 12", in a width that stays put while the count changes.
    private var count: some View {
        ZStack(alignment: .trailing) {
            Text("Invalid pattern").hidden()
            Text(find.widestLabel).hidden()
            Text(find.label)
        }
        .font(.honey(.caption, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        // The words carry the state; the color only underlines it.
        .foregroundStyle(find.hasProblem ? Color.honeyDanger : Color.honeyMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(find.label)
        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
        .accessibilityHidden(find.label.isEmpty)
    }

    private func isFocused(_ field: Field) -> Bool { (focus ?? sampleFocus) == field }

    /// Tab and ⇧Tab in a field. Tab goes from the find field to the replace
    /// field and ⇧Tab back. At the ends, with Full Keyboard Access the
    /// buttons are next (after the fields); without it there is nothing
    /// else in the bar to go to, and the keyboard goes round within the
    /// bar instead of off into the document, where the next key typed
    /// would land on the match.
    private func tab(_ press: KeyPress, from field: Field) -> KeyPress.Result {
        // ⇧Tab arrives as the back-tab character.
        let back = press.key == KeyEquivalent("\u{19}") || press.key == .tab && press.modifiers.contains(.shift)
        guard back || press.key == .tab else { return .ignored }
        let wraps = !NSApp.isFullKeyboardAccessEnabled
        if field == .query, find.showsReplace, !back || wraps {
            focus = .replacement
        } else if field == .replacement, back || wraps {
            focus = .query
        } else if !wraps {
            return .ignored
        }
        return .handled
    }

    /// A field's place in the bar: a paper-colored well, with the Honey
    /// focus ring while the keyboard is in it.
    private func well<Content: View>(_ field: Field, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
        return HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(minWidth: 150, maxWidth: .infinity, minHeight: Self.rowHeight - 4, maxHeight: Self.rowHeight - 4)
            .background(Color.honeySurface.opacity(0.7), in: shape)
            // A hairline says where the field is; the focus ring, which one
            // the keyboard is in.
            .overlay {
                shape.strokeBorder(isFocused(field) ? Color.honeyFocus : Color.honeyLine, lineWidth: isFocused(field) ? 2 : 1)
            }
            .frame(height: Self.rowHeight)
    }
}

/// A bar's text field: plain, in the Honey UI face.
struct BarTextField: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.honeyOffscreen) private var offscreen

    var body: some View {
        if offscreen {
            // `ImageRenderer` can't draw a text field: its text stands in.
            Text(text.isEmpty ? prompt : text)
                .font(.honey(.body))
                .foregroundStyle(text.isEmpty ? Color.honeyMuted : Color.honeyFg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.honey(.body))
        }
    }
}

/// A button inside a glass bar: no glass of its own (never glass on glass),
/// a soft fill on hover and press, and for a toggle that is on an amber
/// pill with an outline, so the shape says it and not only the color.
private struct BarButtonStyle: ButtonStyle {
    var isOn = false
    /// A resting fill, for buttons that are words.
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        BarButton(configuration: configuration, isOn: isOn, filled: filled)
    }
}

private struct BarButton: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let filled: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// At least the 24 pt a pointer target needs.
    static let size: CGFloat = 26

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduceMotion)
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
        configuration.label
            .labelStyle(.iconOnly)
            .font(.honey(.caption, weight: .bold))
            .imageScale(.small)
            .foregroundStyle(isOn ? Color.honeyAccentInk : Color.honeyFg)
            .padding(.horizontal, filled ? 10 : 0)
            .frame(minWidth: Self.size, minHeight: Self.size)
            .background(fill(pressed: pressed), in: shape)
            .overlay { shape.strokeBorder(Color.honeyAccent, lineWidth: isOn ? 1 : 0) }
            .contentShape(shape)
            .scaleEffect(pressed && !motion.reduced ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(motion.quick, value: hovering)
            .animation(motion.quick, value: isOn)
    }

    private func fill(pressed: Bool) -> Color {
        if isOn { return .honeyAccentSoft }
        if pressed { return Color.honeyFg.opacity(0.16) }
        if hovering, isEnabled { return Color.honeyFg.opacity(0.09) }
        return filled ? Color.honeyFg.opacity(0.05) : .clear
    }
}

/// Match case and regular expression: buttons that stay down.
private struct BarToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(BarButtonStyle(isOn: configuration.isOn))
            .modifier(BarFocusRing())
            .accessibilityValue(configuration.isOn ? "on" : "off")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// The Honey focus ring around a bar button while the keyboard is on it.
private struct BarFocusRing: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
                    .strokeBorder(Color.honeyFocus, lineWidth: focused ? 2 : 0)
                    .allowsHitTesting(false)
            }
    }
}
