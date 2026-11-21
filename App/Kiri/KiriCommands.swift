import AppKit
import KiriKit
import SwiftUI

/// Menu commands beyond what DocumentGroup gives (New, Open, Open Recent,
/// Save, Duplicate, Rename, Revert, Close come with it; TextEditingCommands
/// adds Find, Spelling, Substitutions and Transformations). Every feature is
/// in a menu, so the keyboard reaches all of it (⌃F2 opens the menu bar),
/// and the common ones have keys of their own. Help ▸ Keyboard Shortcuts
/// lists them; its contents live next to the keys in `Shortcuts.swift`.
struct KiriCommands: Commands {
    @FocusedValue(\.editorModel) private var editor
    @FocusedValue(\.folderSession) private var folder
    @FocusedValue(\.windowTabs) private var tabs
    @FocusedBinding(\.textEncoding) private var encoding
    @FocusedBinding(\.lineEnding) private var lineEnding
    @FocusedBinding(\.byteOrderMark) private var byteOrderMark
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true
    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.colorThemeKey) private var colorTheme = Honey.Theme.honey.id
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system
    @AppStorage(Prefs.typingAnimationsKey) private var typingAnimations = true
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        TextEditingCommands()

        CommandGroup(after: .appSettings) {
            Button("Install Command Line Tool…") { CLIInstaller.install() }
        }

        CommandGroup(before: .sidebar) {
            Button(folder?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                folder?.sidebarVisible.toggle()
            }
            .keyboardShortcut(Keys.toggleSidebar)
            .disabled(folder == nil)
        }

        // File
        CommandGroup(after: .newItem) {
            Button("New Tab") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut(Keys.newTab)
            Button("Open Folder…") { FolderSessions.openFolderPanel() }
                .keyboardShortcut(Keys.openFolder)
        }

        // Edit
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Go to Line…") { editor?.showGoToLine = true }
                .keyboardShortcut(Keys.goToLine)
                .disabled(editor == nil)
        }

        // View
        CommandGroup(before: .toolbar) {
            Button("Bigger") { textScale = Prefs.bigger(textScale) }
                .keyboardShortcut(Keys.bigger)
            Button("Smaller") { textScale = Prefs.smaller(textScale) }
                .keyboardShortcut(Keys.smaller)
            Button("Actual Size") { textScale = 1 }
                .keyboardShortcut(Keys.actualSize)
            Toggle("Wrap Lines", isOn: $wrapLines)
                .keyboardShortcut(Keys.wrapLines)
            Divider()
            Picker("Theme", selection: $colorTheme) {
                ForEach(Honey.Theme.all) { Text($0.name).tag($0.id) }
            }
            Picker("Appearance", selection: $theme) {
                ForEach(HoneyTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Motion", selection: $motion) {
                ForEach(HoneyMotionLevel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Typing Animations", isOn: $typingAnimations)
                .disabled(motion == .off)
            Divider()
        }

        CommandMenu("Format") {
            Picker("Language", selection: languageBinding) {
                ForEach(Language.all) { Text($0.name).tag($0) }
            }
            .disabled(editor == nil)
            Divider()
            Picker("Text Encoding", selection: $encoding) {
                ForEach(TextEncoding.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .disabled(encoding == nil)
            Toggle("Byte Order Mark", isOn: Binding(get: { byteOrderMark ?? false }, set: { byteOrderMark = $0 }))
                .disabled(byteOrderMark == nil || !(encoding?.isUnicode ?? false))
            Picker("Line Endings", selection: $lineEnding) {
                ForEach(LineEnding.allCases, id: \.self) { Text($0.menuName).tag(Optional($0)) }
            }
            .disabled(lineEnding == nil)
            Divider()
            Button("Shift Right") { editor?.controller?.shiftLines(right: true) }
                .keyboardShortcut(Keys.shiftRight)
                .disabled(editor == nil)
            Button("Shift Left") { editor?.controller?.shiftLines(right: false) }
                .keyboardShortcut(Keys.shiftLeft)
                .disabled(editor == nil)
        }

        // Window: Kiri draws its own tab strip, so it gets Safari's keys
        // too (macOS adds ⌃⇥ / ⌃⇧⇥ by itself).
        CommandGroup(before: .windowList) {
            Button("Select Next Tab") { tabs?.selectNext() }
                .keyboardShortcut(Keys.nextTab)
                .disabled((tabs?.items.count ?? 0) < 2)
            Button("Select Previous Tab") { tabs?.selectPrevious() }
                .keyboardShortcut(Keys.previousTab)
                .disabled((tabs?.items.count ?? 0) < 2)
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { n in
                    Button(tabTitle(n)) { tabs?.select(position: n - 1) }
                        .keyboardShortcut(Keys.tab(n))
                        .disabled((tabs?.items.count ?? 0) < n)
                }
            }
            Divider()
        }

        // Help: there is no help book, so Kiri Help becomes the shortcuts.
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: ShortcutsView.windowID) }
                .keyboardShortcut(Keys.shortcuts)
        }
    }

    private var languageBinding: Binding<Language> {
        Binding(get: { editor?.language ?? .plainText }, set: { editor?.language = $0 })
    }

    private func tabTitle(_ n: Int) -> String {
        guard let items = tabs?.items, items.indices.contains(n - 1) else { return "Tab \(n)" }
        return items[n - 1].title
    }
}
