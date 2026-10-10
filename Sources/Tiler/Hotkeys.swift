import Carbon
import TilerCore

/// Global hotkeys through Carbon `RegisterEventHotKey`: no event tap, no Input
/// Monitoring permission, and the system only delivers the exact combinations
/// registered, so other keystrokes are never delayed.
final class Hotkeys {
    private var refs: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var bindings: [Action: KeyCombo] = [:]
    private let onAction: (Action) -> Void
    private var escapeRef: EventHotKeyRef?
    private var onEscape: (() -> Void)?
    private static let escapeID: UInt32 = 0xE5C
    private static let signature = OSType(0x544C_5252) // "TLRR"

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            if hk.id == Hotkeys.escapeID { me.onEscape?(); return noErr }
            guard Int(hk.id) < Action.allCases.count else { return OSStatus(eventNotHandledErr) }
            me.onAction(Action.allCases[Int(hk.id)])
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Replace the bindings; everything is unregistered until `activate` runs.
    func configure(_ bindings: [Action: KeyCombo]) {
        unregister { _ in true }
        self.bindings = bindings
    }

    /// Register the tiling hotkeys only while a tiled desktop has focus, so
    /// the same keys keep working inside apps on every other desktop. The
    /// toggle key stays registered everywhere.
    func activate(tilingKeys: Bool) {
        for (action, combo) in bindings where refs[action] == nil && (tilingKeys || action.worksOnUntiledDesktop) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature,
                                   id: UInt32(Action.allCases.firstIndex(of: action)!))
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
                log.debug("registered \(combo.text, privacy: .public)")
            } else {
                log.error("could not register hotkey \(combo.text) for \(action.rawValue): \(status)")
            }
        }
        if !tilingKeys { unregister { !$0.worksOnUntiledDesktop } }
    }

    /// Take the Esc key system-wide while `handler` is set (the shortcuts
    /// overlay is up), and give it back when it is cleared.
    func captureEscape(_ handler: (() -> Void)?) {
        onEscape = handler
        if handler != nil, escapeRef == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: Self.escapeID)
            if RegisterEventHotKey(0x35, 0, id, GetApplicationEventTarget(), 0, &ref) == noErr { escapeRef = ref }
        } else if handler == nil, let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
        }
    }

    private func unregister(where match: (Action) -> Bool) {
        for (action, ref) in refs where match(action) {
            UnregisterEventHotKey(ref)
            refs[action] = nil
        }
    }
}
