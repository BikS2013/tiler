import CoreGraphics

public typealias WindowID = UInt32

/// How a split divides its rectangle.
public enum Orientation: Equatable {
    /// Children side by side (the divider is vertical).
    case horizontal
    /// Children stacked top and bottom (the divider is horizontal).
    case vertical

    var flipped: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: String, CaseIterable {
    case left, right, up, down

    var axis: Orientation { (self == .left || self == .right) ? .horizontal : .vertical }
    /// True when the direction points towards larger coordinates (right, down
    /// in the top-left-origin space AX and CoreGraphics use).
    var isForward: Bool { self == .right || self == .down }
}

/// A node of the dwindle tree: a leaf holds one window, a split holds two children.
public final class BSPNode {
    public fileprivate(set) var window: WindowID?
    public fileprivate(set) var orientation: Orientation = .horizontal
    /// Share of the split's length given to `first`, in 0.1...0.9.
    public fileprivate(set) var ratio: Double = 0.5
    public fileprivate(set) var first: BSPNode?
    public fileprivate(set) var second: BSPNode?
    public fileprivate(set) weak var parent: BSPNode?
    /// The rectangle this node occupied in the last `layout` pass.
    public fileprivate(set) var frame: CGRect = .zero

    init(window: WindowID) { self.window = window }

    var isLeaf: Bool { window != nil }

    func leaves(into result: inout [BSPNode]) {
        if isLeaf { result.append(self); return }
        first?.leaves(into: &result)
        second?.leaves(into: &result)
    }
}

/// Binary space partition tree with dwindle insertion, the layout HyprMac and
/// Hyprland use by default. Pure: knows nothing about AX or screens.
public final class BSPTree {
    public static let minRatio = 0.1
    public static let maxRatio = 0.9

    public private(set) var root: BSPNode?
    private var leafByWindow: [WindowID: BSPNode] = [:]

    public init() {}

    public var isEmpty: Bool { root == nil }
    public var count: Int { leafByWindow.count }
    public func contains(_ window: WindowID) -> Bool { leafByWindow[window] != nil }

    /// Windows in tree order (left/top first).
    public var windows: [WindowID] {
        var result: [BSPNode] = []
        root?.leaves(into: &result)
        return result.compactMap(\.window)
    }

    /// Insert `window` by splitting the leaf of `target` (or the last leaf when
    /// `target` is absent from the tree). The split runs along the longer side
    /// of that leaf's last frame and the new window takes the second half.
    public func insert(_ window: WindowID, splitting target: WindowID?) {
        guard leafByWindow[window] == nil else { return }
        let newLeaf = BSPNode(window: window)
        leafByWindow[window] = newLeaf
        guard let root else { self.root = newLeaf; return }

        let host: BSPNode
        if let target, let leaf = leafByWindow[target] {
            host = leaf
        } else {
            var all: [BSPNode] = []
            root.leaves(into: &all)
            host = all.last!
        }
        // The host leaf becomes a split; its window moves into a fresh first child.
        let old = BSPNode(window: host.window!)
        leafByWindow[old.window!] = old
        host.window = nil
        host.orientation = host.frame.height > host.frame.width ? .vertical : .horizontal
        host.ratio = 0.5
        host.first = old
        host.second = newLeaf
        old.parent = host
        newLeaf.parent = host
        old.frame = host.frame
    }

    /// Remove `window`; its sibling takes the parent's place.
    public func remove(_ window: WindowID) {
        guard let leaf = leafByWindow.removeValue(forKey: window) else { return }
        guard let parent = leaf.parent else { root = nil; return }
        let sibling = parent.first === leaf ? parent.second! : parent.first!
        replace(parent, with: sibling)
    }

    private func replace(_ node: BSPNode, with replacement: BSPNode) {
        replacement.parent = node.parent
        replacement.frame = node.frame
        if let grand = node.parent {
            if grand.first === node { grand.first = replacement } else { grand.second = replacement }
        } else {
            root = replacement
        }
    }

    public func swap(_ a: WindowID, _ b: WindowID) {
        guard let la = leafByWindow[a], let lb = leafByWindow[b], a != b else { return }
        la.window = b
        lb.window = a
        leafByWindow[a] = lb
        leafByWindow[b] = la
    }

    /// Flip the orientation of the split that directly holds `window`.
    public func toggleOrientation(of window: WindowID) {
        guard let parent = leafByWindow[window]?.parent else { return }
        parent.orientation = parent.orientation.flipped
    }

    /// Mirror the whole tree left to right; each side keeps its width.
    public func mirrorHorizontally() {
        func visit(_ node: BSPNode?) {
            guard let node, !node.isLeaf else { return }
            if node.orientation == .horizontal {
                Swift.swap(&node.first, &node.second)
                node.ratio = 1 - node.ratio
            }
            visit(node.first)
            visit(node.second)
        }
        visit(root)
    }

    /// Reset every split to 50/50.
    public func equalize() {
        func visit(_ node: BSPNode?) {
            guard let node, !node.isLeaf else { return }
            node.ratio = 0.5
            visit(node.first)
            visit(node.second)
        }
        visit(root)
    }

    /// Move the divider next to `window` in `direction` by `step` (a share of
    /// the split's length). The divider on the `direction` side of the window
    /// is preferred; when the window touches the screen edge on that side the
    /// opposite divider moves instead. Returns false when no divider exists.
    @discardableResult
    public func moveDivider(of window: WindowID, _ direction: Direction, step: Double) -> Bool {
        guard let leaf = leafByWindow[window] else { return false }
        // Divider on the direction side: an ancestor split along the axis where
        // the window sits on the near side (first child for right/down).
        let split = ancestor(of: leaf, axis: direction.axis, inFirst: direction.isForward)
            ?? ancestor(of: leaf, axis: direction.axis, inFirst: !direction.isForward)
        guard let split else { return false }
        let delta = direction.isForward ? step : -step
        split.ratio = clampRatio(split.ratio + delta)
        return true
    }

    private func ancestor(of leaf: BSPNode, axis: Orientation, inFirst: Bool) -> BSPNode? {
        var child = leaf
        while let p = child.parent {
            if p.orientation == axis && (p.first === child) == inFirst { return p }
            child = p
        }
        return nil
    }

    /// After the user dragged an edge of `window` to `newFrame`, set the
    /// ratios of the splits behind each moved edge so the tiles follow it.
    /// `gap` must be the inner gap used by `layout`. Returns true when any
    /// ratio changed.
    @discardableResult
    public func adoptResize(of window: WindowID, to newFrame: CGRect, gap: Double,
                            tolerance: Double = 2) -> Bool {
        guard let leaf = leafByWindow[window] else { return false }
        let old = leaf.frame
        var changed = false
        let half = gap / 2

        func apply(axis: Orientation, inFirst: Bool, divider: Double) {
            guard let split = ancestor(of: leaf, axis: axis, inFirst: inFirst) else { return }
            let f = split.frame
            let start = axis == .horizontal ? Double(f.minX) : Double(f.minY)
            let length = axis == .horizontal ? Double(f.width) : Double(f.height)
            guard length > 0 else { return }
            split.ratio = clampRatio((divider - start) / length)
            changed = true
        }

        if abs(newFrame.maxX - old.maxX) > tolerance {
            apply(axis: .horizontal, inFirst: true, divider: Double(newFrame.maxX) + half)
        }
        if abs(newFrame.minX - old.minX) > tolerance {
            apply(axis: .horizontal, inFirst: false, divider: Double(newFrame.minX) - half)
        }
        if abs(newFrame.maxY - old.maxY) > tolerance {
            apply(axis: .vertical, inFirst: true, divider: Double(newFrame.maxY) + half)
        }
        if abs(newFrame.minY - old.minY) > tolerance {
            apply(axis: .vertical, inFirst: false, divider: Double(newFrame.minY) - half)
        }
        return changed
    }

    private func clampRatio(_ r: Double) -> Double { min(Self.maxRatio, max(Self.minRatio, r)) }

    /// Compute every window's frame inside `rect` with `gap` points between
    /// neighbouring tiles. Records each node's frame for later edits.
    public func layout(in rect: CGRect, gap: Double) -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]
        func visit(_ node: BSPNode, _ r: CGRect) {
            node.frame = r
            if let w = node.window { result[w] = r.pixelAligned; return }
            let half = CGFloat(gap / 2)
            let ratio = CGFloat(node.ratio)
            switch node.orientation {
            case .horizontal:
                let divider = r.minX + r.width * ratio
                visit(node.first!, CGRect(x: r.minX, y: r.minY, width: divider - half - r.minX, height: r.height))
                visit(node.second!, CGRect(x: divider + half, y: r.minY, width: r.maxX - divider - half, height: r.height))
            case .vertical:
                let divider = r.minY + r.height * ratio
                visit(node.first!, CGRect(x: r.minX, y: r.minY, width: r.width, height: divider - half - r.minY))
                visit(node.second!, CGRect(x: r.minX, y: divider + half, width: r.width, height: r.maxY - divider - half))
            }
        }
        if let root { visit(root, rect) }
        return result
    }

    /// Frame of `window` from the last layout pass.
    public func frame(of window: WindowID) -> CGRect? { leafByWindow[window]?.frame }
}

extension CGRect {
    /// Edges rounded to whole points, so neighbouring tiles never overlap.
    var pixelAligned: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        return CGRect(x: x0, y: y0, width: maxX.rounded() - x0, height: maxY.rounded() - y0)
    }
}
