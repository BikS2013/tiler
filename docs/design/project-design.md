# Tiler — Project Design

Tiler is a menu bar app (`LSUIElement`) that tiles windows with a BSP dwindle layout, scoped to
individual macOS desktops: one (display, Space) pair at a time, chosen by the user.

## Goals

- Same core job as HyprMac (Hyprland-style tiling), restricted to the desktops the user turns on.
- Never read, move or resize a window on another display or another desktop. The one exception
  is explicit: the move/resize mode acts on the focused window the user asked it to.
- Fast and light: no polling, no keyboard event tap, no work at all while nothing is tiled.
- Few moving parts, so few bugs.

## What was deliberately left out (compared with HyprMac)

| HyprMac feature | Why Tiler drops it |
|---|---|
| 10 virtual workspaces that hide windows in a screen corner | Conflicts with "touch only this desktop"; native Spaces already provide desktops. The hide-corner, parking, and ghost-window logic were HyprMac's largest bug source. |
| Caps Lock Hypr key (`hidutil` remap + active `CGEventTap` + IOHID reading) | An active tap delays every keystroke system-wide when the app's thread stalls (HyprMac's documented sluggishness). Carbon `RegisterEventHotKey` needs no permission and only sees the registered combinations. |
| 1 Hz discovery polling, frame read-back loops, verification transactions | Replaced by AX notifications plus a ~1 ms reconcile, and by acting on window moves only during a mouse drag. |
| Focus borders, dimming overlays, scratchpad, overview, saved layouts | Not part of the core tiling job; each costs WindowServer time. |

## Architecture

```
main.swift ── AppDelegate ── StatusMenu (NSStatusItem, menu acts on the clicked display)
                  ├── ShortcutsOverlay     HUD panel listing the bindings (never takes focus)
                  ├── SettingsWindowController  toolbar panes, SwiftUI forms, SettingsModel
                  └── Controller (main thread: state, events, layout decisions)
                        ├── Desktop[DesktopKey]  BSPTree + floating set + applied frames
                        ├── AppHandle[pid]       one thread + run loop + AXObserver per app
                        ├── Hotkeys              Carbon hot keys, registered per focus
                        └── Spaces / Screen      SkyLight + NSScreen lookups (read-only)
TilerCore (pure, unit-tested): BSPTree, Geometry, Config, KeyCombo
```

### Desktop identity

`DesktopKey = (display UUID, Space uuid)`. Space ids are reassigned at login, Space uuids are not.
The session Space id is resolved from the uuid with `CGSCopyManagedDisplaySpaces` at launch and on
display changes. A desktop is *visible* when `SLSManagedDisplayGetCurrentSpace(display) == spaceID`.
Each desktop owns its own tree, so switching desktops needs no parking or restoring: a hidden
desktop's tree simply waits.

### Event flow

- `AppHandle` (per app, own thread): app-level `kAXWindowCreated`, `kAXFocusedWindowChanged`;
  window-level `kAXUIElementDestroyed`, `kAXWindowMoved`, `kAXWindowResized`,
  `kAXWindowMiniaturized`. Events hop to the main thread as small enums.
- `NSWorkspace`: app launch/terminate/hide/unhide/activate, active Space change, active display
  change (undocumented `NSWorkspaceActiveDisplayDidChangeNotification`); screen parameter changes.
- Every event schedules a coalesced **reconcile** (20 ms), never a full AX scan.
- Handles exist only while at least one desktop is tiled.

### Reconcile (≈1 ms)

1. Skip unless a tiled desktop is visible; wait while `SLSManagedDisplayIsAnimating`.
2. One `CGWindowListCopyWindowInfo(onScreenOnly)`; keep layer-0 windows of other apps.
3. Per visible tiled desktop: windows whose centre is on its display **and** whose
   `SLSCopySpacesForWindows` contains its Space (empty answer = trust on-screen).
4. Re-check the Space did not change during the read.
5. Remove vanished windows (closed, minimised, hidden, moved away) from the tree; insert new ones.
   Unknown windows are resolved asynchronously on their app's thread (role `AXWindow`, subrole
   `AXStandardWindow`, not minimised/fullscreen, size settable, enabled fullscreen button), with
   one re-check 0.6 s later for windows that become standard after creation.
6. Lay out only if something changed; write only frames that differ from the last written frame.

### Writing frames

`AppHandle.setFrame` stores the newest frame per window and schedules one flush on the app's
thread, so a slow app (iTerm2 takes up to 700 ms) never replays stale layouts and never blocks
other apps or the main thread. The flush turns `AXEnhancedUserInterface` off if it was on, then
writes size → position → size. Every AX call is bounded by a 1 s messaging timeout.

### Feedback-loop rule

Window moved/resized notifications are acted on only while the left mouse button is down
(a user drag). Tiler therefore never reacts to its own writes, or to an app that refuses a size
or snaps itself. On release: a resize adopts the dragged edges into the split ratios
(`BSPTree.adoptResize`), a move onto another tile swaps, anything else snaps back.

### Focus

Focus is tracked from `kAXFocusedWindowChanged` and app activation. Focusing another window uses
`_SLPSSetFrontProcessWithOptions` + the synthetic make-key-window event record (yabai/AeroSpace)
plus `AXRaise`, because since macOS 14 `NSRunningApplication.activate()` from a background app is
ignored. The *active display* is the display of the focused window, else the one under the mouse.
(`SLSCopyActiveMenuBarDisplayIdentifier` was tried and reported the wrong display on macOS 27.)

### Hotkeys

Carbon `RegisterEventHotKey`. `toggleDesktop`, `showHotkeys` and `moveResize` are always
registered; the others only while the active display shows a tiled desktop, and are unregistered
otherwise so apps keep those keys. Transient UIs (overlay, move/resize mode) borrow plain keys
with `Hotkeys.borrow` and give them back with `release()`.

### User interface

- **Menu bar item**: a template glyph drawn in code (one tall tile, two stacked; filled when the
  desktop being worked on is tiled). Menu: section header "Desktop N · Display", Tile This
  Desktop (checkmark, shortcut hint), count of other tiled desktops, Keyboard Shortcuts,
  Settings…, About, Quit. Shortcut hints are real `keyEquivalent`s, rendered by AppKit.
- **Shortcuts overlay**: borderless non-activating `NSPanel`, `.hudWindow` visual effect with a
  rounded mask, SwiftUI content, centred on the active display. It never becomes key, so the
  app underneath keeps the keyboard. Esc is held as a Carbon hotkey only while it is visible;
  a global mouse-down monitor, Space change and app activation also close it.
- **Settings**: `NSTabViewController` in toolbar style (`toolbarStyle = .preference`) with one
  `NSHostingController` per pane (`sizingOptions = .preferredContentSize`, so the window resizes
  per pane), each a `Form` with `.formStyle(.grouped)`. `SettingsModel` holds a copy of the
  config; every change becomes a new `Config`, is serialised with `Config.json()`, re-parsed,
  written atomically and reloaded through `Controller.save`. While a shortcut is recorded,
  `Controller.hotkeysSuspended` unregisters all hotkeys so the keys reach the recorder (an
  `NSEvent` local monitor). Opening the app again, or a second launch, shows Settings.
- **App bundle**: icon rendered by `scripts/make-icon.swift` (no image assets in the repo), a
  standard About panel, and a hidden main menu so ⌘W/⌘Q/⌘,/editing keys work in Settings.
- Minimum macOS is 14 (section-header menu items, `NSApp.activate()`, SwiftUI `onChange` two-value form).

### Focus follows mouse

Optional (`focusFollowsMouse`, off in the template; delay `focusDelay`). Designed so it costs
nothing at rest and almost nothing in motion:

1. **Rest.** A listen-only `CGEventTap` for `mouseMoved` only. Listen-only taps receive copies
   after delivery, so they cannot delay input, unlike the active keyboard tap HyprMac used. It
   exists only while the setting is on and at least one desktop is tiled.
2. **First move.** The callback disables the tap and starts a 40 ms timer that reads the pointer
   position, so a moving mouse costs at most 25 wake-ups per second however fast it reports.
3. **Rested** (no movement for `focusDelay`). One `CGWindowListCopyWindowInfo(onScreenOnly)`
   (~1 ms): if any window at pop-up-menu level or above is on screen (an open menu, a contextual
   menu, the app switcher) nothing happens; otherwise the topmost window under the pointer,
   skipping the cursor ("Window Server") and the Dock's full-screen overlay, decides. It is
   focused only if it is a layer-0 window the visible tiled desktop owns (tile or floating) and is
   not focused already; a menu, popover or panel on top blocks. The timer stops, the tap is on again.

Measured on this Mac (synthetic mouse events at 80 Hz): 0 CPU idle; 0.015 s of CPU per 10 s of
continuous motion (~0.15 % of a core). An `NSEvent` global monitor (one wake-up per event) cost
about 0.13 s for the same motion, so the tap-then-track design is about 9× cheaper. Skipped while
the shortcuts overlay or the move/resize mode is up, during drags and with a mouse button down.

### Floating windows persist

`Desktop.floating` maps each floating window id to its owner pid. `desktops.json` stores, per
desktop, `displayUUID`, `spaceUUID` and `floating: [{id, pid}]` (the 0.2/0.3 list of keys is still
read). On restore a window stays floating only if that id exists now and belongs to the same pid,
because window ids restart after a logout or reboot. Entries drop when the window is destroyed or
its app quits. Reconcile no longer prunes floating windows that are merely hidden, minimised or on
another Space.

### Move/resize mode (untiled windows)

`MoveResizeMode` (menu or `⌃⌘M`) is the one place Tiler touches a window outside a tiled
desktop, and only on an explicit request, only the focused window, only while the mode is on.

- **Target**: the frontmost app's focused window, read on a dedicated `WindowMover` thread
  (`kAXFocusedWindow`, position settable, not full screen). If a tiled desktop holds it
  (`Controller.isTiled`), a HUD says to float it first and nothing changes.
- **Keys**: `Hotkeys.borrow` registers the arrows (plain, ⇧, ⌥, ⇧⌥), C, M, Return, Enter and Esc
  as Carbon hotkeys for the life of the mode and `release()` gives them back, so apps never lose
  those keys otherwise. Pressed and released events are both delivered; a held key repeats from a
  main-thread timer (0.3 s delay, 45 ms interval) because Carbon hotkeys do not auto-repeat. The
  shortcuts overlay borrows Esc the same way.
- **Arithmetic**: `WindowNudge` (TilerCore, pure, unit-tested) computes the next frame inside the
  window's usable display area inset by `outerGap`: moves clamp to the area, resizes keep the
  top-left corner with a 160×100 minimum and push back inside, C centres, M fills.
- **Writes**: `WindowMover.setFrame` coalesces to the newest frame and writes size → position →
  size on its thread, then reads back what the app accepted; the mode continues from that frame,
  so an app's own size limits are respected.
- **End**: Return / Enter / Esc / the shortcut again, an app activation, a Space change, or a
  click (global mouse monitor). The thread stops with the mode.

### Startup

`Controller.prepare()` runs at launch (config, scripting hook); `start()` (desktops, observers,
hotkeys) runs once Accessibility is granted. Menu toggling is disabled until then.

### Layout

`BSPTree`: leaves hold windows, splits hold orientation + ratio (0.1–0.9). New windows split the
last focused tile along its longer side and take the second half. `layout(in:gap:)` records each
node's frame, which `moveDivider` and `adoptResize` use. Frames are rounded to whole points.

## Private APIs (SIP on; verified on macOS 27.0.1)

`SLSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `SLSManagedDisplayGetCurrentSpace`,
`SLSManagedDisplayIsAnimating`, `SLSCopySpacesForWindows`, `_AXUIElementGetWindow`,
`GetProcessForPID`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`.
All are read-only or focus-related; Tiler never moves windows between Spaces (broken on 26/27).

## Files

| Path | Role |
|---|---|
| `Sources/TilerCore/BSPTree.swift` | Dwindle tree, layout, divider moves, drag-resize adoption |
| `Sources/TilerCore/Geometry.swift` | Directional neighbour, hit testing |
| `Sources/TilerCore/Config.swift` | Strict config parsing and writing, actions (titles, groups), key combos (symbols, recorder init), template |
| `Sources/Tiler/Controller.swift` | State, events, reconcile, layout, hotkey actions, drags |
| `Sources/Tiler/AppHandle.swift` | Per-app thread, AX observer, reads/writes |
| `Sources/Tiler/Spaces.swift` | Screens and Spaces lookups |
| `Sources/Tiler/Hotkeys.swift` | Carbon hot keys |
| `Sources/Tiler/StatusMenu.swift` | Menu bar item |
| `Sources/Tiler/ShortcutsOverlay.swift` | Keyboard shortcuts HUD |
| `Sources/Tiler/MoveResizeMode.swift` | Move/resize mode, `WindowMover` thread, its HUD |
| `Sources/Tiler/HUDPanel.swift` | Shared non-activating HUD panel |
| `Sources/TilerCore/WindowNudge.swift` | Move/resize arithmetic (pure, tested) |
| `Sources/Tiler/Settings.swift` | Settings window, model and panes (incl. shortcut recorder) |
| `Sources/Tiler/Appearance.swift` | Menu bar glyph, key caps view, menu key equivalents |
| `Sources/Tiler/PrivateAPI.swift` | Private symbol declarations |
| `scripts/build-app.sh` | Build, bundle (icon, Info.plist), sign, install |
| `scripts/make-icon.swift` | Render the app icon iconset |
| `scripts/tiler-ctl.sh` | Send commands to the running app |
