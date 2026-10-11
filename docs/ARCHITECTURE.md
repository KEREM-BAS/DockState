# Architecture

DockState is a menu bar agent (`LSUIElement`) written in Swift 6 with SwiftUI and a little AppKit.
Reliability lives in a pure-Swift core that is unit-tested; the parts that touch the system are kept thin.

```
┌──────────────────────── DockState.app (UI) ────────────────────────┐
│ MenuBarExtra popover · Onboarding · Preview · Result card · Manage │
│ Settings · Notifications · Global shortcuts · Login item           │
│                AppModel (@MainActor, @Observable)                  │
└───────────────┬─────────────────────────────────┬──────────────────┘
                │                                 │
   DockStateCore (pure, tested)        DockStateSystem (adapters)
   ─ Workspace / SavedWindow models    ─ SystemDisplays (CoreGraphics + NSScreen)
   ─ DisplayMatcher, Recognizer        ─ DisplayChangeObserver (+ settle debounce)
   ─ WindowMatcher (Hungarian)         ─ AccessibilityWindowSystem (AXUIElement)
   ─ RestorePlanner, Placement         ─ AccessibilityPermission, AppLauncher
   ─ RestoreExecutor + undo
   ─ WorkspaceStore (versioned JSON)
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

## Display recognition

Each display is captured as a `DisplayDescriptor`: display UUID, EDID vendor/model/serial, built-in flag,
name, frame, visible frame, pixel size and scale. No single attribute is reliable:

- The UUID can change when the same monitor is plugged into another port.
- Many monitors report serial `0`, so two identical monitors look the same.
- Resolution and arrangement change by user choice.

`DisplayMatcher` scores every saved/current pair (built-in must match built-in; vendor+model must match;
differing non-zero serials rule a pair out; UUID, name, resolution and position add confidence) and searches
all assignments for the best one. The result is classified as `exact`, `sameDisplays` (rearranged/rescaled),
`partial` or `none`, and flagged *ambiguous* if a different assignment scores the same.
Only `exact`/`sameDisplays`, non-ambiguous matches are *recognized* — suggested in the popover or
restored automatically.

Display events (`didChangeScreenParameters`, wake, screens wake) are coalesced by `SettleDebouncer`
(2 s): displays often appear one by one after wake or when a dock connects, and acting on the first event
would match a half-connected setup.

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
| Only window of the app on both sides | 40 |

Pairs below 20 are rejected. The optimal assignment is solved with the Hungarian algorithm. Then each
pair is **challenged**: if swapping it with another plausible pair, or using an unclaimed window instead,
would score within 8 points, the pair is marked *ambiguous* and skipped. Moving the wrong window is worse
than not moving one.

## Restore and undo

`RestorePlanner` produces a side-effect-free `RestorePlan` — moves, already-in-place, skipped with a reason.
The popover count, the notification text, the preview and the executor all read the same plan, so what the
user sees is what happens. (The plan is recomputed right before executing, from a fresh scan.)

`RestoreExecutor` moves windows one by one through the `WindowMoving` protocol. Each move is
size → position → size, with temporarily disabled `AXEnhancedUserInterface` (which otherwise animates and
breaks the sequence), a per-call messaging timeout, and read-back verification. A failure is recorded and
the restore continues.

Undo stores each moved window's before/after frame. Undo only moves windows that are still at their
"after" frame — anything the user moved since is respected and reported.

## Storage

`~/Library/Application Support/DockState/workspaces.json`, written atomically, with `schemaVersion`.
Unreadable files are moved aside (never deleted) and the user is told; files from a newer version are backed
up before being loaded best-effort. Unknown fields and enum values fall back to safe defaults.
Preferences live in `UserDefaults`. Undo history is in memory only.

## Performance

DockState does nothing while idle: no polling, no timers (except a 1 s permission check while onboarding
waits for the user in System Settings). Windows are scanned only when the popover opens, after displays
settle, and around a restore. Accessibility calls run off the main thread with a 0.6 s timeout per call.
