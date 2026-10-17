import AppKit
import PastemindKit
import ServiceManagement
import SwiftUI

/// What a new install opens with, three short pages: the two shortcuts, the model on its way, and the permissions
/// Pastemind asks for (each asked for from here). Drawn like Settings, and like it a plain window: closing it is all it
/// takes, the download goes on, and all of it is in Settings after.
final class WelcomeWindowController {
    private var window: NSWindow?
    private var model: WelcomeModel?
    private var closeObserver: NSObjectProtocol?
    private unowned let app: AppController

    init(app: AppController) {
        self.app = app
    }

    var windowNumber: Int? { window?.windowNumber }

    func show() {
        let window = self.window ?? make()
        self.window = window
        app.hotkeys.recheck()
        model?.start()
        if DebugHooks.enabled {   // debug runs: on the Space in front, without taking it over (and stealing the focus)
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.orderFrontRegardless()
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        PanelChrome.refreshShadow(of: window)
    }

    func close() {
        window?.close()
    }

    /// A new install: it opens at login from now on (the welcome's last page has the switch to turn that off), and
    /// says hello.
    func showFirstTime() {
        do { try SMAppService.mainApp.register() } catch { log("open at login: \(error)") }
        show()
    }

    /// Debug runs: the window as it'd look at the start, with all of it done, or the download failed.
    func debugState(_ name: String) {
        model?.debugState(name)
    }

    /// Debug runs: that page (from 0), as Next and Back would show it.
    func debugPage(_ index: Int) {
        model?.page = min(max(index, 0), WelcomeView.pageCount - 1)
    }

    private func make() -> NSWindow {
        let window = SettingsWindow()
        window.title = "Welcome to Pastemind"
        let model = WelcomeModel(app: app)
        self.model = model
        let view = WelcomeView(model: model, onClose: { [weak window] in window?.close() },
                               onHeight: { [weak window] height in window?.fit(height: height) })
        let hosting = NSHostingView(rootView: view)
        let height = hosting.fittingSize.height
        hosting.sizingOptions = []
        window.contentView = PanelChrome.container(containing: hosting, frosted: true)
        // Closed, it stops following the download and the permissions (shown again, it starts).
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.stop() }
        }
        window.setContentSize(NSSize(width: WelcomeView.width, height: height))
        window.fit(height: height)
        window.center()
        return window
    }
}

@Observable
final class WelcomeModel {
    @ObservationIgnored unowned let app: AppController
    /// Which page is showing: the shortcuts, the model, the permissions.
    var page = 0
    private(set) var combos: [HotkeyCenter.Action: KeyCombo] = [:]
    /// Spotlight has search's keys (a new Mac's ⌘Space): they never reach Pastemind.
    private(set) var spotlightTaken = false
    private(set) var text = AppController.ModelProgress.waiting
    private(set) var pictures = AppController.ModelProgress.waiting
    private(set) var canPaste = AXIsProcessTrusted()
    private(set) var readsFiles = Settings.searchFileContents == true
    private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    @ObservationIgnored private var timer: Timer?
    /// A debug state on show: what's real isn't read meanwhile.
    @ObservationIgnored private var frozen = false

    init(app: AppController) {
        self.app = app
        refresh()
    }

    /// The download moves, and access gets granted in System Settings: while it's shown, the window follows.
    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !frozen else { return }
        combos = Dictionary(uniqueKeysWithValues: HotkeyCenter.Action.allCases.map { ($0, Settings.hotkey($0)) })
        spotlightTaken = combos[.search].map(Self.spotlightHolds) ?? false
        text = app.progress(of: ModelFiles.text)
        pictures = app.progress(of: ModelFiles.pictures)
        canPaste = AXIsProcessTrusted()
        readsFiles = Settings.searchFileContents == true
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func allowPaste() {
        Paster.requestAccess()
    }

    /// Search by what's in files on: macOS asks for the Desktop, Documents and Downloads next.
    func readFiles() {
        app.setFileSearch(true)
        readsFiles = true
    }

    func setOpenAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("open at login: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func retry() {
        app.retryModel()
        refresh()
    }

    func openKeyboardShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// Spotlight's own ⌘Space, on (as on a new Mac, which has no entry for it till it's changed).
    static func spotlightHolds(_ combo: KeyCombo) -> Bool {
        guard combo.unsided.spec == "cmd+space" else { return false }
        let keys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        guard let entry = keys?["64"] as? [String: Any] else { return true }
        let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int] ?? []
        return (entry["enabled"] as? Bool ?? true) && parameters.dropFirst().elementsEqual([49, 1 << 20])
    }

    func debugState(_ name: String) {
        frozen = true
        combos = Settings.defaultHotkeys.compactMapValues(KeyCombo.init)   // a new install's
        openAtLogin = true
        switch name {
        case "done":
            (text, pictures, canPaste, readsFiles, spotlightTaken) = (.ready, .downloading(0.67), true, true, false)
        case "failed":
            (text, pictures, canPaste, readsFiles, spotlightTaken) = (.failed, .waiting, false, false, true)
        default:
            (text, pictures, canPaste, readsFiles, spotlightTaken) = (.downloading(0.42), .waiting, false, false, true)
        }
    }
}

/// A page each: a picture, a title, a line, and the one thing to do there.
struct WelcomeView: View {
    static let width: CGFloat = 480
    static let pageCount = 3
    @Bindable var model: WelcomeModel
    let onClose: () -> Void
    let onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // All three laid out, one shown: the window keeps the tallest one's height, the buttons staying put.
            ZStack(alignment: .top) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    page(index)
                        .opacity(index == model.page ? 1 : 0)
                        .offset(x: index == model.page ? 0 : index < model.page ? -16 : 16)
                        .allowsHitTesting(index == model.page)
                        .accessibilityHidden(index != model.page)
                }
            }
            .animation(.easeOut(duration: 0.22), value: model.page)
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowDragArea())
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { CircleIcon(symbol: "xmark", interactive: true) }
                .buttonStyle(Pressable())
                .help("Close")
                .padding(14)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelChrome.tint)
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0:
            WelcomePage(title: "Welcome to Pastemind",
                        text: "Everything you copy, found by what it's about, in any language.") {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
            } content: {
                shortcuts
            }
        case 1:
            WelcomePage(title: model.text == .ready ? "Search is ready" : "Getting search ready",
                        text: "A one-time download of \(ModelFiles.text.sizeName). It runs on this Mac, so what "
                            + "you copy never leaves it.") {
                Hero(symbol: "sparkle.magnifyingglass")
            } content: {
                download
            }
        default:
            WelcomePage(title: "A few permissions", text: "All optional. Settings has them later too.") {
                Hero(symbol: "hand.raised")
            } content: {
                permissions
            }
        }
    }

    /// The two shortcuts, either side of a modifier (a one-sided one is Settings' business), and a word when Spotlight
    /// has search's keys.
    private var shortcuts: some View {
        VStack(spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                ForEach([(HotkeyCenter.Action.clipboard, "Clipboard history"), (.search, "Search")], id: \.0) { item in
                    GridRow {
                        if let combo = model.combos[item.0] {
                            ComboCaps(combo: combo.unsided).gridColumnAlignment(.trailing)
                        }
                        Text(item.1).font(.system(size: 13.5))
                    }
                }
            }
            if model.spotlightTaken, let search = model.combos[.search] {
                HStack(spacing: 6) {
                    Text("\(search.unsided.display) opens Spotlight for now.")
                        .foregroundStyle(.secondary)
                    Button("Change…") { model.openKeyboardShortcuts() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12))
            }
        }
    }

    /// The text model's progress, then ready; the picture model's after it, in a line.
    @ViewBuilder
    private var download: some View {
        VStack(spacing: 8) {
            switch model.text {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                Text("\(Int(fraction * 100))%  ·  Search by words works meanwhile")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .ready:
                Granted(title: "Ready").font(.system(size: 13, weight: .medium))
                if case .downloading(let fraction) = model.pictures {
                    Text("Pictures next: \(Int(fraction * 100))%")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            case .failed:
                HStack(spacing: 8) {
                    Text("The download didn't finish.").foregroundStyle(.secondary)
                    Button { model.retry() } label: { Pill(title: "Try Again") }
                        .buttonStyle(Pressable())
                }
                .font(.system(size: 12))
            case .waiting:
                Text("Waiting…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var permissions: some View {
        SettingsSection(title: nil) {
            SettingRow(title: "Paste for you", detail: "↩ pastes into the app you're in") {
                if model.canPaste {
                    Granted(title: "Allowed")
                } else {
                    Button { model.allowPaste() } label: { Pill(title: "Allow…") }
                        .buttonStyle(Pressable())
                }
            }
            RowDivider()
            SettingRow(title: "Search your files", detail: "Pictures, PDFs and documents, by meaning") {
                if model.readsFiles {
                    Granted(title: "On")
                } else {
                    Button { model.readFiles() } label: { Pill(title: "Turn On…") }
                        .buttonStyle(Pressable())
                }
            }
            RowDivider()
            SettingRow(title: "Open at login") {
                Switch(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
        }
    }

    /// Where it is (a dot a page), Back, and Next, which is Start on the last.
    private var footer: some View {
        let last = model.page == Self.pageCount - 1
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(index == model.page ? 0.6 : 0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.22), value: model.page)
            Spacer()
            if model.page > 0 {
                Button { model.page -= 1 } label: { Pill(title: "Back") }
                    .buttonStyle(Pressable())
            }
            Button { last ? onClose() : (model.page += 1) } label: {
                Text(last ? "Start" : "Next")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 48)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(Pressable())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.vertical, 16)
    }
}

/// One page: its picture, title and line, centred, and what's to do below.
private struct WelcomePage<Picture: View, Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder var picture: Picture
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            picture
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 16)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            content
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 8)
    }
}

/// A page's picture where it isn't the app's icon: a symbol on a faint round.
private struct Hero: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 76, height: 76)
            .background(Circle().fill(Color.primary.opacity(0.06)))
    }
}

extension ModelFile {
    /// "246 MB": whole megabytes, as a download's size is only for a sense of it.
    var sizeName: String { "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }
}

/// A download's bar and percent, small, for a row's right side.
struct DownloadBar: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(width: 96)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

/// Done, in green: "Allowed", "On", "Ready".
struct Granted: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.green)
    }
}
