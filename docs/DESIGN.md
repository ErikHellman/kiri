# Kiri: Design Language ("Honey" + Liquid Glass)

Kiri uses Honey, the design language from Ting (agreed with Erik 2026-11-17), combined with Apple's Liquid Glass materials from macOS 26. The code lives in `KiriKit` (`KiriKit/Sources/KiriKit`) and the app's main window shows all of it in `StyleGallery` until the editor lands.

## 1. Principles

- **Warm, not sweet.** Cream and honey surfaces, plum-brown ink, one amber accent. No gradients on chrome.
- **Glass for chrome, paper for text.** Tabs, toolbar buttons, the status bar, find and quick-open float as warm Liquid Glass. The document itself sits on a solid `surface` panel, because text people read and edit must never sit on blur.
- **Shape tells state.** A control changes shape when its meaning changes (dirty dot → close button, Save pill → busy circle → "Saved" check). Color alone never carries state.
- **Spring, then settle.** ≈380 ms spring with slight overshoot for shape changes, under 200 ms for hover and color.
- **Respect the person.** Follow reduce motion, reduce transparency and increase contrast; keep WCAG 2.2 AA contrast in both themes.

## 2. Liquid Glass in Honey

| Kind | Material | Use |
|---|---|---|
| `chrome` | `Glass.regular` tinted with `surface` at 35 % | Tab strip, icon buttons, status bar, search field, toasts |
| `honey` | `Glass.regular` tinted with `accent` at 32 % | Something selected or active on glass |
| `prominent` | `Glass.regular` tinted `accent`, `accent-fg` text | The primary action (Save) |
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

## 4. Type

- **Nunito** (OFL, weights 400/600/700/800, bundled in `KiriKit/Sources/KiriKit/Fonts`) for all UI: `Font.honey(.body, weight:)`.
- Scale: 12 caption · 13 meta · 15 body · 17 panel title · 20 view title · 26 heading. Weights: 400 body, 600 secondary emphasis, 700 buttons and tab titles, 800 titles and section labels (11.5 pt uppercase, +0.06 em).
- **Editor and code:** SF Mono via `Font.honeyMono()` at 13 pt.
- `Honey.textScale` scales all of it (macOS has no Dynamic Type).

## 5. Shape and layout

- Radii (`Honey.Radius`): 20 panels, 16 cards, 12 controls, 8 small; buttons, chips and tabs are pills.
- Window: hidden title bar over `canvas`; traffic lights sit on the canvas; the editor (and any side panel) are 20 pt floating panels inset 10 pt, with the two-layer warm shadow (`honeyPanel()`), or a 2 pt outline with increased contrast.
- Toolbar row: glass tab strip and buttons on the canvas, above the editor panel. The status bar is a glass capsule floating over the bottom of the editor panel.

## 6. Motion

| Token | Value | Use |
|---|---|---|
| `Honey.quick` | 140 ms ease-out | Color, opacity, hover |
| `Honey.medium` | 240 ms | Small movement |
| `Honey.shape` / `.honeySpring` | spring 0.38 s, damping 0.72 | Shape changes, panels |

Signature components in Kiri:

1. **Sliding selection pill** for tabs and segmented controls (`HoneyTabStrip`, `HoneySegmentedPicker`).
2. **Dirty dot ↔ close:** an unsaved tab shows an amber dot that becomes the close button on hover.
3. **Busy → done** (`HoneyTaskButton`): Save squeezes into a circle with a spinner, opens into a green "Saved" check for 1.5 s, then returns.
4. **Press squish** (`HoneyGlassButtonStyle`): 0.96 scale and tighter corners while pressed.
5. **Pop in** (`AnyTransition.honeyPop`) for toasts and popovers.

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
