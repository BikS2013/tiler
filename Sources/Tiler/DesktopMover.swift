import AppKit
import SwiftUI
import TilerCore

/// Moves the focused window to the previous or next desktop (Space) on its
/// display, and follows it there. Works on any desktop, tiled or not.
///
/// macOS 14.5+ blocks the private "move window to Space" calls, so this does
/// what a person would: it holds the window by its title bar with a synthetic
/// mouse press, sends the Mission Control "Move left/right a space" shortcut
/// (read from the user's own keyboard settings), and lets go on the new
/// desktop. The pointer is put back afterwards. Tiler ignores the synthetic
/// drag, then carries the window's floating state over to the new desktop if
/// that one is tiled; a tiled target simply tiles the new arrival.
final class DesktopMover {
    private let controller: Controller
    private var busy = false
    private var mover: WindowMover?
    private var toast: HUDPanel?

    init(controller: Controller) { self.controller = controller }

    /// `forward` = next desktop (to the right).
    func move(forward: Bool) {
        guard !busy, controller.started, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { NSSound.beep(); return }
        let mover = WindowMover(pid: app.processIdentifier)
        self.mover = mover
        busy = true
        mover.loadFocusedWindow { [weak self] info in
            guard let self else { return }
            mover.stop()
            self.mover = nil
            guard let info, info.standard else {
                self.busy = false
                self.show("Nothing to move", "Focus a normal window first (not a dialog, a panel or a full-screen window).")
                return
            }
            self.start(window: info, pid: app.processIdentifier, forward: forward)
        }
    }

    private func start(window info: WindowMover.Info, pid: pid_t, forward: Bool) {
        let center = CGPoint(x: info.frame.midX, y: info.frame.midY)
        guard let screen = Screen.all().first(where: { $0.bounds.contains(center) }) else { busy = false; NSSound.beep(); return }
        let current = Spaces.current(onDisplay: screen.uuid)
        // The display's Spaces in Mission Control order (separate Spaces off: the one "Main" list).
        let all = Spaces.all()
        let displayID = all.first(where: { $0.id == current })?.displayID
        let order = all.filter { $0.displayID == displayID }.map(\.id)
        guard let index = order.firstIndex(of: current) else { busy = false; NSSound.beep(); return }
        let targetIndex = index + (forward ? 1 : -1)
        guard order.indices.contains(targetIndex) else {
            busy = false
            show(forward ? "No desktop to the right" : "No desktop to the left",
                 "Add one in Mission Control, or move the window the other way.")
            return
        }
        guard let shortcut = MissionControlShortcut.read(forward: forward) else {
            busy = false
            show("Mission Control shortcut is off",
                 "Turn on “Move \(forward ? "right" : "left") a space” in System Settings › Keyboard › Keyboard Shortcuts › Mission Control.")
            return
        }
        let target = order[targetIndex]
        if all.first(where: { $0.id == target })?.number == 0 {
            busy = false
            show("That is a full-screen space", "A window can only be moved to an ordinary desktop.")
            return
        }

        controller.beginDesktopMove(of: info.id)
        let saved = CGEvent(source: nil)?.location ?? info.grabPoint
        let grab = info.grabPoint
        post(.leftMouseDown, at: grab)
        after(0.05) {
            self.post(.leftMouseDragged, at: CGPoint(x: grab.x + 1, y: grab.y))
            self.after(0.1) {
                shortcut.post()
                self.after(0.5) {
                    self.post(.leftMouseUp, at: CGPoint(x: grab.x + 1, y: grab.y))
                    CGWarpMouseCursorPosition(saved)
                    self.after(0.15) {
                        self.busy = false
                        let moved = Spaces.current(onDisplay: screen.uuid) == target
                        self.controller.endDesktopMove(of: info.id, pid: pid, display: screen.uuid,
                                                       to: moved ? target : nil)
                        if moved {
                            focusWindow(pid: pid, wid: info.id)
                        } else {
                            self.show("The window did not move",
                                      "The app may not allow dragging from that spot of its title bar.")
                        }
                    }
                }
            }
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        // The shortcut's modifiers are still held: the mouse events must not carry them.
        e.flags = []
        e.post(tap: .cghidEventTap)
    }

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    /// A short note at the bottom of the active display.
    private func show(_ title: String, _ detail: String) {
        toast?.dismiss()
        let p = HUDPanel(content: ToastView(title: title, detail: detail))
        p.onDismiss = { [weak self, weak p] in p?.dismiss(); if self?.toast === p { self?.toast = nil } }
        p.present(on: NSScreen.with(displayUUID: controller.activeDisplay()) ?? NSScreen.main ?? NSScreen.screens[0], at: .bottom)
        toast = p
        after(2.2) { [weak self, weak p] in
            guard let p else { return }
            p.dismiss()
            if self?.toast === p { self?.toast = nil }
        }
    }
}

/// The user's Mission Control "Move left/right a space" shortcut, from
/// com.apple.symbolichotkeys (ids 79 and 81). Nil when it is turned off.
struct MissionControlShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static func read(forward: Bool) -> MissionControlShortcut? {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[forward ? "81" : "79"] as? [String: Any] else {
            // Never customised: macOS uses its default, Control (+fn) + arrow.
            return MissionControlShortcut(keyCode: forward ? 0x7C : 0x7B, flags: [.maskControl, .maskSecondaryFn])
        }
        guard (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3 else { return nil }
        return MissionControlShortcut(keyCode: CGKeyCode(parameters[1]), flags: CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    func post() {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }
}

private struct ToastView: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.slash").foregroundStyle(.secondary)
                Text(title).font(.headline)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 460, alignment: .leading)
    }
}
