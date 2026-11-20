# Kiri

A beautiful text editor for quick edits.

Kiri is a native SwiftUI app for macOS that launches instantly, opens the files you reach for every day, and highlights the syntax of common programming languages. It is built for opening a file, making a change and getting back to work, not for replacing a full IDE.

## Goals

- **Instant launch.** Open to a usable editor with no waiting.
- **Looks great.** Warm "Honey" design language with Liquid Glass surfaces.
- **Common formats.** Plain text, Markdown, JSON, YAML, TOML, XML, CSV, logs and source code.
- **Syntax highlighting** for the most common programming languages.

## Status

Early development. Roadmap:

1. Honey + Liquid Glass style kit
2. Core macOS editor
3. Syntax highlighting
4. Polish

## Build

Needs macOS 26 and Xcode 26 (Liquid Glass).

```sh
brew install xcodegen
cd App && xcodegen && open Kiri.xcodeproj
```

The style kit is a Swift package: `cd KiriKit && swift test`. The design language is in [docs/DESIGN.md](docs/DESIGN.md).

## Layout

- `KiriKit/` Swift package: the Honey + Liquid Glass style kit (tokens, Nunito, motion, glass, components, `StyleGallery`).
- `App/` the macOS app (XcodeGen spec in `App/project.yml`).

Nunito is licensed under the SIL Open Font License 1.1 (`KiriKit/Sources/KiriKit/Fonts/OFL.txt`).
