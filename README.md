# Kiri

A beautiful text editor for quick edits.

Kiri is a native SwiftUI app for macOS that launches instantly, opens the files you reach for every day, and highlights the syntax of common programming languages. It is built for opening a file, making a change and getting back to work, not for replacing a full IDE.

## Features

- **Instant launch** into an empty editor (about 0.3 s to the first window on an M-series Mac, measured with `-KiriLaunchTiming YES`).
- **Honey + Liquid Glass design**: glass chrome (tab strip, Save, status bar, find bar, Go to Line) over a warm canvas, the text on a solid panel. Light, dark and high-contrast; follows Reduce Motion and Reduce Transparency. Six color themes (Settings ▸ Theme, View ▸ Theme); changing the theme or light and dark crossfades every window over a quarter of a second, or changes at once with reduced motion.
- **Any text file**: plain text, Markdown, JSON, YAML, TOML, XML, CSV, logs, source code. Kiri detects the encoding (UTF-8, UTF-16/32 with or without BOM, Windows Latin 1) and line endings (LF, CRLF, CR) and saves them back unchanged; change either from the status bar.
- **Saving is yours**: the file changes when you save (⌘S, the Save button, File ▸ Save As…) and at no other time. The Save button is a small glass circle while there is nothing to save and opens into the amber Save pill when the document has unsaved changes, as the tab's dot does. Closing a tab or quitting with unsaved changes asks first. What you haven't saved is kept for a crash: five seconds after an edit Kiri writes a recovery copy (in `~/Library/Autosave Information`, never beside your file), and the next launch brings the document back with its changes, still unsaved; saving, reverting or closing deletes the copy. File ▸ Revert to Saved goes back to the file. A file changed by something else (git, a formatter) is taken up when the document has no unsaved changes; otherwise Save asks before writing over it.
- **Syntax highlighting** with Tree-sitter for Swift, JSON, YAML, Markdown, JavaScript, TypeScript/TSX, Python, shell, HTML, CSS, Go, Rust, Java, Kotlin, C#, C, C++ and Zig, and a lightweight lexer for TOML, INI, XML, Objective-C and more. Only the visible text is colored, so large files stay fast.
- **Tabs**: documents open as tabs in one window (native window tabbing under a Honey tab strip, with dirty dots). The selected tab shows its whole name and the others shorten in the middle ("Greet….swift"); with more tabs than fit, the strip scrolls and a menu at its end lists them all. A tab's tooltip is its file's path, and files with the same name show their folder ("index.ts · api").
- **Folder sidebar** (`kiri <folder>` or File ▸ Open Folder…): the folder's files beside the editor. A click on a file (or Space) shows it in the window's one preview tab, its title slanted, and the next file you click takes that tab over, so looking through a folder leaves one tab and not one for each file. Editing the file, saving it, a double-click on its row or on its tab, or Return on its row keeps the tab. A file that is already open is just selected. Rows say what is open: the name of a file that is open in one of the window's tabs is bold (slanted while it is the preview), and one with unsaved changes has the tabs' amber dot. Drag the edge between the sidebar and the editor to make the sidebar narrower or wider (180 to 400 pt; a double-click on the edge gives the default 230 back); the width is remembered, and a narrow window shows less of it so the editor keeps its room.
- **Drop files on a window**: files dragged from Finder onto a Kiri window (its text, tab strip, sidebar or anywhere else) open as tabs of that window, in the order dropped; a folder opens as a folder window of its own. Kiri need not be the active app. Text dragged from elsewhere still drops into the text.
- **Typing animations** (Settings ▸ Typing animations, on by default): a honey caret that glides and breathes, a current-line highlight that eases between lines, a pulse on the matching bracket, syntax colors that crossfade instead of flickering, and rolling Ln/Col digits. Reduce Motion keeps the fades and drops movement; Motion: Off turns them all off.
- **Find and replace** in a glass bar that floats over the top of the editor instead of pushing the text down. Matches highlight as you type, with a count ("3 of 12"); match case and regular expressions (ICU; `$1` in the replacement); Replace and Replace All are one undo step each. The query is the system's shared find text, so ⌘E in another app carries over. Long files are searched off the main thread.
- **Go to Line** shows the line while you type its number; Return keeps it, Esc goes back to where you were.
- **Status bar**: a glass capsule over the bottom of the text with the language, encoding and line endings (menus: each shows a capsule and a chevron under the pointer), the caret's position (click it for Go to Line; a selection shows its length, "Ln 12, Sel 5") and the indentation Shift Left and Right use ("Spaces: 4" or "Tabs"). It keeps its width as the caret moves, and fades to about a third while you type or scroll so the text under it shows; it is back after a second, or when the pointer comes near. With Reduce Motion or Increase Contrast it stays solid.
- **A hint in a new document**: an empty untitled document shows Open a file ⌘O, Open a folder ⇧⌘O, Keyboard shortcuts ⌘? and, until it is installed, Install the kiri command. Each line is a button; the first thing you type takes the hint away.
- **`kiri` command**: open files and folders from the terminal (see below).
- Line numbers, current-line highlight, editor text size, line wrapping, Shift Left and Right, Toggle Comment (⌘/; off in formats without comments: plain text, JSON, CSV) and File ▸ Open Recent.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N or ⌘T / ⌘O | New tab / open (as a tab) |
| ⌘S / ⇧⌘S | Save / Save As |
| ⇧⌘O | Open folder (a new window with a file sidebar) |
| ⌃⌘S | Show / hide the folder sidebar (also the button left of the tabs) |
| ⇧⌘E | Jump between sidebar and editor (in the sidebar: arrows, Space to show a file in the preview tab, Return to open it to stay and edit, type to select, Esc) |
| ⌘W / ⌥⌘W | Close tab / close all (a tab with unsaved changes asks) |
| ⌘F / ⌥⌘F | Find / Find and Replace (in the bar: Return and ⇧Return for next and previous, Tab between the fields, Esc to close with the match selected) |
| ⌘G / ⇧⌘G | Find next / previous, with the bar open or closed |
| ⌘E / ⌘J | Use the selection as the find text / scroll to the selection |
| ⌘L | Go to line (`12` or `12:5` for line and column; Return keeps it, Esc goes back) |
| ⌘] / ⌘[ | Shift lines right / left |
| ⌘/ | Comment or uncomment the selected lines (Format ▸ Toggle Comment), in the language's own way: `//`, `#`, `--`, `<!-- -->`, `/* */` |
| ⇧⌘] / ⇧⌘[ , ⌘1–⌘9 | Next / previous tab, go to tab |
| ⌃⌘W | Wrap lines |
| ⌘? (⇧⌘/) | Keyboard Shortcuts window (everything, filterable). If macOS's own "Show Help menu" shortcut is on (System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts), the key opens the Help menu instead, where Keyboard Shortcuts is the one item |
| ⌘+ / ⌘- / ⌘0 | Bigger / smaller / actual size for the editor text (View ▸ Bigger Text, Smaller Text, Actual Size) |
| ⌘, | Settings (theme, motion, editor text size, wrapping, the command line tool) |

These are the keys of a U.S. keyboard. On other layouts macOS moves a few of them (on a Swedish keyboard ⌘/ is ⌘´), and the menus show the key that works.

Everything else is in a menu: Format has language, encoding, BOM and line
endings; View has theme, motion and typing animations. ⌃F2 opens the menu bar.

## Command line

Choose **Kiri ▸ Install Command Line Tool…** once (the item after Settings…), or press Install in Settings, which also says whether the command is installed; an empty new document offers it too until it is. It links `/usr/local/bin/kiri` to the script inside the app (`Kiri.app/Contents/Resources/kiri`, source in `App/CLI/kiri`), asking for an administrator password if needed. To do it by hand: `sudo ln -sf /Applications/Kiri.app/Contents/Resources/kiri /usr/local/bin/kiri`.

```sh
kiri                        # open Kiri
kiri notes.md todo.txt      # open files as tabs in the front window
kiri src/main.swift:42:5    # …at line 42, column 5 (or just :42)
kiri ~/project              # a new window with a file sidebar for the folder
kiri new.md                 # a file that doesn't exist yet opens empty; saving creates it
git diff | kiri -           # standard input in a new untitled tab
kiri -n file.txt            # in a new window
kiri -w file.txt            # wait until the tab is closed (save first: closing asks if you haven't)
```

Use Kiri as your editor with `export EDITOR="kiri -w"` and `git config --global core.editor "kiri -w"`.

A running Kiri is reused: the script writes a request to the per-user temporary folder and hands it over with a `kiri://` URL, and `-w` waits for Kiri to delete a marker file when the tabs close.

## Build

Needs macOS 26 and Xcode 26 or later, and XcodeGen.

```sh
brew install xcodegen
scripts/build.sh            # release build → build/Kiri.app (ad-hoc signed)
scripts/build.sh --install  # …and copy it to /Applications
```

The first build downloads the Tree-sitter grammars, about 1.4 GB of git history, which takes several minutes. SwiftPM keeps them in `~/Library/Caches/org.swift.swiftpm`, so later builds start in seconds.

For development, generate the project and open it in Xcode:

```sh
cd App && xcodegen && open Kiri.xcodeproj
```

`Kiri.xcodeproj` and `Info.plist` are generated from `App/project.yml` and not checked in. To sign with your own identity, set `DEVELOPMENT_TEAM` in `App/project.yml` (Xcode) or `SIGN_IDENTITY` for `scripts/build.sh`.

Tests: `cd KiriKit && swift test` (the token, document-model, search, tab-layout, sidebar-width and syntax tests; all but the last also run on Linux). Debug builds (or Release with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=KIRI_SELFTEST`) have smoke tests, run as `Kiri.app/Contents/MacOS/Kiri <file> <flag> YES -ApplePersistenceIgnoreState YES`. The last argument is required: it keeps AppKit from restoring your windows or reopening your unsaved documents into the test, and puts the test's recovery copies in the temporary folder; a launch with a `-Kiri…` flag refuses to run without it.

- `-KiriSelfTest`: typing through the event loop, dirty state, byte-exact save, undo, revert, highlighting after revert; and that saving is explicit: nothing reaches the file before Save (bytes, date and inode, also after an autosave), the recovery copy (written by itself, kept out of the file's folder, deleted by Save, Revert and close), Save in place for files of any type, the close question's Cancel, Don't Save and Save, Revert to Saved, a file changed on disk, Save on an untitled document, File ▸ Open Recent, and `kiri -w` waiting through Cancel, Save, Don't Save and a cancelled quit.
- `-KiriBehaviorTest`: focus at launch, the find bar (the Edit ▸ Find keys, the count, next and previous, highlights, replace and Replace All with undo, the field's Return, Tab and Escape), Go to Line (preview, Return, Escape), the status bar (its items' names, the position button, a width that holds as the caret moves, resting while typing and scrolling), wrapping, the Save button (that it saves, and what it says and its shape with and without unsaved changes), opening/selecting/closing tabs, the tab strip following edits, saves and renames, the menus acting on the window in front (Find, Save, Revert to Saved), Toggle Comment on ⌘/ as a key (comment, uncomment, undo, the selection, off for plain text) and Keyboard Shortcuts on ⌘?, files, folders and text dropped on a window (on the text, the tab strip and the sidebar; on a window that isn't in front), the folder sidebar in a folder of the test's own in the temporary directory (the preview tab: one tab for files clicked one after another, the title and the text changing together, each way of keeping it, find and Go to Line across the change, what VoiceOver hears; the marks on the rows of open, previewed and unsaved files following their tabs; the edge: dragged, at its limits, in a window at its narrowest, remembered without writing the saved preferences; `-KiriSidebarTest` runs these alone), the crossfade of a theme change (begun, replaced by a second change, gone afterwards and after a window closes mid-fade, the new colors drawn, none with reduced motion), the first-run hint (shown in a new untitled document only, gone with the first key and after undo, its lines' names and clicks).
- `-KiriPerfTest`: typing and scrolling cost on the open file, and what the find bar costs on it (use a big file).
- `-KiriRelaunchTest <phase>`: what only a second launch shows. `crash` then `recover`: unsaved documents come back after `kill -9`; `frame-set` then `frame-check`: the window's frame is kept; `restore-quit` then `restore-check` (with `-NSQuitAlwaysKeepsWindows YES`): a window open at the quit comes back once; `empty-check`: with nothing to bring back, the launch starts in one empty document. These need AppKit to reopen things, which `-ApplePersistenceIgnoreState YES` turns off, so they run only in a copy of the app with another bundle identifier and name (its recovery record and saved state are then not Kiri's), without that argument.

## Layout

- `KiriKit/` Swift package:
  - `KiriKit`: the Honey + Liquid Glass style kit (tokens, Nunito, motion, glass, components, `StyleGallery`) the document model (`TextFile`, `LineIndex`, `Language`, syntax tokens and the fallback lexer), find and replace on strings (`TextSearch`), the status bar's position text and indentation detection (`StatusText`, `IndentStyle`) the tab strip's arithmetic (`TabLayout`: shortening names, sharing the width, telling same-named files apart) and the folder sidebar's (`SidebarLayout`: the limits of its width, and what a narrow window shows of it).
  - `KiriSyntax`: Tree-sitter parsing and highlight queries (macOS only).
- `App/` the macOS app (XcodeGen spec in `App/project.yml`): `NSDocument` documents in windows that host SwiftUI, the TextKit 2 editor, tabs, settings and commands.
- `scripts/` `build.sh` (release build) and `icon/kiri-icon.mjs` (draws the app icon: a letter in a glass envelope with a honey seal; run with Node and Playwright).
- `docs/DESIGN.md` the design language.

Nunito is licensed under the SIL Open Font License 1.1 (`KiriKit/Sources/KiriKit/Fonts/OFL.txt`). Tree-sitter grammars and queries are MIT licensed (`KiriKit/Sources/KiriSyntax/Queries/LICENSES.txt`).
