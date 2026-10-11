# Contributing to DockState

Thanks for helping! DockState aims to stay small, reliable and private. Before adding a feature, please open
an issue to discuss it — "does one thing well" is a feature too.

## Setup

- macOS 14+ and Xcode 26 or later (what CI uses). No other tools or package managers needed.
- `open DockState.xcodeproj` and Run. Debug builds are **DockState Dev** (`DockStateDev.app`, bundle ID
  `com.kerembas.DockState.debug`) with their own settings, workspaces and Accessibility entry, so they can run
  next to an installed DockState without affecting it.
- Accessibility permission is tied to the code signature. Ad-hoc ("Sign to Run Locally") builds may need the
  permission toggled again after rebuilding. To avoid that, create `Config/Signing.local.xcconfig`
  (git-ignored):

  ```
  DEVELOPMENT_TEAM = ABCDE12345
  CODE_SIGN_IDENTITY = Apple Development
  CODE_SIGN_ENTITLEMENTS =
  ```

  (The last line drops the entitlement ad-hoc builds need to load Sparkle.framework without a team ID.)

## Project layout

```
DockState/                 App target (SwiftUI + AppKit): UI only
Packages/DockStateKit/
  Sources/DockStateCore    Pure logic: models, display & window matching, restore planning, undo, storage
  Sources/DockStateSystem  Thin adapters: Accessibility, CoreGraphics displays, app launching
  Tests/DockStateCoreTests Swift Testing suite (runs without any permission)
Tools/TestWindow           Throw-away app used by the end-to-end self-test
scripts/                   Build, DMG, notarization, string-catalog and test helpers
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
- Debug builds include an end-to-end self-test against a real (throw-away) window, and a demo mode for
  checking every screen in every language — see [docs/TESTING.md](docs/TESTING.md).

## Code style

- Swift 6 with strict concurrency. UI and model are `@MainActor`; Accessibility calls run off the main thread.
- Prefer clarity over cleverness; comment *why*, not *what*.
- Public API only — no private frameworks, no SIP requirements.
- Never log window titles or app names (`os.Logger` with `.private` if unavoidable).

## Translations

Strings live in `DockState/Localizable.xcstrings`.

1. After changing UI text, run `scripts/sync-strings.sh` (Xcode also updates the catalog when building).
   CI fails when the catalog is out of sync with the code (`scripts/check-strings.sh`) and warns about
   missing translations — you don't need to speak every language to contribute.
2. To add a language: add it to the catalog in Xcode (or add `"xx"` localizations), add the code to
   `knownRegions` in the project, and add `.code("xx")` to `AppLanguage.supported` in
   `DockState/Settings/SettingsView.swift`.
3. Keep placeholders (`%@`, `%lld`, positional `%1$lld`) intact, and add English plural variants for
   strings with a count.
4. Check the UI in the new language with demo mode at the window's minimum size.

## Pull requests

- One topic per PR, on its own branch.
- `swift test` passes and the app builds (CI checks both).
- UI changes: add before/after screenshots.
