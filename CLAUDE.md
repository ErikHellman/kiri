# Kiri

## Concurrency

The app targets (Kiri, KiriVideo) default to the main actor (`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` in `App/project.yml`), so they need no `@MainActor`. Work that must stay off the main thread (reading files and folders, the large-file index and search, highlighting, find, archives, image decoding, the Markdown render) is marked `nonisolated`, or `@concurrent` for an async function, and so is anything it hands across (tokens, results). Callbacks AppKit or a queue calls (`@Sendable` closures, KVO) are not main-actor: they keep `MainActor.assumeIsolated`. Approachable concurrency stays off, so a `nonisolated async` function runs off the main actor. KiriKit is not main-actor by default: it is plain logic that also builds on Linux.

## Lint and warnings

Warnings are errors in CI, in the Debug build, the nightly Release build and KiriKit's tests (`KIRI_WARNINGS_AS_ERRORS=YES`); `KIRI_WARNINGS_AS_ERRORS=YES scripts/build.sh` does the same locally, as does `KIRI_WARNINGS_AS_ERRORS=YES swift test` in KiriKit; `xcodebuild` needs it as a build setting argument (`xcodebuild … KIRI_WARNINGS_AS_ERRORS=YES`), since `App/project.yml` sets it to NO. CI also runs SwiftLint (`.swiftlint.yml`, a small rule set; `KiriKit/Tests/.swiftlint.yml` allows force unwraps in tests) with `swiftlint lint --strict` from the repository root, at the version pinned in `.github/workflows/ci.yml`; install it with `brew install swiftlint` and run the same before pushing. A justified exception is a targeted `// swiftlint:disable:next <rule> - <reason>`; only the self-test files turn a rule (force unwrapping) off for the whole file. The README's Tests section lists the KiriKit tests and the Debug self-tests.

## Periphery

Periphery finds unused code: `scripts/periphery.sh` (needs `brew install xcodegen periphery`) builds the app and KiriKit's tests in its own generated project (`App/periphery.yml`, `.periphery.yml`) and lists what nothing uses. Run it before tagging a release, after removing or replacing a feature, and after a large refactor. It is not in CI: code reached only by name at run time (`NSClassFromString`, `@objc` names in Info.plist, selectors, `$binding` uses) shows up as unused, so grep before deleting anything it lists. Keep such code with `// periphery:ignore - <why>` (or `// periphery:ignore:parameters <names> - <why>`) above the declaration; `@objc` declarations are kept by the config.

## Releases

Follow `docs/RELEASING.md`. Every release has written release notes: before tagging, write `docs/release-notes/<version>.md` covering every user-visible change since the previous tag, one short bullet (one or two sentences) per change, merge it to `main`, then tag that merged commit. The release workflow stops without them, and the same text becomes the GitHub release, the Sparkle update window and Kiri's What's new notice.
