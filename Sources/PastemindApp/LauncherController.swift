import AppKit
import Observation
import QuickLookUI
import SwiftUI
import PastemindKit

/// The search panel: apps, System Settings panes and files by name. Apps and panes are matched in memory
/// on every keystroke (a couple of milliseconds); files come from Spotlight a moment later and join the list. What
/// you open after typing some letters ranks first for those letters next time.
///
/// ⇥ (or a leading ', or "open ") searches files only; ⇥ again goes back. Like the clipboard panel it never
/// activates Pastemind, and it's only as tall as its results: with nothing typed, a capsule (Spotlight's search bar).
/// A tap of ⇧ (or ⌘Y) shows the selected file in Quick Look: Space stays a space, for names of more than one word.
@Observable
final class LauncherController {
    static let width = PanelChrome.searchWidth
    static let fieldHeight = PanelChrome.fieldHeight
    static let rowHeight: CGFloat = 50
    static let visibleRows = 9
    /// The catalog is read again when the panel opens and it's older than this (apps get installed and removed).
    static let catalogLifetime: TimeInterval = 60
    /// Results wait for a pause in the typing this long: shown on every keystroke, they resized the window each time
    /// (one letter matches a screenful, the next a row or two), and it bounced as you typed.
    static let typingPause: CFTimeInterval = 0.08
    /// With results up, new ones wait for the files this long at most (Spotlight answers in ~80 to 240 ms), and come
    /// with them: shown alone, the apps' few rows had the window fold round them and open again for the files, or
    /// (as it then did) stay open over nothing until they came.
    static let filesWait: CFTimeInterval = 0.3

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var results: [LaunchResult] = []
    private(set) var selection: String?
    /// Spotlight is looking (the list may still grow).
    private(set) var searchingFiles = false {
        didSet { if searchingFiles != oldValue { updateSpinner() } }
    }
    /// Files are taking a moment: the spinner. Not for a quick search, where it only popped in and out.
    private(set) var spinning = false
    /// ⇥ turned the files-only filter on.
    private(set) var filesFilter = false
    var filesOnly: Bool { filesFilter || LaunchQuery(query).filesOnly }
    private(set) var resultsVersion = 0

    @ObservationIgnored unowned let app: AppController
    /// The window it shares with the clipboard history (`PanelHost`): search is one of its modes.
    @ObservationIgnored private let host: PanelHost
    private var window: PanelWindow? { host.window }
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored weak var symbolView: SymbolLayerView?
    @ObservationIgnored weak var placeholderView: PlaceholderView?
    /// The results, for where the selected row's icon is: Quick Look zooms out of it.
    @ObservationIgnored weak var list: ListView?
    @ObservationIgnored let quickLook = QuickLook()
    @ObservationIgnored private let shiftTap = ShiftTap()
    @ObservationIgnored private var catalog: [LaunchItem] = []
    @ObservationIgnored private var catalogDate = Date.distantPast
    @ObservationIgnored private var loadingCatalog = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let files = LatestWork<String, [LaunchItem]>(label: "pastemind.spotlight") { text in
        SpotlightFiles.search(text)
    }
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var navigated = false
    @ObservationIgnored private var transition = 0
    /// Bumped each time it opens (the options button shows for a moment then).
    private(set) var opened = 0
    /// It opened out of the clipboard history (the options button stays away then, unless the pointer's over it).
    private(set) var openedQuietly = false
    @ObservationIgnored private let frameAnimator = WindowFrameAnimator()
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var typedAt: CFTimeInterval = 0
    /// The apps' results, shown if the files don't come in time.
    @ObservationIgnored private var filesFallback: DispatchWorkItem?
    @ObservationIgnored private var pendingResults: DispatchWorkItem?
    /// The query `prepare` set up, for `show` to take as it is.
    @ObservationIgnored private var prepared: String?
    /// Set up over the clipboard history, waiting to take its place (`completeTakeover`).
    @ObservationIgnored private var takingOver = false
    @ObservationIgnored private var stack: PanelStack?
    static var maxHeight: CGFloat { fieldHeight + CGFloat(visibleRows) * rowHeight + 14 }

    init(app: AppController, host: PanelHost) {
        self.app = app
        self.host = host
        makeStack()
        refreshCatalog()
        DispatchQueue.main.async {
            // Drawn once now, invisibly, so the first hotkey press shows it at once.
            let window = host.window
            guard !window.isVisible else { return }
            host.show(.search)
            self.place(window, at: PanelChrome.topCenter())
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.displayIfNeeded()
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }

    /// Up, as search (not as the clipboard history, in the same window).
    var isVisible: Bool { host.isShowing(.search) }
    var windowNumber: Int? { window?.windowNumber }
    var selectedResult: LaunchResult? { results.first { $0.id == selection } }

    // MARK: Showing

    func toggle() {
        isVisible ? hide() : show()
    }

    /// `query`: what to open with.
    func show(query initial: String = "") {
        app.files.refreshIfStale()
        guard let window else { return }
        let started = Date()
        host.show(.search)
        transition += 1
        openedQuietly = false
        opened += 1
        if prepared != initial { reset(to: initial) }
        prepared = nil
        symbolView?.set(symbol, animated: false)
        placeholderView?.set(placeholder, animated: false)
        stack?.setBody(visible: true)
        place(window, at: PanelChrome.topCenter())
        // No fade: it opens from the keyboard many times a day, and any animation there reads as lag.
        window.alphaValue = 1
        takeKeyboard(window)
        log("search: shown in \(ms(started, Date()))")
    }

    /// Switching here from the clipboard history, in two steps. As the history sets off, before its first frame:
    /// search is set up for the query, laid out and drawn, unseen in their window, its field taking the keyboard
    /// (what's typed meanwhile is search's; taking it at the switch cost that frame ~5 ms more).
    func beginTakeover(query text: String) {
        transition += 1
        openedQuietly = true
        opened += 1
        if prepared != text { reset(to: text) }
        prepared = nil
        takingOver = true
        symbolView?.set(symbol, animated: false)
        placeholderView?.set(placeholder, animated: false)
        stack?.setBody(visible: false)
        host.prepare(.search)
        focusField()
    }

    /// Then, once the history's body has faded: search takes the window from the history (its stack for the
    /// history's) and carries the history's motion on to its own size, its results coming in. Its field goes where the
    /// history's is now: dragged while it folded, where it was dragged to.
    func completeTakeover(motion: WindowMotion?) {
        guard let window, window.isVisible, takingOver else { return }
        takingOver = false
        let field = motion?.frame ?? window.frame
        let anchor = NSPoint(x: field.midX, y: field.maxY)
        host.show(.search)   // the history lets go: its motion stops here, and this one carries it on
        let target = PanelChrome.frame(NSSize(width: Self.width, height: desiredHeight), at: anchor)
        if let motion, !Motion.reduced {
            frameAnimator.run(window, to: target,
                              spring: target.height >= motion.frame.height ? Motion.grow : Motion.shrink, from: motion)
        } else {
            window.setFrame(target, display: false)
            PanelChrome.refreshShadow(of: window)
        }
        installMonitors()
        beginActivity()
        focusField()
        stack?.revealBody()
    }

    /// Typed while the history turns into it, its keys still the history's: letters, digits and signs into the field
    /// (which has the keyboard since `beginTakeover`), ⌫ out of it. Lost before: they went to the history's field.
    func typeDuringTakeover(_ event: NSEvent) {
        guard isTakingOver, let editor = field?.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        let modifiers = event.modifierFlags.intersection(KeyModifiers.relevant)
        if event.keyCode == 51, modifiers.isEmpty { return editor.deleteBackward(nil) }
        // Below space: control characters (↩ ⇥ ⎋); 0x7F: ⌫; 0xF700 on: the arrow and function keys.
        guard modifiers.isSubset(of: [.shift, .option]), let text = event.characters, let scalar = text.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value),
              text != " " || !query.isEmpty   // never a leading space, as typed in search
        else { return }
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func takeKeyboard(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        PanelChrome.refreshShadow(of: window)
        focusField()
        installMonitors()
        beginActivity()
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Pastemind search open")
    }

    private func focusField() {
        guard let window, let field else { return }
        // Not again when its editor has the keyboard already (taking over, it was set up a moment before): that ended
        // the editing and began it anew, ~3 ms.
        if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        // Set again only when it isn't already (taking over, it was set up a moment before): ~3 ms in the switch's
        // busiest frame.
        if field.stringValue != query { field.stringValue = query }
        field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
    }

    func hide() {
        let showing = host.mode == .search
        leave()
        if showing { window?.orderOut(nil) }
    }

    /// Gone, or the clipboard history took the window: its keys, its motion, Quick Look let go of (the window stays
    /// for the history).
    private func leave() {
        quickLook.close(zooming: false)
        if takingOver { host.unprepare(.search) }   // the switch here didn't happen
        takingOver = false
        pendingResults?.cancel()
        pendingResults = nil
        filesFallback?.cancel()
        filesFallback = nil
        transition += 1
        frameAnimator.stop()
        removeMonitors()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Set up over the clipboard history, invisible, waiting for it to fold (`completeTakeover`).
    var isTakingOver: Bool { takingOver }

    /// The window's height now (mid-animation too): where the clipboard history starts growing from.
    /// The window's size now (mid-animation too): where the clipboard history starts from when it takes over.
    var currentSize: NSSize? { isVisible ? window?.frame.size : nil }

    /// Apps and panes, read in the background (~200 ms: the apps' last-used dates come from Spotlight).
    private func refreshCatalog() {
        guard !loadingCatalog else { return }
        loadingCatalog = true
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let items = LaunchCatalog.load()
            await MainActor.run {
                self.catalog = items
                self.catalogDate = Date()
                self.loadingCatalog = false
                log("search: \(items.count) apps and panes in \(ms(started, Date()))")
                if !self.query.isEmpty { self.queryChanged() }
                self.prewarmIcons(items.filter { $0.kind == .app })
            }
        }
    }

    /// The apps' icons, drawn at their size in the background, so the rows open with all of them ready (drawing them
    /// on first show cost frames).
    private func prewarmIcons(_ items: [LaunchItem]) {
        let paths = items.map(\.path)
        Task.detached(priority: .utility) {
            for path in paths { _ = Icons.path(path, side: 34) }
        }
    }

    // MARK: Searching

    private func queryChanged() {
        generation += 1
        let current = generation
        navigated = false
        typedAt = CACurrentMediaTime()
        filesFallback?.cancel()
        filesFallback = nil
        let typed = LaunchQuery(query)
        let parsed = filesFilter ? LaunchQuery(text: typed.text, filesOnly: true) : typed
        guard !parsed.text.isEmpty else {
            searchingFiles = false
            present([])
            return
        }
        let history = app.launchHistory(for: parsed.text)
        let apps = LaunchRanker.merge(parsed, catalog: catalog, files: [], history: history)
        // One letter matches half the disk: files from the second one on.
        guard parsed.text.count >= 2 else {
            searchingFiles = false
            present(apps)
            return
        }
        searchingFiles = true
        if results.isEmpty {
            // Opening from the capsule: the apps at once, the files growing it after (growing leaves nothing empty).
            present(apps)
        } else {
            // Results up: these stay till the new ones come with the files (see `filesWait`).
            let fallback = DispatchWorkItem { [weak self] in
                guard let self, current == self.generation else { return }
                self.filesFallback = nil
                self.present(apps)
            }
            filesFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.filesWait, execute: fallback)
        }
        let started = Date()
        files.submit(parsed.text) { [weak self] found in
            guard let self, current == self.generation else { return }
            self.filesFallback?.cancel()
            self.filesFallback = nil
            self.searchingFiles = false
            let merged = LaunchRanker.merge(parsed, catalog: self.catalog, files: found, history: history)
            self.present(merged)
            log("search \"\(parsed.text)\": \(found.count) files, \(merged.count) results by \(ms(started, Date()))")
            self.addMeaning(to: merged, parsed, current)
        }
    }

    /// Recent files by what's in them, under what matched by name: when files are asked for, or nothing matched well
    /// by name (an app's name typed needn't load the model).
    private func addMeaning(to merged: [LaunchResult], _ parsed: LaunchQuery, _ current: Int) {
        guard parsed.filesOnly || !LaunchRanker.hasStrongMatch(merged) else { return }
        if Settings.searchFileContents == nil {
            if parsed.text.count >= 3 { present(LaunchRanker.addAction(merged, Self.fileSearchOffer)) }
            return
        }
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            let found = await self.app.fileMatches(for: parsed.text, limit: parsed.filesOnly ? 20 : 5)
            guard current == self.generation, !found.isEmpty else { return }
            self.present(LaunchRanker.addMeaning(merged, files: found))
            log("search \"\(parsed.text)\": \(found.count) files by what's in them by \(ms(started, Date()))")
        }
    }

    /// Shown once the typing pauses (Spotlight is asked at once all the same, so files aren't held up).
    private func present(_ results: [LaunchResult]) {
        pendingResults?.cancel()
        pendingResults = nil
        let wait = typedAt + Self.typingPause - CACurrentMediaTime()
        guard wait > 0 else { return show(results) }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingResults = nil
            self?.show(results)
        }
        pendingResults = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// The results waiting for the typing to pause, now: a key that acts on them, a query set all at once.
    private func flushResults() {
        typedAt = 0
        if let fallback = filesFallback {   // waiting for the files: what's found so far, now
            fallback.perform()
            fallback.cancel()
        }
        guard let work = pendingResults else { return }
        work.perform()
        work.cancel()
    }

    private func show(_ results: [LaunchResult]) {
        let previous = selection
        // The same results again (the files came and changed nothing): left alone, else the list was redone for nothing,
        // ~15 ms, mid-motion when switching from the clipboard history.
        if results == self.results, previous == results.first?.id || navigated { return }
        self.results = results
        if navigated, let previous, results.contains(where: { $0.id == previous }) {
            selection = previous
        } else {
            // An offer (turning something on) is never what ↩ does unasked: it's chosen with the arrows or a click.
            selection = results.first.flatMap { $0.item.kind == .action ? nil : $0.id }
            resultsVersion += 1
        }
        if selection != previous { quickLook.follow(lookItems) }
        resize()
    }

    // MARK: Keys

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.window else { return event }
            self.shiftTap.cancel()
            return self.handle(event) ? nil : event
        }
        shiftTap.start(in: { [weak self] in self?.window }) { [weak self] in self?.shiftTapped() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.quickLook.isVisible else { return self.hide() }
                // Quick Look's preview loading took the focus: it comes back.
                if self.quickLook.tookFocus() {
                    DispatchQueue.main.async { self.window?.makeKey() }
                    return
                }
                // Clicking into Quick Look keeps search up (the new key window is known a moment later).
                DispatchQueue.main.async {
                    guard !self.quickLook.isKey, self.window?.isKeyWindow != true else { return }
                    self.hide()
                }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        shiftTap.stop()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// A tap of ⇧: Quick Look, or closes it. Not while an input method is composing: some switch modes on a ⇧ tap.
    private func shiftTapped() {
        guard (field?.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        toggleQuickLook()
    }

    private static let numberKeys: [Int: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private func handle(_ event: NSEvent) -> Bool {
        if (field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection(KeyModifiers.relevant)
        switch Int(event.keyCode) {
        case 53:  // Esc: closes Quick Look, then search, files only or not (⇥ goes back); what's typed stays (⌘⌫ clears it)
            if quickLook.isVisible { quickLook.close() } else { hide() }
            return true
        case 49 where modifiers.isEmpty:  // Space: typed, never a leading one (it searched for nothing); closes Quick Look
            guard !query.isEmpty else { return true }
            guard quickLook.isVisible else { return false }
            quickLook.close()
            return true
        case 16 where modifiers == .command:  // ⌘Y: Quick Look, as in Finder (or a tap of ⇧)
            // Once a press: held, the key repeats, and each repeat toggled it again.
            if !event.isARepeat { toggleQuickLook() }
            return true
        case 48 where modifiers.isEmpty || modifiers == .shift:  // ⇥ ⇧⇥: files only, and back
            toggleFilesFilter()
            return true
        case 125, 126:  // ↓ ↑
            guard modifiers.isEmpty else { return false }
            flushResults()
            moveSelection(by: event.keyCode == 125 ? 1 : -1)
            return true
        case 36, 76:  // ↩ opens, ⌘↩ shows it in Finder
            flushResults()
            if modifiers == .command { reveal() } else if modifiers.isEmpty { open() } else { return false }
            return true
        case 8 where modifiers == .command:  // ⌘C: the path, unless some of the query is selected or Quick Look is up
            if (field?.currentEditor()?.selectedRange.length ?? 0) > 0 { return false }
            if quickLook.copySelection() { return true }
            flushResults()
            copyPath()
            return true
        case let code where modifiers == .command && Self.numberKeys[code] != nil:  // ⌘1…⌘9
            let number = Self.numberKeys[code]!
            flushResults()
            if number <= results.count {
                selection = results[number - 1].id
                open()
            }
            return true
        case 43 where modifiers == .command:  // ⌘,: Settings (the way there when the menu bar icon is hidden)
            app.openSettings()
            return true
        case 12 where modifiers == .command, 13 where modifiers == .command:  // ⌘Q, ⌘W: close, not quit
            hide()
            return true
        default:
            return false
        }
    }

    func toggleFilesFilter() {
        filesFilter.toggle()
        queryChanged()
        flushResults()
    }

    func moveSelection(by step: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
        quickLook.follow(lookItems)
    }

    func select(_ id: String) {
        selection = id
        navigated = true
        quickLook.follow(lookItems)
    }

    // MARK: Actions

    func open() {
        guard let result = selectedResult else { return }
        let item = result.item
        if item.kind == .action { return turnOnFileSearch() }
        app.recordLaunch(query: LaunchQuery(query).text, item: item.id)
        hide()
        switch item.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration())
        case .setting, .file, .folder:
            NSWorkspace.shared.open(item.url)
        case .action:
            break
        }
    }

    /// Search's offer taken: files by what's in them from now on. macOS asks for three folders next; this query's
    /// results come back once the first files are read.
    private func turnOnFileSearch() {
        hide()
        app.setFileSearch(true)
    }

    /// The offer at the end of a query that found nothing by name, until it's been answered (here, or in Settings).
    static let fileSearchOffer = LaunchItem(
        kind: .action, name: "Find files by what's in them", path: Bundle.main.bundlePath,
        url: URL(string: "pastemind://find-files-by-contents")!,
        detail: "Turn on: Pastemind reads your files on this Mac to find them by what they show or say")

    private func reveal() {
        guard let item = selectedResult?.item else { return }
        guard item.kind != .setting else { return open() }
        app.recordLaunch(query: LaunchQuery(query).text, item: item.id)
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    private func copyPath() {
        guard let item = selectedResult?.item else { return }
        let pasteboard = Pasteboards.main
        pasteboard.clearContents()
        pasteboard.setString(item.kind == .setting ? item.url.absoluteString : item.path, forType: .string)
        hide()
    }

    // MARK: Quick Look

    /// What Quick Look shows for the selected result: the file, folder or app, as Finder's Space does. Nothing for a
    /// settings pane (its path is the pane's extension bundle), or a file that's gone since Spotlight found it.
    private var lookItems: [QuickLook.Item] {
        guard let item = selectedResult?.item, item.kind != .setting,
              FileManager.default.fileExists(atPath: item.path) else { return [] }
        return [QuickLook.Item(URL(fileURLWithPath: item.path))]
    }

    /// Shown over the panel, the keyboard staying here (↑↓ move it along, ⇧, Space or Esc close it); or closed.
    func toggleQuickLook() {
        flushResults()
        guard let window, isVisible else { return }
        if quickLook.isVisible { return quickLook.close() }
        quickLook.show(lookItems, over: window)
    }

    /// Quick Look let go of its controller (see `AppController`): closed by itself, its button or Esc once a click
    /// made it key; the keyboard comes back here.
    func quickLookEnded(_ panel: QLPreviewPanel) {
        quickLook.end(panel)
        if isVisible, let window, !window.isKeyWindow { window.makeKey() }
    }

    /// The selected row's icon (or file's picture) on screen, and as drawn: where Quick Look zooms out of and back
    /// into. None while the row's scrolled out of sight: it fades.
    private func lookSource() -> (frame: NSRect, image: NSImage)? {
        guard let window, isVisible, let selection, let row = results.firstIndex(where: { $0.id == selection }),
              let cell = list?.visibleCell(row) as? LaunchCell,
              let picture = cell.picture(scale: window.backingScaleFactor) else { return nil }
        return (window.convertToScreen(cell.convert(picture.frame, to: nil)), picture.image)
    }

    // MARK: Window

    private func makeStack() {
        let header = NSHostingView(rootView: LauncherHeaderView(controller: self))
        let body = NSHostingView(rootView: LauncherBodyView(controller: self))
        header.sizingOptions = []
        body.sizingOptions = []
        let stack = PanelStack(header: header, body: body, width: Self.width, height: Self.maxHeight)
        self.stack = stack
        quickLook.sourceFrame = { [weak self] _ in self?.lookSource()?.frame ?? .zero }
        quickLook.transitionImage = { [weak self] _ in self?.lookSource()?.image }
        host.add(stack, for: .search, height: Self.maxHeight) { [weak self] in self?.leave() }
    }

    /// Search's content for `text`, laid out ahead (the window hidden) while the clipboard history turns into it, so
    /// taking over costs the motion no frame.
    func prepare(query text: String) {
        guard let window, !window.isVisible else { return }
        reset(to: text)
        prepared = text
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func reset(to text: String) {
        if Date().timeIntervalSince(catalogDate) > Self.catalogLifetime { refreshCatalog() }
        filesFilter = false
        query = ""
        results = []
        query = text
        flushResults()
    }

    var desiredHeight: CGFloat {
        let rows = results.isEmpty ? (searchingFiles && filesOnly ? 1 : 0) : min(results.count, Self.visibleRows)
        return Self.fieldHeight + (rows > 0 ? CGFloat(rows) * Self.rowHeight + 14 : 0)
    }

    private func place(_ window: NSWindow, at anchor: NSPoint) {
        window.setFrame(PanelChrome.frame(NSSize(width: Self.width, height: desiredHeight), at: anchor), display: false)
    }

    /// The middle of the field's top edge while the panel is up: where the clipboard history puts its own.
    var topCenter: NSPoint? {
        guard let window, isVisible else { return nil }
        return NSPoint(x: window.frame.midX, y: window.frame.maxY)
    }

    /// What's typed, without the files-only prefix: the words to carry over to the clipboard history.
    var typedWords: String { LaunchQuery(query).text }

    var placeholder: String { Self.placeholder(filesOnly: filesFilter) }

    static func placeholder(filesOnly: Bool) -> String {
        filesOnly ? "Search files" : "Search apps, settings and files"
    }

    var symbol: String { filesOnly ? "doc" : "magnifyingglass" }

    /// The symbol, placeholder and height it opens with for `text` (apps and settings: files come later): what the
    /// clipboard history turns into when switching here.
    func opening(for text: String) -> (symbol: String, placeholder: String, height: CGFloat) {
        let parsed = LaunchQuery(text)
        let symbol = parsed.filesOnly ? "doc" : "magnifyingglass"
        let placeholder = Self.placeholder(filesOnly: false)
        guard !parsed.text.isEmpty else { return (symbol, placeholder, Self.fieldHeight) }
        let count = LaunchRanker.merge(parsed, catalog: catalog, files: [], history: app.launchHistory(for: parsed.text)).count
        let rows = count == 0 ? (parsed.filesOnly && parsed.text.count >= 2 ? 1 : 0) : min(count, Self.visibleRows)
        return (symbol, placeholder, Self.fieldHeight + (rows > 0 ? CGFloat(rows) * Self.rowHeight + 14 : 0))
    }

    /// Debug runs: the spinner up or not, to look at.
    func debugSpinner(_ on: Bool) { spinning = on }

    private func updateSpinner() {
        spinnerTask?.cancel()
        spinnerTask = nil
        guard searchingFiles else {
            if spinning { spinning = false }
            return
        }
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, self.searchingFiles else { return }
            self.spinning = true
        }
    }

    /// Grows or shrinks downward, keeping the field where it is: along the motion curves, so the capsule opens into
    /// the panel (its corners and rim following the height) instead of jumping. Interruptible: results arriving
    /// mid-way send it on to the new height from where it is.
    private func resize() {
        guard let window, isVisible else { return }   // taking over, its height is the takeover's to set
        let height = desiredHeight
        let heading = frameAnimator.target?.height ?? window.frame.height
        guard abs(heading - height) > 0.5 else { return }
        // Fewer results fold it at once: they're the final ones (they come after a pause in the typing, with the
        // files), and waiting only showed the empty space under them. Not in the middle of a SwiftUI update:
        // resizing from inside one sizes the view wrong.
        DispatchQueue.main.async { self.move(window, toHeight: height) }
    }

    private func move(_ window: NSWindow, toHeight height: CGFloat) {
        guard isVisible else { return }
        // From where it's going, mid-motion: still narrowing from the clipboard history when files came, it took the
        // width it had then for its own and stayed that wide.
        var frame = frameAnimator.target ?? window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        let growing = height > window.frame.height
        if Motion.reduced || (!frameAnimator.isRunning && abs(height - window.frame.height) < 2) {
            frameAnimator.stop()
            window.setFrame(frame, display: true)
            PanelChrome.refreshShadow(of: window)
        } else if frameAnimator.isRunning {
            frameAnimator.retarget(to: frame, spring: growing ? Motion.results : Motion.shrink)
        } else {
            frameAnimator.run(window, to: frame, spring: growing ? Motion.results : Motion.shrink)
        }
    }
}

/// Work where only the latest request matters (typing): one runs at a time on its own queue; while it does, newer
/// requests replace each other, and only the newest runs next. Results come back on the main thread.
nonisolated final class LatestWork<Input: Sendable, Output: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let work: @Sendable (Input) -> Output
    private let lock = NSLock()
    private var pending: (Input, @MainActor (Output) -> Void)?
    private var running = false

    init(label: String, work: @escaping @Sendable (Input) -> Output) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.work = work
    }

    func submit(_ input: Input, then done: @escaping @MainActor (Output) -> Void) {
        let start = lock.withLock { () -> Bool in
            pending = (input, done)
            guard !running else { return false }
            running = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while let (input, done) = lock.withLock({ () -> (Input, @MainActor (Output) -> Void)? in
            guard let next = pending else {
                running = false
                return nil
            }
            pending = nil
            return next
        }) {
            let output = work(input)
            let deliver = UncheckedBox(done)
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver.value(output) } }
        }
    }
}

/// A main-actor closure carried across to the main queue (it only ever runs there).
nonisolated private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
