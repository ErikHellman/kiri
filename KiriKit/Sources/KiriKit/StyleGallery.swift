#if canImport(SwiftUI)
import SwiftUI

/// The style kit on one screen: a mock editor window built from the kit, and
/// a panel with every token and component. Kiri shows it until the real
/// editor lands (plan step 2), and it stays as a debug window after that.
public struct StyleGallery: View {
    @State private var appearance = HoneyAppearance()
    @State private var tabs: [HoneyTab<Int>] = [
        HoneyTab(id: 1, title: "README.md", tooltip: "~/Sources/tidepool/README.md", dirty: true),
        HoneyTab(id: 2, title: "config.yaml", detail: "api", tooltip: "~/Sources/tidepool/api/config.yaml"),
        HoneyTab(id: 3, title: "config.yaml", detail: "web", tooltip: "~/Sources/tidepool/web/config.yaml"),
        HoneyTab(id: 4, title: "Package.swift", tooltip: "~/Sources/tidepool/Package.swift"),
    ]
    @State private var selectedTab = 1
    @State private var save = HoneyTaskState.idle
    // periphery:ignore - used as $query
    @State private var query = ""
    @State private var toast = false

    public init() {}

    public var body: some View {
        VStack(spacing: Honey.gap) {
            toolbar
            HStack(spacing: Honey.gap) {
                MockEditor()
                    .honeyPanel()
                    .overlay(alignment: .bottom) {
                        statusBar.padding(.bottom, Honey.gap)
                    }
                    .overlay(alignment: .top) {
                        if toast {
                            HoneyToast("Saved README.md").padding(.top, 14).transition(.honeyPop)
                        }
                    }
                inspector
                    .frame(width: 340)
                    .honeyPanel()
            }
        }
        .padding(Honey.gap)
        .honeyCanvas()
        .honeyRoot(appearance)
    }

    // MARK: Chrome

    private var toolbar: some View {
        HoneyGlassGroup {
            HStack(spacing: Honey.gap) {
                HoneyTabStrip(tabs, selection: $selectedTab) { id in
                    tabs.removeAll { $0.id == id }
                    if let first = tabs.first, id == selectedTab { selectedTab = first.id }
                }
                Button { tabs.append(HoneyTab(id: (tabs.map(\.id).max() ?? 0) + 1, title: "Untitled")) } label: {
                    Label("New tab", systemImage: "plus")
                }
                .buttonStyle(.honeyIcon)
                .help("New tab")
                Spacer(minLength: 0)
                HoneySegmentedPicker(selection: $appearance.theme).accessibilityLabel("Appearance")
                HoneyTaskButton("Save", systemImage: "square.and.arrow.down", state: save, action: runSave)
            }
        }
        // Room for the traffic lights, which sit on the canvas (§11).
        .padding(.leading, 72)
        .frame(height: 36)
    }

    private var statusBar: some View {
        HoneyStatusBar {
            HoneyStatusMenu("Markdown", name: "Language", tone: .accent) { Button("Markdown") {} }
            HoneyStatusButton("Ln 4, Col 18", systemImage: "text.cursor") {}
            HoneyStatusItem("Spaces: 4")
            HoneyStatusMenu("UTF-8", name: "Encoding") { Button("UTF-8") {} }
            HoneyStatusMenu("LF", name: "Line endings") { Button("LF") {} }
            if tabs.first(where: { $0.id == selectedTab })?.dirty == true {
                HoneyStatusItem("Edited", systemImage: "circle.fill")
            }
        }
    }

    private func runSave() {
        guard save == .idle else { return }
        save = .busy
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            save = .done
            if let i = tabs.firstIndex(where: { $0.id == selectedTab }) { tabs[i].dirty = false }
            withAnimation(HoneyMotion(appearance, systemReduced: false).shape) { toast = true }
            try? await Task.sleep(for: .seconds(Honey.doneHold))
            save = .idle
            withAnimation(.honeyQuick) { toast = false }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Colors") { swatches }
                section("Type") { typeSamples }
                section("Buttons") { buttons }
                section("Pills") {
                    HStack(spacing: 6) {
                        HoneyPill("Swift", tone: .accent)
                        HoneyPill("UTF-8")
                        HoneyPill("Saved", systemImage: "checkmark", tone: .ok)
                        HoneyPill("Read-only", systemImage: "lock.fill", tone: .danger)
                    }
                }
                section("Search") { HoneySearchField("Find in file", text: $query) }
                section("Motion") {
                    HoneySegmentedPicker(selection: $appearance.motion).accessibilityLabel("Motion")
                }
                section("Empty state") {
                    HoneyEmptyState(title: "Drop a file", message: "Or press ⌘O to open one. Kiri remembers where you were.")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(18)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HoneySectionLabel(title)
            content()
        }
    }

    private var swatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Honey.allTokens.indices, id: \.self) { i in
                let item = Honey.allTokens[i]
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
                        .fill(Color.honey(item.token))
                        .frame(height: 34)
                        .overlay(RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
                            .strokeBorder(Color.honeyLine))
                    Text(item.name).font(.honey(.caption, weight: .bold)).foregroundStyle(Color.honeyMuted)
                }
            }
        }
    }

    private var typeSamples: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick edits, beautifully").font(.honey(.largeTitle, weight: .heavy))
            Text("View title, 20 heavy").font(.honey(.title, weight: .heavy))
            Text("Panel title, 17 bold").font(.honey(.headline, weight: .bold))
            Text("Body text, 15 regular. Warm, not sweet.").font(.honey(.body))
            Text("Meta and labels, 13").font(.honey(.subheadline)).foregroundStyle(Color.honeyMuted)
            Text("let editor = \"SF Mono, 13\"").font(.honeyMono())
        }
    }

    private var buttons: some View {
        HoneyGlassGroup {
            HStack(spacing: 8) {
                Button("Open…") {}.buttonStyle(.honeyGlass)
                Button { } label: { Label("Save", systemImage: "square.and.arrow.down") }.buttonStyle(.honeyProminent)
                Button { } label: { Label("Find", systemImage: "magnifyingglass") }.buttonStyle(.honeyIcon)
                Button("Disabled") {}.buttonStyle(.honeyGlass).disabled(true)
            }
        }
    }
}

/// A static editor with a gutter, the current line and a selection, until the
/// real text view arrives in plan step 2.
private struct MockEditor: View {
    private static let lines = [
        "# Kiri",
        "",
        "A beautiful text editor for quick edits.",
        "Open a file, make a change, get back to work.",
        "",
        "## Goals",
        "",
        "- **Instant launch.** Open to a usable editor.",
        "- **Looks great.** Honey with Liquid Glass.",
        "- **Common formats.** Markdown, JSON, YAML…",
    ]
    private static let currentLine = 3
    private static let selection = "make a change"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.lines.indices, id: \.self) { i in
                    HStack(spacing: 0) {
                        Text("\(i + 1)")
                            .font(.honeyMono(size: 12))
                            .foregroundStyle(i == Self.currentLine ? Color.honeyMuted : Color.honeyGutter)
                            .frame(width: 44, alignment: .trailing)
                            .padding(.trailing, 14)
                        line(Self.lines[i], current: i == Self.currentLine)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                    .background(i == Self.currentLine ? Color.honeyCurrentLine : .clear)
                }
            }
            .padding(.vertical, 14)
            .padding(.bottom, 44)
        }
        .font(.honeyMono())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func line(_ text: String, current: Bool) -> some View {
        if current, let range = text.range(of: Self.selection) {
            HStack(spacing: 0) {
                Text(text[..<range.lowerBound])
                Text(text[range]).background(Color.honeySelection)
                Rectangle().fill(Color.honeyCaret).frame(width: 2, height: 16)
                Text(text[range.upperBound...])
            }
        } else {
            Text(text)
        }
    }
}

#Preview("Style gallery") {
    StyleGallery()
        .onAppear { Honey.registerFonts() }
        .frame(width: 1100, height: 760)
}
#endif
