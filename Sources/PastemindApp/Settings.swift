import AppKit
import PastemindKit

/// Preferences, in UserDefaults (`defaults write app.pastemind.Pastemind <key> <value>`).
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static let defaultHotkeys: [HotkeyCenter.Action: String] = [.clipboard: "cmd+lshift+c", .search: "cmd+space"]

    /// "cmd+lshift+c", "cmd+space", "ctrl+opt+v"… (modifiers: cmd, shift, opt, ctrl, or lcmd, rshift… for one side).
    static func hotkey(_ action: HotkeyCenter.Action) -> KeyCombo {
        let key = "\(action.rawValue)Hotkey"
        return defaults.string(forKey: key).flatMap(KeyCombo.init) ?? KeyCombo(defaultHotkeys[action]!)!
    }

    static func setHotkey(_ combo: KeyCombo?, for action: HotkeyCenter.Action) {
        let key = "\(action.rawValue)Hotkey"
        if let combo { defaults.set(combo.spec, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    static var historyDaysChoice: Int {
        get { historyDays }
        set { defaults.set(newValue, forKey: "historyDays") }
    }

    static var pasteRichChoice: Bool {
        get { pasteRich }
        set { defaults.set(newValue, forKey: "pasteRich") }
    }

    /// A copy that starts as the one just before it did, a little longer or shorter (the selection redone), takes its
    /// place (`RedoneCopy`).
    static var mergesRedoneCopies: Bool {
        get { defaults.object(forKey: "mergesRedoneCopies") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mergesRedoneCopies") }
    }

    /// Search finds files by what's in them (`FileIndexer`): nil until it's been offered and answered.
    static var searchFileContents: Bool? {
        get { defaults.object(forKey: searchFileContentsKey) as? Bool }
        set { defaults.set(newValue, forKey: searchFileContentsKey) }
    }

    nonisolated static let searchFileContentsKey = "searchFileContents"

    /// The welcome window's been shown (a new install opens with it).
    static var welcomed: Bool {
        get { defaults.bool(forKey: "welcomed") }
        set { defaults.set(newValue, forKey: "welcomed") }
    }

    /// Reading files paused from the menu.
    static var filesPaused: Bool {
        get { defaults.bool(forKey: filesPausedKey) }
        set { defaults.set(newValue, forKey: filesPausedKey) }
    }

    nonisolated static let filesPausedKey = "filesPaused"

    /// The icon in the menu bar. Without it, opening Pastemind again (or ⌘, in a panel) brings up Settings.
    static var showMenuBarIcon: Bool {
        get { defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }


    /// Copied files are kept (`KeptFiles`) when they take up to this many megabytes in all; 0 keeps none.
    static var keptFilesMegabytes: Int {
        get {
            guard defaults.object(forKey: "keptFilesMegabytes") != nil else { return KeptFiles.defaultMaxBytes >> 20 }
            return max(defaults.integer(forKey: "keptFilesMegabytes"), 0)
        }
        set { defaults.set(newValue, forKey: "keptFilesMegabytes") }
    }

    /// Unpinned clips older than this many days go.
    static var historyDays: Int {
        let days = defaults.integer(forKey: "historyDays")
        return days > 0 ? days : 90
    }

    /// And beyond this many clips, the oldest unpinned ones go.
    static var maxClips: Int {
        let count = defaults.integer(forKey: "maxClips")
        return count > 0 ? count : 10_000
    }

    /// Where the panels open once one has been dragged: the middle of the field's top edge, as fractions of the
    /// screen's visible area.
    static var panelAnchor: CGPoint? {
        get {
            guard let values = defaults.array(forKey: "panelAnchor") as? [Double], values.count == 2 else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
        set {
            if let point = newValue { defaults.set([point.x, point.y], forKey: "panelAnchor") }
            else { defaults.removeObject(forKey: "panelAnchor") }
        }
    }

    static var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }

    /// The preview shows the text read from a picture under it (search finds it either way); off unless turned on.
    /// Read by the preview through @AppStorage, under this key.
    static let showsPictureTextKey = "showsPictureText"
    static var showsPictureText: Bool {
        get { defaults.bool(forKey: showsPictureTextKey) }
        set { defaults.set(newValue, forKey: showsPictureTextKey) }
    }

    /// Code coloured by its language (guessed from the text) in the preview and Quick Look.
    static let highlightsCodeKey = "highlightsCode"
    static var highlightsCode: Bool {
        get { defaults.object(forKey: highlightsCodeKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: highlightsCodeKey) }
    }

    /// The colour of the lists' selection; the lists on screen redraw with it when it changes.
    static var selectionTint: SelectionTint {
        get { defaults.string(forKey: "selectionTint").flatMap(SelectionTint.init(rawValue:)) ?? .accent }
        set {
            defaults.set(newValue.rawValue, forKey: "selectionTint")
            NotificationCenter.default.post(name: SelectionTint.changed, object: nil)
        }
    }

    /// Paste keeps formatting (RTF/HTML) when the clip has it; ⇧↩ always pastes plain text.
    static var pasteRich: Bool { defaults.object(forKey: "pasteRich") as? Bool ?? true }

    /// Apps whose copies are never recorded: password managers, plus `ignoredApps` (bundle identifiers).
    static var ignoredApps: Set<String> {
        Set(defaults.stringArray(forKey: "ignoredApps") ?? []).union([
            "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
            "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass",
            "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "com.sinew.Enpass-Desktop", "in.sinew.Enpass-Desktop",
        ])
    }
}

/// The colours the lists' selection can take: macOS's accent colours (as System Settings › Appearance offers them),
/// or whichever one is chosen there.
enum SelectionTint: String, CaseIterable, Identifiable {
    case accent, blue, purple, pink, red, orange, yellow, green, graphite

    static let changed = Notification.Name("app.pastemind.selectionTint")

    var id: Self { self }

    var name: String { self == .accent ? "System accent color" : rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .accent: .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .graphite: .systemGray
        }
    }
}
