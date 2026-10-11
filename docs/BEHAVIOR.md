# How DockState behaves

DockState's rule: **when unsure, do nothing harmful and say why.**

## Recognizing a desk

A workspace is *recognized* when every display it was saved with is connected:

| Connected displays | Result |
| --- | --- |
| Exactly the saved ones, same arrangement and resolution | Recognized (exact) |
| The saved ones, rearranged or at another resolution | Recognized |
| The saved ones **plus extras** (Sidecar, a projector, the lid opened) | Recognized, if the workspace includes an external display. A *laptop-only* workspace never matches a desk |
| Only some of the saved ones | Not recognized (partial) — you can still restore it by hand from the menu |
| Two monitors that can't be told apart (same model, no serial, same position) | Not recognized (ambiguous) |
| Mirroring | The mirror set counts as one display |

If several workspaces match, DockState prefers the one covering more of the connected displays, then one set
to **Always restore**, then the one you restored most recently, then the newest. Renaming or editing a
workspace never changes which one wins.

## When displays change

DockState reacts only when the **display setup changes** — which displays are connected, where, at what
resolution. Waking from sleep, unlocking, or the Dock moving on the same desk is not a change.

| Event | What DockState does |
| --- | --- |
| Displays connect, disconnect, rearrange or change resolution | Waits ~2 s for things to settle, then rescans |
| Mac wakes and some displays aren't back yet | Waits once more (5 s) so a half-woken desk isn't taken for a new setup |
| Setup changed and matches a workspace set to **Ask me** (default) | Badge on the menu bar icon and a notification with *Restore* / *Preview* |
| Setup changed, workspace set to **Always restore** | Restores right away and shows the result card with **Undo** |
| Workspace set to **Do nothing** | Badge only |
| Matching workspace already in place | Nothing |
| Unknown setup | One notification suggesting to save it (if you have at least one workspace), once per setup |
| Displays already connected when DockState starts (login, relaunch) | Not a change: badge only, nothing moves |
| A notification's *Restore* after the displays changed again | Opens the preview instead of restoring blindly |
| Accessibility permission revoked | Menu bar shows a warning badge; nothing is moved; undo history is cleared |
| DockState starts without the permission (after setup) | The permission step opens, instead of only the badge — unless you chose *Not Now* there; then only the badge, until you allow it |

"Always restore" is an explicit per-workspace opt-in. Every restore — automatic or not — can be undone.
Automatic restores never launch apps.

## During a restore

- Windows are re-scanned and the plan recomputed right before moving anything.
- Only standard windows are touched — not dialogs, sheets, panels or palettes. Excluded windows are never moved.
- Minimized and full-screen windows are left as they are and listed.
- Each window is moved independently. If one fails (the app refuses, times out or the window disappears),
  the rest continue, and the result card lists what didn't work and why.
- A window that can't take the exact size (minimum sizes, Terminal's character grid) counts as in place once
  it got as close as the app allows.
- Windows that straddle displays or hang off an edge stay that way as long as their title bar is reachable.
- **If an app isn't open → Open it** (the default) launches missing apps when *you* restore — from the
  preview, the menu bar, a notification or the shortcut — and places their windows once they appear (also
  windows that show up after a splash or welcome window). The preview lists them under *Will open*, and the
  result card says which apps were opened. Only apps whose windows have somewhere to go are opened; apps
  that aren't installed are reported as such. Automatic (*Always restore*) restores never launch apps.
  With **Skip it**, use *Open & Place* in the preview or the result card — it also works for a running app
  that has no window open.
- **If a saved display is missing → Use main display** places those windows proportionally on the main
  display; **Leave windows in place** skips them.

## The menu bar icon and DockState's windows

- Left- or right-click the icon to open the panel. Esc, a click elsewhere or another click on the icon closes it.
- While any DockState window (Manage, Settings, Preview, Save, onboarding) is open, DockState also shows in the
  Dock and in Cmd+Tab; when the last one closes it goes back to being a menu bar app and focus returns to the
  app you were in. Clicking the Dock icon brings the open windows forward.
- *Settings › General › Keep DockState windows on top* (on by default) keeps those windows above other apps'
  windows. Onboarding never floats (System Settings must stay visible while you grant permission), links open
  in front of them, and the result card and toasts stay above them.
- The update window, alerts and open/save panels count as DockState windows too: they keep DockState in the
  Dock and Cmd+Tab while they're open (also when minimized), and clicking the Dock icon brings them forward.
  While one is on screen, DockState's other windows stop floating, so it stays in front; links it opens (release
  notes, *Version History*) open in front of DockState, which floats again once you use it.

## The Accessibility permission

- macOS lists it under *Privacy & Security › Accessibility*; on macOS 27 the list is called *Device Control
  and Data Access*. The permission step names the one your Mac uses.
- macOS keeps one entry per app and ties it to the signature it approved. After running another copy with the
  same bundle ID (an unsigned build, an older version) the switch can look on while DockState isn't trusted.
  When that looks likely — DockState was trusted before, you asked in an earlier session, or nothing happened
  10 seconds after asking — the permission step offers **Reset Permission**: it removes the entry (no password
  needed) and adds this copy back, so you only turn the switch on again. If macOS refuses, it explains how to
  remove the entry with – and add it again with +.
- Development builds are *DockState Dev* (`com.kerembas.DockState.debug`), with their own entry, settings and
  workspaces, so they never take over an installed DockState's permission.

## Apps opened later

With *Settings › Restore › Place apps you open later* (on by default), when an app opens while a workspace is
recognized, its windows go to their saved places — but only if that workspace is set to **Always restore**, or
you restored it yourself since this desk was connected. Undoing that restore, or disconnecting the desk,
ends this. The toast that appears has its own **Undo**; the restore's undo stays intact.

## Undo

- *Undo* in the result card undoes that restore (including windows placed with *Open & Place* from the card).
- *Undo Last Restore* in the menu (and the optional shortcut) undoes the most recent restore.
- Each window goes back to where it was just before — **unless you've moved or resized it since**, in which
  case it's left alone and counted as "changed".
- Undo history is kept until the next restore or until DockState quits.

## Saving and editing

- Captures standard, non-minimized, non-full-screen windows on the current Space that sit on a connected display.
- A layout without windows is never saved (e.g. on an empty Space, or without permission).
- Saving with the name of an existing workspace replaces it after a warning, keeps its automation setting,
  and can be undone from the toast. *Update from Current Layout* can be undone the same way and keeps excluded
  windows excluded.
- A deleted workspace can be brought back for 15 seconds (toast or ⌘Z in Manage).
- Window titles are stored only if *Use window titles* is on.
- Export writes all workspaces to a JSON file. Import adds them next to yours — nothing is overwritten, taken
  names become "Name (2)", and an imported copy never takes over *Always restore* from a workspace you already
  have for that desk.

## Storage problems

- A damaged `workspaces.json` is moved aside (never deleted) and DockState starts empty; you're told where the copy is.
- A file written by a newer DockState is loaded as far as possible and **not changed** until you choose
  *Convert for This Version* (a backup is kept). Until then, changes aren't saved and DockState says so.

## Shortcuts

Global shortcuts are **off** by default — when on, they take over the same keys in every app. In
*Settings › Shortcuts* each action can get its own combination; it must use ⌃ or two of ⌘ ⌥ ⌃, and
combinations used by macOS or by another DockState action are refused.

## Updates

DockState updates itself with [Sparkle](https://sparkle-project.org).

- **Nothing is requested before you agree.** Right after setup DockState asks once: *Check for updates
  automatically?* If yes, it reads `appcast.xml` from this repository's latest release once a day; if no, only
  when you press *Check Now* (Settings › General) or *DockState › Check for Updates…*. No system profile is sent,
  and no cookies are stored or sent, so checks can't be linked to each other. (If DockState starts with the
  permission step on screen, the question waits for a later launch; *Check Now* works anyway.) Users who had
  turned on the old update check in 0.1.x aren't asked again; their choice carries over.
- **Finding an update** shows what's new and *Install Update*, *Remind Me Later* or *Skip This Version*.
  When a daily check finds one while you're busy, it doesn't pop up behind other apps: the menu bar panel shows
  *Update to DockState x.y.z…* and a notification appears (if notifications are allowed).
- **Download and install updates automatically** (off by default, only with automatic checks) downloads in the
  background and installs when you quit DockState or restart your Mac.
- **Every update is verified** before it's installed: its EdDSA signature must match the key built into
  DockState (checked before the DMG is even opened), and the new app's code signature must be valid. A
  tampered or wrongly signed update is refused and nothing changes.
- Only stable releases are offered (pre-releases are never the "latest" release the feed comes from), and only
  a newer version becomes the latest release. Pre-release builds don't update themselves; Settings says so.
- Updating keeps the Accessibility permission: releases are signed with the same Developer ID.

## Not supported (by design, without private APIs)

- Windows on other Spaces, moving windows between Spaces, full-screen Spaces.
- Restoring app contents, tabs or documents — DockState restores **placement only**.
