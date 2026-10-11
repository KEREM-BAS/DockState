# Contributing to DockState

Thanks for helping! DockState aims to stay small, reliable and private. Before adding a feature, please open
an issue to discuss it — "does one thing well" is a feature too.

## Setup

- macOS 14+ and Xcode 16 or later. No other tools or package managers needed.
- `open DockState.xcodeproj` and Run.
- Accessibility permission is tied to the code signature. Ad-hoc ("Sign to Run Locally") builds may need the
  permission toggled again after rebuilding. To avoid that, create `Config/Signing.local.xcconfig`
  (git-ignored):

  ```
  DEVELOPMENT_TEAM = ABCDE12345
  CODE_SIGN_IDENTITY = Apple Development
  ```

## Project layout

```
DockState/                 App target (SwiftUI + AppKit): UI only
Packages/DockStateKit/
  Sources/DockStateCore    Pure logic: models, display & window matching, restore planning, undo, storage
  Sources/DockStateSystem  Thin adapters: Accessibility, CoreGraphics displays, app launching
  Tests/DockStateCoreTests Swift Testing suite (runs without any permission)
scripts/                   Build, DMG, notarization and string-catalog helpers
docs/                      Architecture, behavior, testing and release docs
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing matching or restore logic.

## Tests

```bash
cd Packages/DockStateKit && swift test
```

- Logic changes in `DockStateCore` need tests. Use the fixtures in `Tests/DockStateCoreTests` and the
  `FakeWindowServer` to simulate windows.
- Behavior that needs a real Mac (multiple monitors, sleep/wake, specific apps) is listed in
  [docs/TESTING.md](docs/TESTING.md). Mention in your PR which of those you checked by hand.
- Debug builds include an end-to-end self-test against a real window (see `DockState/App/SelfTest.swift`).

## Code style

- Swift 6 with strict concurrency. UI and model are `@MainActor`; Accessibility calls run off the main thread.
- Prefer clarity over cleverness; comment *why*, not *what*.
- Public API only — no private frameworks, no SIP requirements.
- Never log window titles or app names (`os.Logger` with `.private` if unavoidable).

## Translations

Strings live in `DockState/Localizable.xcstrings`.

1. After changing UI text, run `scripts/sync-strings.sh` (Xcode also updates the catalog when building).
2. To add a language: add it to the catalog in Xcode (or add `"xx"` localizations), add the code to
   `knownRegions` in the project, and add `.code("xx")` to `AppLanguage.supported` in
   `DockState/Settings/SettingsView.swift`.
3. Keep placeholders (`%@`, `%lld`, positional `%1$lld`) intact.

## Pull requests

- One topic per PR, on its own branch.
- `swift test` passes and the app builds (CI checks both).
- UI changes: add before/after screenshots.
