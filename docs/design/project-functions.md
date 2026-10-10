# Tiler — Functional Requirements

| ID | Feature | Status |
|---|---|---|
| F1 | Turn tiling on/off for the desktop currently shown on a display, from the menu (acts on the display whose menu bar was clicked) or `⌃⌘P` (acts on the active display). Fullscreen Spaces are refused. | Done, checked live |
| F2 | Only windows on a tiled desktop's Space and display are ever read, moved or resized. Other displays, other desktops of the same display, and untiled desktops are untouched. | Done, checked live |
| F3 | Tiled desktops persist across restarts (keyed by display UUID + Space uuid); deleted desktops are forgotten. | Done, checked live |
| F4 | BSP dwindle layout with configurable inner/outer gaps; new windows split the last focused tile along its longer side. | Done, unit-tested, checked live |
| F5 | Windows that open, close, minimise, hide or move onto/off a tiled desktop are added/removed automatically. | Done, checked live |
| F6 | Dialogs, panels, non-resizable and fullscreen windows float; `floatingApps` bundle ids always float. | Done |
| F7 | Keyboard: focus, swap, move divider, float/tile, flip split, mirror, equalize, retile. | Done, checked live |
| F8 | Mouse: drop a tile on another to swap; drag an edge to resize the split; snap back otherwise. | Swap checked live; resize unit-tested |
| F9 | Tiling hotkeys exist only while a tiled desktop has focus; elsewhere the keys reach apps. | Done, checked live |
| F10 | Strict JSON config with live reload; errors shown in the menu and in Settings, last good config kept. | Done, unit-tested |
| F11 | Launch at Login toggle (Settings → General). | Done |
| F12 | Scripting: `Tiler --send "toggle [uuid|active]" / retile / reload / settings / shortcuts / dump`. | Done |
| F13 | Keyboard shortcuts overlay: `⌃⌘/` (works on every desktop) or menu → Keyboard Shortcuts shows a HUD listing every binding, grouped, with key caps; it never takes focus and closes on Esc, a click, a desktop switch, an app switch or the shortcut again. | Done, checked live |
| F14 | Settings window (menu → Settings…, `⌘,`, or opening the app again): General (launch at login, Accessibility status, tiled count, config file actions), Layout (gaps, resize step), Shortcuts (recorder per action with conflict check, clear, restore defaults), Apps (always-float list with app icons, add from running apps or Finder). Every change is validated and written to `config.json` at once. | Done, checked live |
| F16 | Keyboard move/resize mode for untiled windows: `⌃⌘M` or menu → Move or Resize Window acts on the focused window when Tiler is not tiling it (floating windows on tiled desktops, any window on untiled desktops). Arrows move 40 pt, ⇧ arrows resize, ⌥ fine 8 pt, held keys repeat, C centres, M fills the usable area minus the outer gap, Return/Enter/Esc/⌃⌘M end it; an app or desktop switch or a click ends it too. A tiled window is refused with a hint. The window stays on its display. | Done, unit-tested (`WindowNudge`), checked live |
| F17 | Upgrade path: a config missing a newer setting or action is rejected as before; Settings offers **Add Missing Settings**, which adds only the missing keys from the template. | Done, unit-tested, checked live |
| F18 | Floating windows persist across Tiler restarts (per desktop, validated by window id + owner pid; dropped when the window closes or the app quits). | Done, checked live |
| F19 | Focus follows mouse (optional, off by default): on tiled desktops the window under the resting pointer gets focus after `focusDelay`; menus/overlays respected; menu item and Settings toggle + delay. ~0 CPU idle, ~0.15 % of a core while moving. | Done, unit-tested (config), checked live |
| F15 | Native look: template menu bar glyph (filled when the desktop is tiled), menu with section header and shortcut hints, app icon, standard About panel, standard main menu for the Settings window. | Done, checked live |
