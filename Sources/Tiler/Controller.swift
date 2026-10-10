import AppKit
import TilerCore

/// The tiling brain. Main-thread only. Owns the tiled desktops, the per-app
/// AX handles and the hotkeys, and turns window events into layouts.
///
/// Design rules that keep it fast and predictable:
/// - Nothing runs while no desktop is tiled: no AX observers, no threads.
/// - Event-driven, never polled. A reconcile costs one CGWindowList call plus
///   one Space lookup per on-screen window (about a millisecond).
/// - Only windows on a tiled desktop's Space *and* display are ever touched.
/// - Window moves and resizes are acted on only while the mouse button is
///   down (a user drag), so the app can never fight its own writes or an
///   app that refuses a size.
final class Controller {
    private(set) var config: Config?
    private(set) var configError: String?
    private(set) var desktops: [DesktopKey: Desktop] = [:]
    var onChange: (() -> Void)?
    /// The shortcuts overlay hotkey was pressed.
    var onShowHotkeys: (() -> Void)?
    /// A second launch or `tiler-ctl.sh settings` asked for the Settings window.
    var onShowSettings: (() -> Void)?
    /// True while Settings records a shortcut: no hotkey is registered, so the
    /// keys reach the recorder.
    var hotkeysSuspended = false {
        didSet {
            guard hotkeysSuspended != oldValue else { return }
            hotkeys.configure(hotkeysSuspended ? [:] : config?.hotkeys ?? [:])
            updateHotkeys()
        }
    }

    private var apps: [pid_t: AppHandle] = [:]
    private var facts: [CGWindowID: WindowFacts] = [:]
    private var resolving: Set<CGWindowID> = []
    private var rechecked: Set<CGWindowID> = []
    private var focused: (pid: pid_t, id: CGWindowID?)?
    private var reconcileScheduled = false
    private var drag: (key: DesktopKey?, id: CGWindowID, timer: Timer)?
    private let myPID = ProcessInfo.processInfo.processIdentifier
    /// Set once Accessibility is granted and tiling runs.
    private(set) var started = false
    private lazy var hotkeys = Hotkeys { [weak self] action in self?.perform(action) }

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tiler", isDirectory: true)
    static let configURL = supportDir.appendingPathComponent("config.json")
    private static let desktopsURL = supportDir.appendingPathComponent("desktops.json")

    // MARK: Lifecycle

    /// Config and the scripting hook: available before Accessibility is granted,
    /// so Settings and `tiler-ctl.sh` work from the first launch.
    func prepare() {
        reloadConfig()
        // Scripting hook: `scripts/tiler-ctl.sh toggle <display-uuid|active>`, `retile`, `reload`, `settings`, `shortcuts`, `dump`.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.giorgosmarinos.tiler.command"),
                                                            object: nil, queue: .main) { [weak self] n in
            self?.command(n.object as? String ?? "")
        }
    }

    /// Tiling itself; needs Accessibility.
    func start() {
        started = true
        restoreDesktops()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, !desktops.isEmpty, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            attach(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            detach(app.processIdentifier)
            scheduleReconcile()
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleReconcile() }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            readFocus(of: app)
            scheduleReconcile()
        }
        // The second name is undocumented (yabai uses it): focus moved to another display.
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateHotkeys()
                self?.scheduleReconcile()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            refreshSpaceIDs()
            for d in desktops.values { d.applied.removeAll(); d.needsLayout = true }
            scheduleReconcile()
            onChange?()
        }
        if !desktops.isEmpty { attachAll() }
        if let front = NSWorkspace.shared.frontmostApplication { readFocus(of: front) }
        updateHotkeys()
        scheduleReconcile()
    }

    private func command(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        switch parts.first {
        case "toggle":
            let target = parts.count > 1 && parts[1] != "active" ? parts[1] : activeDisplay()
            if let target { toggleDesktop(onDisplay: target) }
        case "retile":
            perform(.retile)
        case "reload":
            reloadConfig()
        case "settings":
            onShowSettings?()
        case "shortcuts":
            onShowHotkeys?()
        case "dump":
            for d in desktops.values {
                let visible = Spaces.current(onDisplay: d.key.displayUUID) == d.spaceID
                let tiles = d.tree.windows.map { id in "\(id)@\(d.frames[id].map { "\($0)" } ?? "-")" }
                log.notice("desktop \(d.key.displayUUID, privacy: .public)/\(d.spaceID) visible=\(visible) tiles=\(tiles, privacy: .public) floating=\(d.floating.sorted(), privacy: .public)")
            }
            log.notice("apps=\(self.apps.count) facts=\(self.facts.count) focused=\(String(describing: self.focused), privacy: .public)")
        default:
            log.error("unknown command '\(text, privacy: .public)'")
        }
    }

    // MARK: Config

    func reloadConfig() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: Self.configURL.path) {
                try Data(Config.template.utf8).write(to: Self.configURL)
            }
            config = try Config.parse(Data(contentsOf: Self.configURL))
            configError = nil
            hotkeys.configure(hotkeysSuspended ? [:] : config!.hotkeys)
            for d in desktops.values { d.applied.removeAll(); d.needsLayout = true }
        } catch {
            // Keep running with the last good config; with none, nothing tiles.
            configError = (error as? ConfigError)?.description ?? error.localizedDescription
            log.error("config: \(self.configError ?? "")")
        }
        updateHotkeys()
        scheduleReconcile()
        onChange?()
    }

    /// While set, Esc anywhere calls `handler` (the shortcuts overlay).
    func captureEscape(_ handler: (() -> Void)?) { hotkeys.captureEscape(handler) }

    /// Write a configuration from Settings and apply it. The text is parsed
    /// before it replaces the file, so a bad value can never land on disk.
    func save(_ new: Config) throws {
        let text = new.json()
        _ = try Config.parse(Data(text.utf8))
        try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: Self.configURL, options: .atomic)
        reloadConfig()
    }

    /// Replace the config file with the template.
    func restoreDefaultConfig() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try Data(Config.template.utf8).write(to: Self.configURL, options: .atomic)
        } catch {
            log.error("could not write config: \(error.localizedDescription)")
        }
        reloadConfig()
    }

    // MARK: Desktops

    /// The tiled desktop currently shown on the display, if any.
    func visibleDesktop(onDisplay uuid: String) -> Desktop? {
        let space = Spaces.current(onDisplay: uuid)
        return desktops.values.first { $0.key.displayUUID == uuid && $0.spaceID == space }
    }

    /// Turn tiling on or off for the desktop showing on the display.
    func toggleDesktop(onDisplay uuid: String) {
        guard started, config != nil else { NSSound.beep(); return }
        let space = Spaces.current(onDisplay: uuid)
        if let d = visibleDesktop(onDisplay: uuid) {
            desktops[d.key] = nil
            log.info("desktop off: \(d.key.spaceUUID)")
        } else {
            guard let info = Spaces.all().first(where: { $0.id == space }), info.number > 0, !info.uuid.isEmpty else {
                NSSound.beep() // fullscreen Spaces are not desktops
                return
            }
            let key = DesktopKey(displayUUID: uuid, spaceUUID: info.uuid)
            desktops[key] = Desktop(key: key, spaceID: space)
            log.info("desktop on: \(info.uuid) (#\(info.number))")
        }
        saveDesktops()
        if desktops.isEmpty { detachAll() } else { attachAll() }
        if let front = NSWorkspace.shared.frontmostApplication { readFocus(of: front) }
        updateHotkeys()
        reconcile()
        onChange?()
    }

    private func saveDesktops() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(desktops.keys)).write(to: Self.desktopsURL)
        } catch {
            log.error("could not save desktops: \(error.localizedDescription)")
        }
    }

    private func restoreDesktops() {
        guard let data = try? Data(contentsOf: Self.desktopsURL),
              let keys = try? JSONDecoder().decode([DesktopKey].self, from: data) else { return }
        let spaces = Dictionary(Spaces.all().map { ($0.uuid, $0.id) }, uniquingKeysWith: { a, _ in a })
        for key in keys {
            // A desktop deleted in Mission Control is forgotten.
            guard let id = spaces[key.spaceUUID] else { continue }
            desktops[key] = Desktop(key: key, spaceID: id)
        }
        if desktops.count != keys.count { saveDesktops() }
    }

    private func refreshSpaceIDs() {
        let spaces = Dictionary(Spaces.all().map { ($0.uuid, $0.id) }, uniquingKeysWith: { a, _ in a })
        for d in desktops.values {
            if let id = spaces[d.key.spaceUUID] { d.spaceID = id }
        }
    }

    // MARK: App handles

    private func attachAll() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != myPID, apps[pid] == nil, pid > 0 else { return }
        let handle = AppHandle(app: app) { [weak self] event in self?.handle(event) }
        apps[pid] = handle
        handle.start()
    }

    private func detach(_ pid: pid_t) {
        apps.removeValue(forKey: pid)?.stop()
        facts = facts.filter { $0.value.pid != pid }
    }

    private func detachAll() {
        for handle in apps.values { handle.stop() }
        apps.removeAll()
        facts.removeAll()
        resolving.removeAll()
    }

    // MARK: Events

    private func handle(_ event: AppEvent) {
        switch event {
        case .windowCreated(_, let id):
            facts[id] = nil
            scheduleReconcile()
            // Some apps put a new window on screen a little after announcing it.
            for delay in [0.15, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleReconcile() }
            }
        case .windowDestroyed(_, let id):
            facts[id] = nil
            rechecked.remove(id)
            for d in desktops.values where d.owns(id) {
                d.tree.remove(id)
                d.floating.remove(id)
                d.applied[id] = nil
                layout(d)
            }
        case .windowMinimized:
            scheduleReconcile()
        case .windowMoved(_, let id), .windowResized(_, let id):
            let tiled = desktops.values.first { $0.tree.contains(id) }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                // A user drag: act once the button is released.
                if drag == nil { beginDrag(of: id, on: tiled) }
            } else if tiled == nil {
                // Something (a script, the app itself) moved an untiled window:
                // it may have landed on a tiled desktop. The window server updates
                // its Space a moment after the move, so look again shortly.
                scheduleReconcile()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scheduleReconcile() }
            }
        case .focusChanged(let pid, let id):
            focusChanged(pid: pid, id: id)
        }
    }

    /// Ask the app which window has focus; the answer arrives as a focus change.
    private func readFocus(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        focused = (pid, nil)
        apps[pid]?.focusedWindow { [weak self] id in self?.focusChanged(pid: pid, id: id) }
        updateHotkeys()
    }

    private func focusChanged(pid: pid_t, id: CGWindowID?) {
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        focused = (pid, id)
        if let id, let d = desktops.values.first(where: { $0.tree.contains(id) }) { d.lastFocused = id }
        updateHotkeys()
    }

    // MARK: Reconcile

    func scheduleReconcile() {
        guard !reconcileScheduled, !desktops.isEmpty else { return }
        reconcileScheduled = true
        // A short delay folds bursts of events (an app opening five windows) into one pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.reconcileScheduled = false
            self?.reconcile()
        }
    }

    /// Bring every visible tiled desktop's tree in line with the windows that
    /// are actually on it.
    private func reconcile() {
        guard config != nil, !desktops.isEmpty else { return }
        let screens = Dictionary(Screen.all().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = desktops.values.filter {
            screens[$0.key.displayUUID] != nil && Spaces.current(onDisplay: $0.key.displayUUID) == $0.spaceID
        }
        // Mid-switch the window list mixes two desktops: wait for the animation to end.
        if visible.contains(where: { Spaces.isAnimating(display: $0.key.displayUUID) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.scheduleReconcile() }
            return
        }
        guard !visible.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }

        // Ordinary (layer 0), visible windows of other apps, front to back.
        var onScreen: [(id: CGWindowID, pid: pid_t, center: CGPoint)] = []
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b), bounds.width > 1, bounds.height > 1 else { continue }
            onScreen.append((id, pid, CGPoint(x: bounds.midX, y: bounds.midY)))
        }

        var toResolve: [pid_t: Set<CGWindowID>] = [:]
        for d in visible {
            let screen = screens[d.key.displayUUID]!
            let present = onScreen.filter {
                guard screen.bounds.contains($0.center) else { return false }
                // An empty answer means the window server did not say; the window is
                // on screen on this display, so it is on the visible desktop.
                let spaces = Spaces.of(window: $0.id)
                return spaces.isEmpty || spaces.contains(d.spaceID)
            }
            // During a desktop switch the list can hold both desktops' windows;
            // if the Space changed while reading, the next event redoes it.
            guard Spaces.current(onDisplay: d.key.displayUUID) == d.spaceID else { continue }

            let presentIDs = Set(present.map(\.id))
            var changed = d.needsLayout
            d.needsLayout = false
            for id in d.tree.windows where !presentIDs.contains(id) || isFloatingApp(facts[id]?.pid) {
                d.tree.remove(id)
                d.applied[id] = nil
                changed = true
            }
            d.floating.formIntersection(presentIDs)

            // Back to front, so the frontmost new window is inserted last.
            for w in present.reversed() where !d.owns(w.id) && !isFloatingApp(w.pid) {
                guard let f = facts[w.id] else {
                    if !resolving.contains(w.id) { toResolve[w.pid, default: []].insert(w.id) }
                    continue
                }
                guard f.tileable else { continue }
                let target = d.lastFocused.flatMap { d.tree.contains($0) ? $0 : nil }
                d.tree.insert(w.id, splitting: target)
                changed = true
            }
            if changed { layout(d) }
        }

        for (pid, ids) in toResolve { resolve(ids, of: pid) }
    }

    private func isFloatingApp(_ pid: pid_t?) -> Bool {
        guard let pid, let config, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return config.floatingApps.contains(bundle)
    }

    private func resolve(_ ids: Set<CGWindowID>, of pid: pid_t) {
        if apps[pid] == nil, let app = NSRunningApplication(processIdentifier: pid) { attach(app) }
        guard let handle = apps[pid] else { return }
        resolving.formUnion(ids)
        handle.resolve(ids) { [weak self] result in
            guard let self else { return }
            resolving.subtract(ids)
            for id in ids {
                let f = result[id] ?? WindowFacts(pid: pid, tileable: false)
                facts[id] = f
                // A window can start out as a non-standard window and become a
                // normal one a moment later: look once more.
                if !f.tileable, rechecked.insert(id).inserted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.facts[id] = nil
                        self?.scheduleReconcile()
                    }
                }
            }
            reconcile()
        }
    }

    // MARK: Layout

    private func layout(_ d: Desktop) {
        defer { log.debug("layout \(d.spaceID): \(d.frames.map { "\($0.key)=\($0.value)" }, privacy: .public)") }
        guard let config, let screen = Screen.all().first(where: { $0.uuid == d.key.displayUUID }) else { return }
        let area = screen.usable.insetBy(dx: config.outerGap, dy: config.outerGap)
        d.frames = d.tree.layout(in: area, gap: config.innerGap)
        for (id, frame) in d.frames where d.applied[id] != frame {
            guard let pid = facts[id]?.pid, let handle = apps[pid] else { continue }
            handle.setFrame(id, frame)
            d.applied[id] = frame
        }
    }

    // MARK: Mouse drags

    private func beginDrag(of id: CGWindowID, on d: Desktop?) {
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self?.endDrag()
        }
        RunLoop.main.add(timer, forMode: .common)
        drag = (d?.key, id, timer)
    }

    /// The user let go of a tiled window: a resized window moves its dividers,
    /// a window dropped onto another tile swaps with it, anything else snaps back.
    private func endDrag() {
        guard let (key, id, timer) = drag else { return }
        timer.invalidate()
        drag = nil
        // A dragged untiled window may have been dropped onto a tiled desktop.
        guard let key else { scheduleReconcile(); return }
        let mouse = CGEvent(source: nil)?.location ?? .zero
        guard let pid = facts[id]?.pid, let handle = apps[pid] else { return }
        handle.frame(of: id) { [weak self] frame in
            guard let self, let config, let d = desktops[key], d.tree.contains(id),
                  let old = d.frames[id], let frame else { return }
            let resized = abs(frame.width - old.width) > 2 || abs(frame.height - old.height) > 2
            if resized {
                d.tree.adoptResize(of: id, to: frame, gap: config.innerGap)
            } else if let target = Geometry.window(at: mouse, in: d.frames), target != id {
                d.tree.swap(id, target)
            } else if !(Screen.all().first { $0.uuid == key.displayUUID }?.bounds.contains(mouse) ?? true) {
                // Dragged to another display: let it go.
                scheduleReconcile()
                return
            }
            d.applied[id] = nil
            layout(d)
        }
    }

    // MARK: Hotkeys

    /// The display the user is working on: the one holding the focused
    /// window, or the one under the mouse when no window has focus.
    func activeDisplay() -> String? {
        let screens = Screen.all()
        if let id = focused?.id,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
           let b = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b),
           let screen = screens.first(where: { $0.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }) {
            return screen.uuid
        }
        guard let mouse = CGEvent(source: nil)?.location else { return nil }
        return screens.first { $0.bounds.contains(mouse) }?.uuid
    }

    /// The tiled desktop the keyboard is working on, and its focused window
    /// when Tiler manages that window.
    private func keyboardContext() -> (Desktop, CGWindowID?)? {
        guard let display = activeDisplay(), let d = visibleDesktop(onDisplay: display) else { return nil }
        let id = focused?.id
        return (d, id.flatMap { d.owns($0) ? $0 : nil })
    }

    private func updateHotkeys() {
        guard started else { return }
        hotkeys.activate(tilingKeys: config != nil && keyboardContext() != nil)
        onChange?()
    }

    private func perform(_ action: Action) {
        log.debug("action \(action.rawValue, privacy: .public)")
        switch action {
        case .toggleDesktop:
            if let display = activeDisplay() { toggleDesktop(onDisplay: display) }
            return
        case .showHotkeys:
            onShowHotkeys?()
            return
        default:
            break
        }
        guard let config, let (d, focusedID) = keyboardContext() else { return }
        let id = focusedID.flatMap { d.tree.contains($0) ? $0 : nil }

        switch action {
        case .focusLeft, .focusRight, .focusUp, .focusDown:
            let target = id.flatMap { Geometry.neighbor(of: $0, direction(action), in: d.frames) }
                ?? (id == nil ? (d.lastFocused.flatMap { d.tree.contains($0) ? $0 : nil } ?? d.tree.windows.first) : nil)
            if let target { focus(target) }
        case .swapLeft, .swapRight, .swapUp, .swapDown:
            guard let id, let other = Geometry.neighbor(of: id, direction(action), in: d.frames) else { return }
            d.tree.swap(id, other)
            layout(d)
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown:
            guard let id, d.tree.moveDivider(of: id, direction(action), step: config.resizeStep) else { return }
            layout(d)
        case .toggleFloat:
            guard let fid = focusedID else { return }
            if d.tree.contains(fid) {
                d.tree.remove(fid)
                d.applied[fid] = nil
                d.floating.insert(fid)
                layout(d)
                centerFloating(fid, on: d)
            } else if d.floating.remove(fid) != nil {
                d.tree.insert(fid, splitting: d.lastFocused.flatMap { d.tree.contains($0) ? $0 : nil })
                d.lastFocused = fid
                layout(d)
            }
        case .toggleSplit:
            guard let id else { return }
            d.tree.toggleOrientation(of: id)
            layout(d)
        case .mirror:
            d.tree.mirrorHorizontally()
            layout(d)
        case .equalize:
            d.tree.equalize()
            layout(d)
        case .retile:
            d.applied.removeAll()
            facts = facts.filter { $0.value.tileable }
            rechecked.removeAll()
            layout(d)
            reconcile()
        case .toggleDesktop, .showHotkeys:
            break
        }
    }

    private func direction(_ action: Action) -> Direction {
        switch action {
        case .focusLeft, .swapLeft, .resizeLeft: return .left
        case .focusRight, .swapRight, .resizeRight: return .right
        case .focusUp, .swapUp, .resizeUp: return .up
        default: return .down
        }
    }

    private func focus(_ id: CGWindowID) {
        guard let pid = facts[id]?.pid else { return }
        apps[pid]?.focus(id)
    }

    /// A window set floating is centred at 60% of the usable area, so it is
    /// obvious that it left the tiling.
    private func centerFloating(_ id: CGWindowID, on d: Desktop) {
        guard let pid = facts[id]?.pid, let screen = Screen.all().first(where: { $0.uuid == d.key.displayUUID }) else { return }
        let u = screen.usable
        let size = CGSize(width: (u.width * 0.6).rounded(), height: (u.height * 0.6).rounded())
        apps[pid]?.setFrame(id, CGRect(x: (u.midX - size.width / 2).rounded(), y: (u.midY - size.height / 2).rounded(),
                                       width: size.width, height: size.height))
    }
}
