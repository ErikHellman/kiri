# Kiri: Design Language ("Honey" + Liquid Glass)

Kiri uses Honey, the design language from Ting (agreed with Erik 2026-11-17), combined with Apple's Liquid Glass materials from macOS 26. The code lives in `KiriKit` (`KiriKit/Sources/KiriKit`) and the app's main window shows all of it in `StyleGallery` until the editor lands.

## 1. Principles

- **Warm, not sweet.** Cream and honey surfaces, plum-brown ink, one amber accent. No gradients on chrome.
- **Glass for chrome, paper for text.** Tabs, toolbar buttons, the status bar, find and the command palette float as warm Liquid Glass. The document itself sits on a solid `surface` panel, because text people read and edit must never sit on blur.
- **Shape tells state.** A control changes shape when its meaning changes (dirty dot → close button; Save: glass circle → amber pill → busy circle → "Saved" check). Color alone never carries state.
- **Spring, then settle.** ≈380 ms spring with slight overshoot for shape changes, under 200 ms for hover and color.
- **Respect the person.** Follow reduce motion, reduce transparency and increase contrast; keep WCAG 2.2 AA contrast in both themes.

## 2. Liquid Glass in Honey

| Kind | Material | Use |
|---|---|---|
| `chrome` | `Glass.regular` tinted with `surface` at 35 % | Tab strip, icon buttons, status bar, search field, toasts |
| `honey` | `Glass.regular` tinted with `accent` at 32 % | Something selected or active on glass |
| `prominent` | `Glass.regular` tinted `accent`, `accent-fg` text | The primary action, while it has work: Save with unsaved changes |
| `tinted(color, foreground:)` | Any tint | One-offs |

- Apply with `.honeyGlass(kind, in: shape)` (or `radius:`); controls pass `interactive: true` so the glass reacts to the pointer.
- Glass that sits side by side goes in a `HoneyGlassGroup` (a `GlassEffectContainer` with the 10 pt gap), so neighbours blend and morph instead of stacking blurs.
- **Reduce transparency** or **increase contrast**: every glass surface becomes its solid Honey fill (`surface-2`, `accent-soft` or `accent`) with a `line` outline (2 pt with more contrast).
- Never put glass on glass, and never put body text on glass.

## 3. Color tokens

Same values as Ting (`Honey.swift`), with high-contrast variants. Kiri adds the editor tokens at the bottom.

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F5EEE1` | `#16120E` | Window background behind the floating panels |
| `surface` | `#FFFCF6` | `#251F18` | The editor panel, dialogs |
| `surface-2` | `#F2E8D6` | `#30281F` | Hover fills, chips, solid glass fallback |
| `surface-3` | `#EADCC4` | `#3B3127` | Pressed fills |
| `line` | `#E8DAC3` | `#3A3027` | Hairlines |
| `fg` | `#3B2A2F` | `#F6ECE0` | Text |
| `fg-muted` | `#76615A` | `#B5A492` | Secondary text (≥ 4.5:1) |
| `accent` | `#E09A2D` | `#F2A93B` | Primary fills, the dirty dot |
| `accent-fg` | `#2A1A08` | `#2A1A08` | Text on `accent` (never white on amber) |
| `accent-ink` | `#995A05` | `#F5B656` | Accent text and icons on surfaces |
| `accent-soft` | `#FBE7C2` | `#47331A` | Selected tab, tints |
| `focus` | `#B8700E` | `#F2A93B` | Focus rings |
| `danger` / `danger-fill` | `#C2412D` / `#C2381C` | `#FF8A70` / `#C8432A` | Destructive text / fills |
| `ok` | `#357A4E` | `#7FD09A` | Saved |
| `selection` | `#F6D9A0` | `#5C4220` | Selected text (`fg` ≥ 7:1 on it) |
| `current-line` | `#FAF3E6` | `#2C251D` | The caret's line |
| `gutter` | `#9A8478` | `#7E6E60` | Line numbers (≥ 3:1; `fg-muted` values with more contrast) |
| `caret` | = `focus` | = `focus` | The insertion point (≥ 3:1) |

`HoneyTests` checks these contrast promises in light, dark and both high-contrast modes.

### 3.1 Syntax colors

Warm, distinct hues on the solid editor surface. Every syntax token is ≥ 4.5:1 on `surface` and `current-line` (≥ 7:1 in the high-contrast variants); `SyntaxContrastTests` checks all four modes. Headings and `**strong**` Markdown are also bold, `*emphasis*` italic, so color never carries meaning alone.

| Token | Light | Dark | HC light | HC dark | Used for |
|---|---|---|---|---|---|
| `syn-keyword` | `#9B2C6E` | `#F08BC0` | `#8D2864` | `#F6A8D0` | Keywords, operators that are words, built-in variables (`self`) |
| `syn-string` | `#4E7A1F` | `#A8D58A` | `#395917` | `#BFE6A8` | Strings, Markdown code |
| `syn-number` | `#A34F00` | `#F5B656` | `#7F3E00` | `#FFC978` | Numbers, booleans, constants |
| `syn-comment` | `#7C6A5F` | `#A08E7E` | `#5B4E46` | `#C9BAAC` | Comments, block quotes |
| `syn-function` | `#1F6F8B` | `#7FC6E0` | `#18566C` | `#A6DCEE` | Functions and methods, links |
| `syn-type` | `#6A3FA0` | `#C3A6F5` | `#562F87` | `#D8C4FA` | Types, constructors, namespaces |
| `syn-property` | `#8A4B2A` | `#F0A07A` | `#6E3A1F` | `#F7BFA0` | Properties, fields, keys |
| `syn-tag` | `#B23A2A` | `#FF8A70` | `#8F2F22` | `#FFB3A0` | HTML/XML tags |
| `syn-attribute` | `#8A5A00` | `#F2C46B` | `#6E4800` | `#F7D592` | Attributes, decorators |
| `syn-punctuation` | `#76615A` | `#B5A492` | `#5D4D47` | `#D5C7B8` | Brackets, delimiters, operators |
| `syn-heading` | `#995A05` | `#F5B656` | `#744404` | `#FFC978` | Markdown headings, TOML/INI sections |
| `syn-escape` | `#A8327A` | `#F7A8D8` | `#8B2965` | `#FAC4E4` | Escapes, regexes, special punctuation |

Highlighting (`KiriSyntax`): Tree-sitter grammars (Swift, JSON, YAML, Markdown with inline, JavaScript, TypeScript/TSX, Python, shell, HTML, CSS, Go, Rust, Java, Kotlin, C#, C, C++ (C's query plus C++'s), Zig) parse on a background queue, incrementally after each burst of edits; only the visible text plus a margin is colored, from a parse that matches the text exactly. Other formats (TOML, INI, XML, Objective-C, …) use a small fallback lexer for strings, numbers, comments and keywords. Capture names map to tokens in `SyntaxKind(capture:)`.

### 3.2 Color themes

Honey is the default; Settings ▸ Theme (and View ▸ Theme) also offers **Matcha**, **Sakura**, **Tide**, **Lavender** and **Graphite**. Each theme is every token above, recolored, so code keeps using `Honey.fg`, `Color.honeyAccent` and friends and never names a theme.

- `scripts/themes/make-themes.py` generates them from Honey in OKLCH: the neutrals (paper and ink) move to the theme's hue and chroma, the accent family to its accent hue, syntax colors turn a little; lightness is kept, then nudged until every contrast promise in this section holds. It writes `KiriKit/Sources/KiriKit/HoneyThemes.swift` and `scripts/themes/themes.json`. `HoneyTests` checks every theme.
- `Honey.theme` is the theme in use. SwiftUI colors read it through an `@Observable`, so views redraw on a change; AppKit colors (`NSColor.honey`) look it up when drawn, and the editor redraws on `.honeyThemeDidChange`.
- `danger`, `danger-fill` and `ok` stay the same in every theme.
- The Dock icon follows the theme: `scripts/icon/kiri-icon.mjs` draws the icon once per theme from `themes.json` into `App/Kiri/ThemeIcons`, and `ThemeController` sets `NSApp.applicationIconImage`. Finder keeps the Honey icon (macOS has no alternate icons for Mac apps).

## 4. Type

- **Nunito** (OFL, weights 400/600/700/800, bundled in `KiriKit/Sources/KiriKit/Fonts`) for all UI: `Font.honey(.body, weight:)`.
- Scale: 12 caption · 13 meta · 15 body · 17 panel title · 20 view title · 26 heading. Weights: 400 body, 600 secondary emphasis, 700 buttons and tab titles, 800 titles and section labels (11.5 pt uppercase, +0.06 em).
- **Editor and code:** SF Mono via `Font.honeyMono()` at 13 pt.
- **Slanted** (`Font.honeyOblique`): a title that is provisional, which today is a preview tab's. Nunito has no italic face, so the upright one is sheared by `Honey.obliqueShear` (0.2, about 11°), as a browser does for a font without italics.
- `Honey.textScale` scales all of it (macOS has no Dynamic Type).

## 5. Shape and layout

- Radii (`Honey.Radius`): 20 panels, 16 cards, 12 controls, 8 small; buttons, chips and tabs are pills.
- Window: hidden title bar over `canvas`; traffic lights sit on the canvas; the editor (and any side panel) are 20 pt floating panels inset 10 pt, with the two-layer warm shadow (`honeyPanel()`), or a 2 pt outline with increased contrast.
- Toolbar row: glass tab strip and buttons on the canvas, above the editor panel. The status bar is a glass capsule floating over the bottom of the editor panel.

## 6. Motion

| Token | Value | Use |
|---|---|---|
| `Honey.quick` | 140 ms ease-out | Color, opacity, hover |
| `Honey.medium` | 240 ms | Small movement; chrome fading to rest (the status bar) |
| `Honey.shape` / `.honeySpring` | spring 0.38 s, damping 0.72 | Shape changes, panels |

Signature components in Kiri:

1. **Sliding selection pill** for tabs and segmented controls (`HoneyTabStrip`, `HoneySegmentedPicker`).
2. **Dirty dot ↔ close:** an unsaved tab shows an amber dot that becomes the close button on hover.
3. **Rest → work → busy → done** (`HoneyTaskButton`, `HoneyTaskState.Look`): with nothing to save, Save rests as a 30 pt `chrome` glass circle with the icon alone, at full strength and still a working button (in an untitled document it opens the Save panel). Unsaved changes spring it open into the amber "Save" pill, the one saturated thing in the window, so amber means "you have unsaved changes"; it follows `WindowTabs.dirty`, set in the same refresh as the tab's dot. Pressed, it squeezes into a circle with a spinner, opens into a green "Saved" check for 1.5 s, then returns to the circle. The top bar's row moves on the same spring, so a crowded tab strip takes up the width the circle frees; with reduced motion the change is the quick ease without the spring, with Motion: Off it is immediate. VoiceOver hears "Save" in every state, with "No unsaved changes", "Unsaved changes", "Saving" or "Saved" as its value; the tooltip is "Save (⌘S)".
4. **Press squish** (`HoneyGlassButtonStyle`): 0.96 scale and tighter corners while pressed.
5. **Pop in** (`AnyTransition.honeyPop`) for toasts and popovers.

Typing animations in the editor (Settings ▸ Typing animations, on by default), all outside text layout so typing and scrolling stay as fast as without them:

- **Caret**: a 2 pt honey (`caret`) bar with a soft `focus` glow glides 90 ms between positions and breathes (opacity 1 → 0.25, 1.1 s cycle) instead of blinking.
- **Current line** eases 160 ms to the caret's new line.
- **Matching bracket** pulses once (`accent-soft` fill, `accent` outline, 0.5 s) when the caret lands next to a bracket.
- **Syntax colors** crossfade for 120 ms when a recolor changes visible colors, so they don't flicker.

`EditorAnimation.resolve` maps the settings to `full`, `fades` (Reduce Motion / Motion: Reduced: fades only, nothing glides or scales) or `none` (Motion: Off or the toggle off: the system caret, no layers).

Motion levels (`HoneyMotionLevel`): `system` (default, follows reduce motion), `full`, `reduced` (no movement or overshoot, quick cross-fades), `off` (no animation, set at the root by `honeyRoot`).

## 7. Using the kit

```swift
WindowGroup {
    ContentView()
        .honeyCanvas()
        .honeyRoot(appearance)   // theme, motion, Nunito, amber tint
}
.windowStyle(.hiddenTitleBar)
```

Call `Honey.registerFonts()` once at launch.

### The status bar

`EditorStatusBar` (built from `HoneyStatusBar`, `HoneyStatusMenu`, `HoneyStatusButton` and `HoneyStatusItem`): a 28 pt `chrome` glass capsule, 8 pt above the bottom of the editor panel. The editor keeps a 44 pt inset below the last line, so the end of a file scrolls clear of it.

- **Items, in order:** the language (a menu), the caret's position (a button: Go to Line), the indentation (a label), the encoding and the line endings (menus). In a panel too narrow for all of them the indentation goes first, then the encoding and line endings, then the language.
- **What can be pressed says so.** On hover and on keyboard focus an item shows a `surface-2` capsule 24 pt high (the tabs' hover; `surface-3` when the bar is solid), with the 2 pt `focus` ring for the keyboard. A menu also shows a small chevron, in room that is always kept for it, so the bar doesn't change width. The language is an `accent-soft` pill with `accent-ink` text at rest, and the pill grows to take the chevron in. The indentation does nothing when pressed and shows nothing.
- **A steady width.** The position keeps the room of the widest text the document can show (as many digits as its last line, its longest line and its length need; at least "Ln 88, Sel 888"), in tabular digits, text at the leading edge. A selection's length takes the column's place ("Ln 12, Sel 5"), not more room. The indentation keeps the room of "Spaces: 8". The room changes only when a count passes a power of ten.
- **Rest.** While the person types or scrolls, the bar fades to `Honey.restOpacity` (35 %) over `Honey.medium`: its content, and the glass gives way to 35 % of its solid fill with a hairline, so the text under it is neither blurred nor bent. It comes back over `Honey.quick` a second after the last key or scroll, when the pointer moves within 40 pt of it, when the keyboard goes to one of its items or when a menu opens; it takes clicks all the while. With reduced motion (the system's or Motion: Reduced or Off) and with increased contrast it stays solid.
- **Names.** VoiceOver hears "Language, Swift", "Encoding, UTF-8", "Line endings, LF" (pop-up buttons), "Go to Line" with "Line 12 of 340, column 5" as its value, and "Indentation, 4 spaces".

### The folder sidebar

A folder window (`kiri <folder>`, File ▸ Open Folder…) shows the folder's tree in a `chrome` glass panel beside the editor (`FolderSidebar`); every tab of the window shares it (`FolderSession`).

- **The preview tab.** A click on a file's row, or Space with the keyboard on it, shows the file in the window's preview tab, and the next file shown that way takes that tab over: the document in the tab's window is replaced (`DocumentWindow.show`), so no tab closes or opens, the strip stays where it is and only a title changes, in the same turn as the text. An empty untitled tab (what a folder window starts with) is taken over the same way; with neither, the preview opens after the tab the file was picked in. A file that is open already is selected instead.
- **Its title slants** (`Font.honeyOblique`), in the tab and in the strip's overflow menu ("name (preview)"): the shape says it is provisional, not color. VoiceOver hears "Preview" as the tab's value and has a Keep Open action; a file's row has Open in a Tab.
- **Keeping it.** An edit (a preview never has unsaved changes), a save, a double-click on the row or on the tab, Return on the row (which also moves the keyboard to the editor), or opening the file by name (⌘O, Open Recent, `kiri`, a drop) makes it a tab like any other, and the next file clicked gets a new preview.
- **The keyboard.** The panel never has an outline of its own. While the sidebar has the keyboard (⇧⌘E, Space on a row, a folder window opened with no file), the keyboard's row has a `surface-2` capsule with the 2 pt `focus` ring, and only in the key window: a window that isn't key shows the current file's `accent-soft` capsule and nothing else, as it does when the editor has the keyboard. A folder window that opens with a file gives the keyboard to the editor (the sidebar is the first thing in the window that can take it, and would otherwise get it); one that opens with only its empty document leaves it in the sidebar, on the first row.
- **Icons** (`FileIcon`): a folder is `folder.fill` in `accent-ink`. A file has the shape of its kind (code and markup `</>`, data `{}`, settings a gear, a script a terminal, a table, a database, prose a text document) tinted with the syntax token of its language (Swift `syn-number`, JavaScript and JSON `syn-attribute`, TypeScript, Go and Markdown `syn-function`, Python and shell `syn-string`, Rust and YAML/TOML/INI `syn-property`, HTML, XML, Ruby and Java `syn-tag`, Kotlin, C# and CSS `syn-type`, the C family `syn-keyword`, SQL `syn-escape`), so a folder can be scanned by color while the shape still says the kind. Plain text and files of no known language keep `doc.text` in `fg-muted`; no file is amber (`syn-heading` is not used). The language comes from the name alone. `FileIconTests` holds every tint, and `fg-muted`, to 3:1 on `surface-2`, `canvas`, `surface` and `accent-soft` in every theme and mode.
- **Rows say what is open.** A file's name is Nunito 600 at 85 % `fg`; open in one of the window's tabs it is 700 at full `fg`, slanted while that tab is the preview, and with unsaved changes the row ends in the tabs' 7 pt `accent` dot (weight, slant and a dot: never color alone). The file the window shows has the `accent-soft` capsule. The marks are made from the tab strip's own items (`WindowTabs.openFiles`), so they change in the same refresh as the tabs. VoiceOver hears "Open", "Open, edited" or "Preview" as the row's value, and the current file as selected.
- **Context menus** (`SidebarMenu`), the system's own menu, in groups. A file: Open in New Window · Reveal in Finder, Copy Path, Copy Relative Path · Rename…. A folder: New File… · Open in New Window · Reveal in Finder, Copy Path, Copy Relative Path. The header and the empty area below the rows, which stand for the folder the window shows: New File… · Reveal in Finder, Copy Path. Rename… and New File… are off in a folder that can't be written to. There is no Move to Trash yet. Open in New Window gives a file a window of its own without the sidebar (a tab that shows it moves out), and a folder a folder window.
- **Names are typed in place** (`NameField`): Rename… turns the row's name into a field holding it, selected; New File… opens the folder and puts an empty row at its top, scrolled into view (for the window's own folder the row sits above the list, wherever the list is scrolled to). The field is a paper well (`surface`, `small` radius) with the 2 pt `focus` ring. Return gives the name, Escape or the keyboard leaving the field gives it up and changes nothing. A name that is taken, empty, or has / or : in it is refused: the ring turns `danger` and the reason shows under the field in `danger` 12 pt (and is announced), until the text changes. Nothing is ever written over. A new file is made empty and opens in a tab to stay, with the keyboard in its editor; a renamed file that is open is moved by its document, so its tab and its row follow and unsaved changes stay unsaved.
- **VoiceOver** hears the panel as "Files in tidepool" and each row as a button: a file by its name, a folder as "Sources, folder" with "collapsed" or "expanded" as its value. A row inside a folder adds its depth ("level 2"), after what it is in a tab ("Open, level 2"). This is the tree in words, not an outline: SwiftUI gives custom rows no outline role, so VoiceOver's own outline commands do not apply.
- **Its width** is the person's: 230 pt until the edge is dragged, then anything from 180 to 400 pt (`SidebarLayout`), one width for every folder window and tab, remembered (`Prefs.sidebarWidthKey`). The edge is the 10 pt of canvas between the two panels (`SidebarEdge`): the pointer over it is the column-resize cursor and a 4 × 36 pt `fg-muted` grip fades in at its middle (the shape says it can be moved; nothing shows at rest), a drag follows the pointer, a double-click springs back to the default. A window too narrow for the width shows what leaves the editor 220 pt, down to 180, and the whole width again when it is widened; the narrowest window (480 pt) holds both. VoiceOver has it as a slider, "Sidebar width, 230 points", stepping 10 pt, with a Default Width action.
- **The window's bars**: an open find bar outlives the file and searches the one that shows now; the command palette closes (what it listed, or the line typed in it, was the other file's).

### First-run hint

An untitled document that opened empty shows `StartHint` centred on its paper, above the status bar and behind the find bar: at most four lines, 28 pt high and 216 pt wide, 13 pt `fg-muted` Nunito 600 with the Keyboard Shortcuts window's key caps at the trailing edge. Open a file ⌘O, Open a folder ⇧⌘O, Everything else ⌘K (the command palette, where every command is, with its key), and "Install the kiri command" in `accent-ink` (a link, no key) until a terminal has the command. While the palette is open the hint is out of its way (glass is never laid over words), and back when it closes.

- Each line is a button: on hover a `surface-2` fill with the `small` radius and `fg` text (the link underlines), the `focus` ring for the keyboard. Nothing else in the hint takes clicks, and it never takes the keyboard: the caret is on line 1 and typing starts the document.
- It goes with the first character put in (typed, pasted or dropped), fading over `Honey.quick` (at once with reduced motion), and doesn't come back in that document, not after undo either. A document with a file never shows it, nor does a panel too small to hold it whole.

### Bars over the editor: find and the command palette

Find (`FindBar`, ⌘F) and the command palette (`CommandPalette`, ⌘K) are `chrome` glass with the `control` radius, floating 12 pt below the top of the editor panel, one at a time: opening one closes the other. They never push the text down: the editor scrolls what they point at into the part nothing floats over (a line of air below the bar, above the status capsule), and may scroll the first lines out from under the bar. When that brings the head of the file into view it shows from line 1, whole and 8 pt below the bar, and stays so when the replace row opens or closes: a first line cut by the bar's edge is never left.

- **Find bar:** the find field with the count inside it ("3 of 12", "12 matches", "No matches", "Invalid pattern"; a width that doesn't change as the count does), match case and regular expression, previous and next, close; a chevron at the leading edge opens the replace row (its field, Replace, Replace All). Fields are paper-colored wells with a `line` hairline, and the `focus` ring (2 pt) on the one the keyboard is in.
- **Buttons in a bar** have no glass of their own (never glass on glass): 26 pt, `small` radius, a faint `fg` fill on hover and press. A toggle that is on is an `accent-soft` pill with an `accent` outline and `accent-ink` text, so the shape says it too.
- **Matches in the text:** every match in `accent-soft`, the current one in `selection` with a 1.5 pt `accent` outline, drawn as layers under the glyphs (never text attributes, never dimming the rest). While the keyboard is in the bar the current match is not selected, so it never shows the grey of an unfocused selection; Escape selects it.
- **Motion:** both arrive with `honeyPop` on the spring and fade with Reduce Motion; the replace row opens with the spring (the chevron turns), or simply changes. Nothing in the palette's list moves: the selection and the rows change at once.

### The command palette

One field finds a file, a tab or a command by a few of its letters (`PaletteController`; ⌘K, also ⌘P, and ⌘L with a colon typed). It is one glass panel up to 520 pt wide with the 2 pt `focus` ring: the field (38 pt, the find bar's text) over a `line` hairline and the list, at most eight 30 pt rows and as many as the panel has room for above the status capsule; more scroll. The keyboard stays in the field throughout.

- **A row** is a button: a 16 pt icon, the title in Nunito 600, a muted 12 pt detail, and at the trailing edge a command's key in the Keyboard Shortcuts window's key caps. A file has its `FileIcon` and its folder (from the window's folder, or from `~`) as the detail; a tab the quiet `rectangle.stack`; a command `command`, or a checkmark where its menu item has one, or an open circle for one of several choices that is not the one in force, and its menu as the detail ("View ▸ Theme"). One choice of several reads "Theme: Tide". A panel too narrow for all of it (the editor beside the sidebar in a small window) drops the detail, never the key.
- **The letters typed are marked** by weight and ink together, never by color alone: 800 at full `fg`, against 600 at 80 % `fg` in the title and 600 `fg-muted` in the detail.
- **The selected row** has the `accent-soft` capsule of the sidebar's current file. The pointer over a row shows the hover fill and selects nothing; a click runs the row. VoiceOver is told the number of results and the selected row as either changes ("12 results. Save, Command S"; "Save As…, Shift Command S, 2 of 12"), since the keyboard never leaves the field.
- **What it lists.** Nothing typed: the window's other tabs, the recent files, then every command in the menus' order. Typed: what matches (`FuzzyQuery`), best first, a file or tab ahead of a command that matches as well; a file that is open and in the folder shows once, as its tab. `>` keeps to commands. Nothing matching says so in a sentence ("No file, tab or command matches “zq”. Fewer letters may find it.").
- **Commands are the menu bar's.** The list is read from the menus when the palette opens (`MenuCommands`): there is no list of commands beside the menus. Left out are the items for the app as a whole (Hide, Quit), the window list, recent files and Go to Tab (those are files and tabs), what macOS adds to the end of every Edit menu, and items that are off. Running a row closes the palette, gives the keyboard back to the editor and only then, a turn later, chooses the item in its menu: Copy, Undo or Make Upper Case act on the document and not on the palette's field.
- **A line** (`:`, Go to Line): `:42` or `:42:7`. In place of the list one line says where Return goes ("Go to line 42", selected like a row), what to type, or "Not a line" in `danger` with a mark, and "of 340" at its end. The line shows as its number is typed: the caret (and so the current-line highlight) goes there and the line pulses once in `accent-soft` (0.7 s); with Reduce Motion or Motion: Off the band stays instead. Return keeps it, Escape or taking the colon away goes back to the selection and the scroll position from before.
- **Previews.** While the selection is on a color theme, on Light, Dark or System, or on a language, the app shows it: the theme and the appearance in every window with the theme crossfade (`ThemePreview`: held in memory, the setting written only by Return), the language in this document once the selection has rested 120 ms. A run of rows passed shows the first and the last, one fade at a time. Anything that closes the palette, or its window no longer being in front, puts back what was chosen.
