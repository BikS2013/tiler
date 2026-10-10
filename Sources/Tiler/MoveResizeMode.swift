import AppKit
import SwiftUI
import TilerCore

/// Keyboard move/resize for the focused window when Tiler is not tiling it:
/// a floating window on a tiled desktop, or any window on an untiled one.
///
/// The shortcut enters a mode with a small HUD. While the mode is on, and only
/// then, the arrow keys and a few letters are borrowed as Carbon hotkeys:
/// arrows move, ⇧ arrows resize, ⌥ makes either fine, C centres, M fills the
/// screen, Return / Esc / the shortcut again end it. Switching app or desktop,
/// or a click, ends it too. Only the window that had focus when the mode began
/// is ever touched, and only by these keys.
final class MoveResizeMode {
    private let controller: Controller
    private var mover: WindowMover?
    private var panel: HUDPanel?
    private let model = MoveResizeModel()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var mouseMonitor: Any?
    private var repeatTimer: Timer?
    private var target: CGRect = .zero
    private var area: CGRect = .zero

    static let step: CGFloat = 40
    static let fineStep: CGFloat = 8

    init(controller: Controller) { self.controller = controller }

    var isActive: Bool { mover != nil }

    func toggle() { isActive ? end() : begin() }

    func begin() {
        guard controller.started, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { NSSound.beep(); return }
        let mover = WindowMover(pid: app.processIdentifier)
        self.mover = mover
        mover.loadFocusedWindow { [weak self] info in
            guard let self, self.mover === mover else { return }
            guard let info else { self.end(); NSSound.beep(); return }
            if self.controller.isTiled(info.id) {
                self.flash("This window is tiled", detail: "Float it first with \(self.controller.config?.hotkeys[.toggleFloat]?.symbols ?? "the Float shortcut"), or move it with the tiling shortcuts.")
                return
            }
            self.start(app: app, info: info)
        }
    }

    func end() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        controller.releaseKeys()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        panel?.dismiss()
        panel = nil
        mover?.stop()
        mover = nil
    }

    // MARK: Running

    private func start(app: NSRunningApplication, info: WindowMover.Info) {
        target = info.frame
        let center = CGPoint(x: info.frame.midX, y: info.frame.midY)
        let screen = Screen.all().first { $0.bounds.contains(center) } ?? Screen.all().first
        let gap = controller.config?.outerGap ?? 0
        area = (screen?.usable ?? info.frame).insetBy(dx: gap, dy: gap)
        model.app = app.localizedName ?? "Window"
        model.title = info.title
        model.frame = info.frame
        model.message = nil
        model.exitKey = controller.config?.hotkeys[.moveResize]?.symbols

        let p = HUDPanel(content: MoveResizeView(model: model))
        p.onDismiss = { [weak self] in self?.end() }
        p.present(on: NSScreen.with(displayUUID: screen?.uuid) ?? NSScreen.main ?? NSScreen.screens[0], at: .bottom)
        panel = p

        var keys: [(code: UInt32, modifiers: UInt32)] = []
        var ops: [(WindowNudge.Operation, CGFloat)?] = []
        let arrows: [(UInt32, Direction)] = [(0x7B, .left), (0x7C, .right), (0x7E, .up), (0x7D, .down)]
        for (mods, resize, fine) in [(UInt32(0), false, false), (KeyCombo.shiftKey, true, false),
                                     (KeyCombo.optionKey, false, true), (KeyCombo.shiftKey | KeyCombo.optionKey, true, true)] {
            for (code, dir) in arrows {
                keys.append((code, mods))
                ops.append((resize ? .resize(dir) : .move(dir), fine ? Self.fineStep : Self.step))
            }
        }
        keys.append((0x08, 0)); ops.append((.center, 0))        // C
        keys.append((0x2E, 0)); ops.append((.maximize, 0))      // M
        for code: UInt32 in [0x24, 0x4C, 0x35] { keys.append((code, 0)); ops.append(nil) } // Return, Enter, Esc
        controller.borrowKeys(keys) { [weak self] index, pressed in
            guard let self else { return }
            guard let (op, step) = ops[index] else { if pressed { self.end() }; return }
            if pressed { self.press(op, step: step) } else { self.repeatTimer?.invalidate(); self.repeatTimer = nil }
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.end() }))
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.end() }
    }

    /// Apply once, then repeat while the key is held (Carbon hotkeys do not auto-repeat).
    private func press(_ op: WindowNudge.Operation, step: CGFloat) {
        apply(op, step: step)
        repeatTimer?.invalidate()
        repeatTimer = nil
        switch op {
        case .move, .resize: scheduleRepeat(op, step: step)
        case .center, .maximize: break
        }
    }

    private func scheduleRepeat(_ op: WindowNudge.Operation, step: CGFloat) {
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            let r = Timer(timeInterval: 0.045, repeats: true) { [weak self] _ in self?.apply(op, step: step) }
            RunLoop.main.add(r, forMode: .common)
            self?.repeatTimer = r
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func apply(_ op: WindowNudge.Operation, step: CGFloat) {
        guard let mover else { return }
        target = WindowNudge.apply(op, to: target, in: area, step: step)
        model.frame = target
        mover.setFrame(target) { [weak self] actual in
            guard let self, self.mover === mover else { return }
            guard let actual else { self.end(); return }   // the window went away
            // An app may refuse a size; carry on from what it accepted.
            if !mover.hasPending { self.target = actual; self.model.frame = actual }
        }
    }

    /// A short message instead of the mode (e.g. the window is tiled).
    private func flash(_ title: String, detail: String) {
        model.app = title
        model.title = ""
        model.message = detail
        let p = HUDPanel(content: MoveResizeView(model: model))
        p.onDismiss = { [weak self] in self?.end() }
        p.present(on: NSScreen.with(displayUUID: controller.activeDisplay()) ?? NSScreen.main ?? NSScreen.screens[0], at: .bottom)
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self, weak p] in
            if let p, self?.panel === p { self?.end() }
        }
    }
}

/// AX access to one window, on a thread of its own for as long as the mode
/// runs, so a slow app never blocks the main thread. Frame writes are
/// coalesced: only the newest wanted frame is written.
final class WindowMover {
    struct Info {
        let id: CGWindowID
        let frame: CGRect
        let title: String
        /// A point in the title bar's drag area: just right of the zoom button,
        /// which works even in apps with tabs in the title bar.
        let grabPoint: CGPoint
        /// AXStandardWindow (not a dialog, sheet or panel).
        let standard: Bool
    }

    private let pid: pid_t
    private let thread = RunLoopThread(name: "tiler.mover")
    private var element: AXUIElement?          // thread-confined
    private let lock = NSLock()
    private var pending: CGRect?
    private var flushing = false

    init(pid: pid_t) {
        self.pid = pid
        thread.startAndWait()
    }

    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }

    func loadFocusedWindow(_ completion: @escaping (Info?) -> Void) {
        thread.perform { [self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            var value: AnyObject?
            var info: Info?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let el = value as! AXUIElement
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(el, kAXPositionAttribute as CFString, &settable) == .success, settable.boolValue,
                   AppHandle.bool(el, "AXFullScreen") != true,
                   let id = AppHandle.windowID(of: el), let frame = AppHandle.frame(of: el) {
                    element = el
                    var grab = CGPoint(x: frame.midX, y: frame.minY + 10)
                    var zoom: AnyObject?
                    if AXUIElementCopyAttributeValue(el, kAXZoomButtonAttribute as CFString, &zoom) == .success,
                       let zoom, CFGetTypeID(zoom) == AXUIElementGetTypeID(),
                       let z = AppHandle.frame(of: zoom as! AXUIElement) {
                        grab = CGPoint(x: z.maxX + 8, y: z.midY)
                    }
                    info = Info(id: id, frame: frame, title: AppHandle.string(el, kAXTitleAttribute) ?? "", grabPoint: grab,
                                standard: AppHandle.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole)
                }
            }
            DispatchQueue.main.async { completion(info) }
        }
    }

    /// Write `frame` (or a newer one, if another arrives first); the completion
    /// gets the frame the app actually took, or nil if the window is gone.
    func setFrame(_ frame: CGRect, completion: @escaping (CGRect?) -> Void) {
        lock.lock()
        pending = frame
        let schedule = !flushing
        flushing = true
        lock.unlock()
        guard schedule else { return }
        thread.perform { [self] in
            var actual: CGRect?
            while true {
                lock.lock()
                guard let next = pending else { flushing = false; lock.unlock(); break }
                pending = nil
                lock.unlock()
                guard let el = element else { break }
                AppHandle.setSize(el, next.size)
                AppHandle.setPosition(el, next.origin)
                AppHandle.setSize(el, next.size)
                actual = AppHandle.frame(of: el)
            }
            DispatchQueue.main.async { completion(actual) }
        }
    }

    /// Unminimize every minimized window of the app; the completion gets how many.
    func unminimizeAll(_ completion: @escaping (Int) -> Void) {
        thread.perform { [self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            var value: AnyObject?
            var count = 0
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                for w in windows where AppHandle.bool(w, kAXMinimizedAttribute) == true {
                    if AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success { count += 1 }
                }
            }
            DispatchQueue.main.async { completion(count) }
        }
    }

    func stop() { thread.stop() }
}

final class MoveResizeModel: ObservableObject {
    @Published var app = ""
    @Published var title = ""
    @Published var frame: CGRect = .zero
    @Published var message: String?
    @Published var exitKey: String?
}

private struct MoveResizeView: View {
    @ObservedObject var model: MoveResizeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model.message == nil ? "arrow.up.and.down.and.arrow.left.and.right" : "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(model.message == nil ? "Move & Resize · \(model.app)" : model.app).font(.headline)
                if model.message == nil {
                    Spacer(minLength: 16)
                    Text(verbatim: "\(Int(model.frame.width)) × \(Int(model.frame.height))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            } else {
                if !model.title.isEmpty {
                    Text(model.title).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 16) {
                    legend("← ↑ → ↓", "move")
                    legend("⇧ arrows", "resize")
                    legend("⌥", "fine")
                    legend("C", "centre")
                    legend("M", "fill")
                    legend("↩ / esc", "done")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
    }

    private func legend(_ keys: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            Text(what).font(.caption).foregroundStyle(.secondary)
        }
    }
}
