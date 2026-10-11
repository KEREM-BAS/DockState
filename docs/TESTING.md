# Testing

## Automated (CI, no permissions needed)

`cd Packages/DockStateKit && swift test` runs the Swift Testing suite (90 tests):

| Area | Covered |
| --- | --- |
| Geometry | clamping, tolerance, placement equivalence, display containment, setup key |
| Store | round-trip, missing file, corrupt file moved aside, unique backup names, structurally invalid file, newer schema read-only and backed up once (also when undecodable), unversioned file migrated, unknown enum values, `lastRestoredAt` |
| Display recognition | identical setup, port change, rearrangement, resolution change, laptop-only vs desk, extra displays (Sidecar, opened lid), laptop-only never matching a desk, different serial/model, vendor-0 displays need the same name, identical monitors told apart by position (also with an extra display on the left), indistinguishable monitors flagged ambiguous |
| Recognizer ranking | coverage before Always, Always before recently edited, last restored, newest |
| Policies | auto-restore only on a setup change, per mode; late placement consent |
| Debounce | event bursts collapse to one action, cancel |
| Window matching | unique window with changed title, unrelated lone window not moved, several windows by title with swapped z-order, indistinguishable windows skipped, competing unassigned saved window, new window opened after saving, closed window, app not running, optimal assignment |
| Planning | full reconnect, already in place, missing display policies, minimized / full-screen / excluded, excluded window never stolen, proportional resize, rearranged displays, straddling windows left alone, unreachable title bars pulled below the menu bar |
| Execution & undo | partial failures, undo, undo respecting user-moved and closed windows, minimum-size constraints, grid-snapping windows count as in place, failed-but-changed moves undoable, windows moved twice |
| Transfer | export/import round trip, titles stripped, never overwriting, automation not taken over, invalid files |

CI also checks that `Localizable.xcstrings` is in sync with the code (`scripts/check-strings.sh`) and builds
the universal Release app.

## End-to-end self-test (Debug builds, real windows)

Debug builds are **DockState Dev** (`DockStateDev.app`, bundle ID `com.kerembas.DockState.debug`). They keep
their own settings, workspaces (`~/Library/Application Support/DockState Dev`) and Accessibility entry, so running
one never affects an installed DockState. Grant Accessibility to `DockStateDev.app`, then:

```bash
scripts/make-test-window-app.sh
open build/DockStateTestWindow.app
open -n -a "$PWD/build/DerivedData/Build/Products/Debug/DockStateDev.app" --args \
  -DockStateSelfTest /tmp/selftest.txt -DockStateSelfTestApp app.dockstate.testwindow \
  -DockStateSelfTestFile "$PWD/build/DockStateTestWindow.app"
cat /tmp/selftest.txt
```

The test window app exists only for this test (it opens one window, at a different position on each launch),
so the test never touches your own apps. Using a throw-away store, the self-test:

1. saves the window, moves it away, checks the setup is recognized and the plan has one move;
2. restores, checks the frame, checks nothing is left to move;
3. undoes and checks the window went back;
4. checks an excluded window is never planned for a move;
5. relaunches the app right after Undo and checks it is **not** placed (consent withdrawn);
6. restores again, relaunches, and checks the window **is** placed;
7. moves the window away, quits the app, restores, and checks DockState **opened the app and placed its
   window**, and that the result reports the opened app;
8. checks *Reset Permission* works from inside the app (on the test app's entry only) and reports failure for an
   app that isn't installed.

`-DockStateSelfTestApp` can target another app (e.g. `com.apple.TextEdit`); steps 5–6 are skipped unless that
app's only window is the given `-DockStateSelfTestFile` document.

## In-app updates (Sparkle, end to end)

```bash
scripts/test-update.sh
SIGN_IDENTITY="Apple Development: Your Name (ABCDE12345)" scripts/test-update.sh
```

Builds DockState Dev, makes an "old" 0.0.1 and a "new" 0.0.2 copy for a throw-away EdDSA key, serves 0.0.2
(DMG and appcast from `scripts/make-appcast.sh`) on `localhost`, and checks that the old copy

1. refuses an update signed with another key and stays 0.0.1;
2. downloads, verifies and installs a correctly signed update, and relaunches as 0.0.2.

With `SIGN_IDENTITY` the copies are signed like a release (hardened runtime, Sparkle's helpers signed, no XPC
services), which also exercises Sparkle's team checks between the app and its installer. Nothing touches an
installed DockState. The hooks it uses (`-DockStateUpdateTest`) exist only in Debug builds.

To see Sparkle's own windows next to DockState's (window levels, the Dock), serve a newer version the same way
and launch the Debug app with `-DockStateUpdateTest YES -DockStateUpdateTestWindows YES -SUFeedURL <feed>
-SUEnableAutomaticChecks NO -DockStateOpen settings`; `-DockStateUpdateTestCloseAfter <seconds>` closes the
update window again.

## Demo mode (Debug builds)

`-DockStateDemo YES` replaces live data with a fictional three-display desk (no real windows are read or
moved, nothing is saved, no apps are launched). Combine with `-DockStateOpen menubar|popover|preview|result|manage|permission|firstSave|settings|icons`
to open a screen directly, `-DockStateTab general|restore|shortcuts|about` for Settings,
`-DockStateDemoPermission missing|stale` for the permission step before it's granted (its buttons do nothing in demo
mode), `-DockStateDemoUpdate 0.3.0` for the panel's update row,
`-DockStateDemoArranged YES` for an arranged desk with nothing saved, and `-AppleLanguages "(tr)"` for Turkish.
All README screenshots are made this way, so no real window titles end up in the repository. Check new UI in
both languages at the window's minimum size — Turkish strings are often a third longer.

## Manual checklist (real hardware)

These depend on hardware and timing and can't be simulated faithfully. Check the relevant ones for changes
to display handling, matching or restore.

- [ ] First launch: onboarding, permission granted while the window waits → advances on its own
- [ ] Launch after setup without the permission → the permission step opens; *Reset Permission* (when shown) puts
      DockState back in the list with the switch off; turning it on continues. After *Not Now*, the next launch
      shows only the badge
- [ ] Permission denied ("Not Now") → warning badge, popover asks for permission, nothing moves
- [ ] Permission revoked while running → warning appears, restore disabled; granting it again resumes what you were doing
- [ ] Save with 1, 2 and 3 displays; quit and relaunch → workspaces kept
- [ ] Unplug external displays, re-plug → notification, preview correct, restore correct, undo correct
- [ ] Sleep and wake on the same desk with an *Always restore* workspace → nothing moves
- [ ] Re-plug a monitor into a different port / through a dock
- [ ] Swap the arrangement of two monitors in System Settings → windows follow their monitor
- [ ] Change resolution / scaling of one monitor → proportional placement
- [ ] Two identical monitors (same model); then open the lid next to them
- [ ] Connect Sidecar or a projector → desk still recognized
- [ ] Close the lid with externals connected (clamshell), open it again
- [ ] Mirroring on and off
- [ ] Apps: Safari/Finder (native, multi-window), VS Code/Slack (Electron), Terminal, a Java/Qt app
- [ ] Minimized and full-screen windows are reported, not touched
- [ ] App not running → "Open & Place"; *Open it first* setting
- [ ] Open an app after restoring → placed, with its own Undo
- [ ] Move a window after restoring, then undo → that window stays put
- [ ] Notifications: *Restore* and *Preview* actions; *Restore* after the displays changed again opens the preview
- [ ] Shortcuts: off by default; record ⌥⌘S; ⌘W is refused; a combination used by macOS is refused
- [ ] Turn off window titles → titles removed from `workspaces.json`
- [ ] Export, then import → copies added as "Name (2)"
- [ ] Corrupt `workspaces.json` by hand → alert, backup kept, app starts empty
- [ ] Updates: no request before setup; right after setup Sparkle asks once; *Check Now* → "up to date" or the
      update window (above Settings, DockState in Cmd+Tab); *Install Update* relaunches the new version with the
      Accessibility permission kept
- [ ] Language switch English ↔ Türkçe; light and dark mode
- [ ] Left- and right-click the real menu bar icon: the panel opens; Esc, an outside click or another click closes it
- [ ] With Manage open: DockState is in the Dock and Cmd+Tab; after closing it, it isn't, and focus returns to the previous app
- [ ] Keep on top: Manage stays above other apps; turning it off in Settings applies immediately; a GitHub link opens in front
- [ ] Restore with an app quit (e.g. VS Code): it opens and its window is placed; with *Skip it* it's only reported
