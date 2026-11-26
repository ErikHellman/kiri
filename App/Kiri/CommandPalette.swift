import KiriKit
import SwiftUI

/// The command palette (⌘K) and the language picker (⌃⌘L): the third of
/// the bars that float over the top of the editor panel, one at a time,
/// with the find bar's glass, radius and focus ring. A field, and under it
/// in the same panel what the field finds. All of it is
/// `PaletteController`'s; this only shows it.
struct CommandPalette: View {
    @Bindable var palette: PaletteController
    /// The document's lines, for `:` mode ("of 340").
    var lineCount = 1
    /// How many rows there is room for under the field (a short window
    /// shows fewer than `Self.mostRows`).
    var rowsThatFit = CommandPalette.mostRows
    /// How wide the editor panel is: in a narrow one (beside the sidebar
    /// in a small window) the field's prompt is one word.
    var panelWidth: CGFloat = 900
    @FocusState private var focused: Bool
    @Environment(\.honeyOffscreen) private var offscreen

    static let width: CGFloat = 520
    static let fieldHeight: CGFloat = 38
    static let rowHeight: CGFloat = 30
    /// Above and below the rows, inside the panel.
    static let listInset: CGFloat = 5
    /// More rows than this scroll.
    static let mostRows = 8

    /// How much of the editor's top the palette covers while a line is
    /// typed (`:` mode: the field and one line under it), with air below
    /// it. The editor shows the line that is typed clear of that.
    static var lineObstruction: CGFloat {
        EditorBar.topPadding + fieldHeight + 1 + rowHeight + 2 * listInset + EditorBar.clearance
    }

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
            if let status = palette.lineStatus {
                Rectangle().fill(Color.honeyLine).frame(height: 1)
                lineRow(status)
            } else if !palette.rows.isEmpty || palette.emptyMessage != nil {
                Rectangle().fill(Color.honeyLine).frame(height: 1)
                if let message = palette.emptyMessage {
                    Text(message)
                        .font(.honey(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.honeyMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 2 * Self.listInset + 12)
                } else {
                    list
                }
            }
            // ⌥ held on a file or a tab: what ⌥↩ does.
            if palette.optionHeld, palette.selectedOpensToSide, palette.lineStatus == nil, !palette.toSide {
                Rectangle().fill(Color.honeyLine).frame(height: 1)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Image(systemName: "rectangle.righthalf.inset.filled").font(.system(size: 10, weight: .semibold))
                    Text("⌥↩ to the side").font(.honey(.caption, weight: .semibold))
                }
                .foregroundStyle(Color.honeyMuted)
                .padding(.horizontal, 14)
                .frame(height: 24)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Option Return opens it to the side")
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
        .accessibilityLabel(name)
    }

    /// What the field says before anything is typed, and what VoiceOver
    /// calls the panel.
    private var name: String { palette.kind == .language ? "Language picker" : "Command palette" }

    private var prompt: String {
        if palette.kind == .language { return panelWidth < 360 ? "Language" : "Search languages by name or file extension" }
        if palette.toSide { return panelWidth < 360 ? "To the side" : "A file or tab to show to the side" }
        return panelWidth < 360 ? "Search" : "Search files, tabs and commands"
    }

    private var symbol: String {
        if palette.kind == .language { return "chevron.left.forwardslash.chevron.right" }
        return palette.mode == .line ? "arrow.right.to.line" : "magnifyingglass"
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.honeyAccentInk)
                .frame(width: 16)
                .accessibilityHidden(true)
            BarTextField(prompt: prompt, text: $palette.text)
                .focused($focused)
                // The arrows move through the rows while the keyboard
                // stays in the field.
                .onKeyPress(.upArrow) { palette.move(by: -1); return .handled }
                .onKeyPress(.downArrow) { palette.move(by: 1); return .handled }
                .onKeyPress(.pageUp) { palette.move(by: -rowsThatFit); return .handled }
                .onKeyPress(.pageDown) { palette.move(by: rowsThatFit); return .handled }
                // ⌥↩: a file or a tab to the side (before the field takes
                // it as a line break).
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.option), palette.selectedOpensToSide else { return .ignored }
                    palette.commit(toSide: true)
                    return .handled
                }
                .onSubmit { palette.commit() }
                .accessibilityLabel(name)
                .accessibilityHint(palette.kind == .language
                    ? "Type to search. Up and Down Arrow choose a language and show it, Return keeps it."
                    : "Type to search. Up and Down Arrow choose a result, Return runs it.")
            // A big folder's first reading: its files are on their way.
            if palette.isReadingFolder {
                Text("Reading the folder…")
                    .font(.honey(.caption, weight: .semibold))
                    .foregroundStyle(Color.honeyMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.fieldHeight)
    }

    /// `:` mode: in place of the list, one line that says where Return
    /// goes ("Go to line 42"), what to type, or "Not a line", and how far
    /// the lines go. Where Return goes it is a row like any other, selected.
    private func lineRow(_ status: PaletteController.LineStatus) -> some View {
        Button { palette.commit() } label: {
            // In a narrow panel the count goes first, then the words get shorter.
            ViewThatFits(in: .horizontal) {
                lineContent(status, text: status.text, count: true)
                lineContent(status, text: status.text, count: false)
                lineContent(status, text: status.short ?? status.text, count: false)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: Self.rowHeight - 2)
            .background { if status.isTarget { Capsule().fill(Color.honeyAccentSoft) } }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        // (Not disabled, which would dim words that are there to be read:
        // with nowhere to go, a click simply does nothing.)
        .allowsHitTesting(status.isTarget)
        .padding(.vertical, Self.listInset)
        .padding(.horizontal, 6)
        .accessibilityLabel("\(status.text), of \(lineCount) lines")
        .accessibilityAddTraits(status.isTarget ? .isSelected : [])
    }

    private func lineContent(_ status: PaletteController.LineStatus, text: String, count: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.isProblem ? "exclamationmark.circle" : "arrow.right.to.line")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.isProblem ? Color.honeyDanger : Color.honeyMuted)
                .frame(width: 16)
            Text(text)
                .font(.honey(.subheadline, weight: .semibold))
                // The words say it; the color only underlines it.
                .foregroundStyle(status.isProblem ? Color.honeyDanger : status.isTarget ? Color.honeyFg : Color.honeyMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if count {
                Text("of \(lineCount)")
                    .font(.honey(.caption, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.honeyMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
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
                    .padding(.horizontal, 6)
                }
                // The air above the first row and below the last is the
                // scroll view's own, so a row scrolled to keeps it.
                .contentMargins(.vertical, Self.listInset, for: .scrollContent)
                .scrollIndicators(.automatic)
                .frame(height: height)
                // The selected row is kept in sight; nothing glides there.
                // A new list starts at its top.
                .onChange(of: [palette.rows.first?.id ?? "", String(palette.rows.count), String(palette.selection)]) {
                    keepSelectionInSight(proxy)
                }
                // The panel opens with its rows already there (the language
                // picker with the document's language selected, far down the
                // list), so nothing changes for the line above to see: the
                // selection is brought into sight once the rows are laid out.
                .onAppear { DispatchQueue.main.async { keepSelectionInSight(proxy) } }
            }
        }
    }

    private func keepSelectionInSight(_ proxy: ScrollViewProxy) {
        let selection = palette.selection
        guard palette.rows.indices.contains(selection) else { return }
        if selection == 0 {
            proxy.scrollTo(palette.rows[0].id, anchor: .top)
        } else {
            proxy.scrollTo(palette.rows[selection].id)
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
            // sidebar in a small window) a file's folders shorten to the
            // nearest one, then the detail goes; never the key.
            ViewThatFits(in: .horizontal) {
                content(detail: row.detail, marks: row.detailMarks)
                if let short = row.shortDetail { content(detail: short, marks: []) }
                content(detail: "", marks: [])
            }
            .padding(.leading, 8)
            .padding(.trailing, row.shortcut == nil && !row.isCurrent ? 10 : 5)
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

    private func content(detail: String, marks: [Range<Int>]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.tint.map { Color.honey($0.token) } ?? Color.honeyMuted)
                .frame(width: 16)
            Text(Self.marked(row.title, row.titleMarks, size: .subheadline, ink: .honeyFg, rest: Color.honeyFg.opacity(0.8)))
                .lineLimit(1)
                .truncationMode(.middle)
            if !detail.isEmpty {
                // (Muted already: the rest of a marked detail is not made fainter still.)
                Text(Self.marked(detail, marks, size: .caption, ink: .honeyMuted, rest: .honeyMuted))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shortcut = row.shortcut {
                KeyCaps(shortcut.glyphs)
            } else if row.isCurrent {
                // The language the document has now.
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.honeyAccentInk)
                    .padding(.trailing, 2)
            }
        }
    }

    /// `text` with the typed letters marked: heavier and in full ink
    /// (`fg`), the rest lighter in both (`rest`), so the mark never rests
    /// on color. Nothing marked is the plain text in `ink`.
    static func marked(_ text: String, _ marks: [Range<Int>], size: Font.TextStyle, ink: Color, rest: Color) -> AttributedString {
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
            run.foregroundColor = marked ? Color.honeyFg : rest
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
