# Architecture

DockState is a menu bar agent (`LSUIElement`) written in Swift 6 with SwiftUI and a little AppKit.
Reliability lives in a pure-Swift core that is unit-tested; the parts that touch the system are kept thin.

```
┌──────────────────────── DockState.app (UI) ────────────────────────┐
│ Status item + panel · Onboarding · Preview · Result card · Manage  │
│ Settings · Notifications · Shortcuts · Login item · Update check   │
│                AppModel (@MainActor, @Observable)                  │
└───────────────┬─────────────────────────────────┬──────────────────┘
                │                                 │
   DockStateCore (pure, tested)        DockStateSystem (adapters)
   ─ Workspace / SavedWindow models    ─ SystemDisplays (CoreGraphics + NSScreen)
   ─ DisplayMatcher, Recognizer        ─ DisplayChangeObserver (+ settle debounce)
   ─ WindowMatcher (Hungarian)         ─ AccessibilityWindowSystem (AXUIElement)
   ─ RestorePlanner, Placement         ─ AccessibilityPermission, AppLauncher
   ─ RestoreExecutor + undo
   ─ AutoRestorePolicy, LatePlacementPolicy
   ─ WorkspaceStore, WorkspaceTransfer
   ─ UpdateCheck (semver, Atom feed)
```

## Key decisions

**Accessibility API, no sandbox.** Moving other apps' windows is only possible through the Accessibility
API (`AXUIElement`), which sandboxed apps cannot use. DockState is therefore distributed outside the Mac App
Store with Developer ID + notarization and Hardened Runtime.

**No Screen Recording.** Window positions come from Accessibility; previews are schematic maps. Asking for
screen recording just to draw thumbnails would be a far bigger privacy ask than the feature is worth.

**Public API only.** No `_AXUIElementGetWindow`, no CGS/SkyLight Spaces calls. As a result, DockState only
sees windows on the current Space and does not manage full-screen Spaces. These limits are documented rather
than hidden.

**Coordinates.** Everything in the core uses global top-left coordinates (CoreGraphics / AX convention).
Saved windows store their frame *relative to their display*, so rearranging displays doesn't break a workspace.
If a display's size changed, the frame is mapped proportionally onto its usable area (`Placement`).

**Decisions are pure functions.** What to do after displays settle (`AutoRestorePolicy`), whether an app opened
later may be placed (`LatePlacementPolicy`), which workspace wins (`WorkspaceRecognizer`), what a restore
will do (`RestorePlanner`) — all live in the core with tests. `AppModel` only gathers inputs and acts.

**Menu bar and windows.** The menu bar icon is an AppKit `NSStatusItem` with a borderless panel (SwiftUI's
`MenuBarExtra` can't handle right-click or be closed programmatically). `WindowRouter` opens DockState's
windows; while any is open the app is `.regular` (Dock, Cmd+Tab) and otherwise an `.accessory` agent.

## Display recognition

Each display is captured as a `DisplayDescriptor`: display UUID, EDID vendor/model/serial, built-in flag,
name, frame, visible frame, pixel size and scale. No single attribute is reliable:

- The UUID can change when the same monitor is plugged into another port.
- Many monitors report serial `0`, so two identical monitors look the same.
- Resolution and arrangement change by user choice.

`DisplayMatcher` scores every saved/current pair (built-in must match built-in; vendor+model must match, or
for unidentified vendor-0 displays the name; differing non-zero serials rule a pair out; UUID, name,
resolution and position add confidence) and searches all assignments for the best one. Positions are compared
relative to the arrangement of the displays that can pair on both sides, so an extra display (an opened lid)
can't shift the reference point and swap identical monitors. The result is classified as `exact`,
`sameDisplays` (rearranged/rescaled), `withExtraDisplays` (all saved displays plus others; only for
workspaces with an external display), `partial` or `none`, and flagged *ambiguous* when another assignment
scores within 1 point.

Only recognized (`exact`, `sameDisplays`, `withExtraDisplays`), non-ambiguous matches are suggested or
restored automatically. Ranking: quality, then coverage (more matched displays, fewer extras), then
*Always restore*, then last restored, then newest.

Display events (`didChangeScreenParameters`, wake, screens wake) are coalesced by `SettleDebouncer` (2 s).
`AppModel` reacts only when the **setup key** (display ids, frames and pixel sizes — not the visible frame, which
changes when the Dock moves) differs from the last one handled. After wake, if not every display from before
sleep is back, it waits once more.

## Window matching

The hardest problem: which live window *is* the saved one? Window identifiers don't survive app relaunches,
titles change, apps open new windows.

`WindowMatcher` works per app (bundle ID must match) and scores each saved/live pair:

| Signal | Weight |
| --- | --- |
| Title identical / similar (word Jaccard) | 60 / up to 35 (only if titles are enabled) |
| Size similarity | up to 20 |
| Window currently on the display it belongs to | 10 |
| Same front-to-back order within the app | 6 (3 if off by one) |
| Only window of the app on both sides | 40 — unless the titles share nothing *and* the size differs |

Pairs below 20 are rejected. The optimal assignment is solved with the Hungarian algorithm. Then each
pair is **challenged**: if swapping it with another plausible pair, giving its live window to a saved window
that got none, or using an unclaimed window instead would score within 8 points, the pair is marked
*ambiguous* and skipped. Excluded windows take part in matching so they keep their own live window and can
never be mistaken for another one. Moving the wrong window is worse than not moving one.

## Restore and undo

`RestorePlanner` produces a side-effect-free `RestorePlan` — moves, already-in-place, skipped with a reason.
The popover count, the notification text, the preview and the executor all read the same plan, so what the
user sees is what happens. (The plan is recomputed right before executing, from a fresh scan.)

"In place" means position within 4 pt and size within max(8 pt, 3 %) — or, for a window the last restore already
moved there, the exact frame it reached (`SettledPlacement`), because some apps can't take every size.

`RestoreExecutor` moves windows one by one through the `WindowMoving` protocol, inside a batch
(`beginBatch`/`endBatch`). The Accessibility mover does size → position → size, turns
`AXEnhancedUserInterface` off once per app for the batch (it animates moves and breaks the sequence), uses
a 0.6 s timeout for reads and 1.5 s for moves, and verifies by reading back. A failure is recorded and the
restore continues; if the failed move had already changed the window, that is recorded for undo too.

Undo stores each moved window's before/after frame and walks them newest first. It only moves windows that
are still at their "after" frame — anything the user moved since is respected and reported.

## Window identity

`AccessibilityWindowSystem` keeps a registry of `AXUIElement`s keyed by `LiveWindowID` (pid + token). Some apps
(Terminal, for one) return element objects whose hash changes between scans, so a new element that is
`CFEqual` to a known one keeps the old id. Apps that don't answer a scan (busy, timed out) keep their
entries; windows of apps that quit are pruned after each full scan.

## Storage

`~/Library/Application Support/DockState/workspaces.json`, written atomically, with `schemaVersion`.
Unreadable files are moved aside (never deleted) and the user is told. Files from a newer version are backed
up once and loaded read-only — saving needs the user's explicit *Convert for This Version*. Unknown fields and
enum values fall back to safe defaults. Export/import use the same JSON envelope (`WorkspaceTransfer`).
Preferences live in `UserDefaults`. Undo history is in memory only.

## Performance and network

DockState does nothing while idle: no polling. Windows are scanned when the popover opens, after displays
settle, around a restore, when an app launches (only that app is polled while its windows appear), and when
the user switches apps while a workspace is recognized (at most every 15 s, to keep the menu bar dot honest).
Accessibility calls run off the main thread. A 1 s timer runs only while onboarding waits for permission.

The only network request is the opt-in update check: GitHub's `releases.atom` feed (no account, no
identifiers, no API rate limit), at most once a day, re-evaluated hourly and retried once after a failure.
