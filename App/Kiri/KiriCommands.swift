import KiriKit
import SwiftUI

/// Menu commands beyond what DocumentGroup gives (New, Open, Open Recent,
/// Save, Save As, Revert, Close come with it; the Style Gallery window lists
/// itself in the Window menu).
struct KiriCommands: Commands {
    @FocusedValue(\.editorModel) private var editor
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true

    var body: some Commands {
        TextEditingCommands()

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Go to Line…") { editor?.showGoToLine = true }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(editor == nil)
        }

        CommandGroup(before: .toolbar) {
            Button("Bigger") { textScale = Prefs.bigger(textScale) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { textScale = Prefs.smaller(textScale) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { textScale = 1 }
                .keyboardShortcut("0", modifiers: .command)
            Toggle("Wrap Lines", isOn: $wrapLines)
            Divider()
        }
    }
}
