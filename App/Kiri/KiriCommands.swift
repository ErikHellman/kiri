import KiriKit
import SwiftUI

/// Menu commands beyond what DocumentGroup gives (New, Open, Open Recent,
/// Save, Save As, Revert, Close come with it; the Style Gallery window lists
/// itself in the Window menu).
struct KiriCommands: Commands {
    @FocusedValue(\.editorModel) private var editor
    @FocusedValue(\.folderSession) private var folder
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true

    var body: some Commands {
        TextEditingCommands()

        CommandGroup(after: .appSettings) {
            Button("Install Command Line Tool…") { CLIInstaller.install() }
        }

        CommandGroup(after: .newItem) {
            Button("Open Folder…") { FolderSessions.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(before: .sidebar) {
            Button(folder?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                folder?.sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(folder == nil)
        }

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
