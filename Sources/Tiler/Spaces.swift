import AppKit

/// One physical display, in the top-left-origin global coordinates AX and
/// CoreGraphics use.
struct Screen {
    let uuid: String
    let name: String
    /// Whole display.
    let bounds: CGRect
    /// Display minus menu bar and Dock.
    let usable: CGRect

    static func all() -> [Screen] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        func flip(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        return NSScreen.screens.compactMap { s in
            guard let uuid = s.displayUUID else { return nil }
            return Screen(uuid: uuid, name: s.localizedName, bounds: flip(s.frame), usable: flip(s.visibleFrame))
        }
    }
}

extension NSScreen {
    /// The UUID the window server uses for this display.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Read-only view of native macOS Spaces. Every call is a cheap local
/// window-server query (tens of microseconds), so nothing is cached.
enum Spaces {
    static let connection = SLSMainConnectionID()

    /// The Space showing on the display. With "Displays have separate Spaces"
    /// off every display shows the single "Main" Space.
    static func current(onDisplay uuid: String) -> SpaceID {
        let id = SLSManagedDisplayGetCurrentSpace(connection, uuid as CFString)
        return id != 0 ? id : SLSManagedDisplayGetCurrentSpace(connection, "Main" as CFString)
    }

    static func isAnimating(display uuid: String) -> Bool {
        SLSManagedDisplayIsAnimating(connection, uuid as CFString)
    }

    /// Every Space the window is on (usually one; "all desktops" windows have many).
    static func of(window: CGWindowID) -> [SpaceID] {
        let ids = [NSNumber(value: window)] as CFArray
        guard let result = SLSCopySpacesForWindows(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return result.map(\.uint64Value)
    }

    struct Info {
        let id: SpaceID
        let uuid: String
        /// 1-based position among the display's ordinary desktops (0 for fullscreen Spaces).
        let number: Int
        let displayID: String
    }

    /// Every Space on every display. One heavier call (~1-15 ms); used only
    /// when a desktop is turned on, at launch and when Spaces are rearranged.
    static func all() -> [Info] {
        guard let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result: [Info] = []
        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? "Main"
            var number = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
                        ?? (space["id64"] as? NSNumber)?.uint64Value else { continue }
                let isDesktop = (space["type"] as? Int ?? 0) == 0
                if isDesktop { number += 1 }
                result.append(Info(id: id, uuid: space["uuid"] as? String ?? "", number: isDesktop ? number : 0,
                                   displayID: displayID))
            }
        }
        return result
    }
}
