import KiriKit
import SwiftUI

/// Help ▸ Keyboard Shortcuts (⌘/): every feature and its keys, on Honey
/// cards over the canvas. Typing filters the list; Escape closes it.
struct ShortcutsView: View {
    static let windowID = "keyboard-shortcuts"

    @State private var filter = ""
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
        VStack(alignment: .leading, spacing: 14) {
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

            if groups.isEmpty {
                HoneyEmptyState(title: "No match", message: "No shortcut is called “\(filter)”.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Honey.gap, alignment: .top)],
                              alignment: .leading, spacing: Honey.gap) {
                        ForEach(groups) { GroupCard(group: $0) }
                    }
                    .padding(.bottom, Honey.gap)
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
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

/// Key caps for "⌘X  ⌘C  ⌘V" (chords split on double spaces), or a muted
/// note such as "Format menu".
private struct KeyCaps: View {
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
