import AppKit

// A menu bar app (LSUIElement): no Dock icon, no menu bar (a main menu only for its Edit keys), floating panels.
let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory)
if let appearance = ProcessInfo.processInfo.environment["PASTEMIND_APPEARANCE"] {   // debug captures in either look
    application.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
}
application.run()
