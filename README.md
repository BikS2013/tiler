# Tiler

A small, fast tiling window manager for macOS that lives in the menu bar and tiles **one desktop
on one display at a time**, only where you turn it on. Every other display and every other
desktop (Space) is left exactly as it is.

It does the core job of [HyprMac](https://github.com/BikS2013-forks/HyprMac): Hyprland-style BSP
"dwindle" tiling with keyboard focus, swap and resize, and mouse drag-to-swap and drag-to-resize.
It does this in about 3,600 lines (Settings, the shortcuts overlay, the move/resize mode and focus follows mouse included) instead of 35,000, with no polling, no keyboard event tap and no
virtual workspaces.

## Use it

1. Click the menu bar icon on the display you want, then choose **Tile This Desktop**
   (or press `⌃⌘P`). The windows on that desktop arrange themselves.
2. Do the same on any other desktop you want tiled. Each one is independent and remembered
   across restarts.
3. Choose it again (or `⌃⌘P`) to stop tiling that desktop. Windows stay where they are.

The icon is filled when the desktop you are working on is tiled. The tiling hotkeys only exist
while a tiled desktop has focus, so on every other desktop the same keys still reach your apps.

Forgot a shortcut? Press `⌃⌘/` (or menu → **Keyboard Shortcuts**) for an overlay listing them all;
Esc or a click closes it. Change anything in **Settings…** (`⌘,` from the menu, or open Tiler
again): gaps, resize step, every shortcut (click it and press the new keys), apps that always
float, and Launch at Login.

## Default hotkeys

| Keys | Action |
|------|--------|
| `⌃⌘P` | Turn tiling on/off for the current desktop (works everywhere) |
| `⌃⌘ ←/→/↑/↓` | Focus the neighbouring window |
| `⌃⌘⇧ ←/→/↑/↓` | Swap with the neighbouring window |
| `⌃⌘[` / `⌃⌘]` | Move the vertical divider next to the window left / right |
| `⌃⌘⇧[` / `⌃⌘⇧]` | Move the horizontal divider next to the window up / down |
| `⌃⌘T` | Float / tile the focused window (floated windows are centred at 60%) |
| `⌃⌘J` | Flip the split the window is in (side by side ↔ stacked) |
| `⌃⌘⇧J` | Mirror the desktop left ↔ right |
| `⌃⌘E` | Make every split 50/50 |
| `⌃⌘R` | Retile: re-read the desktop and rewrite every tile |
| `⌃⌘/` | Show the keyboard shortcuts overlay (works everywhere) |
| `⌃⌘M` | Move or resize the focused untiled window with the keyboard (works everywhere, see below) |

### Focus follows mouse

Off by default. Turn it on from the menu (**Focus Follows Mouse**) or in Settings → General, where
you can also set the delay (default 150 ms). On a tiled desktop, the window under the pointer gets
focus once the pointer rests there; passing over a window does not focus it. Menus, popovers and
floating windows on top are respected, an open menu is never closed, and desktops Tiler does not
tile are left alone.

It costs nothing while the mouse is still and about 0.15 % of one core while it moves: a
listen-only listener wakes Tiler on the first movement, then Tiler checks the pointer 25 times a
second until it stops, instead of handling every mouse event.

### Floating windows

`⌃⌘T` floats the focused window (centred at 60 %) or tiles it again. Floating windows are
remembered per desktop across Tiler restarts, as long as the window is still open.

### Moving and resizing untiled windows

`⌃⌘M` (or menu → **Move or Resize Window**) starts a move/resize mode for the window you are in,
as long as Tiler is not tiling it: a floating window on a tiled desktop, or any window on a desktop
Tiler leaves alone. A small hint appears at the bottom of the screen.

| Key | In the mode |
|-----|-------------|
| `← ↑ → ↓` | Move 40 pt (hold to keep moving) |
| `⇧` + arrows | Resize: → and ↓ grow, ← and ↑ shrink (the top-left corner stays) |
| `⌥` | With either of the above: fine 8 pt steps |
| `C` | Centre on the screen |
| `M` | Fill the screen (minus the outer gap) |
| `↩` / `esc` / `⌃⌘M` | Done |

The arrow keys belong to Tiler only while the mode is on; switching app or desktop, or clicking,
also ends it. A tiled window is left alone (float it first with `⌃⌘T`).

With the mouse: drag a tile onto another tile to swap them, drag a tile's edge to resize the
split, and drop a window from elsewhere onto the desktop to tile it.

The defaults avoid the shortcuts Rectangle (`⌃⌥`, `⌃⌥⌘`) and the local Hammerspoon config
(Hyper+←/→) use. Rebind anything in Settings → Shortcuts or in the config file.

## Install

With Homebrew:

```sh
brew tap BikS2013/tiler
brew install --cask tiler
```

Or download `Tiler-<version>.dmg` from [Releases](https://github.com/BikS2013/tiler/releases) and drag
Tiler to Applications. The app is universal (Apple silicon and Intel), needs macOS 14 or later, and is
signed with a Developer ID certificate and notarized by Apple.

On first launch macOS asks for **Accessibility** permission (System Settings → Privacy &
Security → Accessibility). Tiler needs no other permission (no Input Monitoring, no Screen
Recording, SIP stays on). Turn on **Launch at Login** in Settings → General.

Decks: [for users and for engineers](https://biks2013.github.io/tiler/) (also in `Project Deck/`).

### Build from source

Requirements: Xcode command-line tools and a code-signing certificate.

```sh
security find-identity -v -p codesigning          # pick one (SHA-1)
TILER_SIGN_IDENTITY=<sha1> scripts/build-app.sh --install
```

Releases: `scripts/package.sh` signs, notarizes and packages; see
[docs/design/release-runbook.md](docs/design/release-runbook.md).

## Configuration

`~/Library/Application Support/Tiler/config.json`, written on first launch. Every key is required;
a missing or invalid key is reported in the menu and the last good configuration stays in force.
Settings writes this file for you; if you edit it by hand, choose Settings → General → Reload.

```json
{
  "innerGap": 8,
  "outerGap": 8,
  "resizeStep": 0.05,
  "floatingApps": ["com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.calculator"],
  "hotkeys": { "toggleDesktop": "ctrl+cmd+p", "focusLeft": "ctrl+cmd+left", "…": "…" }
}
```

Full reference: [docs/design/configuration-guide.md](docs/design/configuration-guide.md).

## Scripting and debugging

```sh
scripts/tiler-ctl.sh toggle active     # or a display UUID
scripts/tiler-ctl.sh retile | reload | settings | shortcuts | moveresize | dump
log stream --predicate 'subsystem == "com.giorgosmarinos.tiler"' --level debug
```

## Development

```sh
swift build            # debug build
swift test             # layout, geometry and config tests
```

Design: [docs/design/project-design.md](docs/design/project-design.md) ·
Features: [docs/design/project-functions.md](docs/design/project-functions.md) ·
Research behind the implementation choices: [docs/reference/macos-tiling-research.md](docs/reference/macos-tiling-research.md) ·
Known issues: [Issues - Pending Items.md](Issues%20-%20Pending%20Items.md)

## License

[MIT](LICENSE) © 2026 Giorgos Marinos
