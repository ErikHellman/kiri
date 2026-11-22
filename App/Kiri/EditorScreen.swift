import KiriKit
import SwiftUI

/// One document window: the editor on a solid Honey panel over the canvas,
/// with the glass status bar floating over its bottom edge.
struct EditorScreen: View {
    let document: KiriDocument
    @State private var model = EditorModel()
    @State private var commandLineTool = CommandLineTool.shared
    @State private var tabs = WindowTabs()
    @State private var saveState = HoneyTaskState.idle
    @State private var saver = SaveObserver()
    /// What the layout shows: follows `folder.sidebarVisible`, animated
    /// only when the person toggles it.
    @State private var sidebarShown = false
    /// The folder sidebar's width, the same in every window.
    @State private var sidebarWidth = SidebarWidth.shared
    /// How wide the row of sidebar and editor is, once it has been laid out.
    @State private var rowWidth = 0.0
    /// The editor panel's size: the command palette shows as many rows as
    /// it has room for, and fewer words in a narrow one.
    @State private var panelSize = DocumentWindow.defaultSize
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true
    @AppStorage(Prefs.typingAnimationsKey) private var typingAnimations = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the document's file is: nil until it is saved, and it follows
    /// Save As and a move in Finder.
    private var fileURL: URL? { document.location }

    var body: some View {
        VStack(spacing: Honey.gap) {
            topBar
            HStack(spacing: 0) {
                if let folder = tabs.folder, sidebarShown {
                    // The sidebar and, in the gap between the panels, the
                    // edge that is dragged to make it narrower or wider. A
                    // window too narrow for the width asked for shows what
                    // leaves the editor its minimum.
                    let widest = SidebarLayout.widest(in: rowWidth, gap: Honey.gap)
                    let width = SidebarLayout.shown(preferred: sidebarWidth.preferred, available: rowWidth, gap: Honey.gap)
                    HStack(spacing: 0) {
                        FolderSidebar(session: folder, model: model, tabs: tabs, currentFile: fileURL?.standardizedFileURL,
                                      width: width)
                        SidebarEdge(width: width, widest: widest, store: sidebarWidth)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                editor
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { rowWidth = $0 }
            // Only Show/Hide Sidebar slides it. A new tab of a folder window
            // gets the folder as it opens, and must not slide it in again.
            .onChange(of: tabs.folder?.sidebarVisible, initial: true) { old, new in
                let show = new ?? false
                if old == nil || new == nil || old == new {
                    sidebarShown = show
                } else {
                    withAnimation(HoneyMotion(appearance, systemReduced: reduceMotion).shape) { sidebarShown = show }
                }
            }
        }
        .padding(.horizontal, Honey.gap)
        .padding(.bottom, Honey.gap)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: SidebarLayout.narrowestWindow, minHeight: 280)
        .honeyCanvas()
        .background(WindowReader {
            tabs.attach($0)
            // The menus act on the window that is in front.
            FrontEditor.shared.register($0, editor: model, tabs: tabs, document: document)
        })
        .onAppear {
            detectLanguage()
            tabs.resume()
            #if DEBUG || KIRI_SELFTEST
            if UserDefaults.standard.bool(forKey: "KiriShowSettings") { openWindow(id: SettingsView.windowID) }
            if UserDefaults.standard.bool(forKey: "KiriShowShortcuts") { openWindow(id: ShortcutsView.windowID) }
            if UserDefaults.standard.bool(forKey: "KiriShowStyleGallery") { openWindow(id: "style-gallery") }
            #endif
        }
        .onChange(of: fileURL) { detectLanguage() }
        // Another document in this window (the preview tab going from
        // file to file): a Save that was under way was the other one's.
        .onChange(of: ObjectIdentifier(document)) {
            detectLanguage()
            saveState = .idle
        }
        .onDisappear { tabs.invalidate() }
    }

    private var editor: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduceMotion)
        // The bars pop in; with Reduce Motion they fade.
        let arrive: AnyTransition = motion.reduced ? .opacity : .honeyPop
        return EditorView(document: document, model: model, fontScale: textScale, language: model.language,
                   isUntitled: fileURL == nil, wrapLines: wrapLines,
                   animation: EditorAnimation.resolve(motion: appearance.motion, systemReduceMotion: reduceMotion,
                                                      typingAnimations: typingAnimations))
            // Under the bars: the first-run hint, on the paper of an empty
            // untitled document until something is typed into it. (Not
            // while the palette is open: its list would lie over the
            // hint's lines, glass over words.)
            .overlay {
                if model.showsStartHint, !model.palette.isOpen {
                    StartHint(commandLineTool: commandLineTool.status) { model.palette.open() }
                        .padding(.bottom, StartHint.bottomClearance)
                        .transition(.opacity)
                }
            }
            .honeyPanel()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
            .overlay(alignment: .bottom) {
                EditorStatusBar(model: model, document: document, encoding: encodingBinding, lineEnding: lineEndingBinding,
                                byteOrderMark: bomBinding)
            }
            .overlay(alignment: .top) {
                // One at a time: opening one closes the others.
                if model.find.isOpen {
                    FindBar(find: model.find).padding(.top, EditorBar.topPadding).transition(arrive)
                } else if model.palette.isOpen {
                    CommandPalette(palette: model.palette, lineCount: model.lineCount,
                                   rowsThatFit: CommandPalette.rowsThatFit(in: panelSize.height), panelWidth: panelSize.width)
                        .padding(.top, EditorBar.topPadding).transition(arrive)
                }
            }
            .animation(motion.shape, value: model.find.isOpen)
            .animation(motion.shape, value: model.palette.isOpen)
            // The hint fades out; with reduced motion it is simply gone.
            .animation(motion.reduced ? nil : motion.quick, value: model.showsStartHint && !model.palette.isOpen)
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
                                      onClose: { tabs.close($0) }, onKeep: { tabs.keep($0) })
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
            HoneyTaskButton("Save", systemImage: "square.and.arrow.down", state: saveState, pending: tabs.dirty, action: save)
                .help("Save (⌘S)")
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
        guard saveState == .idle, let doc = tabs.document else { return }
        saveState = .busy
        saver.save(doc) { saved in
            saveState = saved ? .done : .idle
            guard saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Honey.doneHold) { saveState = .idle }
        }
    }

    // Changing the save format is an undoable edit of the document.
    private var encodingBinding: Binding<TextEncoding> {
        Binding(get: { document.encoding }, set: { document.setEncoding($0) })
    }

    private var lineEndingBinding: Binding<LineEnding> {
        Binding(get: { document.lineEnding }, set: { document.setLineEnding($0) })
    }

    private var bomBinding: Binding<Bool> {
        Binding(get: { document.hasBOM }, set: { document.setByteOrderMark($0) })
    }

    private func detectLanguage() {
        let language = document.detectedLanguage
        if model.language != language { model.language = language }
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
