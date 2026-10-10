import CoreGraphics
import TilerCore

/// Identifies one macOS desktop on one display across launches. Space ids are
/// reassigned at login; the Space uuid is not.
struct DesktopKey: Codable, Hashable {
    let displayUUID: String
    let spaceUUID: String
}

/// One tiled desktop: a single Space on a single display. Windows anywhere
/// else are never read, moved or resized.
final class Desktop {
    let key: DesktopKey
    /// Session id of the Space; refreshed from `key.spaceUUID` when Spaces change.
    var spaceID: SpaceID
    let tree = BSPTree()
    /// Tileable windows the user chose to float on this desktop.
    var floating: Set<CGWindowID> = []
    /// Last frame written per window, so unchanged tiles are not rewritten.
    var applied: [CGWindowID: CGRect] = [:]
    /// Frames from the last layout pass.
    var frames: [CGWindowID: CGRect] = [:]
    /// Set when the screen or the gaps changed: rewrite every tile on the next pass.
    var needsLayout = true
    /// The tiled window that last had focus here: new windows split it.
    var lastFocused: CGWindowID?

    init(key: DesktopKey, spaceID: SpaceID) {
        self.key = key
        self.spaceID = spaceID
    }

    func owns(_ id: CGWindowID) -> Bool { tree.contains(id) || floating.contains(id) }
}
