import AppKit

/// What an app's AX observer reports back to the main thread.
enum AppEvent {
    case windowCreated(pid_t, CGWindowID)
    case windowDestroyed(pid_t, CGWindowID)
    case windowMoved(pid_t, CGWindowID)
    case windowResized(pid_t, CGWindowID)
    case windowMinimized(pid_t, CGWindowID)
    case focusChanged(pid_t, CGWindowID?)
    /// The app accepted the window notifications (a launching app may only
    /// after a few tries): windows it opened before then went unannounced.
    case subscribed(pid_t)
}

/// What Tiler needs to know about a window before it can tile it.
struct WindowFacts {
    let pid: pid_t
    let tileable: Bool
}

/// A thread with its own run loop. Each app gets one, so a slow or hung app
/// only ever stalls its own thread, never the main thread or other apps.
final class RunLoopThread: Thread {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInteractive
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A far-future timer keeps the run loop alive when no AX source is attached yet.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
        ready.signal()
        while !isCancelled {
            CFRunLoopRunInMode(.defaultMode, 3600, false)
        }
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func stop() {
        cancel()
        perform { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}

/// Owns everything AX for one running app: its observer, its window elements,
/// and every read and write. Public methods may be called from the main
/// thread; the work runs on the app's own thread and results come back on main.
final class AppHandle {
    let pid: pid_t
    let bundleID: String?
    private let app: AXUIElement
    private let thread: RunLoopThread
    private let onEvent: (AppEvent) -> Void

    // Thread-confined state (touched only on `thread`).
    private var observer: AXObserver?
    private var elements: [CGWindowID: AXUIElement] = [:]

    // Latest frame wanted per window; the flush writes only the newest one, so a
    // slow app never replays a backlog of stale layouts.
    private let lock = NSLock()
    private var pendingFrames: [CGWindowID: CGRect] = [:]
    private var flushScheduled = false

    /// Live handles by pid, read from the C observer callback.
    private static let registryLock = NSLock()
    private static var registry: [pid_t: AppHandle] = [:]

    init(app: NSRunningApplication, onEvent: @escaping (AppEvent) -> Void) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        self.app = AXUIElementCreateApplication(pid)
        self.onEvent = onEvent
        thread = RunLoopThread(name: "tiler.app.\(pid)")
    }

    func start() {
        Self.registryLock.lock(); Self.registry[pid] = self; Self.registryLock.unlock()
        thread.startAndWait()
        thread.perform { [self] in
            // A hung app costs at most this long per AX call.
            AXUIElementSetMessagingTimeout(app, 1.0)
            var obs: AXObserver?
            guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else {
                log.error("AXObserverCreate failed for pid \(self.pid)")
                return
            }
            observer = obs
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            subscribeApp(attempt: 1)
        }
    }

    /// An app that is still launching refuses subscriptions; try a few times.
    private func subscribeApp(attempt: Int) {
        guard let observer else { return }
        var ok = true
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            let err = AXObserverAddNotification(observer, app, name as CFString, nil)
            if err != .success && err != .notificationAlreadyRegistered { ok = false }
        }
        if ok {
            DispatchQueue.main.async { [onEvent, pid] in onEvent(.subscribed(pid)) }
            return
        }
        guard attempt < 5 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.thread.perform { self?.subscribeApp(attempt: attempt + 1) }
        }
    }

    func stop() {
        Self.registryLock.lock(); Self.registry[pid] = nil; Self.registryLock.unlock()
        thread.perform { [self] in
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            elements.removeAll()
        }
        thread.stop()
    }

    // MARK: Requests (call from main)

    /// Look up the given windows and report whether each can be tiled.
    func resolve(_ ids: Set<CGWindowID>, completion: @escaping ([CGWindowID: WindowFacts]) -> Void) {
        thread.perform { [self] in
            refreshElements()
            var facts: [CGWindowID: WindowFacts] = [:]
            for id in ids {
                guard let el = elements[id] else { continue }
                facts[id] = WindowFacts(pid: pid, tileable: isTileable(el))
            }
            DispatchQueue.main.async { completion(facts) }
        }
    }

    /// Move and resize a window. Coalesced: only the newest frame is written.
    func setFrame(_ id: CGWindowID, _ frame: CGRect) {
        lock.lock()
        pendingFrames[id] = frame
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule { thread.perform { [self] in flushFrames() } }
    }

    /// Read a window's current frame.
    func frame(of id: CGWindowID, completion: @escaping (CGRect?) -> Void) {
        thread.perform { [self] in
            let f = elements[id].flatMap(Self.frame(of:))
            DispatchQueue.main.async { completion(f) }
        }
    }

    /// Raise the window and give it keyboard focus.
    func focus(_ id: CGWindowID) {
        thread.perform { [self] in
            guard let el = elements[id] else { return }
            focusWindow(pid: pid, wid: id)
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        }
    }

    /// Ask which window of this app has focus.
    func focusedWindow(completion: @escaping (CGWindowID?) -> Void) {
        thread.perform { [self] in
            var value: AnyObject?
            var id: CGWindowID?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let el = value as! AXUIElement
                id = Self.windowID(of: el)
                if let id { remember(el, id: id) }
            }
            DispatchQueue.main.async { completion(id) }
        }
    }

    // MARK: Thread-side work

    private func flushFrames() {
        lock.lock()
        let frames = pendingFrames
        pendingFrames.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !frames.isEmpty else { return }

        // Apps with AXEnhancedUserInterface on (set by VoiceOver-aware tools)
        // animate every AX resize; turn it off for the duration of the writes.
        let enhanced = Self.bool(app, "AXEnhancedUserInterface") == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        for (id, frame) in frames {
            guard let el = elements[id] else { continue }
            // Size first so the move cannot be clamped by the old size at a
            // screen edge, then position, then size again in case the first
            // resize was clamped by the old position.
            Self.setSize(el, frame.size)
            Self.setPosition(el, frame.origin)
            Self.setSize(el, frame.size)
        }
    }

    /// Re-read the app's window list and map each element to its window id.
    private func refreshElements() {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return }
        for el in list {
            if let id = Self.windowID(of: el) { remember(el, id: id) }
        }
    }

    /// Store the element and subscribe to its per-window notifications once.
    private func remember(_ el: AXUIElement, id: CGWindowID) {
        guard elements[id] == nil else { return }
        elements[id] = el
        AXUIElementSetMessagingTimeout(el, 1.0)
        guard let observer else { return }
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id))
        for name in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification,
                     kAXWindowResizedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(observer, el, name as CFString, refcon)
        }
    }

    private func isTileable(_ el: AXUIElement) -> Bool {
        guard Self.string(el, kAXRoleAttribute) == kAXWindowRole,
              Self.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              Self.bool(el, kAXMinimizedAttribute) != true,
              Self.bool(el, "AXFullScreen") != true else { return false }
        // Dialogs and settings panes have no working green button: they float.
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXFullScreenButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID(),
              Self.bool(button as! AXUIElement, kAXEnabledAttribute) == true else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return true
    }

    fileprivate func handle(_ name: String, _ element: AXUIElement, refcon: UnsafeMutableRawPointer?) {
        let refID = CGWindowID(UInt(bitPattern: refcon))
        let event: AppEvent
        switch name {
        case kAXWindowCreatedNotification:
            guard let id = Self.windowID(of: element) else { return }
            remember(element, id: id)
            event = .windowCreated(pid, id)
        case kAXFocusedWindowChangedNotification:
            let id = Self.windowID(of: element)
            if let id { remember(element, id: id) }
            event = .focusChanged(pid, id)
        case kAXUIElementDestroyedNotification:
            guard refID != 0 else { return }
            elements[refID] = nil
            event = .windowDestroyed(pid, refID)
        case kAXWindowMovedNotification:
            event = .windowMoved(pid, refID)
        case kAXWindowResizedNotification:
            event = .windowResized(pid, refID)
        case kAXWindowMiniaturizedNotification:
            event = .windowMinimized(pid, refID)
        default:
            return
        }
        DispatchQueue.main.async { [onEvent] in onEvent(event) }
    }

    fileprivate static func handle(for pid: pid_t) -> AppHandle? {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[pid]
    }

    // MARK: AX helpers

    static func windowID(of el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        var pos: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
    }

    static func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }
}

/// C callback for every app's observer; runs on that app's thread.
private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    AppHandle.handle(for: pid)?.handle(name as String, element, refcon: refcon)
}
