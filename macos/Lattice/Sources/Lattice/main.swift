import AppKit

let application = NSApplication.shared
let delegate = LatticeAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
