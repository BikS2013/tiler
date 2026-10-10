import CoreGraphics

/// The keyboard move/resize mode's arithmetic, kept pure so it is unit-tested.
/// Frames are in top-left-origin screen coordinates (AX), `area` is the usable
/// part of the window's display.
public enum WindowNudge {
    public enum Operation: Equatable {
        /// Move by `step` points.
        case move(Direction)
        /// Right/down grow the window, left/up shrink it; the top-left corner stays.
        case resize(Direction)
        /// Centre in the area, keeping the size.
        case center
        /// Fill the area.
        case maximize
    }

    public static let minimumSize = CGSize(width: 160, height: 100)

    public static func apply(_ op: Operation, to frame: CGRect, in area: CGRect, step: CGFloat) -> CGRect {
        var f = frame
        switch op {
        case .move(let d):
            switch d {
            case .left: f.origin.x -= step
            case .right: f.origin.x += step
            case .up: f.origin.y -= step
            case .down: f.origin.y += step
            }
            f = keepInside(f, area)
        case .resize(let d):
            switch d {
            case .left: f.size.width -= step
            case .right: f.size.width += step
            case .up: f.size.height -= step
            case .down: f.size.height += step
            }
            f.size.width = min(max(f.width, minimumSize.width), area.width)
            f.size.height = min(max(f.height, minimumSize.height), area.height)
            // Growing past the right or bottom edge pushes the window back in.
            f = keepInside(f, area)
        case .center:
            f.size.width = min(f.width, area.width)
            f.size.height = min(f.height, area.height)
            f.origin = CGPoint(x: area.midX - f.width / 2, y: area.midY - f.height / 2)
        case .maximize:
            f = area
        }
        return CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())
    }

    /// Slide the frame so it lies inside the area (top-left wins when it is larger).
    static func keepInside(_ frame: CGRect, _ area: CGRect) -> CGRect {
        var f = frame
        if f.maxX > area.maxX { f.origin.x = area.maxX - f.width }
        if f.maxY > area.maxY { f.origin.y = area.maxY - f.height }
        if f.minX < area.minX { f.origin.x = area.minX }
        if f.minY < area.minY { f.origin.y = area.minY }
        return f
    }
}
