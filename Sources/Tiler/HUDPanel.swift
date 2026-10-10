import AppKit
import SwiftUI

/// A translucent HUD (rounded `.hudWindow` material) with SwiftUI content.
/// It never becomes key or main, so the app underneath keeps the keyboard;
/// a click on it calls `onDismiss`. Used by the shortcuts overlay and the
/// move/resize mode.
final class HUDPanel: NSPanel {
    enum Placement { case center, bottom }

    var onDismiss: (() -> Void)?
    private let host: NSView

    init<Content: View>(content: Content) {
        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        self.host = host
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 18)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onDismiss?() } else { super.sendEvent(event) }
    }

    /// Fade in on `screen`: centred, or near the bottom of its visible area.
    func present(on screen: NSScreen, at placement: Placement) {
        let size = frame.size
        let v = screen.visibleFrame
        let y = placement == .center ? v.midY - size.height / 2 : v.minY + 64
        setFrameOrigin(NSPoint(x: (v.midX - size.width / 2).rounded(), y: y.rounded()))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    /// Keep the panel's size in step with content whose size changes.
    func fitContent() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size != frame.size else { return }
        var f = frame
        f.origin.x += (f.width - size.width) / 2
        f.size = size
        setFrame(f, display: true)
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.orderOut(nil) })
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
