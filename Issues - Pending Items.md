# Issues - Pending Items

## Pending

1. **Apps with a minimum size overlap their neighbour.** Tiler writes the tile size and accepts
   what the app does. Outlook refuses widths below 770 pt, so on the 1512 pt laptop display two
   tiles overlap by ~26 pt. A fix would read back the actual size after a write and shift the
   split ratio, which needs care to avoid oscillation. Seen 2026-10-10.
2. **Conflicts with other window tools.** Rectangle (`⌃⌥` arrows/letters, `⌃⌥⌘←/→`), the local
   Hammerspoon config (Hyper+←/→ moves the window to the adjacent Space; its `⌘⌥`-drag was
   removed in favour of Tiler's), any other `⌘⌥`-drag tool, and a running
   HyprMac would act on the same windows or keys. Tiler's defaults avoid the known shortcuts; do
   not tile with Tiler on a desktop HyprMac also manages.
3. **Drag-resize not yet checked live** (unit-tested via `BSPTree.adoptResize`). Drag-swap was
   checked live.
4. **Tahoe corner radii.** macOS 26+ windows have large, varying corner radii, so equal gaps can
   look uneven. Cosmetic.
5. **"Displays have separate Spaces" off** is handled in code (falls back to the "Main" managed
   display) but not checked live.
6. **A binding can be taken by another app first.** Carbon accepts a registration even when
   another tool (e.g. Hammerspoon's `⌃⌥K`) already owns the combination, and that tool then
   wins. Settings can only detect clashes between Tiler's own actions. Seen 2026-10-10 while
   testing the recorder.
7. **Old `~/Library/Application Support/Tider/` folder** is left from before the rename (its
   `desktops.json` was copied to the `Tiler` folder). Safe to delete.

9. **Move/resize mode keeps a window on its display.** Moving a window to another display with
   the keyboard is not supported (frames are clamped to the window's display).

10. **Moving a window to another desktop depends on a title-bar drag.** An app whose title bar
    has no draggable area right of the zoom button (custom-drawn chrome) may not move; Tiler then
    says "The window did not move". It also needs the Mission Control "Move left/right a space"
    shortcuts on. Your Hammerspoon Hyper+←/→ does the same thing; either can stay.

11. **Modifier + drag and synthetic clicks.** `WindowDrag` lets Tiler's own synthetic events
    through (the desktop mover posts with no modifiers anyway), but another tool posting a
    synthetic ⌘⌥ click would be taken as a drag. Not seen; noted 2026-10-10.

## Completed

- **2026-10-10 — ⌘⌥ + drag moves a window from anywhere in it (0.7.0).** `WindowDrag`, config
  key `dragToMove` (Settings → General → Drag windows with), replacing the Hammerspoon
  `windowDragTap` (removed from `~/.hammerspoon/init.lua` and its hotkeys cheatsheet; backup kept
  outside the repo). First build moved tiled windows without snapping back: the swallowed press
  never reaches the window server, so `NSEvent.pressedMouseButtons` reads 0; fixed by
  `WindowDrag.isActive` feeding the controller's `userDragging`. Checked live: TextEdit moved by
  exactly the drag (−300, −200) with no text selected; plain drags and ⌃⌘ / ⌃⌥⌘ drags reached the
  app; on tiled Desktop 1 a drop on another tile swapped, a short drag snapped back; 0 CPU idle.

- **2026-10-10 — Move the focused window to the previous/next desktop (0.6.0).** `DesktopMover`,
  `⌃⌘,` / `⌃⌘.`. Checked live on the main display: untiled Desktop 3 → 4 → 3 → 2 → tiled
  Desktop 1 (window tiled on arrival) → refused toward the full-screen Space → out to Desktop 2
  (left Desktop 1's layout) → back to Desktop 3.

- **2026-10-10 — Floating windows now keep their size and position (0.5.0).** Frames are captured
  0.3 s after a floating window moves or resizes, saved (coalesced 1 s), restored once after a
  restart, and reused when a window is floated again. Checked live: frame saved after the
  move/resize mode; a window moved while Tiler was off returned to its saved frame on restart;
  tile → float again returned to the saved frame; closing removed the entry.

- **2026-10-10 — Floating windows were tiled again after a Tiler restart (0.4.0).** Floating is
  now saved per desktop with the window's owner pid and validated on restore; closed windows and
  quit apps drop out. Checked live: a floated TextEdit window stayed floating across a restart;
  closing it removed the entry.
- **2026-10-10 — Focus follows mouse (0.4.0).** Listen-only mouse tap at rest, 40 ms tracking
  while moving, one window-list read at rest. Checked live: focus follows a resting pointer
  across three apps; a fast pass does not focus; an open menu blocks it. CPU: 0 idle, 0.015 s per
  10 s of motion (an NSEvent global monitor measured ~0.13 s, so it was replaced).

- **2026-10-10 — Keyboard move/resize for untiled windows (0.3.0).** `⌃⌘M` mode
  (`MoveResizeMode`, `WindowNudge`, `Hotkeys.borrow`). Checked live on a floated TextEdit window:
  refusal on a tiled window, move 40 pt, ⌥ 8 pt, ⇧ resize, hold-to-repeat, M fill, Return and
  ⌃⌘M end, arrows released afterwards. Test-tool note: synthetic arrow-key events must carry the
  fn + numeric-pad flags real keyboards send, or Carbon does not match them.
- **2026-10-10 — Upgrading made the config invalid.** Adding an action makes older files miss a
  required key. Kept strict (no silent default) and added the explicit **Add Missing Shortcuts**
  button in Settings (`Config.addingMissingHotkeys`); checked live: only `moveResize` was added.
- **2026-10-10 — Move/resize hint showed "1.576 × 801"** (locale grouping) and an odd Esc glyph.
  Now `Text(verbatim:)` and "esc".

- **2026-10-10 — Renamed Tider → Tiler** (targets, bundle id `com.giorgosmarinos.tiler`, support
  folder, log subsystem, `TILER_SIGN_IDENTITY`, `scripts/tiler-ctl.sh`, Carbon signature `TLRR`).
  `/Applications/Tider.app` moved to the Trash; tiled desktops carried over.
- **2026-10-10 — Shortcuts overlay ignored Esc.** A non-activating panel shown while another app is
  frontmost does not get keyboard focus. The overlay now never takes focus; Esc is registered as
  a Carbon hotkey only while the overlay is visible (`Hotkeys.captureEscape`). Checked live with
  Finder frontmost: open, Esc, and toggle all work, and Finder keeps focus.
- **2026-10-10 — Settings opened behind other apps** when requested by `tiler-ctl.sh settings` or a
  second launch (macOS 14+ ignores `activate()` without a click in the app). `show()` now brings
  the window forward with `focusWindow` when the app is not active.

- **2026-10-10 — Focus hotkeys did nothing.** `NSRunningApplication.activate()` from a background
  app is ignored since macOS 14. Fixed with `_SLPSSetFrontProcessWithOptions` + make-key-window
  event record + `AXRaise` (`PrivateAPI.swift: focusWindow`). Checked live.
- **2026-10-10 — Tiling hotkeys swallowed keys on an untiled desktop.**
  `SLSCopyActiveMenuBarDisplayIdentifier` reported the laptop display while Finder on the main
  display had focus. The active display is now the focused window's display, else the mouse's.
  Checked live: `⌃⌘J` reached Finder on the main display.
- **2026-10-10 — First default hotkeys collided** with Rectangle and Hammerspoon (a resize key moved
  the window to another display / another Space). Defaults moved to the `⌃⌘` family.
- **2026-10-10 — Screen or gap changes were not applied** until a window came or went. Desktops now
  carry `needsLayout`, set on display changes and config reloads.

## Release log

- **2026-10-10 — v0.6.0 (build 15).** Move the focused window to the previous/next desktop. 30
  tests passed; app and disk image `status: Accepted`, `source=Notarized Developer ID`. Zip
  SHA-256 `9abd1adbf3caf464cde5a701cd0bc26e6ea97c63549987514e79cf612eb530cb`, DMG
  `105ac65a8abfc4af9779647f89b07b54b1d868863ae521108290b0a56b8cde5b`. Config gains two
  shortcuts (Add Missing Settings).

- **2026-10-10 — v0.5.0 (build 11).** Floating windows keep size and position. 29 tests passed;
  app and disk image `status: Accepted`, `source=Notarized Developer ID`. Zip SHA-256
  `2b3c91eda14a30b138e9b6e794ab97f0b24bfe1768157e79b85d6774ea3a01e7`, DMG
  `0271dd8f694c01b46f10cbbf5cb1629f47faa524e47f3fa1f899d52df662e609`. No config changes.

- **2026-10-10 — v0.4.0 (build 9).** Floating windows persist; focus follows mouse; Add Missing
  Settings. `scripts/package.sh`: 29 tests passed; app and disk image `status: Accepted`,
  `source=Notarized Developer ID`. Zip SHA-256
  `1b660b6ce8b9b293cc1524410207d32f456e6ff9f427d91c56106f2e7eae5aa2`, DMG
  `47ee563a1b9e4b99996dae05ba0ec8fd676149cfccd81a441f542aded5217492`. Installed over 0.3.0
  here; Accessibility kept.

- **2026-10-10 — v0.3.0 (build 3).** Keyboard move/resize mode, Add Missing Shortcuts, MIT
  license. `scripts/package.sh`: 27 tests passed; app and disk image `status: Accepted`, stapled,
  `source=Notarized Developer ID`. Zip SHA-256
  `4e042965f57064f39e310ac90ce6f4cd366c317a42117c26f4256a50f79195b1`, DMG
  `3b4e479d0a5a61e2bd079e50ccc13424b28ea5840882e223924316d1ca9aeb04`. Installed over 0.2.0 on
  this Mac: the Accessibility grant was kept (same Developer ID).

- **2026-10-10 — v0.2.0 (build 1).** `scripts/package.sh` with Developer ID `2C7D6068…` and
  profile `tiler-notary`: 22 tests passed; app and disk image `status: Accepted`, stapled,
  `source=Notarized Developer ID`; universal (x86_64 arm64). Zip SHA-256
  `c3729a053a7b2873d8206baa86ffb039ddd48e27ebf0de7b179f93e412ce345f`, DMG
  `d45a90348b75076ce1613335637827fd193ea4f1593917defa21beb7db44df2b`. Release
  https://github.com/biks2013-tools/tiler/releases/tag/v0.2.0 (downloaded zip checksum verified). Tap
  `biks2013-tools/homebrew-tiler`: `brew style` clean, `brew audit --cask --online` clean, scratch
  `brew install --cask` accepted by Gatekeeper and uninstalled. Moving from the Apple Development
  to the Developer ID signature dropped the Accessibility grant on this Mac (expected; re-grant once).

## Dependency vetting log

- 2026-10-10 — No third-party dependencies. System frameworks only (AppKit, ApplicationServices,
  Carbon, ServiceManagement, private SkyLight).
