import Foundation

/// Set GJPIP_DEBUG=1 to trace capture and input forwarding.
///
/// Worth keeping around: a screenshot can't verify this app from the outside
/// (the inspecting tool would need Screen Recording itself), and interaction
/// mode swallows the mouse, so logging is the practical way to see what it did.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["GJPIP_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("gjPiP: \(message())")
    }
}
