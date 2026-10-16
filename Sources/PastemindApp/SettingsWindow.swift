import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window, drawn like the panels: glass in one rounded shape, the field row's geometry on top, a footer
/// below. Otherwise a plain window: it activates the app, stays until closed (✕, Esc, ⌘W), and moves by its top row.
final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    private unowned let app: AppController

    init(app: AppController) {
        self.app = app
    }

    var windowNumber: Int? { window?.windowNumber }

    /// A note under Clear history for a moment, as clearing shows (debug runs: the window's height changing).
    func flash(_ note: String) {
        model?.flash(note)
    }

    /// The window and its content's frames, for debug runs.
    var frames: String {
        guard let window else { return "no window" }
        let views = (window.contentView?.subviews ?? []).map { "\(type(of: $0)) \($0.frame)" }.joined(separator: "; ")
        return "window \(window.frame), views \(views), screen \(window.screen?.visibleFrame ?? .zero)"
    }

    func show() {
        let window = self.window ?? make()
        self.window = window
        app.hotkeys.recheck()   // a conflict may have been resolved in System Settings meanwhile
        model?.refresh()   // and the history's grown (the counts to clear)
        model?.maxHeight = SettingsWindow.maxHeight(on: window.screen)
        if DebugHooks.enabled {   // debug runs: on the Space in front, without taking it over (and stealing the focus)
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.orderFrontRegardless()
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        PanelChrome.refreshShadow(of: window)
    }

    private func make() -> NSWindow {
        let window = SettingsWindow()
        let model = SettingsModel(app: app)
        model.maxHeight = SettingsWindow.maxHeight(on: NSScreen.main)
        self.model = model
        let view = SettingsView(model: model, onClose: { [weak window] in window?.close() },
                                onHeight: { [weak window] height in window?.fit(height: height) })
        let hosting = NSHostingView(rootView: view)
        let height = hosting.fittingSize.height
        // Then its height is set by `fit` alone: the hosting view's constraints resized the window too, as content
        // grew (from the bottom, the top going under the menu bar, `fit` then finding the height right already).
        hosting.sizingOptions = []
        window.contentView = PanelChrome.container(containing: hosting, frosted: true)
        window.fit(height: height)
        window.center()
        return window
    }
}

private final class SettingsWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 500),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Pastemind Settings"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Room kept above and below it on the screen.
    static let margin: CGFloat = 10

    /// How tall it may be on that screen (past that, its middle scrolls).
    static func maxHeight(on screen: NSScreen?) -> CGFloat {
        ((screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 2 * margin
    }

    /// As tall as its content, the top staying where it is, and on the screen.
    func fit(height: CGFloat) {
        guard height > 0, abs(frame.height - height) > 0.5 else { return }
        var frame = self.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = max(min(frame.origin.y, visible.maxY - height), visible.minY + Self.margin)
        }
        setFrame(frame, display: true)
        PanelChrome.refreshShadow(of: self)
    }

    /// Esc closes it, as it closes the panels (while a shortcut is being recorded, Esc cancels that first).
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@Observable
final class SettingsModel {
    @ObservationIgnored unowned let app: AppController
    private(set) var combos: [HotkeyCenter.Action: KeyCombo] = [:]
    private(set) var problems: [HotkeyCenter.Action: String] = [:]
    var recording: HotkeyCenter.Action?
    /// Record the side of each modifier (Left ⇧) rather than either side.
    var sided: [HotkeyCenter.Action: Bool] = [:]
    var historyDays = Settings.historyDaysChoice {
        didSet { Settings.historyDaysChoice = historyDays }
    }
    var pasteRich = Settings.pasteRichChoice {
        didSet { Settings.pasteRichChoice = pasteRich }
    }
    var mergesRedoneCopies = Settings.mergesRedoneCopies {
        didSet { Settings.mergesRedoneCopies = mergesRedoneCopies }
    }
    var selectionTint = Settings.selectionTint {
        didSet { Settings.selectionTint = selectionTint }
    }
    var showsPictureText = Settings.showsPictureText {
        didSet { Settings.showsPictureText = showsPictureText }
    }
    var highlightsCode = Settings.highlightsCode {
        didSet { Settings.highlightsCode = highlightsCode }
    }
    var paused = Settings.paused {
        didSet { Settings.paused = paused }
    }
    var searchFileContents = Settings.searchFileContents == true {
        didSet { app.setFileSearch(searchFileContents) }
    }
    /// "1,204 files read" or how far the reading is, read when the window draws (`historyVersion` bumps it).
    var indexedFiles: String {
        _ = historyVersion
        if let progress = app.files.progressLine { return progress }
        let count = app.files.count
        return count == 1 ? "1 file read" : "\(count.formatted()) files read"
    }
    var openAtLogin = SMAppService.mainApp.status == .enabled
    /// Sparkle's own setting (kept in its defaults); only in builds that update.
    var checksForUpdates = false {
        didSet { app.updater.automaticallyChecks = checksForUpdates }
    }
    var showMenuBarIcon = Settings.showMenuBarIcon {
        didSet {
            Settings.showMenuBarIcon = showMenuBarIcon
            app.updateStatusItem()
        }
    }
    private(set) var canPaste = AXIsProcessTrusted()
    /// The window's tallest on its screen.
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    /// A range clicked once to clear: deleting can't be undone, the second click clears.
    private(set) var armed: ClearRange?
    /// What the last clearing did, for a moment.
    private(set) var cleared: String?
    /// Bumped when the history may have changed (cleared here, or the window shown again): the counts follow.
    private(set) var historyVersion = 0
    @ObservationIgnored private var armedTask: Task<Void, Never>?
    @ObservationIgnored private var clearedTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    init(app: AppController) {
        self.app = app
        checksForUpdates = app.updater.automaticallyChecks
        refresh()
        for action in HotkeyCenter.Action.allCases { sided[action] = combos[action]?.isSided ?? false }
        app.hotkeys.onChange = { [weak self] in self?.refresh() }
        // Pausing from the menu bar icon or a panel's "…" menu, with the window open: its switch follows.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.paused != Settings.paused else { return }
                self.paused = Settings.paused
            }
        }
        // Accessibility gets granted in System Settings: the window notices.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.canPaste { self.canPaste = trusted }
            }
        }
    }

    func refresh() {
        combos = app.hotkeys.combos
        problems = app.hotkeys.problems
        historyVersion += 1
        readChangedElsewhere()
    }

    /// What can change elsewhere with the window closed (it's kept, showing what it first read otherwise): pausing
    /// from the menus, opening at login in System Settings.
    private func readChangedElsewhere() {
        if paused != Settings.paused { paused = Settings.paused }
        let atLogin = SMAppService.mainApp.status == .enabled
        if openAtLogin != atLogin { openAtLogin = atLogin }
    }

    /// How many clips clearing `range` would delete (pinned ones stay).
    func clearableCount(_ range: ClearRange) -> Int {
        _ = historyVersion
        return app.clearableClips(since: range.since()).count
    }

    /// The first click arms the range (for 3 seconds), the second clears it.
    func clear(_ range: ClearRange) {
        guard armed == range else {
            armed = range
            armedTask?.cancel()
            armedTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.armed = nil
            }
            return
        }
        armed = nil
        armedTask?.cancel()
        let count = app.clearClips(since: range.since())
        historyVersion += 1
        flash(count == 1 ? "Cleared 1 clip" : "Cleared \(count.formatted()) clips")
    }

    func flash(_ note: String) {
        cleared = note
        clearedTask?.cancel()
        clearedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.cleared = nil
        }
    }

    func startRecording(_ action: HotkeyCenter.Action) {
        stopRecording()
        recording = action
        app.hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, modifiers.isEmpty {   // Esc: never mind
                self.stopRecording()
                return nil
            }
            guard let combo = KeyCombo(keyCode: event.keyCode, flags: event.modifierFlags,
                                       sided: self.sided[action] ?? false) else {
                NSSound.beep()   // needs ⌘, ⌥ or ⌃ (or an F-key)
                return nil
            }
            self.save(combo, for: action)
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil {
            recording = nil
            app.hotkeys.resume()
        }
    }

    func save(_ combo: KeyCombo?, for action: HotkeyCenter.Action) {
        Settings.setHotkey(combo, for: action)
        app.applyHotkeys()
        sided[action] = Settings.hotkey(action).isSided
        refresh()
    }

    /// The side switch re-saves the current combination with or without its sides.
    func setSided(_ value: Bool, for action: HotkeyCenter.Action) {
        sided[action] = value
        guard let combo = combos[action] else { return }
        if !value {
            save(combo.unsided, for: action)
        } else if !combo.isSided {
            startRecording(action)   // which side was meant is only known from a key press
        }
    }

    func restoreDefaults() {
        for action in HotkeyCenter.Action.allCases { Settings.setHotkey(nil, for: action) }
        app.applyHotkeys()
        for action in HotkeyCenter.Action.allCases { sided[action] = Settings.hotkey(action).isSided }
        refresh()
    }

    func setOpenAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("open at login: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openKeyboardShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    func allowPaste() {
        Paster.requestAccess()
    }
}

struct SettingsView: View {
    static let width: CGFloat = 600
    /// Its height, whatever's open in it (the settings scroll), unless the screen's shorter.
    static let height: CGFloat = 660
    @Bindable var model: SettingsModel
    let onClose: () -> Void
    let onHeight: (CGFloat) -> Void
    /// Room for the footer's line clear of the window's rounded corners (the panels' 30 put it in them).
    private static let footerHeight: CGFloat = 40
    private static let chromeHeight = PanelChrome.fieldHeight + footerHeight + 2
    @State private var keysShown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            InsetDivider()
            // The settings scroll between the header and the footer, which stay.
            ScrollView(.vertical) { sections }
                .scrollBounceBehavior(.basedOnSize)
                .modifier(SoftScrollEdges())
                .frame(height: max(min(Self.height, model.maxHeight) - Self.chromeHeight, 0))
            InsetDivider()
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelChrome.tint)
        .onDisappear { model.stopRecording() }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Shortcuts") {
                shortcutRow(.clipboard, title: "Clipboard history", detail: "Your copies, searchable by meaning")
                RowDivider()
                shortcutRow(.search, title: "Search", detail: "Apps, System Settings and files")
                RowDivider()
                keysRow
            }
            HStack {
                Text("Click a shortcut, then press the new keys. Esc cancels.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.restoreDefaults() } label: { Pill(title: "Restore Defaults") }
                    .buttonStyle(Pressable())
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            SettingsSection(title: "Clipboard") {
                SettingRow(title: "Keep history for") {
                    Menu {
                        Picker("Keep history for", selection: $model.historyDays) {
                            ForEach(Self.historyChoices, id: \.days) { Text($0.name).tag($0.days) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Pill(title: Self.historyChoices.first { $0.days == model.historyDays }?.name ?? "",
                             symbol: "chevron.up.chevron.down", prominent: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                RowDivider()
                SettingRow(title: "Paste with formatting when a clip has it") { Switch(isOn: $model.pasteRich) }
                RowDivider()
                SettingRow(title: "Merge a copy with the one before it",
                           detail: "When it starts the same, only longer or shorter, within 5 minutes.") {
                    Switch(isOn: $model.mergesRedoneCopies)
                }
                RowDivider()
                SettingRow(title: "Show text read from pictures", detail: "Search finds it either way.") {
                    Switch(isOn: $model.showsPictureText)
                }
                RowDivider()
                SettingRow(title: "Highlight code", detail: "Colors code by its language, guessed from the text.") {
                    Switch(isOn: $model.highlightsCode)
                }
                RowDivider()
                // In the orange of the panels' "!" while it's on.
                SettingRow(title: "Pause recording", detail: "New copies aren't saved while it's on.",
                           tint: model.paused ? OptionsMenu.pausedColor : nil) {
                    Switch(isOn: $model.paused)
                        .tint(model.paused ? OptionsMenu.pausedColor : nil)
                }
                RowDivider()
                SettingRow(title: "Clear history",
                           detail: model.cleared ?? "Pinned clips stay. Click a range, then again to clear it.") {
                    HStack(spacing: 6) {
                        ForEach(ClearRange.allCases) { range in clearPill(range) }
                    }
                }
            }

            SettingsSection(title: "Search") {
                SettingRow(title: "Find files by what's in them",
                           detail: "Pictures, PDFs, documents, videos and recordings in your home folder. What you "
                               + "open is read at once, the last 60 days in the background, the rest while the Mac is "
                               + "idle on power. Only their meaning is kept, not what's in them"
                               + (model.searchFileContents ? " (\(model.indexedFiles))." : ".")) {
                    Switch(isOn: $model.searchFileContents)
                }
            }

            SettingsSection(title: "General") {
                SettingRow(title: "Selection color") {
                    HStack(spacing: 8) {
                        ForEach(SelectionTint.allCases) { tint in
                            Button { model.selectionTint = tint } label: {
                                TintSwatch(tint: tint, selected: model.selectionTint == tint)
                            }
                            .buttonStyle(Pressable())
                            .help(tint.name)
                        }
                    }
                }
                RowDivider()
                SettingRow(title: "Open at login") {
                    Switch(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                }
                RowDivider()
                SettingRow(title: "Show icon in menu bar",
                           detail: model.showMenuBarIcon ? nil
                               : "To get back here, open Pastemind again (from Applications, Spotlight or its own "
                               + "search), or press ⌘, in a panel.") {
                    Switch(isOn: $model.showMenuBarIcon)
                }
                if model.app.updater.isOn {
                    RowDivider()
                    SettingRow(title: "Check for updates automatically",
                               detail: "Once a day, from GitHub. The request carries only Pastemind's version; updates are signed.") {
                        HStack(spacing: 10) {
                            Button { model.app.updater.checkNow() } label: { Pill(title: "Check Now") }
                                .buttonStyle(Pressable())
                            Switch(isOn: $model.checksForUpdates)
                        }
                    }
                }
                RowDivider()
                SettingRow(title: "Auto-paste and Left/Right keys") {
                    if model.canPaste {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Button { model.allowPaste() } label: { Pill(title: "Allow in Accessibility…") }
                            .buttonStyle(Pressable())
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }

    /// The keys in the clipboard history, folded away under a row of their own (opened, it stays so while the app
    /// runs).
    @ViewBuilder
    private var keysRow: some View {
        Button { keysShown.toggle() } label: {
            HStack(spacing: 12) {
                Text("Keys in the clipboard history").font(.system(size: 13.5))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(keysShown ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: keysShown)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if keysShown {
            KeysGrid(canPaste: model.canPaste)
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 14)
        }
    }

    /// A range to clear, with how many clips it holds; armed (clicked once), it asks to be clicked again, in red.
    private func clearPill(_ range: ClearRange) -> some View {
        let count = model.clearableCount(range)
        let armed = model.armed == range
        return Button { model.clear(range) } label: {
            if armed {
                ConfirmLabel(title: "Clear (\(count.formatted()))?")
            } else {
                HStack(spacing: 5) {
                    Text(range.shortTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text(count.formatted())
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: ConfirmLabel.height)
                .capsuleChrome(interactive: true)
                .contentShape(Capsule())
            }
        }
        .buttonStyle(Pressable())
        .disabled(count == 0)
        .opacity(count == 0 ? 0.4 : 1)
    }

    private static let historyChoices: [(days: Int, name: String)] = [
        (7, "1 week"), (30, "1 month"), (90, "3 months"), (180, "6 months"), (365, "1 year"),
    ]

    /// The panels' field row, with a title in place of the field.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.system(size: PanelChrome.iconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text("Settings")
                .font(.system(size: PanelChrome.fieldFontSize))
            Spacer()
            Button(action: onClose) { CircleIcon(symbol: "xmark", interactive: true) }
                .buttonStyle(Pressable())
                .help("Close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: PanelChrome.fieldHeight)
        .background(WindowDragArea())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Pastemind \(Self.version)")
                .foregroundStyle(.secondary)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Text("Quit Pastemind")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            HStack(spacing: 4) {
                Keycap(key: "esc")
                Text("Close").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 20)
        .frame(height: Self.footerHeight)
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    @ViewBuilder
    private func shortcutRow(_ action: HotkeyCenter.Action, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                ShortcutField(combo: model.combos[action], recording: model.recording == action) {
                    model.recording == action ? model.stopRecording() : model.startRecording(action)
                }
            }
            Toggle("Only the left or right modifier key, as pressed",
                   isOn: Binding(get: { model.sided[action] ?? false }, set: { model.setSided($0, for: action) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if let problem = model.problems[action] {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if problem.contains("System Settings") {
                        Button { model.openKeyboardShortcuts() } label: { Pill(title: "Open…") }
                            .buttonStyle(Pressable())
                    } else if problem.contains("Accessibility") {
                        Button { model.allowPaste() } label: { Pill(title: "Allow…") }
                            .buttonStyle(Pressable())
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A colour to pick for the selection, as System Settings shows the accent colours: a dot, ringed when chosen; the
/// system's own a rainbow (it follows whatever's chosen there).
private struct TintSwatch: View {
    let tint: SelectionTint
    let selected: Bool

    var body: some View {
        Group {
            if tint == .accent {
                Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                                              center: .center))
            } else {
                Circle().fill(Color(nsColor: tint.color))
            }
        }
        .frame(width: 16, height: 16)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
        .padding(3)
        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.75 : 0), lineWidth: 1.5))
        .contentShape(Circle())
    }
}

/// The clipboard history's keys, in two columns: the key caps, then what they do.
private struct KeysGrid: View {
    let canPaste: Bool

    private var keys: [(caps: [String], action: String)] {
        var keys: [(caps: [String], action: String)] = [(["↩"], canPaste ? "Paste" : "Copy")]
        if canPaste { keys.append((["⇧", "↩"], "Paste as plain text")) }
        keys += [
            (["⌘", "↩"], "Copy"),
            (["⌘", "1–9"], canPaste ? "Paste by number" : "Copy by number"),
            (["space"], "Quick Look a picture or file"),
            (["⌘", "P"], "Pin"),
            (["⌘", "S"], "Keep as a snippet"),
            (["⇥"], "Snippets, and back"),
            (["⌘", "N"], "New snippet, in the snippets"),
            (["esc"], "Close"),
        ]
        return keys
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            let keys = keys
            ForEach(Array(stride(from: 0, to: keys.count, by: 2)), id: \.self) { index in
                GridRow {
                    cell(keys[index])
                    if index + 1 < keys.count { cell(keys[index + 1]) } else { Color.clear.gridCellUnsizedAxes(.vertical) }
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ key: (caps: [String], action: String)) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(key.caps, id: \.self) { Keycap(key: $0) }
            }
            .frame(width: 52, alignment: .trailing)
            Text(key.action)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A titled group: the clipboard list's section title over rows on a faint card, its corners concentric with the
/// window's (26 − 12 of inset).
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 16)
                .padding(.bottom, 6)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}

/// A setting: its name (and a line about it) on the left, its control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var tint: Color?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .padding(.vertical, detail == nil ? 0 : 8)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

private struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// On macOS 26 the settings fade softly under the header and footer as they scroll (Liquid Glass's scroll edge).
private struct SoftScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            content
        }
    }
}

/// The shortcut field's look: Liquid Glass on macOS 26, a faint fill and rim before; ringed in the accent colour
/// while it's recording.
private struct FieldChrome: ViewModifier {
    let recording: Bool
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.background(shape.fill(Color.primary.opacity(0.05)))
            }
        }
        .overlay(shape.strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.1),
                                    lineWidth: recording ? 1.5 : 1)
            .opacity(recording || !Self.glass ? 1 : 0))   // glass has its own rim
    }

    private static var glass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }
}

/// A small capsule on the glass: buttons, and the value of a menu.
private struct Pill: View {
    let title: String
    var symbol: String?
    /// A value (the history's length) reads in the primary color; an action, quieter.
    var prominent = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(prominent ? .primary : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .capsuleChrome(interactive: true)
        .contentShape(Capsule())
    }
}

/// Pressed, a control gives a little: it heard the click.
private struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Drags the window (it has no title bar): under the top row.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// The current shortcut as keycaps; click to record a new one.
private struct ShortcutField: View {
    let combo: KeyCombo?
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if recording {
                    Text("Press keys…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                } else if let combo {
                    ForEach(Array(combo.caps.enumerated()), id: \.offset) { _, cap in
                        Text(cap)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12)))
                    }
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 150, minHeight: 28)
            .padding(.horizontal, 6)
            .modifier(FieldChrome(recording: recording))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }
}
