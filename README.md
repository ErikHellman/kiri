# Kiri

A beautiful text editor for quick edits.

Kiri is a native SwiftUI app for macOS that launches instantly, opens the files you reach for every day, and highlights the syntax of common programming languages. It is built for opening a file, making a change and getting back to work, not for replacing a full IDE.

## Features

- **Instant launch** into an empty editor (about 0.3 s to the first window on an M-series Mac, measured with `-KiriLaunchTiming YES`).
- **Honey + Liquid Glass design**: glass chrome (tab strip, Save, status bar, Go to Line) over a warm canvas, the text on a solid panel. Light, dark and high-contrast; follows Reduce Motion and Reduce Transparency.
- **Any text file**: plain text, Markdown, JSON, YAML, TOML, XML, CSV, logs, source code. Kiri detects the encoding (UTF-8, UTF-16/32 with or without BOM, Windows Latin 1) and line endings (LF, CRLF, CR) and saves them back unchanged; change either from the status bar.
- **Syntax highlighting** with Tree-sitter for Swift, JSON, YAML, Markdown, JavaScript, TypeScript/TSX, Python, shell, HTML and CSS, and a lightweight lexer for TOML, INI, XML, Rust, Go and more. Only the visible text is colored, so large files stay fast.
- **Tabs**: documents open as tabs in one window (native window tabbing under a Honey tab strip, with dirty dots).
- **Typing animations** (Settings ▸ Typing animations, on by default): a honey caret that glides and breathes, a current-line highlight that eases between lines, a pulse on the matching bracket, syntax colors that crossfade instead of flickering, and rolling Ln/Col digits. Reduce Motion keeps the fades and drops movement; Motion: Off turns them all off. A letter fade-in exists in the code but is off: TextKit 2 doesn't yet redraw the fading letter every frame.
- Line numbers, current-line highlight, find and replace, Go to Line, text size, line wrapping, File ▸ Open Recent and Revert.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N or ⌘T / ⌘O | New tab / open (as a tab) |
| ⌘S / ⇧⌘S | Save / Duplicate |
| ⌘W | Close tab |
| ⌘F / ⌥⌘F | Find / Find and Replace |
| ⌘G / ⇧⌘G | Find next / previous |
| ⌘L | Go to line (`12` or `12:5` for line and column) |
| ⌘] / ⌘[ | Shift lines right / left |
| ⇧⌘] / ⇧⌘[ , ⌘1–⌘9 | Next / previous tab, go to tab |
| ⌃⌘W | Wrap lines |
| ⌘/ | Keyboard Shortcuts window (everything, filterable) |
| ⌘+ / ⌘- / ⌘0 | Bigger / smaller / actual text size |
| ⌘, | Settings (theme, motion, text size, wrapping) |

Everything else is in a menu: Format has language, encoding, BOM and line
endings; View has theme, motion and typing animations. ⌃F2 opens the menu bar.

## Build

Needs macOS 26 and Xcode 26 or later, and XcodeGen.

```sh
brew install xcodegen
scripts/build.sh            # release build → build/Kiri.app (ad-hoc signed)
scripts/build.sh --install  # …and copy it to /Applications
```

For development, generate the project and open it in Xcode:

```sh
cd App && xcodegen && open Kiri.xcodeproj
```

`Kiri.xcodeproj` and `Info.plist` are generated from `App/project.yml` and not checked in. To sign with your own identity, set `DEVELOPMENT_TEAM` in `App/project.yml` (Xcode) or `SIGN_IDENTITY` for `scripts/build.sh`.

Tests: `cd KiriKit && swift test` (the token, document-model and syntax tests; the first two also run on Linux). Debug builds (or Release with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=KIRI_SELFTEST`) have smoke tests, run as `Kiri.app/Contents/MacOS/Kiri <file> <flag> YES`:

- `-KiriSelfTest`: typing through the event loop, dirty state, byte-exact save, undo, revert, highlighting after revert.
- `-KiriBehaviorTest`: focus at launch, Go to Line, wrapping, the Save button, opening/selecting/closing tabs, the letter fade.
- `-KiriPerfTest`: typing and scrolling cost on the open file.

## Layout

- `KiriKit/` Swift package:
  - `KiriKit`: the Honey + Liquid Glass style kit (tokens, Nunito, motion, glass, components, `StyleGallery`) and the document model (`TextFile`, `LineIndex`, `Language`, syntax tokens and the fallback lexer).
  - `KiriSyntax`: Tree-sitter parsing and highlight queries (macOS only).
- `App/` the macOS app (XcodeGen spec in `App/project.yml`): `DocumentGroup` documents, the TextKit 2 editor, tabs, settings and commands.
- `scripts/` `build.sh` (release build) and `icon/kiri-icon.mjs` (draws the app icon: a letter in a glass envelope with a honey seal; run with Node and Playwright).
- `docs/DESIGN.md` the design language.

Nunito is licensed under the SIL Open Font License 1.1 (`KiriKit/Sources/KiriKit/Fonts/OFL.txt`). Tree-sitter grammars and queries are MIT licensed (`KiriKit/Sources/KiriSyntax/Queries/LICENSES.txt`).
