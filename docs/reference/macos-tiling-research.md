# macOS Tiling Window Manager — Research Reference (Tiler)

**Scope:** a fast, minimal, low-bug macOS menu-bar tiling app in Swift that tiles windows on exactly **one display** and exactly **one macOS Space** (the Space that was active on that display when the user turned tiling on). All other displays and Spaces stay untouched.
**Target OS:** macOS 26 Tahoe and macOS 27. The dev machine reports Darwin 27.0.0, so macOS 27 behaviour matters most.
**Research date:** 2026-10-10.
**Method:** read the actual source of AeroSpace (`main`), yabai (`master`, non-SA code paths), Amethyst (`development`) plus its Silica dependency, Rectangle (`main`) and Loop (`develop`). Added recent GitHub issues about macOS 26/27 regressions.

---

## 0. TL;DR architecture recommendation

| Concern | Recommendation |
|---|---|
| Space identity | On activation, record `targetDisplayUUID` and `targetSpaceID = SLSManagedDisplayGetCurrentSpace(cid, uuid)`. Tile only while `SLSManagedDisplayGetCurrentSpace(cid, targetDisplayUUID) == targetSpaceID`. Otherwise do nothing (paused). |
| Space-change detection | `NSWorkspace.activeSpaceDidChangeNotification` plus the undocumented `"NSWorkspaceActiveDisplayDidChangeNotification"`. On each one, re-read the current Space of **every** display and diff against a snapshot. That diff tells you which display changed. |
| Window discovery (fast path) | One `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` call. Keep layer 0, alpha > 0, and windows whose bounds centre is on the target display. That gives a set of `(pid, wid)`. Then ask only those pids for `kAXWindows` and map each element with `_AXUIElementGetWindow`. |
| Space membership (secondary check) | `SLSCopySpacesForWindows(cid, 0x7, [wid])`. It is useful, but reports from macOS 27 conflict (see §1.6), so if it returns an empty array, treat that as "unknown", not "not on this Space". |
| Window liveness | Never drop a window just because it is missing from `kAXWindows` or from the on-screen list. Both leave out windows on Spaces that aren't showing. Drop it only on `kAXUIElementDestroyedNotification` **and** when `CGWindowListCopyWindowInfo(.optionIncludingWindow, wid)` comes back empty. |
| Setting frames | Use one thread and run loop per app (AeroSpace model). Turn `AXEnhancedUserInterface` off around the write. Write size → position → size. Cancel any pending job for the same window first. Use a short messaging timeout. |
| Feedback loops | Store the expected frame per wid. Ignore moved/resized notifications that match it within about 2 pt, or that arrive while a write is in flight. |
| Filtering | Tile only `AXWindow` + `AXStandardWindow` subrole, movable, not minimized, not `AXFullScreen`, app not hidden, fullscreen button present and enabled (AeroSpace's dialog heuristic). Float everything else. |
| Hotkeys | Carbon `RegisterEventHotKey`. It needs no TCC permission, has the lowest latency and swallows the key. Call it directly (about 60 lines), so there is no dependency. |
| Layout | BSP "dwindle" (Hyprland's default) with a per-split ratio. Master-stack can come later as a second pure function. |
| Packaging | SwiftPM executable plus a `build.sh` that assembles `Tiler.app` (Info.plist with `LSUIElement=true`) and signs it with a **self-signed code-signing certificate** and a fixed `--identifier`. Ad-hoc signing loses the Accessibility grant on every rebuild. |
| Menu bar | `NSStatusItem` (AppKit). It is smaller and more predictable than SwiftUI `MenuBarExtra` for a no-window agent app. |

---

## 1. Spaces: identifying the current Space per display, and a window's Space

### 1.1 The private SkyLight/CoreGraphics functions

`SLS*` (SkyLight.framework) and `CGS*` (CoreGraphics re-exports) are the same functions under two names. yabai uses `SLS*` names (`src/misc/extern.h`). Amethyst/Silica use `CGS*` names (CGSInternal headers). Both resolve on macOS 15/26/27 without disabling SIP. SIP only matters for yabai's *scripting addition*, which injects into Dock.app. Read-only Space queries never need it.

Signatures as yabai declares them (`src/misc/extern.h`, verified 2026-10):

```c
extern int        SLSMainConnectionID(void);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int cid);
extern uint64_t   SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern CFStringRef SLSCopyManagedDisplayForWindow(int cid, uint32_t wid);
extern CFStringRef SLSCopyBestManagedDisplayForRect(int cid, CGRect rect);
extern CFStringRef SLSCopyActiveMenuBarDisplayIdentifier(int cid);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
extern int        SLSSpaceGetType(int cid, uint64_t sid);       // 0 user, 2 system, 4 fullscreen (yabai)
extern int        SLSGetSpaceManagementMode(int cid);          // 1 = "Displays have separate Spaces"
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces,
                                                   uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);
extern CFUUIDRef  CGDisplayCreateUUIDFromDisplayID(uint32_t did);   // public-ish, in ColorSync/CG
extern AXError    _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *wid);
```

CGSInternal (`NUIKit/CGSInternal/CGSSpace.h`) adds `CGSGetActiveSpace(cid)` and the mask enum:

```c
typedef enum {
  CGSSpaceIncludesCurrent = 1 << 0,   // 1
  CGSSpaceIncludesOthers  = 1 << 1,   // 2
  CGSSpaceIncludesUser    = 1 << 2,   // 4
  kCGSCurrentSpaceMask = 5, kCGSOtherSpacesMask = 6, kCGSAllSpacesMask = 7,
} CGSSpaceMask;
```

Loop names the same values `onScreenManaged = 5`, `offScreenManaged = 6`, `allManaged = 7` (`Loop/Private APIs/SkyLightSymbolLoader.swift`). Amethyst calls `CGSCopySpacesForWindows(CGSMainConnectionID(), kCGSAllSpacesMask, [wid])` (`Amethyst/Model/CGInfo.swift`).

**`CGSGetActiveSpace` caveat:** it returns a single Space, the one on the display that owns the active menu bar. With multiple displays, use `SLSManagedDisplayGetCurrentSpace(cid, uuid)` per display instead. yabai's `space_manager_active_space()` = current Space of the *active* display.

### 1.2 Display UUID ↔ CGDirectDisplayID (yabai `src/display.c`)

```c
CFStringRef display_uuid(uint32_t did) {
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did); if (!u) return NULL;
    CFStringRef s = CFUUIDCreateString(NULL, u); CFRelease(u); return s;
}
uint32_t display_id(CFStringRef uuid) {
    CFUUIDRef u = CFUUIDCreateFromString(NULL, uuid);
    uint32_t did = CGDisplayGetDisplayIDFromUUID(u); CFRelease(u); return did;
}
uint64_t display_space_id(uint32_t did) {
    CFStringRef uuid = display_uuid(did);
    uint64_t sid = SLSManagedDisplayGetCurrentSpace(g_connection, uuid);
    CFRelease(uuid); return sid;
}
```

Get the `CGDirectDisplayID` of an `NSScreen` from `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID`. Store the **UUID string**, not the display ID: display IDs get re-enumerated after sleep/wake (seen in spaces-renamer #27), while UUIDs are stable. Amethyst instead uses `CGSCopyBestManagedDisplayForRect(cid, screen.frameIncludingDockAndMenu)` to get the managed-display identifier for an `NSScreen`.

### 1.3 Structure of `SLSCopyManagedDisplaySpaces`

It returns an array with one dictionary per display (only one when "Displays have separate Spaces" is off):

```
[ { "Display Identifier": "<UUID>" | "Main",
    "Current Space": { "ManagedSpaceID": 7, "id64": 7, "uuid": "…", "type": 0, … },
    "Spaces": [ { "ManagedSpaceID": 5, "id64": 5, "uuid": "…", "type": 0 }, … ] }, … ]
```

- Amethyst reads `"Current Space"` → `ManagedSpaceID`, `type`, `uuid` (`CGSpacesInfo.space(fromSpaceDescription:)`). yabai reads `"Spaces"[i]["id64"]`.
- **Stable ID:** use `ManagedSpaceID`/`id64` (UInt64). It stays stable while the Space exists, but it is not stable across reboots or Space deletion. If you need to persist across logins, also key by `uuid`; Amethyst keys its per-Space layouts by `uuid`. An empty `uuid` string is common for the first desktop.
- When separate Spaces is **off**, `"Display Identifier"` is `"Main"` and there is one entry. Amethyst handles this with `screensHaveSeparateSpaces ? match by id : descriptions[0]`.
- **Split View tiles (macOS 26+):** tile dictionaries put the *parent* id in `ManagedSpaceID` and the tile's own sub-space id in `id64` (Rememoru PR #4). Treat `type == 4` (fullscreen) Spaces as "not tileable" and pause.

### 1.4 Detecting Space changes

- `NSWorkspace.shared.notificationCenter` → `NSWorkspace.activeSpaceDidChangeNotification`. It fires once for **any** display's Space change and carries **no** display info.
- yabai also observes the undocumented `"NSWorkspaceActiveDisplayDidChangeNotification"` (focus moved to another display) (`src/workspace.m`).
- **How to tell which display changed:** keep `[displayUUID: spaceID]`. On either notification, recompute `SLSManagedDisplayGetCurrentSpace` for each display and diff. Only the target display matters:

```swift
func onSpaceOrDisplayChanged() {
    let now = SLSManagedDisplayGetCurrentSpace(cid, targetDisplayUUID as CFString)
    if now == targetSpaceID { resumeAndReconcile() } else { pause() }   // never touch other spaces
}
```

- The notification arrives at the start or end of the Space-switch animation. To be safe, debounce by about 50–100 ms and re-check. yabai's `SLSManagedDisplayIsAnimating(cid, uuid)` can tell you whether the switch is still in progress.
- Also re-validate on `NSApplication.didChangeScreenParametersNotification` (display added/removed/rearranged) and `NSWorkspace.didWakeNotification`. If the target display disappears, pause and drop the target.

### 1.5 Which Space is a window on?

```c
CFArrayRef spaces = SLSCopySpacesForWindows(cid, 0x7 /* all */, (CFArrayRef)@[@(wid)]);
// usually [sid]; a sticky ("all Spaces") window returns many; [] means unknown
```

For your own Space, the cheaper test is that a window is on the target Space **iff** (a) the target Space is currently showing on the target display and (b) the window is on-screen (`kCGWindowIsOnscreen`) and its bounds are on the target display. That uses only public API (`CGWindowListCopyWindowInfo`).

### 1.6 macOS 26 / 27 breakage status (read-only queries, no SIP)

| API | Status | Evidence |
|---|---|---|
| `SLSMainConnectionID` / `CGSMainConnectionID` | Works on 26 and 27 | Used everywhere |
| `SLSCopyManagedDisplaySpaces` | Works on 27.0 (26A428) | Lanterna #86 probe on 27.0; DesktopRenamer, SpaceKeeper, noswoosh on 26/27 |
| `SLSManagedDisplayGetCurrentSpace` | Works (yabai non-SA path) | yabai `display.c` |
| `SLSCopySpacesForWindows(cid, 7, …)` | **Conflicting on 27.** Lanterna #86 (27.0) reports correct per-window Space IDs. NUEM #6 (27.0) reports `[]` "for an ordinary window" where 26.5 returned `[1]`. Hammerspoon #3897 says `moveWindowToSpace` silently fails on 27 (write path). | Treat `[]` as unknown. Don't put this call on the hot path |
| `SLSWindowIteratorGetAttributes` | **Always returns 0 from macOS 26.3** (Loop, from disassembly). This breaks yabai-style `attributes & 0x2` filters in `space_window_list_for_connection`. | Loop `SkyLightSymbolLoader.swift` comment |
| Space *mutation* (create/destroy/move window to Space) | Broken or changed repeatedly in 26.x and 27 (yabai #2675, #2707, #2730, #2799; Hammerspoon #3897) | Out of scope for Tiler. Never mutate Spaces |
| Mission Control AX tree | Moved from Dock to `com.apple.WindowManager` on 27. Mission Control ignores synthetic mouse events. | Hammerspoon #3897 |

**Design consequence:** Tiler only *reads* the current Space ID per display and otherwise relies on public CG/AX APIs. That is the most future-proof position available.

### 1.7 Swift declarations

Option A (best ABI correctness, AeroSpace style): a tiny C target in SwiftPM.

`Sources/CPrivate/include/CPrivate.h`:

```c
#pragma once
#include <ApplicationServices/ApplicationServices.h>
typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;
extern CGSConnectionID SLSMainConnectionID(void);
extern CGSSpaceID  SLSManagedDisplayGetCurrentSpace(CGSConnectionID cid, CFStringRef displayUUID);
extern CFArrayRef  SLSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;
extern CFArrayRef  SLSCopySpacesForWindows(CGSConnectionID cid, int mask, CFArrayRef windowIDs) CF_RETURNS_RETAINED;
extern CFStringRef SLSCopyManagedDisplayForWindow(CGSConnectionID cid, uint32_t wid) CF_RETURNS_RETAINED;
extern int         SLSSpaceGetType(CGSConnectionID cid, CGSSpaceID sid);
extern bool        SLSManagedDisplayIsAnimating(CGSConnectionID cid, CFStringRef displayUUID);
extern AXError     _AXUIElementGetWindow(AXUIElementRef element, uint32_t *outWindowID);
```

Plus an empty `Sources/CPrivate/shim.c`. Link SkyLight with `linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]`. Alternatively use the `CGS*` names, which live in CoreGraphics and need no extra framework flag.

Option B (pure Swift, `@_silgen_name`, as AeroSpace's comment and Loop do):

```swift
import ApplicationServices
typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ displayUUID: CFString) -> CGSSpaceID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSSpaceGetType")
func CGSSpaceGetType(_ cid: CGSConnectionID, _ sid: CGSSpaceID) -> Int32
```

Return CF objects as `Unmanaged<…>?` and call `.takeRetainedValue()` for `Copy` functions. That avoids depending on how Swift's calling convention treats object returns from `@_silgen_name` functions. Loop's header comment warns that `@_silgen_name` binds at **load time**: if Apple removes a symbol, the app crashes on launch.

Option C (graceful degradation, Loop style): `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)` + `dlsym` into `@convention(c)` typed optionals:

```swift
typealias GetCurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
let slsGetCurrentSpace: GetCurrentSpaceFn? = dlsym(handle, "SLSManagedDisplayGetCurrentSpace")
    .map { unsafeBitCast($0, to: GetCurrentSpaceFn.self) }
```

**Recommendation:** Option B for `_AXUIElementGetWindow` (it has been stable for 10+ years and every WM depends on it). Option C for all SkyLight calls, so a missing symbol on a future macOS turns into a clear error at runtime ("Space detection unavailable") instead of a launch crash. Per the no-fallback configuration rule, surface it as an error, not a silent default.

---

## 2. AXUIElement ↔ CGWindowID and enumerating current-Space windows

### 2.1 `_AXUIElementGetWindow`

AeroSpace documents this as the **only** private API it uses (README; `Sources/PrivateApi/include/private.h`):

```c
AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);
```

Its usage (`accessibility.swift`):

```swift
func containingWindowId() -> CGWindowID? {
    var id = CGWindowID()
    return _AXUIElementGetWindow(self, &id) == .success && id != kCGNullWindowID ? id : nil
}
```

Cache the wid per element (Silica caches it in `SIWindow._windowID`).

### 2.2 What `kAXWindowsAttribute` returns

- AeroSpace's own doc comment: *"Returns windows visible on all monitors. If some windows are located on not active macOS Spaces then they won't be returned."* (`Ax.windowsAttr`).
- Confirmed again on macOS 27.0 by Lanterna #86 and alt-tab-macos #14/#447/#431: `kAXWindows` leaves out windows on Spaces that no display is showing.
- With several displays it returns windows on **every visible** Space, one per display. So you still have to filter by display.
- It **does** include minimized windows, and windows of hidden apps in some cases (subrole flips to `AXDialog` when minimized or hidden, per AeroSpace's comment), so filter on `kAXMinimizedAttribute`.

### 2.3 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`

- One IPC to WindowServer for every window. Public API. It doesn't need Screen Recording permission for bounds, pid, layer and number (only `kCGWindowName` needs it).
- `.optionOnScreenOnly` gives exactly the windows on currently showing Spaces, excluding minimized windows and hidden apps. Amethyst uses it for `isOnScreen` and for hit-testing (`WindowsInformation.swift`, Silica `-[SIWindow isOnScreen]`).
- Filter: `kCGWindowLayer == 0`, `kCGWindowAlpha > 0`, bounds intersect target display. Use `kCGWindowOwnerPID` to choose which apps to query over AX.
- yabai's private alternative `SLSCopyWindowsWithOptionsAndTags(cid, 0, [sid], 0x2, &set, &clear)` + `SLSWindowQuery*` iterators gives windows **of a specific Space** even when it isn't showing. But its tag/attribute filters are now unreliable (§1.6). Avoid it.

### 2.4 Fastest reliable approach for Tiler

1. `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)` → `[(pid, wid, bounds)]` on the target display, layer 0.
2. For each distinct pid, use the cached per-app `AXUIElementCreateApplication(pid)` and read `kAXWindows`. Map elements to wids. Keep the intersection with step 1.
3. Apply the tileability filter (§5).
4. Optional sanity check when available: `CGSCopySpacesForWindows(cid, 7, [wid])` contains `targetSpaceID` (ignore empty results).

This avoids asking every running app for AX data (AX calls are the slow part, one IPC each and blocked by unresponsive apps) and needs no Space-mutation APIs.

### 2.5 Why AeroSpace avoids macOS Spaces, and the trade-offs

AeroSpace guide: Spaces have slow, undisableable animations, a cap of 16 per monitor, no public API, and can't be created, moved or assigned with hotkeys. So AeroSpace **emulates** workspaces. Inactive workspaces' windows are moved off-screen into the bottom-right or bottom-left corner. It recommends turning **off** "Displays have separate Spaces", since many users report "weird focus and performance issues" when it is on.

- Pros: instant switching, only one private symbol, no SIP, no dependence on Space APIs.
- Cons: windows peek out if monitors are arranged without a free corner. Fights with the native Spaces model. Mission Control/Exposé shows the "hidden" windows piled in a corner. Users have to adopt AeroSpace's model.
- **For Tiler** the requirement is the opposite: respect native Spaces and touch only one. So Tiler must read Space IDs (§1). It still copies AeroSpace's AX engineering: per-app threads, setFrame order, heuristics.

---

## 3. Setting window frames fast

### 3.1 AeroSpace's per-app thread model (`Sources/AppBundle/tree/MacApp.swift`)

- Each app gets its own `Thread` named `"AxAppThread <app>"`. It creates `AXUIElementCreateApplication(pid)`, subscribes `AXObserver`s **on that thread's run loop**, then calls `CFRunLoopRun()`. All AX reads and writes for that app run as jobs on that run loop (`thread.runInLoop` / `runInLoopAsync`).
- Why: AX calls are synchronous IPC into the target process. One hung app (Godot is cited) would freeze the whole WM if the calls ran on the main thread. With threads, apps get resized **in parallel**.
- `setFrameJobs[windowId]` keeps the latest job per window. A new layout cancels the pending one (`setFrameJobs.removeValue(forKey:)?.cancel()`), so stale frames are never applied.
- On termination, AX objects are destroyed in reverse order of creation, on the owning thread.
- AeroSpace never sends AX requests to its own pid ("AX requests crash if you send them to yourself") and skips the lock screen app.

### 3.2 setFrame order (AeroSpace issues #143 and #335; Rectangle)

```swift
// AeroSpace MacApp.swift
private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}
```

Rectangle (`AccessibilityElement.setFrame`) does the same: `size` (if adjusting size first) → `position` → `size`. macOS clamps a size that wouldn't fit at the *current* position, so the second size write fixes clamping after the move.

### 3.3 Disabling animation with `AXEnhancedUserInterface`

```swift
// AeroSpace: refs yabai commit 3fe4c77 and Rectangle PR #285
private func disableAnimations<T>(app: AXUIElement, _ body: () throws -> T) rethrows -> T {
    let wasEnabled = app.get("AXEnhancedUserInterface") == true
    if wasEnabled { app.set("AXEnhancedUserInterface", false) }
    defer { if wasEnabled { app.set("AXEnhancedUserInterface", true) } }
    return try body()
}
```

- The attribute lives on the **application** element. VoiceOver-style tools (and some apps such as Electron, Chrome and Firefox when assistive tech is detected) turn it on, which makes frame changes animate and lag. Loop and Rectangle use the same trick, and Rectangle can be configured to restore or not restore it.
- Only toggle it if it was `true` (saves 2 IPCs per window otherwise). Restore it afterwards.

### 3.4 Messaging timeout

`AXUIElementSetMessagingTimeout(element, seconds)` caps how long an AX call blocks. Rectangle calls it on its wrapped elements. Per Apple's header docs, setting it on `AXUIElementCreateSystemWide()` sets the **global** timeout. Recommendation: global 1.0 s at startup, plus about 0.25–0.5 s on each app element used for frame writes. With per-app threads, a slow app delays only itself.

### 3.5 Other speed and correctness tricks

- **Skip no-op writes:** compare the target frame with the cached frame within a tolerance. Amethyst's `setFrame(_:withThreshold:)` exists because some apps (Terminal) snap sizes to cell grids, so the frame you read back never exactly equals the one you wrote.
- **Minimum sizes:** some apps refuse to shrink below a minimum. After the write, read `kAXSize` back once. If it is larger than requested, record it as `minSize[wid]` and let the layout either accept the overlap (AeroSpace does) or rebalance the split ratio once. Don't loop.
- **Don't move windows while the left mouse button is down** (`NSEvent.pressedMouseButtons & 1`). AeroSpace delays new-window registration while the mouse is down so dragging a tab out of a browser works (#1001).
- **Write position as top-left in global Quartz coordinates**: origin at the top-left of the primary display, y grows downward. `NSScreen.frame` uses a bottom-left origin, so convert with `y_quartz = primaryScreenHeight - nsRect.maxY`.

### 3.6 Avoiding feedback loops from your own moves

- yabai: `WINDOW_MOVED` returns early if `CGPointEqualToPoint(new_origin, window->frame.origin)`, and `WINDOW_RESIZED` returns early if `CGRectEqualToRect(new_frame, window->frame)`. It updates the cached frame *before* writing, so the echo notification matches (`src/event_loop.c`).
- Recommended for Tiler: `expected[wid] = (frame, deadline: now + 300 ms)`. On a moved/resized notification, read the frame. If it is within 2 pt of `expected` or before the deadline, ignore it. Otherwise it is a user drag or resize: wait for mouse-up, then either swap tiles (drop target) or adjust the split ratio.
- Coalesce: collect notifications for about 16–30 ms (one display frame) and run a single layout pass.

---

## 4. Observing window events

### 4.1 What AeroSpace subscribes to (`MacApp.swift`, `AxSubscription.swift`)

- **App element:** `kAXWindowCreatedNotification`, `kAXFocusedWindowChangedNotification` → "refresh".
- **Each window element:** `kAXUIElementDestroyedNotification`, `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification` → refresh; `kAXMovedNotification` → moved; `kAXResizedNotification` → resized.
- One `AXObserver` per handler group. `CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)` runs **on the app's own thread**.
- **Retention:** the subscription objects are kept in memory for the whole life of the window or app ("keep subscriptions in memory"). If the `AXObserver` is deallocated, notifications stop silently. `deinit` removes the run-loop source and every notification, on the same thread.
- If *any* `AXObserverAddNotification` fails, the whole bulk subscription is rejected (returns `[]`) and retried later. This often happens with `kAXErrorCannotComplete` while an app is still launching.

### 4.2 App lifecycle

- `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification`. AX is often not ready at launch, so yabai KVO-observes `NSRunningApplication.isFinishedLaunching` and `activationPolicy` before subscribing (`src/workspace.m`). Only manage `activationPolicy == .regular` apps.
- `NSWorkspace.didHideApplicationNotification` / `didUnhideApplicationNotification` (yabai) or `kAXApplicationHiddenNotification` / `kAXApplicationShownNotification` → remove from or re-add to the layout.
- `NSWorkspace.didActivateApplicationNotification` is a cheap focus signal.

### 4.3 Pitfalls

- **Destroyed notifications are unreliable.** They can arrive late or never (apps that order windows out instead of closing them; Brave's "ordered-out closes" in hyprdarwin PR #6), and the element is already invalid when the callback runs. Remember the wid when you subscribe, and confirm with `CGWindowListCopyWindowInfo(.optionIncludingWindow, wid)`: empty means really gone. hyprdarwin waits about 1 s before declaring a window off every Space as closed.
- **Windows missing from `kAXWindows` are not necessarily closed.** They may be on another Space, or in a native-fullscreen transition. Mark them "away", don't delete them (hyprdarwin PR #6).
- Callbacks run on the thread whose run loop holds the source. If that is the main thread, one slow app's notification storm stalls the UI and hotkeys.
- AX calls that target your own process crash or deadlock (AeroSpace).
- The lock screen creates windows that look real (AeroSpace `lockScreenAppBundleId` guard).

---

## 5. Window filtering (what to tile)

### 5.1 Amethyst (`Window.swift`)

`shouldBeManaged()` = `isMovable()` **and** `subrole == kAXStandardWindowSubrole`. `shouldFloat()` = window smaller than a configurable threshold. Silica treats `AXSheet` role as part of its parent.

### 5.2 AeroSpace (`model/AxUiElementWindowType.swift`)

Three classes: `.window` (tile), `.dialog` (float), `.popup` (ignore).

- **isWindow** is false (popup) when the window has none of close/fullscreen/zoom/minimize buttons, isn't focused or main, isn't the app's focused window, and its subrole isn't `AXStandardWindow` (tooltips, context menus, keyboard-layout HUD, screen-share pill). Accessory-policy apps without a close button are also ignored.
- **isDialog** is true (float) when:
  - subrole != `AXStandardWindow` (Chrome find bar, file pickers `AXDialog`, `AXUnknown`, `AXFloatingWindow`). Exception: qutebrowser.
  - **fullscreen button missing or disabled** ("windows without fullscreen button are not designed to be big": Finder copy dialog, System Settings, About This Mac, Calculator). Exceptions: terminals, Emacs and VS Code with hidden title bars, Chrome tab drag-out, GIMP, Activity Monitor, Steam.
  - per-app special cases: Firefox PiP (minimize button disabled), iPhone Simulator, Photo Booth, 1Password, Ghostty quick terminal (`AXIdentifier == com.mitchellh.ghostty.quickTerminal`), Xcode "open_quickly".
  - windows above the normal level (`windowLevel != .normalWindow`), being rolled out per app.
- Note: "Minimized windows or windows of a hidden app have subrole AXDialog". Check minimized and hidden *before* classifying.

### 5.3 Recommended minimal filter for Tiler

```
tile iff
  role == AXWindow && subrole == AXStandardWindow
  && !AXMinimized && !AXFullScreen && app not hidden
  && AXPosition and AXSize are settable (AXUIElementIsAttributeSettable)
  && fullscreen button exists && enabled   (with a small allowlist for terminals)
  && CG layer == 0 && on target display && target space showing
  && pid != own pid && app.activationPolicy == .regular
float otherwise; plus user "float app" rules by bundle id.
```

---

## 6. Global hotkeys

| Option | Permission | Swallows key | Latency / reliability | Notes |
|---|---|---|---|---|
| **Carbon `RegisterEventHotKey`** | **None** | Yes | Lowest, delivered by WindowServer as `kEventHotKeyPressed` | Used by AeroSpace (via `soffes/HotKey` 0.2.1, a thin Carbon wrapper), Rectangle and Amethyst. macOS 15.0 rejected Option-only / Option+Shift-only combos (error −9868); 15.2 relaxed this. Combos with Cmd or Ctrl always work. |
| `CGEventTap` (active) | Accessibility (or Input Monitoring for listen-only) | Yes | Very low, but the tap is **disabled by the system** if the callback is slow (`kCGEventTapDisabledByTimeout`) and must be re-enabled | Needed only for modifier-only triggers or mouse gestures (Loop uses event taps on a dedicated thread, `EventTapThread.swift`) |
| `NSEvent.addGlobalMonitorForEvents` | Accessibility | **No** (observe only) | OK | Can't consume keys, so unsuitable for WM bindings |

**Recommendation:** call Carbon directly. That's about 60 lines (`InstallEventHandler(GetApplicationEventTarget(), …, kEventClassKeyboard/kEventHotKeyPressed)` + `RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature:id:), GetApplicationEventTarget(), 0, &ref)`). It needs no TCC prompt and avoids adding a dependency, which also avoids the dependency-vetting step. The handler runs on the main thread, so dispatch work to the WM's serial queue immediately. Default to `ctrl+opt+…` or `cmd+opt+…` bindings.

---

## 7. Layout

- **BSP dwindle (Hyprland default):** each new window splits the focused (or last) leaf. The split direction follows the leaf's aspect ratio (width > height → vertical split). Each internal node stores `ratio` (default 0.5). That gives "Hyprland-like" feel, natural mouse-resize semantics (adjust a node ratio), and easy swap/move by direction. yabai's `bsp` and Amethyst's `BinarySpacePartitioningLayout` work the same way.
- **Master-stack:** simplest (one master column plus an evenly split stack), but resizing and rearranging are less expressive.
- **Recommendation:** implement layout as a **pure function** `layout(tree, rect, gaps) -> [wid: CGRect]` with unit tests (AeroSpace tests its tree heavily). Start with dwindle. Keep the tree per `(displayUUID, spaceID)`, and with only one target, a single tree. Inner and outer gaps of 8–10 pt look right with Tahoe's larger window corner radii.

---

## 8. Packaging: SwiftPM-only menu-bar app with persistent Accessibility permission

### 8.1 Build

- `Package.swift`: `.executableTarget(name: "Tiler", dependencies: ["CPrivate"])`, `platforms: [.macOS(.v14)]` or later. AeroSpace itself builds `AeroSpaceApp` as an SPM executable, but uses Xcode for release.
- `build.sh`: `swift build -c release` → create `Tiler.app/Contents/{MacOS,Resources}` → copy the binary → write `Info.plist` with `CFBundleIdentifier` (for example `com.giorgosmarinos.tiler`), `CFBundleExecutable`, `CFBundlePackageType=APPL`, **`LSUIElement=true`** (no Dock icon) → `codesign`.
- Launch with `open Tiler.app`, not by running the raw binary from a terminal. Otherwise TCC attributes the AX permission to Terminal or iTerm instead of Tiler.

### 8.2 Why the TCC grant resets, and the fix

- With **ad-hoc** signing (`codesign -s -`, or the linker's default ad-hoc signature), TCC pins the grant to the exact **cdhash**. Every rebuild changes the cdhash, so the grant silently stops working while System Settings still shows the box ticked (shannoncoat `build.sh` notes; AeroSpace even runs `tccutil reset Accessibility <bundle-id>` because "macOS doesn't reset it for us when the app signature changes").
- **Fix:** create a self-signed **Code Signing** certificate once (Keychain Access → Certificate Assistant → Create a Certificate…, Identity Type "Self Signed Root", Certificate Type "Code Signing"), then:

```bash
codesign --force --options runtime --sign "Tiler Local Signing" \
         --identifier com.giorgosmarinos.tiler Tiler.app
codesign -d -r- Tiler.app   # check: designated => identifier "com.giorgosmarinos.tiler" and certificate leaf = H"…"
```

The designated requirement (identifier plus certificate hash) stays the same across rebuilds, so the Accessibility grant persists. Per the no-fallback rule, `build.sh` should **fail** if the signing identity is missing rather than silently falling back to ad-hoc (shannoncoat does exactly this).
- If a stale entry exists: `tccutil reset Accessibility com.giorgosmarinos.tiler`, then re-grant once.
- Request permission with `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` and poll `AXIsProcessTrusted()` every second until it is granted (AeroSpace `waitForAccessibilityPermission_nonCancellable`).
- Don't enable the App Sandbox: AX control of other apps is not allowed in the sandbox.

### 8.3 `NSStatusItem` vs SwiftUI `MenuBarExtra`

- `MenuBarExtra` works from SPM (`@main struct App: App { var body: some Scene { MenuBarExtra("Tiler", systemImage: …) { … } } }`). AeroSpace uses SwiftUI for its menu bar (`ui/MenuBar.swift`). But it brings SwiftUI scene lifecycle quirks, has limited control over menu rebuilding, and doesn't give you `NSApplicationDelegate` hooks without an adaptor.
- **`NSStatusItem`** with a plain `main.swift` (`NSApplication.shared.setActivationPolicy(.accessory); app.delegate = …; app.run()`) is smaller, starts faster and is fully predictable. Recommended for a minimal agent app.

---

## 9. macOS 26 / 27 changes that affect AX window management

1. **Larger, variable window corner radii (Tahoe "Liquid Glass").** Gaps look uneven between windows with different radii (toolbar windows have bigger radii). Loop reads them via `SLSWindowIteratorGetResolvedCornerRadii` (macOS 26+, all four corners identical). There was also a user-facing resize hit-area regression: the corner resize zone falls mostly outside the window. 26.3's release notes claimed a fix, then re-listed it as a known issue (Daring Fireball, heise, 9to5Mac, Jan–Feb 2026). It doesn't affect AX writes, but it affects mouse-resize UX inside a tiled layout.
2. **`SLSWindowIteratorGetAttributes` returns 0 from 26.3** (Loop). Any filter copied from yabai's `space_window_list_for_connection` breaks.
3. **macOS 27: Mission Control's AX tree moved to `com.apple.WindowManager`**, and Mission Control ignores synthetic mouse events (Hammerspoon #3897). Don't automate Mission Control.
4. **macOS 27: Space-move write paths fail silently** (Hammerspoon #3897, yabai issues). There are conflicting reports on `SLSCopySpacesForWindows` read results (§1.6).
5. **Native window tiling (since Sequoia):** "Drag windows to screen edges to tile" and the green-button tiling menu can fight with Tiler. Recommend users turn off System Settings → Desktop & Dock → "Drag windows to screen edges to tile" and "Tiled windows have margins". The Tahoe Split View/tile Spaces show up as `type 4` / tile dictionaries (§1.3); pause on them.
6. **Stage Manager:** windows in the side strip are still reported over AX and on-screen, but are scaled thumbnails. Detect it and refuse to tile: read `defaults read com.apple.WindowManager GloballyEnabled` (read-only), or check whether the CG bounds disagree with AX size by more than 50%.
7. **Option-only hotkeys** (macOS 15.0, relaxed in 15.2). Default to Cmd/Ctrl combos.
8. **Display IDs re-enumerate after sleep/wake** (spaces-renamer #27, Oct 2026). Key everything by display UUID and rebuild display state on `didWakeNotification` and `didChangeScreenParametersNotification`.

---

## 10. Reference event flow for Tiler

```
activate(hotkey or menu):
  targetDisplayUUID = display under focused window (or under mouse)
  targetSpaceID     = SLSManagedDisplayGetCurrentSpace(cid, targetDisplayUUID)
  guard SLSSpaceGetType(cid, targetSpaceID) == 0 else error("not a user desktop")
  discover() → tree.insert(wids) → apply()

discover():
  cg = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], 0)
       .filter(layer==0 && alpha>0 && onTargetDisplay(bounds))
  for pid in Set(cg.pids): app[pid].onThread { kAXWindows → wid map → filter → register observers }

on AX event (per app thread) → post to WM serial queue → coalesce 16–30 ms →
  guard currentSpace(targetDisplayUUID) == targetSpaceID else return    // paused
  reconcile(created/destroyed/minimized/moved/resized) → layout() → apply()

apply(): for each (wid, rect) changed: app[pid].setFrameJob(wid) {
  disableEnhancedUI { size → position → size }; expected[wid] = rect }

on activeSpaceDidChange / ActiveDisplayDidChange / wake / screen params:
  recompute currentSpace(targetDisplayUUID); == target ? resume+reconcile : pause
  (windows not visible are "away", never deleted unless CG says the wid is gone)

deactivate: unsubscribe observers, stop app threads (CFRunLoopStop on each), keep frames as-is.
```

---

## 11. Assumptions & scope

| Assumption | Confidence | Impact if wrong |
|---|---|---|
| "Displays have separate Spaces" is ON (the default) | MEDIUM | If off, there is one `"Main"` entry in `CopyManagedDisplaySpaces` and one Space spans all displays. "One display only" then means filtering by bounds only. The code must handle both (Amethyst does). |
| Read-only SkyLight Space queries keep working on 27.x | MEDIUM-HIGH | If `SLSManagedDisplayGetCurrentSpace` breaks, a public-only fallback: target Space is showing ⇔ the wids registered at activation are on-screen (`kCGWindowIsOnscreen`) on the target display. |
| `SLSCopySpacesForWindows` is reliable on 27 | LOW (conflicting reports) | Only used as an optional check. |
| `_AXUIElementGetWindow` remains available | HIGH | Every macOS WM depends on it. |
| `AXEnhancedUserInterface` toggle still speeds up writes on 26/27 | MEDIUM | Possibly a wasted IPC; harmless. |
| A self-signed cert keeps TCC grants across rebuilds on 26/27 | HIGH (multiple 2026 reports) | Otherwise use `tccutil reset` and re-grant after each build. |
| Default AX messaging timeout is "several seconds" (often cited as ~6 s) | LOW-MEDIUM | Set it explicitly anyway. |

**Out of scope:** yabai's scripting addition (SIP-off) features; creating, destroying or moving windows between Spaces; focus-follows-mouse; window borders and overlays; animations.

## 12. Uncertainties & gaps

- The exact macOS 27 behaviour of `SLSCopySpacesForWindows`. NUEM's `[]` may concern windows owned by the caller's own connection or a custom Space, while Lanterna's probe of foreign windows worked. Needs a local probe on the dev machine.
- Whether `NSWorkspace.activeSpaceDidChangeNotification` fires before or after `SLSManagedDisplayGetCurrentSpace` updates on 27. Debounce and re-check to be safe.
- Stage Manager detection: the `com.apple.WindowManager GloballyEnabled` default is a widely used heuristic, not documented API.
- Apple has no official documentation for `AXEnhancedUserInterface`'s effect. The evidence is empirical (yabai, Rectangle, Loop, AeroSpace).

## 13. Clarifying questions

1. Should the target display be chosen by focused window, mouse location, or an explicit menu choice?
2. When the user drags a window *into* the target Space or display, should it auto-tile, or only windows present at activation plus newly created ones?
3. Should tiling state persist across app restarts (key by Space `uuid`), or always start fresh?
4. Is support for "Displays have separate Spaces = OFF" required?
5. Should Tiler support more than one tiled Space at a time later (one tree per `(display, space)`)?

---

## References

| # | Source | URL | Information gathered |
|---|---|---|---|
| 1 | AeroSpace `private.h` | https://github.com/nikitabobko/AeroSpace/blob/main/Sources/PrivateApi/include/private.h | `_AXUIElementGetWindow` declaration; commented CGWindowList alternative |
| 2 | AeroSpace `MacApp.swift` | https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/MacApp.swift | Per-app thread + `CFRunLoopRun`, setFrame order, `AXEnhancedUserInterface`, job cancellation, AX subscriptions |
| 3 | AeroSpace `AxSubscription.swift` | https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/util/AxSubscription.swift | Observer retention, run-loop source on current thread, deinit cleanup |
| 4 | AeroSpace `accessibility.swift` | https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/util/accessibility.swift | `kAXWindows` current-Space comment, TCC reset via tccutil, attribute wrappers |
| 5 | AeroSpace `AxUiElementWindowType.swift` | https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/model/AxUiElementWindowType.swift | Window/dialog/popup heuristics |
| 6 | AeroSpace `Package.swift` | https://github.com/nikitabobko/AeroSpace/blob/main/Package.swift | SPM layout, HotKey 0.2.1, C PrivateApi target |
| 7 | AeroSpace guide | https://nikitabobko.github.io/AeroSpace/guide | Why workspaces are emulated; "separate Spaces" recommendation |
| 8 | yabai `extern.h` | https://github.com/koekeishiya/yabai/blob/master/src/misc/extern.h | SLS* signatures |
| 9 | yabai `space.c` | https://github.com/koekeishiya/yabai/blob/master/src/space.c | `SLSCopyWindowsWithOptionsAndTags` + iterator filters, Space types |
| 10 | yabai `display.c` | https://github.com/koekeishiya/yabai/blob/master/src/display.c | UUID↔ID, `SLSManagedDisplayGetCurrentSpace`, `id64` parsing |
| 11 | yabai `workspace.m` | https://github.com/koekeishiya/yabai/blob/master/src/workspace.m | Notifications observed, finishedLaunching KVO |
| 12 | yabai `event_loop.c` | https://github.com/koekeishiya/yabai/blob/master/src/event_loop.c | SPACE_CHANGED/DISPLAY_CHANGED, self-move suppression |
| 13 | Amethyst `CGInfo.swift` | https://github.com/ianyh/Amethyst/blob/development/Amethyst/Model/CGInfo.swift | `CGSCopySpacesForWindows(kCGSAllSpacesMask)`, "Current Space"/ManagedSpaceID/uuid parsing |
| 14 | Amethyst `Screen.swift`, `Window.swift`, `WindowsInformation.swift` | https://github.com/ianyh/Amethyst/tree/development/Amethyst/Model | Managed display id, `shouldBeManaged`, focus via `_SLPSSetFrontProcessWithOptions`, onScreen CG list |
| 15 | Silica `SIWindow.m` | https://github.com/ianyh/Silica/blob/master/Silica/Sources/SIWindow.m | wid caching, isOnScreen, sheet handling |
| 16 | CGSInternal `CGSSpace.h` | https://github.com/NUIKit/CGSInternal/blob/master/CGSSpace.h | Space mask enum, `CGSGetActiveSpace`, `CGSCopySpacesForWindows` |
| 17 | Rectangle `AccessibilityElement.swift` | https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift | size→position→size, EnhancedUI handling, `AXUIElementSetMessagingTimeout` |
| 18 | Loop `PrivateApis.swift`, `SkyLightSymbolLoader.swift` | https://github.com/MrKai77/Loop/tree/develop/Loop/Private%20APIs | dlsym loader pattern, Space mask names, macOS 26.3 attributes=0, corner radii API |
| 19 | yabai issues #2675, #2707, #2730, #2799, #2634 | https://github.com/koekeishiya/yabai/issues/2675 | Tahoe regressions (SA / Space mutation) |
| 20 | NUEM issue #6 | https://github.com/tgtools123/NUEM/issues/6 | macOS 27: `SLSCopySpacesForWindows` returns [] in their case |
| 21 | Lanterna issue #86 | https://github.com/peacock0803sz/Lanterna/issues/86 | macOS 27: kAXWindows leaves out hidden-Space windows; CGS Space queries work |
| 22 | Hammerspoon issue #3897 | https://github.com/Hammerspoon/hammerspoon/issues/3897 | macOS 27 Mission Control AX tree moved; moveWindowToSpace silently fails |
| 23 | hyprdarwin PR #6 | https://github.com/BruceChanJianLe/hyprdarwin/pull/6 | "Away" windows across Spaces/fullscreen; delayed close detection |
| 24 | Rememoru PR #4 | https://github.com/L-K-M/Rememoru/pull/4 | Split-view tile dicts: ManagedSpaceID vs id64 |
| 25 | spaces-renamer PR #29 | https://github.com/Quelaan1/spaces-renamer/pull/29 | Display IDs re-enumerate after wake |
| 26 | shannoncoat `build.sh` | https://git.bdeshi.space/bdeshi/shannoncoat/raw/branch/main/build.sh | Ad-hoc cdhash pinning vs self-signed DR; fail if identity missing |
| 27 | Eternal Storms blog / Apple forums 763878 | https://blog.eternalstorms.at/2024/09/23/keyboard-shortcuts-using-option-and-or-shift-modifiers-only-no-longer-allowed-on-macos-sequoia/ | Sequoia RegisterEventHotKey Option-only restriction and 15.2 relaxation |
| 28 | Daring Fireball / heise / 9to5Mac on Tahoe resizing | https://daringfireball.net/2026/01/resizing_windows_macos_26 | Tahoe corner radius / resize hit-area regression |
| 29 | Apple forums: identify first desktop | https://developer.apple.com/forums/thread/71058 | No public API for Space identity |
