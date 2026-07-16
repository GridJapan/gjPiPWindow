import AppKit

// Top-level code in SwiftPM isn't MainActor-isolated, but all of AppKit is.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    // NSApplication.delegate is weak; this local owns it for the run loop's life.
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
