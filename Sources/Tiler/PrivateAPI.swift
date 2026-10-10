// Private SkyLight / HIServices symbols. All of them work with SIP enabled and
// are the same ones yabai, AeroSpace and HyprMac rely on. Checked on macOS 27.

import ApplicationServices
import CoreGraphics

typealias SLSConnectionID = Int32
typealias SpaceID = UInt64

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> SLSConnectionID

/// Display → Spaces dictionary array ("Display Identifier", "Current Space", "Spaces").
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: SLSConnectionID) -> Unmanaged<CFArray>?

/// The Space currently shown on the display with this UUID (or "Main").
@_silgen_name("SLSManagedDisplayGetCurrentSpace")
func SLSManagedDisplayGetCurrentSpace(_ cid: SLSConnectionID, _ displayUUID: CFString) -> SpaceID

/// The Spaces the windows belong to. Mask 0x7 = all Spaces.
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: SLSConnectionID, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

/// CGWindowID behind an AX window element.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// True while the display is animating between Spaces.
@_silgen_name("SLSManagedDisplayIsAnimating")
func SLSManagedDisplayIsAnimating(_ cid: SLSConnectionID, _ displayUUID: CFString) -> Bool

// Focusing another app's window from a background app. Since macOS 14,
// NSRunningApplication.activate() from an inactive app is ignored
// ("cooperative activation"); these are what yabai and AeroSpace use.

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

/// Bring the process to the front with `wid` as its key window.
func focusWindow(pid: pid_t, wid: CGWindowID) {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    let userGenerated: UInt32 = 0x200
    _ = _SLPSSetFrontProcessWithOptions(&psn, wid, userGenerated)
    // Synthetic "make key window" event record (layout from yabai).
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes)
}
