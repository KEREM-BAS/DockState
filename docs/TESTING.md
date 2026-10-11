# Testing

## Automated (CI, no permissions needed)

`cd Packages/DockStateKit && swift test` runs the Swift Testing suite:

| Area | Covered |
| --- | --- |
| Geometry | clamping, tolerance, display containment |
| Store | round-trip, missing file, corrupt file moved aside, structurally invalid file, newer schema backed up, unversioned file migrated, unknown enum values |
| Display recognition | identical setup, port change (new UUID, same serial), rearrangement, resolution change, laptop-only vs desk, extra displays, different serial, different model, identical monitors told apart by position, indistinguishable monitors flagged ambiguous, recognizer tie-breaking |
| Debounce | event bursts collapse to one action, cancel |
| Window matching | unique window with changed title, multiple windows by title with swapped z-order, indistinguishable windows skipped, new window opened after saving, closed window, app not running, optimal assignment |
| Planning | full reconnect, already in place, missing display policies, minimized / full-screen / excluded, proportional resize, rearranged displays |
| Execution & undo | partial failures, undo, undo respecting user-moved and closed windows, minimum-size constraints, no-op restore |

## End-to-end self-test (Debug builds, real windows)

With Accessibility granted to the Debug build and a TextEdit window open:

```bash
open -a build/…/Debug/DockState.app --args -DockStateSelfTest /tmp/dockstate-selftest.txt
cat /tmp/dockstate-selftest.txt
```

It saves the window into a throw-away store, moves it, verifies recognition, restores, verifies the frame,
undoes, verifies again, and puts the window back. Use `-DockStateSelfTestApp <bundle id>` to target another app.

## Manual checklist (real hardware)

These depend on hardware and timing and can't be simulated faithfully. Check the relevant ones for changes
to display handling, matching or restore.

- [ ] First launch: onboarding, permission granted while the window waits → advances on its own
- [ ] Permission denied ("Not Now") → menu bar badge, popover asks for permission, nothing moves
- [ ] Permission revoked while running → warning appears, restore disabled
- [ ] Save with 1, 2 and 3 displays; quit and relaunch → workspaces kept
- [ ] Unplug external displays, re-plug → notification, preview correct, restore correct, undo correct
- [ ] Re-plug a monitor into a different port / through a dock
- [ ] Swap the arrangement of two monitors in System Settings → windows follow their monitor
- [ ] Change resolution / scaling of one monitor → proportional placement
- [ ] Two identical monitors (same model)
- [ ] Close the lid with externals connected (clamshell), open it again
- [ ] Sleep/wake with displays connected; displays that wake at different times
- [ ] Mirroring on and off
- [ ] Apps: Safari/Finder (native, multi-window), VS Code/Slack (Electron), Terminal, a Java/Qt app
- [ ] Minimized and full-screen windows are reported, not touched
- [ ] App not running → "Open & Place"; *Open it first* setting
- [ ] Move a window after restoring, then undo → that window stays put
- [ ] Always restore mode: restores automatically with result card
- [ ] Turn off window titles → titles removed from `workspaces.json`
- [ ] Corrupt `workspaces.json` by hand → alert, backup kept, app starts empty
- [ ] Language switch English ↔ Türkçe
- [ ] Light and dark mode
