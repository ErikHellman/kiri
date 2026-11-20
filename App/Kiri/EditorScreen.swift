import KiriKit
import SwiftUI

/// One document window: the editor on a solid Honey panel over the canvas,
/// with the glass status bar floating over its bottom edge.
struct EditorScreen: View {
    @ObservedObject var document: KiriDocument
    let fileURL: URL?
    @State private var model = EditorModel()
    @State private var tabs = WindowTabs()
    @State private var saveState = HoneyTaskState.idle
    @State private var saver = SaveObserver()
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true
    @AppStorage(Prefs.typingAnimationsKey) private var typingAnimations = true
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Honey.gap) {
            topBar
            EditorView(document: document, model: model, fontScale: textScale, language: model.language,
                       wrapLines: wrapLines,
                       animation: EditorAnimation.resolve(motion: appearance.motion, systemReduceMotion: reduceMotion,
                                                          typingAnimations: typingAnimations))
                .honeyPanel()
                .overlay(alignment: .bottom) {
                    statusBar.padding(.bottom, 8)
                }
                .overlay(alignment: .top) {
                    if model.showGoToLine {
                        GoToLine(model: model).padding(.top, 12).transition(.honeyPop)
                    }
                }
                .animation(HoneyMotion(appearance, systemReduced: reduceMotion).shape, value: model.showGoToLine)
        }
        .padding(.horizontal, Honey.gap)
        .padding(.bottom, Honey.gap)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 480, minHeight: 280)
        .honeyCanvas()
        .background(WindowReader { tabs.attach($0) })
        .focusedSceneValue(\.editorModel, model)
        .onAppear {
            detectLanguage()
            tabs.resume()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "KiriShowSettings") { openSettings() }
            #endif
        }
        .onChange(of: fileURL) { detectLanguage() }
        .onDisappear { tabs.invalidate() }
    }

    /// The toolbar row on the canvas, level with the traffic lights: the tab
    /// strip, a new-tab button and Save.
    private var topBar: some View {
        HStack(spacing: 8) {
            HoneyGlassGroup {
                HStack(spacing: 8) {
                    if !tabs.items.isEmpty {
                        HoneyTabStrip(tabs.items.map { HoneyTab(id: $0.id, title: $0.title, dirty: $0.dirty) },
                                      selection: Binding(get: { tabs.selected }, set: { tabs.select($0) }),
                                      onClose: { tabs.close($0) })
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        NSDocumentController.shared.newDocument(nil)
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                    .buttonStyle(.honeyIcon)
                    .help("New document (⌘N)")
                }
            }
            Spacer(minLength: 0)
            HoneyTaskButton("Save", systemImage: "square.and.arrow.down", state: saveState, action: save)
                .help("Save (⌘S)")
                .opacity(tabs.dirty || saveState != .idle ? 1 : 0.55)
        }
        .padding(.leading, 78) // the traffic lights
        .frame(height: 32)
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

    private var statusBar: some View {
        HoneyStatusBar {
            Menu {
                Picker("Language", selection: $model.language) {
                    ForEach(Language.all) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HoneyPill(model.language.name, tone: .accent)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Language")

            HoneyStatusItem(position, systemImage: "text.cursor")
                .accessibilityLabel(positionAccessibility)

            Menu {
                Picker("Encoding", selection: encodingBinding) {
                    ForEach(TextEncoding.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Byte Order Mark", isOn: bomBinding).disabled(!document.encoding.isUnicode)
            } label: {
                HoneyStatusItem(document.encoding.label + (document.hasBOM && document.encoding.isUnicode ? " BOM" : ""))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Text encoding used when saving")

            Menu {
                Picker("Line Endings", selection: lineEndingBinding) {
                    ForEach(LineEnding.allCases, id: \.self) { Text(lineEndingName($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HoneyStatusItem(document.lineEnding.label)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Line endings used when saving")
        }
    }

    private var position: String {
        let base = "Ln \(model.line), Col \(model.column)"
        return model.selectedLength > 0 ? base + " (\(model.selectedLength) selected)" : base
    }

    private var positionAccessibility: String {
        "Line \(model.line) of \(model.lineCount), column \(model.column)"
    }

    private func lineEndingName(_ e: LineEnding) -> String {
        switch e {
        case .lf: "LF — macOS and Linux"
        case .crlf: "CRLF — Windows"
        case .cr: "CR — Classic Mac OS"
        }
    }

    // Changing the save format is an undoable edit, so the document turns dirty.
    private func undoable<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<KiriDocument, V>, _ name: String) -> Binding<V> {
        Binding {
            document[keyPath: keyPath]
        } set: { new in
            set(keyPath, new, name)
        }
    }

    private func set<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<KiriDocument, V>, _ new: V, _ name: String) {
        let old = document[keyPath: keyPath]
        guard old != new else { return }
        document[keyPath: keyPath] = new
        let doc = document
        let undo = undoManager
        undo?.registerUndo(withTarget: doc) { d in
            MainActor.assumeIsolated {
                d[keyPath: keyPath] = old
                undo?.registerUndo(withTarget: d) { d in MainActor.assumeIsolated { d[keyPath: keyPath] = new } }
            }
        }
        undo?.setActionName(name)
    }

    private var encodingBinding: Binding<TextEncoding> { undoable(\.encoding, "Change Encoding") }
    private var lineEndingBinding: Binding<LineEnding> { undoable(\.lineEnding, "Change Line Endings") }
    private var bomBinding: Binding<Bool> { undoable(\.hasBOM, "Change Byte Order Mark") }

    private func detectLanguage() {
        let firstLine = document.file.text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        model.language = Language.detect(fileName: fileURL?.lastPathComponent, firstLine: firstLine)
    }
}

/// ⌘L: a small glass field over the top of the editor.
private struct GoToLine: View {
    let model: EditorModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.honeyAccentInk)
            TextField("Line (1–\(model.lineCount))", text: $text)
                .textFieldStyle(.plain)
                .font(.honey(.body))
                .frame(width: 180)
                .focused($focused)
                .onSubmit(go)
            Text("of \(model.lineCount)").font(.honey(.caption, weight: .semibold)).foregroundStyle(Color.honeyMuted)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .honeyGlass(.chrome, radius: .control)
        .overlay {
            RoundedRectangle(cornerRadius: Honey.Radius.control.value, style: .continuous)
                .strokeBorder(Color.honeyFocus, lineWidth: 2)
        }
        .onAppear { text = ""; focused = true }
        .onExitCommand { close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go to line")
    }

    private func go() {
        // "12" or "12:5" (line:column).
        let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let line = parts.first { model.controller?.goTo(line: line, column: parts.count > 1 ? parts[1] : 1) }
        close()
    }

    private func close() {
        model.showGoToLine = false
        model.controller?.focus()
    }
}

extension FocusedValues {
    /// The front window's editor, for menu commands.
    @Entry var editorModel: EditorModel?
}
