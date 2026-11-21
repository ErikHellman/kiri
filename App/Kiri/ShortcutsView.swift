import KiriKit
import SwiftUI

/// Help ▸ Keyboard Shortcuts (⌘/): every feature and its keys, on Honey
/// cards over the canvas. Typing filters the list; Escape closes it.
struct ShortcutsView: View {
    static let windowID = "keyboard-shortcuts"

    /// The window's side margins.
    private static let margin: CGFloat = 20
    /// Between cards: wide enough for a card's shadow to fade out before
    /// the next card, where `Honey.gap` would show only its darkest part.
    private static let cardGap: CGFloat = 20

    #if DEBUG || KIRI_SELFTEST
    /// Screenshot helper: -KiriShortcutsFilter <text> opens the window filtered.
    @State private var filter = UserDefaults.standard.string(forKey: "KiriShortcutsFilter") ?? ""
    #else
    @State private var filter = ""
    #endif
    @Environment(\.dismiss) private var dismiss

    private var groups: [ShortcutGroup] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ShortcutGroup.all }
        return ShortcutGroup.all.compactMap { g in
            if g.title.localizedCaseInsensitiveContains(q) { return g }
            let items = g.items.filter { $0.title.localizedCaseInsensitiveContains(q) }
            return items.isEmpty ? nil : ShortcutGroup(title: g.title, systemImage: g.systemImage, items: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts").font(.honey(.largeTitle, weight: .heavy))
                    Text("Everything else is in the menu bar: ⌃F2 opens it, ⇧⌘/ searches it.")
                        .font(.honey(.subheadline)).foregroundStyle(Color.honeyMuted)
                }
                Spacer(minLength: 16)
                HoneySearchField("Filter", text: $filter).frame(width: 220)
            }
            .padding(.top, 34) // clear of the traffic lights
            .padding(.horizontal, Self.margin)

            if groups.isEmpty {
                HoneyEmptyState(title: "No match", message: "No shortcut is called “\(filter)”.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The scroll view runs to the window's edges and the margins
                // are inside it, so it doesn't cut the cards' shadows off.
                ScrollView {
                    MasonryColumns(minimumWidth: 300, spacing: Self.cardGap) {
                        ForEach(groups) { GroupCard(group: $0) }
                    }
                    .padding(.horizontal, Self.margin)
                    .padding(.top, 14)
                    .padding(.bottom, Self.margin + Honey.gap)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .honeyCanvas()
        .ignoresSafeArea(.container, edges: .top)
        .onExitCommand {
            if filter.isEmpty { dismiss() } else { filter = "" }
        }
    }
}

private struct GroupCard: View {
    let group: ShortcutGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                HoneySectionLabel(group.title)
            } icon: {
                Image(systemName: group.systemImage).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.honeyAccentInk)
            }
            .padding(.bottom, 2)
            ForEach(group.items) { item in
                HStack(spacing: 12) {
                    Text(item.title).font(.honey(.body))
                    Spacer(minLength: 8)
                    KeyCaps(item.keys)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .honeyPanel(radius: .card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }
}

/// Columns of equal width that pack by height: each view goes under the
/// shortest column so far, so cards of different heights leave no holes.
/// As many columns as fit at `minimumWidth`, like an adaptive grid.
private struct MasonryColumns: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat

    private func columns(in width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        return (count, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
    }

    /// Each subview's column and frame, and the height of the tallest column.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let (count, columnWidth) = columns(in: width)
        var bottoms = [CGFloat](repeating: 0, count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let y = bottoms[column] == 0 ? 0 : bottoms[column] + spacing
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            bottoms[column] = y + height
        }
        return (frames, bottoms.max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// Key caps for "⌘X  ⌘C  ⌘V" (chords split on double spaces), or a muted
/// note such as "Format menu".
struct KeyCaps: View {
    let chords: [String]
    let isNote: Bool

    init(_ keys: String) {
        chords = keys.components(separatedBy: "  ")
        // Words, not keys: "Format menu", "Type its first letters".
        isNote = keys.contains(where: \.isLowercase) && keys.contains(" ") && !keys.contains("  ")
    }

    var body: some View {
        if isNote {
            Text(chords.joined(separator: " ")).font(.honey(.subheadline, weight: .semibold))
                .foregroundStyle(Color.honeyMuted)
        } else {
            HStack(spacing: 4) {
                ForEach(chords, id: \.self) { chord in
                    Text(chord)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.honeyFg)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .frame(minWidth: 26, minHeight: 22)
                        .background(Color.honeySurface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.honeyLine, lineWidth: 1)
                        }
                }
            }
        }
    }
}
