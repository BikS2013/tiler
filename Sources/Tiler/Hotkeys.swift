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
    private var borrowedRefs: [EventHotKeyRef] = []
    private var onBorrowed: ((Int, Bool) -> Void)?
    private static let borrowedBase: UInt32 = 0x1000
    private static let signature = OSType(0x544C_5252) // "TLRR"

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            if hk.id >= Hotkeys.borrowedBase {
                log.debug("borrowed key \(hk.id - Hotkeys.borrowedBase) pressed=\(pressed)")
                me.onBorrowed?(Int(hk.id - Hotkeys.borrowedBase), pressed)
                return noErr
            }
            guard pressed, Int(hk.id) < Action.allCases.count else { return noErr }
            me.onAction(Action.allCases[Int(hk.id)])
            return noErr
        }, specs.count, &specs, me, &handler)
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

    /// Borrow plain keys system-wide (Esc for the shortcuts overlay; arrows and
    /// letters for the move/resize mode) while a transient UI is up, and give
    /// them back with `release()`. `handler` gets the key's index in `keys` and
    /// whether it was pressed (true) or released (false). One borrower at a time.
    func borrow(_ keys: [(code: UInt32, modifiers: UInt32)], handler: @escaping (Int, Bool) -> Void) {
        release()
        onBorrowed = handler
        for (i, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: Self.borrowedBase + UInt32(i))
            let status = RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                borrowedRefs.append(ref)
            } else {
                log.error("could not borrow key \(key.code) mods \(key.modifiers): \(status)")
            }
        }
    }

    func release() {
        for ref in borrowedRefs { UnregisterEventHotKey(ref) }
        borrowedRefs.removeAll()
        onBorrowed = nil
    }

    private func unregister(where match: (Action) -> Bool) {
        for (action, ref) in refs where match(action) {
            UnregisterEventHotKey(ref)
            refs[action] = nil
        }
    }
}
