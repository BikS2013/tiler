import AppKit
import TilerCore

/// Modifier + drag moves the window under the pointer from anywhere in it
/// (default ⌘⌥), on any desktop, tiled or not.
///
/// - The press is swallowed, so the app underneath never sees the click (no
///   link opened, no text selection, no terminal cursor jump).
/// - This is Tiler's one active event tap. It sees only left-button
///   down/dragged/up events (never key presses or plain mouse moves), and its
///   callback does nothing but compare the modifiers and record the pointer,
///   on a thread of its own, so a busy main thread or a slow app never holds
///   up anyone's clicks.
/// - Accessibility work (finding the window, moving it) runs on a second
///   thread. Moves are coalesced: however fast the mouse reports, the window
///   gets the newest position as soon as the previous write is done.
/// - A tiled window dragged this way behaves like one dragged by its title
///   bar: on release it swaps with the tile it was dropped on or snaps back.
///   The swallowed press never reaches the window server, so the system does
///   not report the button as down; `isActive` tells the controller instead,
///   and `onGrab`/`onDrop` hand it the window and the drop point directly, so
///   the drop never waits for the app's own (possibly late) moved
///   notifications.
final class WindowDrag {
    /// True (main thread) from the moment a window is grabbed until its last
    /// move has been written.
    private(set) var isActive = false
    /// Main thread: a window was grabbed (its id), and later dropped (its id
    /// and the pointer at release).
    var onGrab: ((CGWindowID) -> Void)?
    var onDrop: ((CGWindowID, CGPoint) -> Void)?

    private let tapThread = RunLoopThread(name: "tiler.drag.tap")
    private let axThread = RunLoopThread(name: "tiler.drag.ax")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The configured modifiers as event flags (main thread copy).
    private var modifiers: UInt32?

    // Tap thread only.
    private var required: CGEventFlags = []
    private var dragging = false

    // Shared between the tap and AX threads.
    private let lock = NSLock()
    private var start: CGPoint = .zero
    private var target: CGPoint?
    private var released = false
    private var flushing = false

    // AX thread only.
    private var element: AXUIElement?
    private var windowID: CGWindowID = 0
    private var origin: CGPoint = .zero
    private var last: CGPoint?

    private static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    private let myPID = ProcessInfo.processInfo.processIdentifier

    /// Turn the drag on with these modifiers (a Carbon mask), or off with nil.
    func configure(_ mods: UInt32?) {
        guard mods != modifiers || (mods != nil && tap == nil) else { return }
        modifiers = mods
        guard let mods else { removeTap(); return }
        var flags: CGEventFlags = []
        if mods & KeyCombo.cmdKey != 0 { flags.insert(.maskCommand) }
        if mods & KeyCombo.optionKey != 0 { flags.insert(.maskAlternate) }
        if mods & KeyCombo.controlKey != 0 { flags.insert(.maskControl) }
        if mods & KeyCombo.shiftKey != 0 { flags.insert(.maskShift) }
        if tap == nil { installTap(flags) } else { tapThread.perform { [self] in required = flags } }
    }

    private func installTap(_ flags: CGEventFlags) {
        if tapThread.isExecuting == false { tapThread.startAndWait(); axThread.startAndWait() }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: windowDragCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("drag to move: could not create the mouse tap")
            modifiers = nil
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.tap = tap
        self.source = source
        tapThread.perform { [self] in
            required = flags
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func removeTap() {
        guard let tap, let source else { return }
        self.tap = nil
        self.source = nil
        tapThread.perform {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
            CFMachPortInvalidate(tap)
        }
    }

    // MARK: Tap thread

    /// Returns true when the event is Tiler's and must not reach the app.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // The release may have gone by while the tap was off: drop the
            // window where the pointer is now rather than stay mid-drag.
            if dragging, let p = CGEvent(source: nil)?.location { move(to: p, up: true) }
            return false
        case .leftMouseDown:
            // Tiler's own synthetic drags (the desktop mover) pass through.
            guard event.flags.intersection(Self.relevant) == required,
                  event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(myPID) else { return false }
            dragging = true
            let p = event.location
            lock.lock()
            start = p; target = nil; released = false
            lock.unlock()
            axThread.perform { [self] in begin(at: p) }
            return true
        case .leftMouseDragged, .leftMouseUp:
            guard dragging else { return false }
            move(to: event.location, up: type == .leftMouseUp)
            return true
        default:
            return false
        }
    }

    /// The pointer of the drag in progress is at `point` (released if `up`).
    private func move(to point: CGPoint, up: Bool) {
        if up { dragging = false }
        lock.lock()
        target = point
        if up { released = true }
        let schedule = !flushing && element != nil
        if schedule { flushing = true }
        lock.unlock()
        if schedule { axThread.perform { [self] in flush() } }
    }

    // MARK: AX thread

    /// Find the window under the press; then catch up with the pointer.
    private func begin(at point: CGPoint) {
        let found = Self.window(at: point)
        lock.lock()
        element = found?.element
        origin = found?.origin ?? .zero
        last = nil
        let pending = found != nil && target != nil && !flushing
        if pending { flushing = true }
        lock.unlock()
        guard let found else { return }
        windowID = found.id
        DispatchQueue.main.async { [self] in
            isActive = true
            onGrab?(found.id)
        }
        // The swallowed click never brings the window forward the way a
        // title-bar press does. Focus its app first, then raise it (an app in
        // the background ignores the raise), as `AppHandle.focus` does, so it
        // moves above the tiles it is dragged over.
        focusWindow(pid: found.pid, wid: found.id)
        AXUIElementPerformAction(found.element, kAXRaiseAction as CFString)
        if pending { flush() }
    }

    /// Apply the newest pointer position until none is pending.
    private func flush() {
        while true {
            lock.lock()
            guard let el = element, let t = target else { flushing = false; lock.unlock(); return }
            let p = CGPoint(x: origin.x + t.x - start.x, y: origin.y + t.y - start.y)
            target = nil
            let done = released
            if done { element = nil }
            lock.unlock()
            if p != last {
                AppHandle.setPosition(el, p)
                last = p
            }
            if done {
                lock.lock(); flushing = false; lock.unlock()
                let id = windowID
                DispatchQueue.main.async { [self] in
                    isActive = false
                    onDrop?(id, t)
                }
                return
            }
        }
    }

    private static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.5)
        return el
    }()

    /// The movable, standard, non-full-screen window at `point`, if any.
    private static func window(at point: CGPoint) -> (element: AXUIElement, id: CGWindowID, pid: pid_t, origin: CGPoint)? {
        guard let window = axWindow(at: point) ?? visibleWindow(at: point) else { return nil }
        var pid: pid_t = 0
        var settable = DarwinBoolean(false)
        guard AXUIElementGetPid(window, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier,
              AppHandle.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              AppHandle.bool(window, "AXFullScreen") != true,
              AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success, settable.boolValue,
              let id = AppHandle.windowID(of: window), let frame = AppHandle.frame(of: window) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.5)
        return (window, id, pid, frame.origin)
    }

    /// The window of the accessibility element under `point`.
    private static func axWindow(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        if AppHandle.string(hit, kAXRoleAttribute) == kAXWindowRole { return hit }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The frontmost ordinary window the window server shows under `point`,
    /// as its app's accessibility element. Covers apps whose accessibility
    /// tree is built lazily (Electron, Chromium), where the first hit test
    /// can come back without a window.
    private static func visibleWindow(at point: CGPoint) -> AXUIElement? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return nil }
            return windows.first { AppHandle.windowID(of: $0) == id }
        }
        return nil
    }
}

/// The drag tap's callback (tap thread). Swallows the drag's own events.
private func windowDragCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let drag = Unmanaged<WindowDrag>.fromOpaque(userInfo).takeUnretainedValue()
    return drag.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
