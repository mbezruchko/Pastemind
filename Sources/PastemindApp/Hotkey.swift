import AppKit
import Carbon.HIToolbox

/// A key combination like "cmd+space" or "cmd+lshift+c", as written in defaults. Modifiers are cmd, shift, opt, ctrl
/// (either side), or lcmd, rshift, lopt… for one side only.
nonisolated struct KeyCombo: Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// Device-dependent modifier bits (NX_DEVICE…KEYMASK) that must be down: a left or right key only. Zero when either
    /// side will do.
    let sides: UInt64
    /// How it's saved: "cmd+lshift+c".
    let spec: String
    /// The keycaps, in order: ["⌘", "Left ⇧", "C"].
    let caps: [String]

    var display: String { caps.joined(separator: " ") }
    var isSided: Bool { sides != 0 }

    /// One side of a modifier: its name in a spec, the generic modifier, its device bit and its keycap.
    private struct Side {
        let name: String
        let generic: Int
        let bit: UInt64
        let cap: String
    }

    private static let sideKeys: [Side] = [
        Side(name: "lctrl", generic: controlKey, bit: 0x0000_0001, cap: "Left ⌃"),
        Side(name: "rctrl", generic: controlKey, bit: 0x0000_2000, cap: "Right ⌃"),
        Side(name: "lopt", generic: optionKey, bit: 0x0000_0020, cap: "Left ⌥"),
        Side(name: "ropt", generic: optionKey, bit: 0x0000_0040, cap: "Right ⌥"),
        Side(name: "lshift", generic: shiftKey, bit: 0x0000_0002, cap: "Left ⇧"),
        Side(name: "rshift", generic: shiftKey, bit: 0x0000_0004, cap: "Right ⇧"),
        Side(name: "lcmd", generic: cmdKey, bit: 0x0000_0008, cap: "Left ⌘"),
        Side(name: "rcmd", generic: cmdKey, bit: 0x0000_0010, cap: "Right ⌘"),
    ]
    private static let genericKeys: [(name: String, modifier: Int, cap: String)] = [
        ("ctrl", controlKey, "⌃"), ("opt", optionKey, "⌥"), ("shift", shiftKey, "⇧"), ("cmd", cmdKey, "⌘"),
    ]

    private static let keys: [String: (code: Int, name: String)] = {
        var keys: [String: (Int, String)] = [
            "space": (kVK_Space, "Space"), "return": (kVK_Return, "↩"), "tab": (kVK_Tab, "⇥"),
            "slash": (kVK_ANSI_Slash, "/"), "period": (kVK_ANSI_Period, "."), "comma": (kVK_ANSI_Comma, ","),
            "semicolon": (kVK_ANSI_Semicolon, ";"), "quote": (kVK_ANSI_Quote, "'"),
            "backslash": (kVK_ANSI_Backslash, "\\"), "grave": (kVK_ANSI_Grave, "`"), "minus": (kVK_ANSI_Minus, "-"),
            "equal": (kVK_ANSI_Equal, "="), "leftbracket": (kVK_ANSI_LeftBracket, "["),
            "rightbracket": (kVK_ANSI_RightBracket, "]"),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
        ]
        for (letter, code) in letters { keys[letter] = (code, letter.uppercased()) }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { keys["f\(index + 1)"] = (code, "F\(index + 1)") }
        return keys
    }()

    /// Key code → its name in a spec and on a keycap.
    private static let names: [Int: (spec: String, cap: String)] = {
        var names: [Int: (String, String)] = [:]
        for (spec, key) in keys where names[key.code] == nil { names[key.code] = (spec, key.name) }
        return names
    }()

    /// Parses "cmd+space", "opt+cmd+v", "cmd+lshift+c"…
    init?(_ text: String) {
        var modifiers = 0
        var sides: UInt64 = 0
        var key: Int?
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }) {
            let word = String(part)
            if let side = Self.sideKeys.first(where: { $0.name == word }) {
                modifiers |= side.generic
                sides |= side.bit
            } else if let generic = Self.genericKeys.first(where: { $0.name == word })
                        ?? Self.aliases[word].flatMap({ alias in Self.genericKeys.first { $0.name == alias } }) {
                modifiers |= generic.modifier
            } else if key == nil, let found = Self.keys[word] {
                key = found.code
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self.init(code: key, modifiers: modifiers, sides: sides)
    }

    private static let aliases = ["command": "cmd", "⌘": "cmd", "⇧": "shift", "option": "opt", "alt": "opt",
                                  "⌥": "opt", "control": "ctrl", "⌃": "ctrl"]

    /// From a key press in the shortcut recorder: with `sided`, only the sides of the modifiers that were held.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, sided: Bool) {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        var sides: UInt64 = 0
        if sided {
            for side in Self.sideKeys where UInt64(flags.rawValue) & side.bit != 0 && modifiers & side.generic != 0 {
                sides |= side.bit
            }
        }
        self.init(code: Int(keyCode), modifiers: modifiers, sides: sides)
    }

    private init?(code: Int, modifiers: Int, sides: UInt64) {
        guard let name = Self.names[code] else { return nil }
        let isFunctionKey = name.cap.count > 1 && name.cap.hasPrefix("F") && name.cap != "Space"
        guard modifiers & (cmdKey | optionKey | controlKey) != 0 || isFunctionKey else { return nil }
        keyCode = UInt32(code)
        carbonModifiers = UInt32(modifiers)
        self.sides = sides
        var caps: [String] = [], parts: [String] = []
        for generic in Self.genericKeys where modifiers & generic.modifier != 0 {
            let chosen = Self.sideKeys.filter { $0.generic == generic.modifier && sides & $0.bit != 0 }
            if chosen.count == 1 {
                caps.append(chosen[0].cap)
                parts.append(chosen[0].name)
            } else {
                caps.append(generic.cap)
                parts.append(generic.name)
            }
        }
        self.caps = caps + [name.cap]
        spec = (parts + [name.spec]).joined(separator: "+")
    }

    /// The same keys, either side of each modifier.
    var unsided: KeyCombo {
        KeyCombo(code: Int(keyCode), modifiers: Int(carbonModifiers), sides: 0) ?? self
    }

    /// A key event (from the event tap) is this combination: the same key, the same modifiers, the right sides.
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == Int64(self.keyCode) else { return false }
        var modifiers = 0
        if flags.contains(.maskCommand) { modifiers |= cmdKey }
        if flags.contains(.maskShift) { modifiers |= shiftKey }
        if flags.contains(.maskAlternate) { modifiers |= optionKey }
        if flags.contains(.maskControl) { modifiers |= controlKey }
        return modifiers == Int(carbonModifiers) && flags.rawValue & sides == sides
    }

    /// The combo as an NSMenuItem key equivalent, so the menu shows it (without the side: menus can't).
    var menuEquivalent: (String, NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        let name = caps.last ?? ""
        return (name == "Space" ? " " : name.count == 1 ? name.lowercased() : "", flags)
    }
}

/// Pastemind's hotkeys: one opens the clipboard history, the other search. A combination for one side of a modifier
/// (Left ⇧) goes through an event tap, which needs Accessibility access and lets the other side through to the app in
/// front; without that access it falls back to both sides. The rest are Carbon hotkeys, which need nothing.
final class HotkeyCenter {
    enum Action: String, CaseIterable {
        case clipboard, search
    }

    /// The Carbon registrations, by their id in `CarbonHotkeys`.
    private var carbon: [Action: UInt32] = [:]
    private let tap = SidedKeyTap()
    private(set) var combos: [Action: KeyCombo] = [:]
    /// Why a hotkey doesn't work as set, for Settings and the menu.
    private(set) var problems: [Action: String] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var isSuspended = false
    private var retryTimer: Timer?
    var onChange: () -> Void = {}

    func handle(_ action: Action, with handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// Registers `combos`, replacing what's there.
    func apply(_ combos: [Action: KeyCombo]) {
        self.combos = combos
        guard !isSuspended else { return }
        register()
    }

    /// While the shortcut recorder listens: nothing registered, so pressing the current combination reaches it.
    func suspend() {
        isSuspended = true
        unregisterCarbon()
        tap.bindings = []
        tap.stop()
    }

    func resume() {
        isSuspended = false
        register()
    }

    private func unregisterCarbon() {
        for id in carbon.values { CarbonHotkeys.shared.unregister(id) }
        carbon.removeAll()
    }

    private func register() {
        unregisterCarbon()
        problems.removeAll()
        var sided: [(KeyCombo, () -> Void)] = []
        var waitingForAccess = false
        for action in Action.allCases {
            guard let combo = combos[action] else { continue }
            let fire: () -> Void = { [weak self] in self?.handlers[action]?() }
            if combo.isSided, tap.start() {
                sided.append((combo, fire))
            } else {
                if combo.isSided {
                    waitingForAccess = true
                    problems[action] = "\(combo.display) needs Accessibility access to tell left from right; until "
                        + "then either side works."
                }
                let plain = combo.unsided
                if let id = CarbonHotkeys.shared.register(plain, fire) {
                    carbon[action] = id
                } else {
                    problems[action] = "\(plain.display) is taken by another app."
                }
            }
        }
        tap.bindings = sided
        if sided.isEmpty { tap.stop() }
        // Accessibility access comes later (the first paste asks for it): pick it up when it does.
        retryTimer?.invalidate()
        retryTimer = nil
        if waitingForAccess {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted(), !self.isSuspended else { return }
                    self.register()
                }
            }
        }
        onChange()
    }

    /// Registered again on request (the menu opening): what another app held may be free now.
    func recheck() {
        guard !isSuspended else { return }
        register()
    }
}

/// Key presses for one-sided combinations, from a session event tap: the matching one is swallowed and acted on, every
/// other key passes untouched. Lives on the main run loop.
final class SidedKeyTap {
    var bindings: [(KeyCombo, () -> Void)] = []
    nonisolated(unsafe) fileprivate var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// True when the tap is running (macOS allows it only with Accessibility access).
    func start() -> Bool {
        if port != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                           callback: sidedKeyTapCallback, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        (port, source) = (nil, nil)
    }

    fileprivate func action(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> (() -> Void)? {
        guard let action = bindings.first(where: { $0.0.matches(keyCode: keyCode, flags: flags) })?.1 else { return nil }
        // Holding the combination: swallowed too, but acted on once.
        return isRepeat ? {} : action
    }
}

/// Runs on the main run loop (where the tap's source is). macOS turns a slow tap off: it's turned back on.
private nonisolated func sidedKeyTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                             _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let address = UInt(bitPattern: userInfo)
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let swallow = MainActor.assumeIsolated { () -> Bool in
        let tap = Unmanaged<SidedKeyTap>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type == .keyDown, let action = tap.action(keyCode: keyCode, flags: flags, isRepeat: isRepeat) else {
            return false
        }
        DispatchQueue.main.async { action() }
        return true
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// System-wide hotkeys through Carbon's `RegisterEventHotKey`, which needs no Accessibility access. One event handler
/// serves them all: installed with the first, it looks each press up by the id it was registered with.
final class CarbonHotkeys {
    static let shared = CarbonHotkeys()

    private struct Registered {
        let reference: EventHotKeyRef
        let action: () -> Void
    }

    private var registered: [UInt32: Registered] = [:]
    nonisolated(unsafe) private var handler: EventHandlerRef?
    private var lastID: UInt32 = 0
    /// Our presses' signature ("PMND"): another handler's hotkeys aren't ours to act on.
    nonisolated fileprivate static let signature: OSType = 0x504D_4E44

    /// The id to unregister it by; nil when macOS refuses the combination (another app holds it).
    func register(_ combo: KeyCombo, _ action: @escaping () -> Void) -> UInt32? {
        guard installHandler() else { return nil }
        lastID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: lastID),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return nil }
        registered[lastID] = Registered(reference: reference, action: action)
        return lastID
    }

    func unregister(_ id: UInt32) {
        guard let hotkey = registered.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(hotkey.reference)
    }

    /// A press of one of ours: acted on (true), or not ours (false).
    fileprivate func pressed(_ id: UInt32) -> Bool {
        guard let hotkey = registered[id] else { return false }
        hotkey.action()
        return true
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var pressedKind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyPressed, 1, &pressedKind, nil, &handler)
            == noErr
    }
}

/// Carbon calls this on the main thread for every hotkey press the app gets.
private nonisolated func carbonHotkeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                             _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var key = EventHotKeyID()
    guard let event,
          GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                            MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
          key.signature == CarbonHotkeys.signature else { return OSStatus(eventNotHandledErr) }
    let handled = MainActor.assumeIsolated { CarbonHotkeys.shared.pressed(key.id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
