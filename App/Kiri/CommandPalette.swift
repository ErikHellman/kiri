import KiriKit
import SwiftUI

/// The command palette (⌘K): the third of the bars that float over the top
/// of the editor panel, one at a time, with the find bar's glass, radius
/// and focus ring. A field, and under it in the same panel what the field
/// finds. All of it is `PaletteController`'s; this only shows it.
struct CommandPalette: View {
    @Bindable var palette: PaletteController
    /// How many rows there is room for under the field (a short window
    /// shows fewer than `Self.mostRows`).
    var rowsThatFit = CommandPalette.mostRows
    @FocusState private var focused: Bool
    @Environment(\.honeyOffscreen) private var offscreen

    static let width: CGFloat = 520
    static let fieldHeight: CGFloat = 38
    static let rowHeight: CGFloat = 30
    /// Above and below the rows, inside the panel.
    static let listInset: CGFloat = 5
    /// More rows than this scroll.
    static let mostRows = 8

    /// How many rows a panel `height` tall has room for, between the top
    /// of the panel and the status capsule at its bottom.
    static func rowsThatFit(in height: CGFloat) -> Int {
        let room = height - EditorBar.topPadding - fieldHeight - 2 * listInset - 1
            - EditorStatusBar.bottomPadding - HoneyStatusMetrics.barHeight - EditorBar.clearance
        return min(mostRows, max(2, Int(room / rowHeight)))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.control.value, style: .continuous)
        VStack(spacing: 0) {
            field
            if !palette.rows.isEmpty || palette.emptyMessage != nil {
                Rectangle().fill(Color.honeyLine).frame(height: 1)
                if let message = palette.emptyMessage {
                    Text(message)
                        .font(.honey(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.honeyMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 2 * Self.listInset + 12)
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: Self.width)
        .honeyGlass(.chrome, in: shape)
        .overlay { shape.strokeBorder(Color.honeyFocus, lineWidth: 2).allowsHitTesting(false) }
        .padding(.horizontal, EditorBar.sideMargin)
        // Not `onAppear`: a palette that is opened again while it is still
        // leaving is the same view and would not get the keyboard.
        .onChange(of: palette.focusRequest, initial: true) { focused = true }
        // And once more a turn after it is there: asked for as it
        // appears, the keyboard is sometimes not given (seen after other
        // windows have come and gone), and what is typed next would land
        // in the document. (`PaletteController` asks again too, should
        // the field still not have it.)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { palette.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.honeyAccentInk)
                .accessibilityHidden(true)
            BarTextField(prompt: "Search commands", text: $palette.text)
                .focused($focused)
                // The arrows move through the rows while the keyboard
                // stays in the field.
                .onKeyPress(.upArrow) { palette.move(by: -1); return .handled }
                .onKeyPress(.downArrow) { palette.move(by: 1); return .handled }
                .onKeyPress(.pageUp) { palette.move(by: -rowsThatFit); return .handled }
                .onKeyPress(.pageDown) { palette.move(by: rowsThatFit); return .handled }
                .onSubmit { palette.commit() }
                .accessibilityLabel("Command palette")
                .accessibilityHint("Type to search. Up and Down Arrow choose a result, Return runs it.")
        }
        .padding(.horizontal, 14)
        .frame(height: Self.fieldHeight)
    }

    @ViewBuilder private var list: some View {
        let shown = min(palette.rows.count, rowsThatFit)
        let height = CGFloat(shown) * Self.rowHeight + 2 * Self.listInset
        if offscreen {
            // `ImageRenderer` draws no scroll view: the rows that show.
            VStack(spacing: 0) {
                ForEach(Array(palette.rows.prefix(shown).enumerated()), id: \.element.id) { index, row in
                    PaletteRowView(row: row, selected: index == palette.selection) { palette.run(row) }
                }
            }
            .padding(.vertical, Self.listInset)
            .padding(.horizontal, 6)
            .frame(height: height)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(palette.rows.enumerated()), id: \.element.id) { index, row in
                            PaletteRowView(row: row, selected: index == palette.selection) { palette.run(row) }
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, Self.listInset)
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.automatic)
                .frame(height: height)
                // The selected row is kept in sight; nothing glides there.
                .onChange(of: palette.selection) { _, now in
                    if palette.rows.indices.contains(now) { proxy.scrollTo(palette.rows[now].id) }
                }
                .onChange(of: palette.rows.first?.id) { _, first in
                    if let first { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
    }
}

/// One row: an icon, the title with the letters that were typed marked in
/// it, a muted detail, and at the trailing edge a command's key in the
/// Keyboard Shortcuts window's key caps. The selected row has the capsule
/// the sidebar's current file has.
private struct PaletteRowView: View {
    let row: PaletteRow
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // In a panel too narrow for all of it (the editor beside the
            // sidebar in a small window) the detail goes, never the key.
            ViewThatFits(in: .horizontal) {
                content(detail: true)
                content(detail: false)
            }
            .padding(.leading, 8)
            .padding(.trailing, row.shortcut == nil ? 10 : 5)
            .frame(height: CommandPalette.rowHeight - 2)
            .background {
                if selected {
                    Capsule().fill(Color.honeyAccentSoft)
                } else if hovering {
                    Capsule().fill(Color.honeySurface2.opacity(0.7))
                }
            }
            .frame(height: CommandPalette.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false) // the field keeps the keyboard
        // The pointer shows what a click would run; it selects nothing.
        .onHover { hovering = $0 }
        .accessibilityLabel(row.spoken)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func content(detail: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.tint.map { Color.honey($0.token) } ?? Color.honeyMuted)
                .frame(width: 16)
            Text(Self.marked(row.title, row.titleMarks, size: .subheadline, ink: .honeyFg))
                .lineLimit(1)
                .truncationMode(.middle)
            if detail, !row.detail.isEmpty {
                Text(Self.marked(row.detail, row.detailMarks, size: .caption, ink: .honeyMuted))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shortcut = row.shortcut { KeyCaps(shortcut.glyphs) }
        }
    }

    /// `text` with the typed letters marked: heavier and in full ink, the
    /// rest a little lighter in both, so the mark never rests on color.
    /// Nothing marked is the plain text.
    static func marked(_ text: String, _ marks: [Range<Int>], size: Font.TextStyle, ink: Color) -> AttributedString {
        let plain = Font.honey(size, weight: .semibold)
        guard !marks.isEmpty else {
            var whole = AttributedString(text)
            whole.font = plain
            whole.foregroundColor = ink
            return whole
        }
        var out = AttributedString()
        let units = text.utf16
        var at = 0
        func piece(_ range: Range<Int>, marked: Bool) {
            guard !range.isEmpty, let from = units.index(units.startIndex, offsetBy: range.lowerBound, limitedBy: units.endIndex),
                  let to = units.index(units.startIndex, offsetBy: range.upperBound, limitedBy: units.endIndex),
                  let part = String(units[from..<to]) else { return }
            var run = AttributedString(part)
            run.font = marked ? Font.honey(size, weight: .heavy) : plain
            run.foregroundColor = marked ? Color.honeyFg : ink.opacity(0.8)
            out += run
        }
        for mark in marks where mark.lowerBound >= at {
            piece(at..<mark.lowerBound, marked: false)
            piece(mark, marked: true)
            at = mark.upperBound
        }
        piece(at..<units.count, marked: false)
        return out
    }
}
