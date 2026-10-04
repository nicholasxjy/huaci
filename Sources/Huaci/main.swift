import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar app: no Dock icon even when run outside the bundle.
    app.setActivationPolicy(.accessory)
    app.run()
}
