import KiriKit
import SwiftUI

/// A document window: the tab strip, and the editor of the tab that shows
/// on a solid Honey panel over the canvas, with the glass status bar
/// floating over its bottom edge.
struct EditorScreen: View {
    let tabs: WindowTabs

    var body: some View {
        if let tab = tabs.selectedTab {
            TabScreen(tabs: tabs, tab: tab)
        } else {
            // (The last tab has gone and the window is closing.)
            Color.clear.honeyCanvas()
        }
    }
}

/// What a window shows of its selected tab: the top bar, and the tab's
/// editor on its panel, or two tabs side by side (`WindowTabs.panels`).
private struct TabScreen: View {
    let tabs: WindowTabs
    let tab: DocumentTab
    private var model: EditorModel { tab.model }
    private var document: KiriDocument { tab.document }
    @State private var whatsNew = WhatsNew.shared
    @State private var saveState = HoneyTaskState.idle
    @State private var saver = SaveObserver()
    /// What the layout shows: follows `folder.sidebarVisible`, animated
    /// only when the person toggles it.
    @State private var sidebarShown = false
    /// The folder sidebar's width, the same in every window.
    @State private var sidebarWidth = SidebarWidth.shared
    /// How wide the row of sidebar and editor is, once it has been laid out.
    @State private var rowWidth = 0.0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the document's file is: nil until it is saved, and it follows
    /// Save As and a move in Finder.
    private var fileURL: URL? { document.location }

    /// The least the editors keep beside the sidebar: one editor's
    /// minimum, or two and their gap.
    private var editorsMinimum: Double {
        tabs.isSplit ? SplitLayout.minimumRow(gap: Honey.gap) : SidebarLayout.editorMinimum
    }

    /// The narrowest the window gets: with two editors, what holds them
    /// (and the narrowest sidebar).
    private var minimumWidth: Double {
        guard tabs.isSplit else { return SidebarLayout.narrowestWindow }
        let sidebar = tabs.folder != nil && sidebarShown ? SidebarLayout.widths.lowerBound + Honey.gap : 0
        return max(SidebarLayout.narrowestWindow, SplitLayout.minimumRow(gap: Honey.gap) + sidebar + 2 * Honey.gap)
    }

    var body: some View {
        VStack(spacing: Honey.gap) {
            topBar
            HStack(spacing: 0) {
                if let folder = tabs.folder, sidebarShown {
                    // The sidebar and, in the gap between the panels, the
                    // edge that is dragged to make it narrower or wider. A
                    // window too narrow for the width asked for shows what
                    // leaves the editors their minimum.
                    let widest = SidebarLayout.widest(in: rowWidth, gap: Honey.gap, editors: editorsMinimum)
                    let width = SidebarLayout.shown(preferred: sidebarWidth.preferred, available: rowWidth, gap: Honey.gap,
                                                    editors: editorsMinimum)
                    HStack(spacing: 0) {
                        FolderSidebar(session: folder, model: model, tabs: tabs, currentFile: fileURL?.standardizedFileURL,
                                      width: width)
                        SidebarEdge(width: width, widest: widest, store: sidebarWidth)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                EditorPanels(tabs: tabs)
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: {
                rowWidth = $0
                tabs.rowWidth = $0
            }
            // Only Show/Hide Sidebar slides it. A new tab of a folder window
            // gets the folder as it opens, and must not slide it in again.
            .onChange(of: tabs.folder?.sidebarVisible, initial: true) { old, new in
                let show = new ?? false
                if old == nil || new == nil || old == new {
                    sidebarShown = show
                } else {
                    withAnimation(HoneyMotion(appearance, systemReduced: reduceMotion).shape) { sidebarShown = show }
                }
                tabs.sidebarInRow = show
            }
        }
        .padding(.horizontal, Honey.gap)
        .padding(.bottom, Honey.gap)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: minimumWidth, minHeight: 280)
        .honeyCanvas()
        .background(WindowReader {
            // The menus act on the window that is in front.
            if let window = $0 as? DocumentNSWindow { FrontEditor.shared.register(window) }
        })
        .onAppear {
            tabs.refresh()
            #if DEBUG || KIRI_SELFTEST
            if UserDefaults.standard.bool(forKey: "KiriShowSettings") { openWindow(id: SettingsView.windowID) }
            if UserDefaults.standard.bool(forKey: "KiriShowShortcuts") { openWindow(id: ShortcutsView.windowID) }
            if UserDefaults.standard.bool(forKey: "KiriShowCommandLine") { openWindow(id: CommandLineHelpView.windowID) }
            if UserDefaults.standard.bool(forKey: "KiriShowStyleGallery") { openWindow(id: "style-gallery") }
            #endif
        }
        // Another tab, or another document in this one (the preview tab
        // going from file to file): a Save that was under way was the
        // other one's.
        .onChange(of: tab.id) { saveState = .idle }
        // The first tab to show after an update has What's new, and it
        // stays in front in its window: another tab coming forward (the
        // next file of a launch's, say) takes it along. (Not the keyboard
        // going to the other side of a split: both show.)
        .onChange(of: tab.id, initial: true) { old, new in
            if old != new, let previous = tabs.tab(id: old), !tabs.isShown(previous) {
                whatsNew.follow(from: previous.model, to: model, document: document)
            }
            whatsNew.offer(model, document: document)
        }
        .onChange(of: ObjectIdentifier(document)) { saveState = .idle }
    }

    /// The toolbar row on the canvas, level with the traffic lights: in a
    /// folder window the sidebar's button, then the tab strip, a new-tab
    /// button and Save.
    ///
    /// Save says whether there is anything to save by its shape: a glass
    /// circle while the document is as its file is, the amber pill once it
    /// has unsaved changes (`WindowTabs.dirty`, set in the same refresh as
    /// the tab's dot). A crowded tab strip gets the width the circle frees.
    private var topBar: some View {
        let saveLook = saveState.look(pending: tabs.dirty)
        return HStack(spacing: 8) {
            HoneyGlassGroup {
                HStack(spacing: 8) {
                    if let folder = tabs.folder {
                        // What View ▸ Hide Sidebar does; the layout slides
                        // the sidebar when `sidebarVisible` changes.
                        Button {
                            folder.sidebarVisible.toggle()
                            if !folder.sidebarVisible { model.controller?.focus() }
                        } label: {
                            Label(folder.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                        }
                        .buttonStyle(.honeyIcon)
                        .help(folder.sidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
                    }
                    if !tabs.items.isEmpty {
                        HoneyTabStrip(tabs.tabs,
                                      selection: Binding(get: { tabs.selected }, set: { tabs.select($0) }),
                                      scrollOffset: Binding(get: { tabs.stripOffset }, set: { tabs.stripOffset = $0 }),
                                      onClose: { tabs.close($0) }, onKeep: { tabs.keep($0) },
                                      onDragOut: { id in tabs.tab(id: id).map(TabDrag.begin) },
                                      onOptionClick: { id in tabs.tab(id: id).map { _ = tabs.openToSide($0, source: .tab) } },
                                      menu: { tabs.menu(for: $0) })
                    }
                    Button {
                        NSDocumentController.shared.newDocument(nil)
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                    .buttonStyle(.honeyIcon)
                    .help("New tab (⌘T)")
                }
            }
            Spacer(minLength: 0)
            if tab.canPreviewMarkdown {
                MarkdownSwitch(tab: tab).transition(.opacity)
            }
            HoneyTaskButton("Save", systemImage: "square.and.arrow.down", state: saveState, pending: tabs.dirty, action: save)
                .help(document.isLargeFile ? "Read-only: large files open for reading and searching"
                      : document.isReadOnly ? "Read-only: Kiri shows this file, it doesn’t change it" : "Save (⌘S)")
                .disabled(document.isReadOnly)
        }
        // The whole row moves with Save's outline, on the same spring: the
        // strip takes up or gives back the width without a jump.
        .animation(HoneyMotion(appearance, systemReduced: reduceMotion).shape, value: saveLook)
        .padding(.leading, 84) // the traffic lights
        .frame(height: 32)
        .padding(.top, Honey.gap)
        .background {
            // Empty canvas in the top bar moves the window, as a title bar would.
            Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
        }
    }

    private func save() {
        guard saveState == .idle, let doc = tabs.document, !document.isReadOnly else { return }
        saveState = .busy
        saver.save(doc) { saved in
            saveState = saved ? .done : .idle
            guard saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Honey.doneHold) { saveState = .idle }
        }
    }

}

/// Text or Preview, for a Markdown or SVG file (View ▸ Markdown Preview, ⌃⌘P).
private struct MarkdownSwitch: View {
    let tab: DocumentTab

    var body: some View {
        HoneySegmentedPicker([(value: false, label: "Text"), (value: true, label: "Preview")],
                             selection: Binding(get: { tab.showsMarkdownPreview }, set: { tab.setMarkdownPreview($0) }))
            .accessibilityLabel(tab.isSVG ? "Show SVG as" : "Show Markdown as")
            .help(tab.isSVG ? "Show the text or the picture (\(Keys.markdownPreview.glyphs))"
                  : "Show the text or the rendered Markdown (\(Keys.markdownPreview.glyphs))")
    }
}

extension LineEnding {
    /// The status bar and Format menu name.
    var menuName: String {
        switch self {
        case .lf: "LF — macOS and Linux"
        case .crlf: "CRLF — Windows"
        case .cr: "CR — Classic Mac OS"
        }
    }
}
