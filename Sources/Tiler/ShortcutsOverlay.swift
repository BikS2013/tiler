import AppKit
import SwiftUI
import TilerCore

/// The keyboard shortcuts cheat sheet: a translucent HUD centred on the
/// display being worked on. It never takes focus, so the app underneath keeps
/// the keyboard; it closes on Esc (held as a hotkey only while it is up), a
/// click anywhere, a desktop switch, or the shortcut again.
final class ShortcutsOverlay {
    private let controller: Controller
    private var panel: HUDPanel?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var mouseMonitor: Any?

    init(controller: Controller) { self.controller = controller }

    var isShown: Bool { panel != nil }

    func toggle() { isShown ? close() : show() }

    func show() {
        close()
        guard let config = controller.config else { NSSound.beep(); return }
        let display = controller.activeDisplay()
        let tiled = display.flatMap { controller.visibleDesktop(onDisplay: $0) } != nil
        let screen = NSScreen.with(displayUUID: display) ?? NSScreen.main ?? NSScreen.screens[0]
        let p = HUDPanel(content: ShortcutsView(config: config, tiled: tiled))
        p.onDismiss = { [weak self] in self?.close() }
        p.present(on: screen, at: .center)
        panel = p
        controller.borrowKeys([(0x35, 0)]) { [weak self] _, pressed in if pressed { self?.close() } }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.close() }))
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        controller.releaseKeys()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        p.dismiss()
    }
}

private struct ShortcutsView: View {
    let config: Config
    let tiled: Bool

    private var columns: [[Action.Group]] { [[.general, .focus, .swap], [.resize, .layout]] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tiler Keyboard Shortcuts").font(.title3.weight(.semibold))
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 36) {
                ForEach(columns.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(columns[i], id: \.self) { group in section(group) }
                    }
                    .frame(width: 290, alignment: .leading)
                }
            }
            Text("Drag a tile onto another to swap them · drag an edge to resize · Esc or click to close")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .fixedSize()
    }

    private var status: String {
        if tiled { return "This desktop is tiled." }
        let key = config.hotkeys[.toggleDesktop].map { " Press \($0.symbols) to tile it." } ?? ""
        return "This desktop is not tiled; only the General shortcuts work here.\(key)"
    }

    private func section(_ group: Action.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.rawValue.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Action.allCases.filter { $0.group == group }, id: \.self) { action in
                HStack {
                    Text(action.title).font(.callout)
                    Spacer(minLength: 12)
                    KeyCaps(combo: config.hotkeys[action])
                }
                .opacity(tiled || action.worksOnUntiledDesktop ? 1 : 0.45)
            }
        }
    }
}
