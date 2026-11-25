# Kiri

[![Latest release](https://img.shields.io/github/v/release/ErikHellman/kiri?label=release&color=E09A2D)](https://github.com/ErikHellman/kiri/releases/latest)
[![CI](https://github.com/ErikHellman/kiri/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ErikHellman/kiri/actions/workflows/ci.yml)
[![Downloads](https://img.shields.io/github/downloads/ErikHellman/kiri/total?color=995A05)](https://github.com/ErikHellman/kiri/releases)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-3B2A2F?logo=apple)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-6B8E23)](#license)

A beautiful text editor for quick edits. **[kiri.hellsoft.se](https://kiri.hellsoft.se)** · **[Download for Mac](https://github.com/ErikHellman/kiri/releases/latest)**

[![Kiri, a text editor for the Mac, in light and dark](docs/promo/hero.png)](https://kiri.hellsoft.se)

Kiri is a native SwiftUI app for macOS that launches instantly, opens the files you reach for every day, and highlights the syntax of common programming languages. It is built for opening a file, making a change and getting back to work, not for replacing a full IDE.

## Features

- **Instant launch** into an empty editor (about 0.3 s to the first window on an M-series Mac, measured with `-KiriLaunchTiming YES`).
- **Honey + Liquid Glass design**: glass chrome (tab strip, Save, status bar, find bar, command palette) over a warm canvas, the text on a solid panel. Light, dark and high-contrast; follows Reduce Motion and Reduce Transparency. Six color themes (Settings ▸ Theme, View ▸ Theme); in Settings each swatch shows its theme's accent, canvas, paper and syntax colors, light above the diagonal and dark below, and pointing at one shows that theme in every window until the pointer moves away (a click keeps it). Changing the theme or light and dark crossfades every window over a quarter of a second, or changes at once with reduced motion.
- **Any text file**: plain text, Markdown, JSON, YAML, TOML, XML, CSV, logs, source code. Kiri detects the encoding (UTF-8, UTF-16/32 with or without BOM, Windows Latin 1) and line endings (LF, CRLF, CR) and saves them back unchanged; change either from the status bar.
- **Saving is yours**: the file changes when you save (⌘S, the Save button, File ▸ Save As…) and at no other time. The Save button is a small glass circle while there is nothing to save and opens into the amber Save pill when the document has unsaved changes, as the tab's dot does. Closing a tab or quitting with unsaved changes asks first. What you haven't saved is kept for a crash: five seconds after an edit Kiri writes a recovery copy (in `~/Library/Autosave Information`, never beside your file), and the next launch brings the document back with its changes, still unsaved; saving, reverting or closing deletes the copy. File ▸ Revert to Saved goes back to the file. A file changed by something else (git, a formatter) is taken up when the document has no unsaved changes; otherwise Save asks before writing over it.
- **Syntax highlighting** with Tree-sitter for Swift, JSON, YAML, Markdown, JavaScript, TypeScript/TSX, Python, shell, HTML, CSS, Go, Rust, Java, Kotlin, C#, C, C++ and Zig, and a lightweight lexer for TOML, INI, XML, Objective-C and more. Only the visible text is colored, so large files stay fast.
- **Tabs**: documents open as tabs in one window, under a Honey tab strip with dirty dots. The tabs are Kiri's own, not the system's window tabs: opening a file never makes a window, so window managers (AeroSpace, yabai, Rectangle) have nothing to move or retile, and the file's text fades in where the window is. Each tab keeps its own selection, scroll position and find bar. Pull a tab out of the strip to give it a window of its own, or onto another window's strip to move it there; Window ▸ Move Tab to New Window and Merge All Windows do the same from the menu. A window comes back at the next launch with all its tabs. The selected tab shows its whole name and the others shorten in the middle ("Greet….swift"); with more tabs than fit, the strip scrolls and a menu at its end lists them all. A tab's tooltip is its file's path, and files with the same name show their folder ("index.ts · api").
- **Folder sidebar** (`kiri <folder>` or File ▸ Open Folder…): the folder's files beside the editor. A click on a file (or Space) shows it in the window's one preview tab, its title slanted, and the next file you click takes that tab over, so looking through a folder leaves one tab and not one for each file (and nothing in Open Recent: a file is a recent document once it is kept). Editing the file, saving it, a double-click on its row or on its tab, or Return on its row keeps the tab. A file that is already open is just selected. A folder opened with a file has the keyboard in the editor; a folder opened alone has it in the sidebar, so the arrows and Space look through the files at once. Each file has an icon for its kind (code, markup, data, settings, a script, a table, prose) in its language's syntax color, so a folder can be scanned by color; folders are amber. Rows say what is open: the name of a file that is open in one of the window's tabs is bold (slanted while it is the preview), and one with unsaved changes has the tabs' amber dot. A right-click (or Control-click) on a row has Open in New Window, Reveal in Finder, Copy Path, Copy Relative Path and, on a file, Rename…; on a folder and on the empty area there is New File…, which makes an empty file there and opens it. Names are typed in place: Return gives the name, Escape gives it up, and a name that is taken is refused. A renamed file's tab follows it. Drag the edge between the sidebar and the editor to make the sidebar narrower or wider (180 to 400 pt; a double-click on the edge gives the default 230 back); the width is remembered, and a narrow window shows less of it so the editor keeps its room.
- **Drop files on a window**: files dragged from Finder onto a Kiri window (its text, tab strip, sidebar or anywhere else) open as tabs of that window, in the order dropped; a folder opens as a folder window of its own. Kiri need not be the active app. Text dragged from elsewhere still drops into the text.
- **Typing animations** (Settings ▸ Typing animations, on by default): a honey caret that glides and breathes, a current-line highlight that eases between lines, a pulse on the matching bracket, syntax colors that crossfade instead of flickering, and rolling Ln/Col digits. Reduce Motion keeps the fades and drops movement; Motion: Off turns them all off.
- **Find and replace** in a glass bar that floats over the top of the editor instead of pushing the text down. Matches highlight as you type, with a count ("3 of 12"); match case and regular expressions (ICU; `$1` in the replacement); Replace and Replace All are one undo step each. The query is the system's shared find text, so ⌘E in another app carries over. Long files are searched off the main thread.
- **Command palette** (⌘K, or ⌘P): one field over the top of the editor that finds a file anywhere in the window's folder, another tab, a recent file or a command by a few of its letters ("grsw" finds Greeter.swift, "tc" Toggle Comment), with the letters marked. Every command of the menu bar is in it, read from the menus themselves, with the menu it is in and its key, so the palette is also where to look a key up. With nothing typed it lists the other tabs, the recent files and then the commands. ↑ and ↓ choose, Return opens the file (in a tab, to stay) or runs the command, Esc or ⌘K closes; `>` keeps to commands and `:` goes to a line. While the arrows have the selection on a theme, on light or dark, or on a language, the window shows it; moving on or Esc puts back what was there and Return keeps it. A folder's files are read in the background (up to 20 000, without `.git`, `node_modules`, build folders and the like), so the palette opens at once in a folder of any size.
- **Language picker** (⌃⌘L, or the language in the status bar): the palette's panel with only the languages, searched by name, by file extension or by file name ("rs" finds Rust, "yml" YAML, "Gemfile" Ruby), each row with its extensions beside it and the document's own language ticked. ↑ and ↓ show the language in the document as you pass it, Return keeps it, Esc puts back the one before.
- **Go to Line** (⌘L) is the palette with a colon typed: `:42` shows line 42 while you type it (`:42:7` for a column); Return keeps it, Esc goes back to where you were.
- **Status bar**: a glass capsule over the bottom of the text with the language, encoding and line endings (menus: each shows a capsule and a chevron under the pointer), the caret's position (click it for Go to Line; a selection shows its length, "Ln 12, Sel 5") and the indentation Shift Left and Right use ("Spaces: 4" or "Tabs"). It keeps its width as the caret moves, and fades to about a third while you type or scroll so the text under it shows; it is back after a second, or when the pointer comes near. With Reduce Motion or Increase Contrast it stays solid.
- **A hint in a new document**: an empty untitled document shows Open a file ⌘O, Open a folder ⇧⌘O, Everything else ⌘K (the command palette) and, until it is installed, Install the kiri command. Each line is a button; the first thing you type takes the hint away.
- **`kiri` command**: open files and folders from the terminal (see below).
- **Settings** (⌘,), in four groups: Appearance (theme, light or dark), Editor (font, text size, wrapping), Motion (motion, typing animations) and Command line tool (whether `kiri` is installed, and Install…). The font is any installed monospaced family, SF Mono by default, with a line of code in it under the menu; every window's text and line numbers follow at once.
- Line numbers, current-line highlight, editor font and text size, line wrapping, Shift Left and Right, Toggle Comment (⌘/; off in formats without comments: plain text, JSON, CSV) and File ▸ Open Recent.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N or ⌘T / ⌘O | New tab / open (as a tab) |
| ⌘S / ⇧⌘S | Save / Save As |
| ⇧⌘O | Open folder (a new window with a file sidebar) |
| ⌃⌘S | Show / hide the folder sidebar (also the button left of the tabs) |
| ⇧⌘E | Jump between sidebar and editor (in the sidebar: arrows, Space to show a file in the preview tab, Return to open it to stay and edit, type to select, Esc) |
| ⌘W / ⇧⌘W / ⌥⌘W | Close tab / close window / close all (a tab with unsaved changes asks) |
| ⌘F / ⌥⌘F | Find / Find and Replace (in the bar: Return and ⇧Return for next and previous, Tab between the fields, Esc to close with the match selected) |
| ⌘G / ⇧⌘G | Find next / previous, with the bar open or closed |
| ⌘E / ⌘J | Use the selection as the find text / scroll to the selection |
| ⌘K or ⌘P | Command palette: type a few letters of a file in the window's folder, a tab, a recent file or a command (shown with its key); ↑ ↓ choose, Return opens or runs it, Esc or ⌘K closes. `>` lists commands only, `:` goes to a line |
| ⌃⌘L | Language picker: type a language's name or a file extension, ↑ ↓ choose (the document shows it), Return keeps it, Esc puts the old one back |
| ⌘L | Go to line: the palette with a colon typed (`:12`, or `:12:5` for line and column; the line shows as you type, Return keeps it, Esc goes back) |
| ⌘] / ⌘[ | Shift lines right / left |
| ⌘/ | Comment or uncomment the selected lines (Format ▸ Toggle Comment), in the language's own way: `//`, `#`, `--`, `<!-- -->`, `/* */` |
| ⇧⌘] / ⇧⌘[ (or ⌃⇥ / ⌃⇧⇥), ⌘1–⌘9 | Next / previous tab, go to tab |
| ⌃⌘W | Wrap lines |
| ⌘? (⇧⌘/) | Keyboard Shortcuts window (everything, filterable). If macOS's own "Show Help menu" shortcut is on (System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts), the key opens the Help menu instead, where Keyboard Shortcuts is the one item |
| ⌘+ / ⌘- / ⌘0 | Bigger / smaller / actual size for the editor text (View ▸ Bigger Text, Smaller Text, Actual Size) |
| ⌘, | Settings (theme, light or dark, editor font, text size, wrapping, motion, the command line tool) |

These are the keys of a U.S. keyboard. On other layouts macOS moves a few of them (on a Swedish keyboard ⌘/ is ⌘´), and the menus show the key that works.

Everything else is in a menu, and so in the palette: Format has language,
encoding, BOM and line endings; View has theme, motion and typing animations.
⌃F2 opens the menu bar.

## Command line

Choose **Kiri ▸ Install Command Line Tool…** once (the item after Settings…), or press Install… in Settings ▸ Command line tool, which also says whether the command is installed; an empty new document offers it too until it is. It links `/usr/local/bin/kiri` to the script inside the app (`Kiri.app/Contents/Resources/kiri`, source in `App/CLI/kiri`), asking for an administrator password if needed. To do it by hand: `sudo ln -sf /Applications/Kiri.app/Contents/Resources/kiri /usr/local/bin/kiri`.

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
scripts/dmg.sh --build      # …and pack it into build/Kiri-<version>.dmg
```

`scripts/dmg.sh` makes the disk image people install from: a Honey window with Kiri, Applications and a bee between them (see `docs/DESIGN.md`, Disk image). It needs Python 3.10 or later and installs a pinned [dmgbuild](https://github.com/dmgbuild/dmgbuild) into `build/dmg-venv`, which writes Finder's layout without scripting Finder, so it also runs headless. `--open` mounts the result. To publish it on a website, sign and notarize it: see [docs/RELEASING.md](docs/RELEASING.md). Pushing a version tag (`git tag -a v0.2.0 -m "notes" && git push origin v0.2.0`) does all of that on GitHub and publishes it as a [release](https://github.com/ErikHellman/kiri/releases), where Kiri's built-in updater (Sparkle) finds it.

The first build downloads the Tree-sitter grammars, about 1.4 GB of git history, which takes several minutes. SwiftPM keeps them in `~/Library/Caches/org.swift.swiftpm`, so later builds start in seconds.

For development, generate the project and open it in Xcode:

```sh
cd App && xcodegen && open Kiri.xcodeproj
```

`Kiri.xcodeproj` and `Info.plist` are generated from `App/project.yml` and not checked in. To sign with your own identity, set `DEVELOPMENT_TEAM` in `App/project.yml` (Xcode) or `SIGN_IDENTITY` for `scripts/build.sh`.

Tests: `cd KiriKit && swift test` (the token, document-model, search, fuzzy-match, language-search, tab-layout, sidebar-width, reveal-timing and syntax tests; all but the last also run on Linux). Debug builds (or Release with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=KIRI_SELFTEST`) have smoke tests, run as `Kiri.app/Contents/MacOS/Kiri <file> <flag> YES -ApplePersistenceIgnoreState YES`. The last argument is required: it keeps AppKit from restoring your windows or reopening your unsaved documents into the test, and puts the test's recovery copies in the temporary folder; a launch with a `-Kiri…` flag refuses to run without it.

- `-KiriSelfTest`: typing through the event loop, dirty state, byte-exact save, undo, revert, highlighting after revert; and that saving is explicit: nothing reaches the file before Save (bytes, date and inode, also after an autosave), the recovery copy (written by itself, kept out of the file's folder, deleted by Save, Revert and close), Save in place for files of any type, the close question's Cancel, Don't Save and Save, Revert to Saved, a file changed on disk, Save on an untitled document, File ▸ Open Recent, and `kiri -w` waiting through Cancel, Save, Don't Save and a cancelled quit.
- `-KiriBehaviorTest`: focus at launch, the find bar (the Edit ▸ Find keys, the count, next and previous, highlights, replace and Replace All with undo, the field's Return, Tab and Escape), Go to Line (the palette with a colon: preview, Return, Escape, the colon taken away), the command palette (⌘K, ⌘P and ⌘L as keys; the rows read from the menu bar and what is left out; typing, the arrows, Return and Escape in its field; a command run with the keyboard back in the editor; files, tabs and recent files in a folder of the test's own; a theme, an appearance and a language shown while selected and nothing written to the saved preferences; never open with the find bar; the language picker on ⌃⌘L and from the status bar: every language with the document's own selected and ticked, search by name, extension and file name, the preview as the selection moves, Escape, Return, and ⌘K turning it back into the palette; `-KiriPaletteTest` runs these alone), the status bar (its items' names, the position button, a width that holds as the caret moves, resting while typing and scrolling), wrapping, the Save button (that it saves, and what it says and its shape with and without unsaved changes), opening/selecting/closing tabs (and that opening files in a window with tabs makes no window; a new tab's text coming in word by word, all of it showing when another tab takes its place or a key is pressed; `-KiriRevealFreeze <seconds>` holds the reveal still that far in, for pictures, and `-KiriRevealScrollTo <line>` scrolls a file opened by `-KiriOpenLater` to that line just after it opens), the tab strip following edits, saves and renames, the menus acting on the window in front (Find, Save, Revert to Saved), Toggle Comment on ⌘/ as a key (comment, uncomment, undo, the selection, off for plain text) and Keyboard Shortcuts on ⌘?, files, folders and text dropped on a window (on the text, the tab strip and the sidebar; on a window that isn't in front), the folder sidebar in a folder of the test's own in the temporary directory (the preview tab: one tab for files clicked one after another, the title and the text changing together, each way of keeping it (an edit, a save, a double-click, Return, opening it by name), find and Go to Line across the change, what VoiceOver hears; the marks on the rows of open, previewed and unsaved files following their tabs; where the keyboard is when a folder window opens (the editor with a file, the sidebar without) and that the sidebar shows the keyboard's row only in the key window; the rows' context menus (their items and when they are off, the two Copy items on a pasteboard of the test's own, New File… typed in place, names that are refused, New File… with the rows scrolled away, Rename… on a file with unsaved changes and on one that isn't open, Open in New Window, and the menus AppKit is given for a right-click on a row and on the empty area; Reveal in Finder is never chosen, and a test launch would not show Finder); the edge: dragged, at its limits, in a window at its narrowest, remembered without writing the saved preferences; `-KiriSidebarTest` runs these alone), the crossfade of a theme change (begun, replaced by a second change, gone afterwards and after a window closes mid-fade, the new colors drawn, none with reduced motion), a theme shown without being chosen (`ThemePreview`), Settings (its six groups; the theme swatches showing a theme under the pointer or the keyboard and putting the chosen one back, a press choosing one, closing with the pointer on a swatch; the Font menu's families, all measured to be monospaced; the open window's text and line numbers following a font at their size; a family that is gone giving SF Mono; nothing written to the saved preferences; `-KiriSettingsTest` runs these alone), the first-run hint (shown in a new untitled document only, gone with the first key and after undo, its lines' names and clicks).
- `-KiriFeedbackTest`: Help ▸ Send Feedback… (the window, its screenshot of the document window drawn and not blank, the screenshot off until switched on, ⌘Return doing nothing with nothing written and sending once there is, a click on the screenshot opening it larger, Escape and Cancel closing the window). A test launch never sends anything. `-KiriShowFeedback general|crash` opens the window for a picture of it (with `-KiriFeedbackText <text>`, `-KiriFeedbackScreenshotOn YES`, `-KiriFeedbackPreview YES`, `-KiriFeedbackThanks YES`, `-KiriFeedbackShot <path>`).
- `-KiriPerfTest`: typing and scrolling cost on the open file, and what the find bar costs on it (use a big file).
- `-KiriRelaunchTest <phase>`: what only a second launch shows. `crash` then `recover`: unsaved documents come back after `kill -9`; `frame-set` then `frame-check`: the window's frame is kept; `restore-quit` then `restore-check` (with `-NSQuitAlwaysKeepsWindows YES`): a window open at the quit comes back once; `tabs-quit` (with three files) then `tabs-check`: a window comes back with its three tabs in order, the one that showed showing; `empty-check`: with nothing to bring back, the launch starts in one empty document. These need AppKit to reopen things, which `-ApplePersistenceIgnoreState YES` turns off, so they run only in a copy of the app with another bundle identifier and name (its recovery record and saved state are then not Kiri's), without that argument.

## Layout

- `KiriKit/` Swift package:
  - `KiriKit`: the Honey + Liquid Glass style kit (tokens, Nunito, motion, glass, components, `StyleGallery`) the document model (`TextFile`, `LineIndex`, `Language`, syntax tokens and the fallback lexer), find and replace on strings (`TextSearch`), the sidebar's file icons (`FileIcon`), the command palette's fuzzy matching (`FuzzyQuery`: letters in order, scored for standing together, starting words and path components, and a file's name over its folders), the language picker's search (`LanguageSearch`: by name, file extension or file name), the status bar's position text and indentation detection (`StatusText`, `IndentStyle`), the tab strip's arithmetic (`TabLayout`: shortening names, sharing the width, telling same-named files apart), the timing of a file's words coming into view (`RevealSchedule`) and the folder sidebar's (`SidebarLayout`: the limits of its width, and what a narrow window shows of it).
  - `KiriSyntax`: Tree-sitter parsing and highlight queries (macOS only).
- `App/` the macOS app (XcodeGen spec in `App/project.yml`): `NSDocument` documents as tabs of windows that host SwiftUI (`DocumentWindow`, `WindowTabs`), the TextKit 2 editor, the command palette, settings and commands.
- `scripts/` `build.sh` (release build) and `icon/kiri-icon.mjs` (draws the app icon: a letter in a glass envelope with a honey seal; run with Node and Playwright).
- `docs/DESIGN.md` the design language.
- `site/` the website, [kiri.hellsoft.se](https://kiri.hellsoft.se), published by `.github/workflows/pages.yml` on every push to `main` that changes it.
- `docs/promo/` promotional graphics (`hero.png`, `social.png` for GitHub's social preview, `light-dark.png`, `themes.png`), drawn by `node scripts/promo/promo.mjs` (Node and Playwright) from the app screenshots in `docs/promo/shots`, which also writes the website's images into `site/assets`.

## License

Kiri is free and open source, licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <https://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <https://opensource.org/licenses/MIT>)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in Kiri by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

Nunito is licensed under the SIL Open Font License 1.1 (`KiriKit/Sources/KiriKit/Fonts/OFL.txt`). Tree-sitter grammars and queries are MIT licensed (`KiriKit/Sources/KiriSyntax/Queries/LICENSES.txt`).
