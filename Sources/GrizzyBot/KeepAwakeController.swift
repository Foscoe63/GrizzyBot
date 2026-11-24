import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion so the Mac doesn't idle-sleep. Releasing it
/// returns control to the system's Energy settings.
@MainActor
enum KeepAwakeController {
    private static var assertionID: IOPMAssertionID = 0
    private static var active = false

    static func set(_ on: Bool) {
        if on, !active {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "GrizzyBot keep awake" as CFString,
                &assertionID
            )
            active = (result == kIOReturnSuccess)
        } else if !on, active {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            active = false
        }
    }
}
