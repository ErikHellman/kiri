import KiriKit
import SwiftUI

/// One document window: the editor on a solid Honey panel over the canvas,
/// with the glass status bar floating over its bottom edge.
struct EditorScreen: View {
    @ObservedObject var document: KiriDocument
    let fileURL: URL?
    @State private var model = EditorModel()
    @AppStorage(Settings.textScaleKey) private var textScale = 1.0
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        EditorView(document: document, model: model, fontScale: textScale, language: model.language)
            .honeyPanel()
            .overlay(alignment: .bottom) {
                statusBar.padding(.bottom, 8)
            }
            .padding(.horizontal, Honey.gap)
            .padding(.bottom, Honey.gap)
            .frame(minWidth: 480, minHeight: 280)
            .honeyCanvas()
            .focusedSceneValue(\.editorModel, model)
            .onAppear(perform: detectLanguage)
            .onChange(of: fileURL) { detectLanguage() }
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

extension FocusedValues {
    /// The front window's editor, for menu commands.
    @Entry var editorModel: EditorModel?
}
