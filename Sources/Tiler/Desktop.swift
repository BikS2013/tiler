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
    /// Tileable windows the user chose to float on this desktop, with the pid
    /// of the app that owns each one. Saved with the desktop, so floating
    /// survives a Tiler restart; the pid lets a restore reject a window id the
    /// window server has since given to another app.
    var floating: [CGWindowID: pid_t] = [:]
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

    func owns(_ id: CGWindowID) -> Bool { tree.contains(id) || floating[id] != nil }
}

/// One desktop in `desktops.json`.
struct SavedDesktop: Codable {
    struct Window: Codable { let id: CGWindowID; let pid: pid_t }
    let displayUUID: String
    let spaceUUID: String
    let floating: [Window]
}
