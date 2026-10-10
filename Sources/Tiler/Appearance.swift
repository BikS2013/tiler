import AppKit
import SwiftUI
import TilerCore

/// Shared look: the menu bar glyph, key caps, and menu key equivalents.
enum Appearance {
    /// The menu bar glyph: one tall tile and two stacked ones, the layout
    /// Tiler makes. Filled while the desktop being worked on is tiled. A
    /// template image, so macOS tints it for light, dark and tinted menu bars.
    static func statusImage(tiled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            let line: CGFloat = 1.3
            let gap: CGFloat = 1.6
            let outer = NSRect(x: 1, y: 1.5, width: 16, height: 13)
            let left = NSRect(x: outer.minX, y: outer.minY, width: (outer.width - gap) * 0.5, height: outer.height)
            let rightX = left.maxX + gap
            let rightW = outer.maxX - rightX
            let half = (outer.height - gap) / 2
            let top = NSRect(x: rightX, y: outer.minY + half + gap, width: rightW, height: half)
            let bottom = NSRect(x: rightX, y: outer.minY, width: rightW, height: half)
            NSColor.black.set()
            for r in [left, top, bottom] {
                if tiled {
                    NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                } else {
                    let p = NSBezierPath(roundedRect: r.insetBy(dx: line / 2, dy: line / 2), xRadius: 1.6, yRadius: 1.6)
                    p.lineWidth = line
                    p.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = tiled ? "Tiler: desktop tiled" : "Tiler"
        return image
    }

    /// The key equivalent NSMenuItem needs to show `combo` on the right of a
    /// menu item, the way every macOS menu shows its shortcuts.
    static func menuKey(_ combo: KeyCombo) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = []
        if combo.carbonModifiers & KeyCombo.controlKey != 0 { mods.insert(.control) }
        if combo.carbonModifiers & KeyCombo.optionKey != 0 { mods.insert(.option) }
        if combo.carbonModifiers & KeyCombo.shiftKey != 0 { mods.insert(.shift) }
        if combo.carbonModifiers & KeyCombo.cmdKey != 0 { mods.insert(.command) }
        let name = combo.canonicalText.split(separator: "+").last.map(String.init) ?? ""
        func fn(_ code: Int) -> String { String(UnicodeScalar(UInt16(code)).map(Character.init) ?? " ") }
        let key: String
        switch name {
        case "left": key = fn(NSLeftArrowFunctionKey)
        case "right": key = fn(NSRightArrowFunctionKey)
        case "up": key = fn(NSUpArrowFunctionKey)
        case "down": key = fn(NSDownArrowFunctionKey)
        case "return": key = "\r"
        case "tab": key = "\t"
        case "space": key = " "
        case "delete": key = "\u{8}"
        case "escape": key = "\u{1b}"
        default:
            if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...20).contains(n) {
                key = fn(NSF1FunctionKey + n - 1)
            } else {
                key = name
            }
        }
        return (key, mods)
    }
}

extension NSMenuItem {
    /// Show `combo` as this item's shortcut.
    func show(_ combo: KeyCombo?) {
        guard let combo else { keyEquivalent = ""; return }
        let k = Appearance.menuKey(combo)
        keyEquivalent = k.key
        keyEquivalentModifierMask = k.modifiers
    }
}

extension NSScreen {
    static func with(displayUUID uuid: String?) -> NSScreen? {
        guard let uuid else { return nil }
        return screens.first { $0.displayUUID == uuid }
    }
}

/// A shortcut drawn as macOS key caps: one cap per modifier and one for the key.
struct KeyCaps: View {
    let combo: KeyCombo?
    var body: some View {
        if let combo {
            HStack(spacing: 3) {
                ForEach(Array((combo.modifierSymbols.map(String.init) + [combo.keySymbol]).enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, part.count > 1 ? 5 : 0)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(combo.symbols)
        } else {
            Text("Not set").foregroundStyle(.tertiary)
        }
    }
}
