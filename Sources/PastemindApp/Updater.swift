import AppKit
import Sparkle

/// Updates through Sparkle: once a day it reads the appcast (`SUFeedURL` in Info.plist, the latest GitHub release's
/// appcast.xml), and an update is installed only if its EdDSA signature matches `SUPublicEDKey`. Builds without a feed
/// or key, and debug runs (they share the installed app's defaults, where Sparkle keeps its own), never check.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] is String, info["SUPublicEDKey"] is String,
              ProcessInfo.processInfo.environment["PASTEMIND_DEBUG"] == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Whether this build updates at all (the menu's item and the setting show only then).
    var isOn: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// From the menu or Settings: Sparkle's own window, which says when there's nothing new.
    func checkNow() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // A menu bar app: a check made on schedule shows its window without taking the focus from the app in front.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
