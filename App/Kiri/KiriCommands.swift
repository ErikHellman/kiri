import AppKit
import KiriKit
import SwiftUI

/// Menu commands beyond what DocumentGroup gives (New, Open, Open Recent,
/// Save, Duplicate, Rename, Revert, Close come with it). Every feature is
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
        CommandGroup(replacing: .appSettings) {
            // With the gear macOS gives a Settings scene's own item.
            Button("Settings…", systemImage: "gear") { openWindow(id: SettingsView.windowID) }
                .keyboardShortcut(Keys.settings)
            // Below Settings…, where apps keep such one-time setup. Settings
            // and the first-run hint offer it too, and say whether it is done.
            Button("Install Command Line Tool…") { CLIInstaller.install() }
        }

        CommandGroup(before: .sidebar) {
            Button(folder?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                guard let folder else { return }
                folder.sidebarVisible.toggle()
                if !folder.sidebarVisible { editor?.controller?.focus() }
            }
            .keyboardShortcut(Keys.toggleSidebar)
            .disabled(folder == nil)
            Button(editor?.sidebarHasFocus == true ? "Focus Editor" : "Focus Sidebar") {
                guard let editor else { return }
                if editor.sidebarHasFocus {
                    editor.controller?.focus()
                } else {
                    folder?.sidebarVisible = true
                    editor.sidebarFocusRequest += 1
                }
            }
            .keyboardShortcut(Keys.focusSidebar)
            .disabled(folder == nil || editor == nil)
            Button("Refresh Folder") { folder?.refresh() }
                .disabled(folder == nil)
        }

        // File
        CommandGroup(after: .newItem) {
            Button("New Tab") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut(Keys.newTab)
            Button("Open Folder…") { FolderSessions.openFolderPanel() }
                .keyboardShortcut(Keys.openFolder)
        }

        // Edit: Find and Transformations, written out instead of taken from
        // `TextEditingCommands`, which also brings Spelling and Grammar,
        // Substitutions and Speech: prose tools that a code editor with
        // spell checking and smart quotes off has no use for. The Find
        // items drive the front document's own find bar (`FindController`),
        // whichever has the keyboard, the editor or a field of the bar. The
        // Transformations send the standard action down the responder
        // chain, as AppKit's own items do. None is ever disabled: with
        // nothing to act on, the action goes nowhere.
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { EditAction.find(.show, in: editor) }
                    .keyboardShortcut(Keys.find)
                Button("Find and Replace…") { EditAction.find(.showReplace, in: editor) }
                    .keyboardShortcut(Keys.findAndReplace)
                Button("Find Next") { EditAction.find(.next, in: editor) }
                    .keyboardShortcut(Keys.findNext)
                Button("Find Previous") { EditAction.find(.previous, in: editor) }
                    .keyboardShortcut(Keys.findPrevious)
                Button("Use Selection for Find") { EditAction.find(.useSelection, in: editor) }
                    .keyboardShortcut(Keys.useSelectionForFind)
                Button("Jump to Selection") { EditAction.jumpToSelection(in: editor) }
                    .keyboardShortcut(Keys.jumpToSelection)
            }
            Menu("Transformations") {
                // With the symbols macOS gives its own Transformations items.
                Button("Make Upper Case", systemImage: "characters.uppercase") {
                    EditAction.send(#selector(NSResponder.uppercaseWord(_:)))
                }
                Button("Make Lower Case", systemImage: "characters.lowercase") {
                    EditAction.send(#selector(NSResponder.lowercaseWord(_:)))
                }
                Button("Capitalize", systemImage: "textformat.characters") {
                    EditAction.send(#selector(NSResponder.capitalizeWord(_:)))
                }
            }
            Divider()
            Button("Go to Line…") { editor?.goToLine.open() }
                .keyboardShortcut(Keys.goToLine)
                .disabled(editor == nil)
        }

        // View. The size is the editor text's (and its line numbers'), not
        // the interface's, so the items say "Text".
        CommandGroup(before: .toolbar) {
            Button("Bigger Text") { textScale = Prefs.bigger(textScale) }
                .keyboardShortcut(Keys.bigger)
            Button("Smaller Text") { textScale = Prefs.smaller(textScale) }
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

/// The Edit menu's actions: standard AppKit editing actions sent to whatever
/// has keyboard focus, and the find commands, which go to the front
/// document's find bar.
@MainActor enum EditAction {
    static func send(_ action: Selector, tag: Int = 0) {
        // The find actions read which one they are from the sender's tag,
        // as they do from AppKit's own menu items.
        let sender = NSMenuItem()
        sender.tag = tag
        #if DEBUG || KIRI_SELFTEST
        let target = NSApp.keyWindow == nil ? selfTestTarget : nil
        #else
        let target: NSResponder? = nil
        #endif
        NSApp.sendAction(action, to: target, from: sender)
    }

    #if DEBUG || KIRI_SELFTEST
    /// Self-tests run in the background, where no window is key and an
    /// action without a target has nowhere to go; they name the editor here.
    static weak var selfTestTarget: NSResponder?
    #endif

    /// The front window's editor: the focused scene's, or in a self-test
    /// (run in the background, where no scene has focus) the one it named.
    private static func front(_ editor: EditorModel?) -> EditorModel? {
        #if DEBUG || KIRI_SELFTEST
        if editor == nil, NSApp.keyWindow == nil {
            return ((selfTestTarget as? NSTextView)?.delegate as? EditorController)?.model
        }
        #endif
        return editor
    }

    /// A find command, for the front document's find bar. In a window
    /// without an editor (Settings, Keyboard Shortcuts) the standard action
    /// goes down the responder chain instead, to whatever text has focus.
    static func find(_ action: FindController.Action, in editor: EditorModel?) {
        if let editor = front(editor) {
            editor.find.perform(action)
            return
        }
        let standard: NSTextFinder.Action? = switch action {
        case .show: .showFindInterface
        case .showReplace: .showReplaceInterface
        case .next: .nextMatch
        case .previous: .previousMatch
        case .useSelection: .setSearchString
        default: nil
        }
        if let standard { send(#selector(NSTextView.performFindPanelAction(_:)), tag: standard.rawValue) }
    }

    /// ⌘J scrolls the editor to its selection, also while the keyboard is
    /// in the find bar.
    static func jumpToSelection(in editor: EditorModel?) {
        if let textView = front(editor)?.controller?.textView {
            textView.centerSelectionInVisibleArea(nil)
        } else {
            send(#selector(NSText.centerSelectionInVisibleArea(_:)))
        }
    }
}
