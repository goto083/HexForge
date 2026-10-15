import AppKit

// AppKit bootstrap. Using an explicit NSApplication + NSWindow keeps the app
// deterministic when launched through SwiftPM (`swift run`) as well as from Xcode.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()