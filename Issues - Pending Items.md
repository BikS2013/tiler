# Issues - Pending Items

## Pending

1. **Apps with a minimum size overlap their neighbour.** Tiler writes the tile size and accepts
   what the app does. Outlook refuses widths below 770 pt, so on the 1512 pt laptop display two
   tiles overlap by ~26 pt. A fix would read back the actual size after a write and shift the
   split ratio, which needs care to avoid oscillation. Seen 2026-10-10.
2. **Conflicts with other window tools.** Rectangle (`⌃⌥` arrows/letters, `⌃⌥⌘←/→`), the local
   Hammerspoon config (Hyper+←/→ moves the window to the adjacent Space) and a running
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

## Completed

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

- **2026-10-10 — v0.2.0 (build 1).** `scripts/package.sh` with Developer ID `2C7D6068…` and
  profile `tiler-notary`: 22 tests passed; app and disk image `status: Accepted`, stapled,
  `source=Notarized Developer ID`; universal (x86_64 arm64). Zip SHA-256
  `c3729a053a7b2873d8206baa86ffb039ddd48e27ebf0de7b179f93e412ce345f`, DMG
  `d45a90348b75076ce1613335637827fd193ea4f1593917defa21beb7db44df2b`. Release
  https://github.com/BikS2013/tiler/releases/tag/v0.2.0 (downloaded zip checksum verified). Tap
  `BikS2013/homebrew-tiler`: `brew style` clean, `brew audit --cask --online` clean, scratch
  `brew install --cask` accepted by Gatekeeper and uninstalled. Moving from the Apple Development
  to the Developer ID signature dropped the Accessibility grant on this Mac (expected; re-grant once).

## Dependency vetting log

- 2026-10-10 — No third-party dependencies. System frameworks only (AppKit, ApplicationServices,
  Carbon, ServiceManagement, private SkyLight).
