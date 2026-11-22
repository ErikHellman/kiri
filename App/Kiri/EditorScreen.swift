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
            HStack(spacing: Honey.gap) {
                if let folder = tabs.folder, sidebarShown {
                    FolderSidebar(session: folder, model: model, currentFile: fileURL?.standardizedFileURL, open: openFromSidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                editor
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
            }
        }
        .padding(.horizontal, Honey.gap)
        .padding(.bottom, Honey.gap)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 480, minHeight: 280)
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
            // untitled document until something is typed into it.
            .overlay {
                if model.showsStartHint {
                    StartHint(commandLineTool: commandLineTool.status)
                        .padding(.bottom, StartHint.bottomClearance)
                        .transition(.opacity)
                }
            }
            .honeyPanel()
            .overlay(alignment: .bottom) {
                EditorStatusBar(model: model, document: document, encoding: encodingBinding, lineEnding: lineEndingBinding,
                                byteOrderMark: bomBinding)
            }
            .overlay(alignment: .top) {
                // One at a time: opening one closes the other.
                if model.find.isOpen {
                    FindBar(find: model.find).padding(.top, EditorBar.topPadding).transition(arrive)
                } else if model.goToLine.isOpen {
                    GoToLine(goToLine: model.goToLine, lineCount: model.lineCount)
                        .padding(.top, EditorBar.topPadding).transition(arrive)
                }
            }
            .animation(motion.shape, value: model.find.isOpen)
            .animation(motion.shape, value: model.goToLine.isOpen)
            // The hint fades out; with reduced motion it is simply gone.
            .animation(motion.reduced ? nil : motion.quick, value: model.showsStartHint)
    }

    /// Opens a sidebar file as a tab of this window. An empty untitled tab
    /// (what a folder window starts with) gives its place to the file.
    private func openFromSidebar(_ url: URL) {
        let blank = fileURL == nil && document.text.isEmpty && !(tabs.document?.isDocumentEdited ?? true)
        let blankWindow = tabs.window
        let folder = tabs.folder
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, alreadyOpen, error in
            MainActor.assumeIsolated {
                if let error { _ = NSApp.presentError(error); return }
                guard let doc else { return }
                if alreadyOpen, let w = Editors.window(for: doc) {
                    w.tabGroup?.selectedWindow = w
                    w.makeKeyAndOrderFront(nil)
                }
                guard blank, !alreadyOpen, let blankWindow, let folder else { return }
                Editors.whenReady(doc) { _ in
                    guard let w = Editors.window(for: doc), blankWindow.tabbedWindows?.contains(w) ?? false else { return }
                    FolderSessions.set(folder, for: w)
                    if let d = NSDocumentController.shared.document(for: blankWindow), d.fileURL == nil, !d.isDocumentEdited {
                        blankWindow.performClose(nil)
                    }
                }
            }
        }
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
                                      onClose: { tabs.close($0) })
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
        let firstLine = document.file.text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        model.language = Language.detect(fileName: fileURL?.lastPathComponent, firstLine: firstLine)
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
