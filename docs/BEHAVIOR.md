# How DockState behaves

DockState's rule: **when unsure, do nothing harmful and say why.**

## When displays change

| Event | What DockState does |
| --- | --- |
| Displays connect, disconnect, rearrange, change resolution; Mac wakes | Waits ~2 s for things to settle, then rescans |
| Setup matches a workspace, mode **Ask me** (default) | Badge on the menu bar icon; a notification with *Restore* / *Preview* (once per setup change) |
| Setup matches, mode **Always restore** | Restores right away and shows the result card with **Undo** |
| Setup matches, mode **Do nothing** | Badge only |
| Matching workspace is already in place | Nothing |
| Unknown setup | One notification suggesting to save it (if you have at least one workspace) |
| Only some saved displays connected (*partial*) | Never automatic. You can still open the workspace's preview and restore manually |
| Two monitors that can't be told apart (same model, no serial, same position) | Treated as ambiguous: never suggested or automatic |
| Mirroring | The mirror set counts as one display |
| Lid closed (clamshell) | The built-in display is simply absent from the setup |
| Accessibility permission revoked | Menu bar shows a warning; nothing is moved; undo history is cleared |

"Always restore" is an explicit per-workspace opt-in. Every restore — automatic or not — can be undone.

## During a restore

- Windows are re-scanned and the plan recomputed right before moving anything.
- Only standard windows are touched — not dialogs, sheets, panels or palettes.
- Minimized and full-screen windows are left as they are and listed.
- Each window is moved independently. If one fails (the app refuses, times out or the window disappears),
  the rest continue, and the result card lists what didn't work and why.
- If **If an app isn't open** is *Open it first*, missing apps are launched (in the background) and DockState
  waits up to 8 s for their windows. Otherwise use *Open & Place* in the preview or result card.
- Saved display missing: **Use main display** places the windows proportionally on the main display;
  **Leave windows in place** skips them.

## Undo

- Available from the result card, the menu, and ⌥⌘Z, until the next restore or quit.
- Moves each window back to where it was just before the restore — **unless you've moved or resized it
  since**, in which case it's left alone and counted as "changed".
- Undo history is not kept across app restarts.

## Saving

- Captures standard, non-minimized, non-full-screen windows on the current Space that sit on a connected display.
- Saving with the name of an existing workspace replaces it (the save sheet warns you), keeping its
  automation setting.
- *Update from Current Layout* keeps excluded windows excluded.
- Window titles are stored only if *Use window titles* is on.

## Not supported (by design, without private APIs)

- Windows on other Spaces, moving windows between Spaces, full-screen Spaces.
- Restoring app contents, tabs or documents — DockState restores **placement only**.
