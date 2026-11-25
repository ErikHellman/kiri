import AppKit
import KiriKit
import SwiftUI

/// The menus. Every feature is in one, so the keyboard reaches all of it
/// (⌃F2 opens the menu bar), and the common ones have keys of their own.
/// Help ▸ Keyboard Shortcuts lists them; its contents live next to the keys
/// in `Shortcuts.swift`.
///
/// What an item acts on is the front document window (`FrontEditor`).
struct KiriCommands: Commands {
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true
    @AppStorage(Prefs.themeKey) private var theme = HoneyTheme.system
    @AppStorage(Prefs.colorThemeKey) private var colorTheme = Honey.Theme.honey.id
    @AppStorage(Prefs.motionKey) private var motion = HoneyMotionLevel.system
    @AppStorage(Prefs.typingAnimationsKey) private var typingAnimations = true
    @Environment(\.openWindow) private var openWindow

    /// The palette's own menu items, which it leaves out of its list.
    static let paletteTitle = "Command Palette…"
    static let goToFileTitle = "Go to File…"
    /// Format ▸ Choose Language…: the language picker (⌃⌘L).
    static let chooseLanguageTitle = "Choose Language…"
    /// The menus whose choices the palette shows while the selection is
    /// on one of them (`PaletteController.preview`): where they are in
    /// the menu bar, said once for the menus and for the palette.
    static let themeMenu = ["View", "Theme"]
    static let appearanceMenu = ["View", "Appearance"]
    static let languageMenu = ["Format", "Language"]

    private var editor: EditorModel? { FrontEditor.shared.editor }
    private var folder: FolderSession? { FrontEditor.shared.folder }
    private var tabs: WindowTabs? { FrontEditor.shared.tabs }
    private var document: KiriDocument? { FrontEditor.shared.document }

    var body: some Commands {
        // Below About Kiri, where Mac apps keep it. Off in a build that
        // can't update itself (no feed or key: see `Updater`).
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.canCheck)
        }

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

        // File. Written out, since the documents are AppKit's own and no
        // SwiftUI scene brings these items: an explicit-save File menu,
        // with Revert going back to the file and no Duplicate, Rename,
        // Move To or Versions. The symbols are the ones macOS gives its
        // own items of these names.
        CommandGroup(replacing: .newItem) {
            Button("New", systemImage: "plus") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut(Keys.new)
            Button("New Tab") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut(Keys.newTab)
            Button("Open…", systemImage: "arrow.up.forward") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut(Keys.open)
            Button("Open Folder…") { FolderSessions.openFolderPanel() }
                .keyboardShortcut(Keys.openFolder)
            // The command palette, which finds a file anywhere in the
            // window's folder, a tab or a recent file by a few letters.
            Button(Self.goToFileTitle) { editor?.palette.open() }
                .keyboardShortcut(Keys.goToFile)
                .disabled(editor == nil)
            Menu("Open Recent", systemImage: "clock") {
                let recent = RecentDocuments.shared.urls
                let folders = TabNames.details(titles: recent.map(\.lastPathComponent), paths: recent.map(\.path))
                ForEach(Array(zip(recent, folders)), id: \.0) { url, folder in
                    // Two of a name are told apart by their folders, as tabs are.
                    Button(folder.map { "\(url.lastPathComponent) — \($0)" } ?? url.lastPathComponent) {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                            MainActor.assumeIsolated { if let error { _ = NSApp.presentError(error) } }
                        }
                    }
                }
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
                    .disabled(recent.isEmpty)
            }
        }
        CommandGroup(replacing: .saveItem) {
            // In a document window the tab that shows; otherwise whatever
            // window has the keyboard: Settings, a panel.
            Button("Close", systemImage: "xmark") { FileAction.close() }
                .keyboardShortcut(Keys.close)
            // Every tab of the front document window, as its close button does.
            Button("Close Window", systemImage: "xmark.square") { FileAction.closeWindow() }
                .keyboardShortcut(Keys.closeWindow)
                .disabled(tabs == nil)
            Button("Close All", systemImage: "xmark.rectangle") { FileAction.closeAll() }
                .keyboardShortcut(Keys.closeAll)
            Button("Save", systemImage: "square.and.arrow.down") { document?.save(nil) }
                .keyboardShortcut(Keys.save)
                .disabled(document == nil)
            Button("Save As…", systemImage: "square.and.arrow.down.on.square") { document?.saveAs(nil) }
                .keyboardShortcut(Keys.saveAs)
                .disabled(document == nil)
            // Back to the file as it was last saved; the document asks first.
            Button("Revert to Saved", systemImage: "arrow.counterclockwise") { document?.revertToSaved(nil) }
                .disabled(document?.location == nil || tabs?.dirty != true)
        }

        // Edit: Find and Transformations, written out instead of taken from
        // `TextEditingCommands`, which also brings Spelling and Grammar,
        // Substitutions and Speech: prose tools that a code editor with
        // spell checking and smart quotes off has no use for. The Find
        // items drive the front document's own find bar (`FindController`),
        // whichever has the keyboard, the editor or a field of the bar; Find…
        // and Find Next and Previous find a file instead while the folder
        // sidebar has the keyboard (`SidebarFind`). The
        // Transformations send the standard action down the responder
        // chain, as AppKit's own items do. None is ever disabled: with
        // nothing to act on, the action goes nowhere.
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { EditAction.find(.show) }
                    .keyboardShortcut(Keys.find)
                Button("Find and Replace…") { EditAction.find(.showReplace) }
                    .keyboardShortcut(Keys.findAndReplace)
                Button("Find Next") { EditAction.find(.next) }
                    .keyboardShortcut(Keys.findNext)
                Button("Find Previous") { EditAction.find(.previous) }
                    .keyboardShortcut(Keys.findPrevious)
                Button("Use Selection for Find") { EditAction.find(.useSelection) }
                    .keyboardShortcut(Keys.useSelectionForFind)
                Button("Jump to Selection") { EditAction.jumpToSelection() }
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
            // Every command here and in the other menus, found by a few
            // of its letters, with its key.
            Button(Self.paletteTitle) { editor?.palette.toggle() }
                .keyboardShortcut(Keys.palette)
                .disabled(editor == nil)
            Divider()
            Button("Bigger Text") { textScale = Prefs.bigger(textScale) }
                .keyboardShortcut(Keys.bigger)
            Button("Smaller Text") { textScale = Prefs.smaller(textScale) }
                .keyboardShortcut(Keys.smaller)
            Button("Actual Size") { textScale = 1 }
                .keyboardShortcut(Keys.actualSize)
            Toggle("Wrap Lines", isOn: $wrapLines)
                .keyboardShortcut(Keys.wrapLines)
            Divider()
            Picker(Self.themeMenu[1], selection: $colorTheme) {
                ForEach(Honey.Theme.all) { Text($0.name).tag($0.id) }
            }
            Picker(Self.appearanceMenu[1], selection: $theme) {
                ForEach(HoneyTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Motion", selection: $motion) {
                ForEach(HoneyMotionLevel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Typing Animations", isOn: $typingAnimations)
                .disabled(motion == .off)
            Divider()
        }

        CommandMenu(Self.languageMenu[0]) {
            // The picker with a search field; the menu below it is the
            // same choice for the menu bar (and the palette's "Language:" rows).
            Button(Self.chooseLanguageTitle) { editor?.palette.toggleLanguages() }
                .keyboardShortcut(Keys.chooseLanguage)
                .disabled(editor == nil)
            Picker(Self.languageMenu[1], selection: languageBinding) {
                ForEach(Language.all) { Text($0.name).tag($0) }
            }
            .disabled(editor == nil)
            Divider()
            Picker("Text Encoding", selection: Binding(get: { document?.encoding }, set: { if let new = $0 { document?.setEncoding(new) } })) {
                ForEach(TextEncoding.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .disabled(document == nil)
            Toggle("Byte Order Mark", isOn: Binding(get: { document?.hasBOM ?? false }, set: { document?.setByteOrderMark($0) }))
                .disabled(!(document?.encoding.isUnicode ?? false))
            Picker("Line Endings", selection: Binding(get: { document?.lineEnding }, set: { if let new = $0 { document?.setLineEnding(new) } })) {
                ForEach(LineEnding.allCases, id: \.self) { Text($0.menuName).tag(Optional($0)) }
            }
            .disabled(document == nil)
            Divider()
            Button("Shift Right") { editor?.controller?.shiftLines(right: true) }
                .keyboardShortcut(Keys.shiftRight)
                .disabled(editor == nil)
            Button("Shift Left") { editor?.controller?.shiftLines(right: false) }
                .keyboardShortcut(Keys.shiftLeft)
                .disabled(editor == nil)
            // Off in a format that has no comments (plain text, JSON, CSV).
            Button("Toggle Comment") { editor?.controller?.toggleComment() }
                .keyboardShortcut(Keys.toggleComment)
                .disabled(editor?.language.comment == nil)
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
            Divider()
            Button("Move Tab to New Window", systemImage: "macwindow.badge.plus") { WindowAction.moveTabToNewWindow() }
                .disabled((tabs?.items.count ?? 0) < 2)
            Button("Merge All Windows", systemImage: "rectangle.stack") { WindowAction.mergeAllWindows() }
                .disabled(tabs == nil || DocumentWindow.all.count < 2)
            Divider()
            Button("Bring All to Front", systemImage: "macwindow.on.rectangle") { NSApp.arrangeInFront(nil) }
        }

        // Help: there is no help book, so Kiri Help becomes the shortcuts.
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: ShortcutsView.windowID) }
                .keyboardShortcut(Keys.shortcuts)
            // The newest release notes in the app (`WhatsNew`).
            Button("What's New in Kiri", systemImage: "sparkles") { WhatsNew.showLatest() }
                .disabled(WhatsNew.latest == nil)
            Divider()
            // Anonymous, through Vaka (`FeedbackWindow`, `Telemetry`).
            Button("Send Feedback…", systemImage: "bubble.left") { FeedbackWindow.show() }
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

/// The Window menu's tab actions, on the front document window.
@MainActor enum WindowAction {
    static func moveTabToNewWindow() { FileAction.documentWindow?.moveTabToNewKiriWindow(nil) }
    static func mergeAllWindows() { FileAction.documentWindow?.mergeAllKiriWindows(nil) }
}

/// The File menu's actions that take more than a line.
@MainActor enum FileAction {
    /// ⌘W: the tab that shows, in a document window; any other window
    /// (Settings, Keyboard Shortcuts) closes.
    static func close() {
        if let window = documentWindow {
            window.performCloseTab(nil)
        } else {
            NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
        }
    }

    /// ⇧⌘W: the front document window, every tab of it.
    static func closeWindow() {
        documentWindow?.performClose(nil)
    }

    /// The document window the File menu acts on: the key window, or in a
    /// test launch (which has none) the one the menus are told is in front.
    static var documentWindow: DocumentNSWindow? {
        if let key = NSApp.keyWindow { return key as? DocumentNSWindow }
        return FrontEditor.shared.tabs?.window
    }

    /// ⌥⌘W: every window closes. A document with unsaved changes asks
    /// first, and Cancel there keeps all the documents open.
    static func closeAll() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.closable) && window.canBecomeMain
            && !DocumentWindow.isDocumentWindow(window) && window.sheetParent == nil {
            window.performClose(nil)
        }
        NSDocumentController.shared.closeAllDocuments(withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil)
    }
}

/// The Edit menu's actions: standard AppKit editing actions sent to whatever
/// has keyboard focus, and the find commands, which go to the front
/// document's find bar (`FrontEditor`), wherever in that window the
/// keyboard is.
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

    private static var editor: EditorModel? { FrontEditor.shared.editor }

    /// A find command, for the front document's find bar. While the folder
    /// sidebar has the keyboard (its rows or its find field), Find…, Find
    /// Next and Find Previous find a file or folder there instead
    /// (`SidebarFind`). In a window without an editor (Settings, Keyboard
    /// Shortcuts) the standard action goes down the responder chain
    /// instead, to whatever text has focus.
    static func find(_ action: FindController.Action) {
        if let editor, editor.sidebarHasFocus, let folder = FrontEditor.shared.folder, folder.sidebarVisible,
           folder.find.perform(action, in: FrontEditor.shared.tabs?.window) {
            return
        }
        if action == .show || action == .showReplace { Telemetry.track("find_open", ["replace": action == .showReplace]) }
        if let editor {
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
    static func jumpToSelection() {
        if let textView = editor?.controller?.textView {
            textView.centerSelectionInVisibleArea(nil)
        } else {
            send(#selector(NSText.centerSelectionInVisibleArea(_:)))
        }
    }
}
