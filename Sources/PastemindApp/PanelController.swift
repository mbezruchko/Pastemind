import AppKit
import QuickLookUI
import Observation
import PastemindKit
import SwiftUI

/// A row of the panel's list.
struct PanelRow: Identifiable, Equatable {
    let clip: Clip
    /// Dimmed: a meaning match well behind the best one.
    var weak = false
    /// The typed words are in it (a meaning match alone has none to show in an excerpt).
    var words = true
    /// Several copied files found by one of them: its name.
    var file: String?
    var id: Int64 { clip.id }
}

struct PanelSection: Identifiable, Equatable {
    let id: String
    let title: String?
    let rows: [PanelRow]
    /// A copy on its way in, above the rows (`AppController.incoming`).
    var incoming: CaptureSource? = nil
}

/// What "Clear history" offers: the clips copied in the last few minutes, today, or all of them.
enum ClearRange: CaseIterable, Identifiable {
    case fiveMinutes, fifteenMinutes, today, all

    var id: Self { self }

    var title: String {
        switch self {
        case .fiveMinutes: "Last 5 minutes"
        case .fifteenMinutes: "Last 15 minutes"
        case .today: "Today"
        case .all: "All"
        }
    }

    /// For a button: "5 min", "Today".
    var shortTitle: String {
        switch self {
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .today: "Today"
        case .all: "All"
        }
    }

    /// Since when (nil: from the start).
    func since(_ now: Date = Date()) -> Date? {
        switch self {
        case .fiveMinutes: now.addingTimeInterval(-5 * 60)
        case .fifteenMinutes: now.addingTimeInterval(-15 * 60)
        case .today: Calendar.current.startOfDay(for: now)
        case .all: nil
        }
    }
}

/// The clipboard history, or the snippets (⇥ switches).
enum PanelMode: Equatable {
    case history, snippets
}

enum PanelPhase: Equatable {
    case recent      // nothing typed: the history, newest first
    case words       // word matches; meaning matches on the way
    case meaning     // words + meaning: final
    case wordsOnly   // final, but without meaning search (the model isn't ready, or the query is too short)
}

/// The hotkey panel: a search field over the history, the selected clip previewed on the right. It never activates
/// Pastemind (a non-activating panel, like Spotlight's), so the app you were in stays in front, and a paste lands there.
///
/// Every keystroke shows word matches at once (about a millisecond); the query is embedded at the same time and the
/// hybrid results replace them a moment later.
@Observable
final class PanelController {
    static let width = PanelChrome.width
    static let listWidth: CGFloat = 310
    static let fieldHeight = PanelChrome.fieldHeight
    static let footerHeight: CGFloat = 30
    static let height: CGFloat = 470
    static let recentLimit = 400
    /// Meaning results replace word results no sooner than this after the keystroke, so they don't reshuffle the list
    /// while you type, and the next keystroke cancels them instead of waiting behind their ~25 ms of layout.
    static let typingPause: Duration = .milliseconds(100)
    /// Results shown at most: about six screenfuls of the list, more than anyone scrolls, and each one costs every
    /// keystroke its layout (80 cost a long history ~35 ms a keystroke).
    static let resultLimit = 50
    /// Typing that finds nothing keeps the results before it up (dimmed) until it pauses this long: a sentence's words
    /// cut short mean nothing yet, and "No matches" blinked in on nearly every letter of one.
    static let emptyHold: Duration = .milliseconds(600)

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var sections: [PanelSection] = []
    private(set) var selection: Int64?
    private(set) var phase = PanelPhase.recent
    /// The rows are an earlier search's, kept (dimmed) while the typing since found nothing; see `set`.
    private(set) var stale = false
    /// The words the rows were found for, which they and the preview mark ("" for the history).
    private(set) var shownWords = ""
    private(set) var mode = PanelMode.history {
        didSet { if mode != .snippets { snippetFolder = nil } }   // the snippets open at the top again
    }
    /// The snippets mode's list: folders and snippets matching the query (see `Snippet.rows`).
    private(set) var snippetRows: [SnippetRow] = []
    private(set) var snippetSelection: SnippetRow.ID?
    /// The folder open in the snippets; nil: the top, with the folders.
    private(set) var snippetFolder: Int64?
    /// The snippet whose name gets the cursor when its editor appears (a new one).
    var focusTitleOf: Int64?
    /// The same for a new folder's name.
    var focusFolderNameOf: Int64?
    /// Quick Look has the selected clip's picture out: the preview pane leaves its place empty.
    private(set) var lifted = false
    /// Of several copied files, the one whose picture Quick Look has out (its path).
    private(set) var liftedFile: String?
    /// Meaning results are taking a moment (the model busy with a backlog): the spinner. Not for the usual 50 ms, where
    /// it only flickered on every keystroke.
    private(set) var searching = false
    private(set) var note: String?
    /// Bumped when anything the footer shows may have changed (model state, backlog).
    private(set) var statusVersion = 0
    /// Bumped on every new result set, so the list scrolls back to the top.
    private(set) var resultsVersion = 0

    @ObservationIgnored unowned let app: AppController
    /// The window it shares with search (`PanelHost`): the clipboard history is one of its modes.
    @ObservationIgnored private let host: PanelHost
    private var window: PanelWindow? { host.window }
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored weak var symbolView: SymbolLayerView?
    @ObservationIgnored weak var placeholderView: PlaceholderView?
    @ObservationIgnored let quickLook = QuickLook()
    /// The selected clip's picture in the preview pane (or its first file's icon), where Quick Look zooms from.
    @ObservationIgnored let pictureAnchor = ScreenAnchor()
    /// Several copied files: each one's picture in the pane's grid, by path.
    @ObservationIgnored private var fileAnchors: [String: ScreenAnchor] = [:]

    func fileAnchor(_ path: String) -> ScreenAnchor {
        if let anchor = fileAnchors[path] { return anchor }
        if fileAnchors.count > 400 { fileAnchors = [:] }
        let anchor = ScreenAnchor()
        fileAnchors[path] = anchor
        return anchor
    }

    /// The pane shows the selected clip's files as a grid (several of them), each with an anchor of its own.
    private var showsFileGrid: Bool { (selectedClip?.fileURLs.count ?? 0) > 1 }

    /// The files Quick Look shows, in its order (those still there): the item at `index`.
    private func quickLookFile(_ index: Int) -> URL? {
        let urls = QuickLook.items(for: selectedClip).compactMap(\.previewItemURL)
        return urls.indices.contains(index) ? urls[index] : nil
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var meaningTask: Task<Void, Never>?
    /// What the history was last searched for (trimmed), and its search while it waits for the next frame.
    @ObservationIgnored private var pendingSearch: DispatchWorkItem?
    @ObservationIgnored private var searchedText: String?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    /// When the query last changed; what typing that found nothing will show once it pauses, and the wait for that.
    @ObservationIgnored private var typedAt = ContinuousClock.now
    @ObservationIgnored private var held: (sections: [PanelSection], phase: PanelPhase, keepSelection: Bool)?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    /// Turning into search: search takes the keyboard before this goes, and losing it mustn't close this early.
    @ObservationIgnored private var handingOver = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private let shiftTap = ShiftTap()
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// ↑/↓ moved the selection since the last keystroke: new results keep it instead of jumping to the top.
    @ObservationIgnored private var navigated = false
    /// Bumped by every switch and by hide(), so a transition that's overtaken doesn't finish.
    @ObservationIgnored private var transition = 0
    /// Bumped each time it opens (the options button shows for a moment then).
    private(set) var opened = 0
    /// It opened out of search (the options button stays away then, unless the pointer's over it).
    private(set) var openedQuietly = false
    @ObservationIgnored private let frameAnimator = WindowFrameAnimator()
    @ObservationIgnored private var stack: PanelStack?

    init(app: AppController, host: PanelHost) {
        self.app = app
        self.host = host
        // Built and drawn once now, invisibly, so the first hotkey press shows it at once (the first layout and draw
        // cost ~150 ms; later ones ~15).
        makeStack()
        let window = host.window
        DispatchQueue.main.async { [weak self] in
            guard let self, !window.isVisible else { return }
            host.show(.clipboard)
            self.showRecent()
            window.setFrame(PanelChrome.frame(NSSize(width: Self.width, height: Self.height), at: PanelChrome.topCenter()),
                            display: false)
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.displayIfNeeded()
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }

    /// Up, as the clipboard history (not as search, in the same window).
    var isVisible: Bool { host.isShowing(.clipboard) }
    var windowNumber: Int? { window?.windowNumber }
    /// The sections' rows in order, kept with them: views ask for it per row, and flattening the sections each time
    /// made a redraw quadratic in the list's length (measured 2026-10-14).
    private(set) var rows: [PanelRow] = []
    /// ⌘1…⌘9 for the first nine rows.
    private(set) var shortcuts: [Int64: Int] = [:]
    var selectedClip: Clip? { rows.first { $0.id == selection }?.clip }
    var canPaste: Bool { Paster.canPaste || DebugHooks.enabled }
    var hotkeyDisplay: String { app.hotkeyDisplay(.clipboard) }
    static let placeholder = "Search your clipboard: words or what it's about…"
    var placeholder: String {
        guard mode == .snippets else { return Self.placeholder }
        return openFolder.map { "Search “\($0.name)”" } ?? "Search snippets"
    }
    /// The sparkle all through a meaning search (word results first, then meaning: it flickered per keystroke).
    var symbol: String {
        if mode == .snippets { return snippetFolder == nil ? "text.quote" : "folder" }
        return phase == .meaning || phase == .words ? "sparkle.magnifyingglass" : "list.clipboard"
    }
    var selectedSnippet: Snippet? { snippetRows.first { $0.id == snippetSelection }?.snippet }
    var selectedFolder: SnippetFolder? { snippetRows.first { $0.id == snippetSelection }?.folder }
    var openFolder: SnippetFolder? { snippetFolder.flatMap { id in app.snippetFolders.first { $0.id == id } } }

    /// The first nine rows, for ⌘1…⌘9.

    // MARK: Showing

    func toggle() {
        isVisible ? hide() : show()
    }

    /// `query`: what was typed in search when it switched here. `topCenter`: the middle of search's field's top edge,
    /// so this one's field takes its place. `growingFrom`: search's size then: the window grows (wider, and taller)
    /// from it, and the body comes in. `fromSymbol`, `fromPlaceholder`: search's, which turn into this one's.
    func show(query initial: String = "", topCenter: NSPoint? = nil, growingFrom start: NSSize? = nil,
              fromSymbol: String? = nil, fromPlaceholder: String? = nil) {
        let started = Date()
        guard let window else { return }
        app.engine.wake()   // the model in, if it's out, for a search
        host.show(.clipboard)   // out of search: search lets go of the window (its motion stops; this one's starts)
        transition += 1
        openedQuietly = start != nil
        opened += 1
        meaningTask?.cancel()
        mode = .history   // it opens on the history, as search opens on everything
        query = ""
        showRecent()
        resultsVersion += 1   // from the top, should it have closed without the reset in `leave` (already there: no cost)
        query = initial
        flushSearch()
        let anchor = topCenter ?? PanelChrome.topCenter()
        let full = PanelChrome.frame(NSSize(width: Self.width, height: Self.height), at: anchor)
        symbolView?.set(fromSymbol ?? symbol, animated: false)
        placeholderView?.set(fromPlaceholder ?? Self.placeholder, animated: false)
        if let start {
            stack?.setBody(visible: false)
            window.setFrame(Motion.reduced ? full : PanelChrome.frame(start, at: anchor), display: false)
        } else {
            stack?.setBody(visible: true)
            window.setFrame(full, display: false)
        }
        // No fade: it opens from the keyboard many times a day, and any animation there reads as lag.
        window.alphaValue = 1
        if start != nil {
            // Out of search, in their window: the field takes the keyboard from search's, and the body is laid out
            // and drawn, hidden, before it fades in, all before the first frame. The motion starts with that frame,
            // so they only hold it back a few ms; done a frame or two in, they cost it frames on the way, a stutter.
            window.orderFrontRegardless()   // no refreshShadow: it draws the whole window now; each step redoes the shadow
            takeKeyboard(window)
            if !Motion.reduced { frameAnimator.run(window, to: full, spring: Motion.grow) }
            symbolView?.set(symbol, animated: true)
            placeholderView?.set(Self.placeholder, animated: true)
            stack?.prepareBody()
            stack?.revealBody()
        } else {
            window.orderFrontRegardless()
            PanelChrome.refreshShadow(of: window)
            takeKeyboard(window)
        }
        if activity == nil {
            // A background app's threads drop to efficiency cores (App Nap): not while the panel is up.
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Pastemind panel open")
        }
        let shown = Date()
        DispatchQueue.main.async {
            log("panel: shown in \(ms(started, shown)), drawn by \(ms(started, Date()))")
        }
    }

    private func takeKeyboard(_ window: NSWindow) {
        window.makeKey()
        if let field {
            window.makeFirstResponder(field)
            field.stringValue = query
            field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        }
        installMonitors()
    }

    /// Quick Look let go of its controller (see `AppController`): closed by itself, its button or Esc once a click
    /// made it key; the keyboard comes back here.
    func quickLookEnded(_ panel: QLPreviewPanel) {
        quickLook.end(panel)
        if isVisible, let window, !window.isKeyWindow { window.makeKey() }
    }

    func toggleQuickLook() {
        flushSearch()
        guard let window, isVisible else { return }
        if quickLook.isVisible { return quickLook.close() }
        quickLook.show(QuickLook.items(for: selectedClip), over: window)
    }

    /// One of several copied files clicked in the pane: Quick Look, from it (the others a step away).
    func look(at url: URL) {
        flushSearch()
        guard let window, isVisible else { return }
        let items = QuickLook.items(for: selectedClip)
        guard let index = items.firstIndex(where: { $0.previewItemURL == url }) else { return }
        quickLook.show(items, over: window, at: index)
    }

    /// Where the selected clip's picture (or first file's icon) is drawn in the preview pane, on screen: Quick Look
    /// zooms out of it and back into it. Nowhere for a clip without one (the panel follows the selection onto text,
    /// and closes): it fades.
    private func previewFrame(_ index: Int) -> NSRect {
        guard let clip = selectedClip, [.image, .file, .code, .text].contains(clip.kind) else { return .zero }
        if showsFileGrid { return quickLookFile(index).flatMap { fileAnchor($0.path).frame } ?? .zero }
        return pictureAnchor.frame ?? .zero
    }

    /// Code's block (or text) in the pane, as Quick Look zooms out of it: its first lines on the text background
    /// (Quick Look's own, for text), in the block's rounded shape. A bitmap, as the picture's.
    private func textImage(_ clip: Clip) -> NSImage? {
        let code = clip.kind == .code
        guard let size = pictureAnchor.frame?.size, size.width > 0, size.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (window?.effectiveAppearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            let rect = NSRect(origin: .zero, size: size)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            NSColor.textBackgroundColor.setFill()
            shape.fill()
            shape.addClip()
            // As the pane sets each: code's lines kept whole, text wrapped.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = code ? 3 : 4
            paragraph.lineBreakMode = code ? .byClipping : .byWordWrapping
            let font = code ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13.5)
            NSAttributedString(string: String(clip.text.prefix(4_000)), attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]).draw(with: code ? rect.insetBy(dx: 12, dy: 12) : rect.insetBy(dx: 18, dy: 16),
                    options: [.usesLineFragmentOrigin])
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The selected picture as the pane shows it, with the file's size in pixels (what Quick Look sizes it by), for it
    /// to fly out of the pane into Quick Look.
    private func liftPicture() -> (image: NSImage, pixels: CGSize)? {
        guard let clip = selectedClip, clip.kind == .image, let name = clip.image,
              let picture = ImageCache.shared.cached(name, pixels: Pictures.previewPixels)
                ?? ImageCache.shared.cached(name, pixels: Pictures.iconPixels) else { return nil }
        if let width = clip.width, let height = clip.height { return (picture, CGSize(width: width, height: height)) }
        let url = AppPaths.images.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (picture, CGSize(width: width, height: height))
    }

    private func previewImage(_ index: Int) -> NSImage? {
        guard let clip = selectedClip else { return nil }
        if clip.kind == .code || clip.kind == .text { return textImage(clip) }
        let picture: NSImage
        var frame = pictureAnchor.frame
        if showsFileGrid {
            guard let url = quickLookFile(index) else { return nil }
            picture = Thumbnails.shared.cached(url.path, side: Thumbnails.gridSide) ?? Icons.file(url)
            frame = fileAnchor(url.path).frame
        } else if let name = clip.image {
            guard let image = ImageCache.shared.cached(name, pixels: Pictures.previewPixels)
                    ?? ImageCache.shared.cached(name, pixels: Pictures.iconPixels) else { return nil }
            picture = image
        } else if let path = Thumbnails.coverPath(of: clip),
                  let image = Thumbnails.shared.cached(path, side: Thumbnails.coverSide) {
            picture = image   // a file's cover (a document's page, a video's frame), as the pane shows it
        } else {
            return clip.fileURLs.first.map(Icons.file)
        }
        guard let size = frame?.size, let source = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return picture }
        // With the pane's rounded corners, so the zoom starts from what was there and lands as it will be. A bitmap:
        // Quick Look draws one drawn on demand as a black box.
        let scale = window?.backingScaleFactor ?? 2
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return picture }
        context.scaleBy(x: scale, y: scale)
        let rect = CGRect(origin: .zero, size: size)
        context.addPath(ClipPreview.pictureShape.path(in: rect).cgPath)
        context.clip()
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        return context.makeImage().map { NSImage(cgImage: $0, size: size) } ?? picture
    }

    func hide() {
        let showing = host.mode == .clipboard
        let wasHandingOver = handingOver
        leave()
        if showing { window?.orderOut(nil) }
        if wasHandingOver { app.historyHid() }
    }

    /// Gone, or search took the window: the keys, the motion, Quick Look let go of (the window stays for search).
    private func leave() {
        quickLook.close(zooming: false)
        let switched = window?.isVisible == true && host.mode != .clipboard
        handingOver = false
        transition += 1
        frameAnimator.stop()
        removeMonitors()
        meaningTask?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        // Back to the history now, while nobody's looking, and laid out: the next show opens on it, and turning a
        // long list of results back into it there cost the show ~60 ms with a long history (measured 2026-10-14).
        // Turned into search, once search has settled: right away (10 to 13 ms with results) it held up search's motion.
        let token = transition
        DispatchQueue.main.asyncAfter(deadline: .now() + (switched ? 0.45 : 0)) { [weak self] in
            guard let self, token == self.transition, !self.isVisible else { return }
            self.mode = .history
            self.query = ""
            self.flushSearch()
            self.showRecent()
            self.resultsVersion += 1   // scrolled to the top here too, so the next show has no rows to lay out for it
            self.stack?.layoutSubtreeIfNeeded()
        }
    }

    /// On the way to search: the body fades, the window folds up to the field, then `done` (which shows search in its
    /// place, in their window). Overtaken by another switch or a hide, it doesn't call `done`.
    /// `height` and `symbol`: search's, for the query it's about to show, so the history turns straight into it
    /// (its symbol too) instead of folding up to a capsule for search to open again. Once the body has faded, `done`
    /// gets the motion under way, for search to take over and carry on.
    func collapse(toHeight height: CGFloat, symbol: String, placeholder: String,
                  then done: @escaping (WindowMotion?) -> Void) {
        guard let window, isVisible else { return done(nil) }
        transition += 1
        let token = transition
        handingOver = true
        stack?.fadeOutBody()
        symbolView?.set(symbol, animated: true)
        placeholderView?.set(placeholder, animated: true)
        if Motion.reduced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, token == self.transition else { return }
                done(nil)
            }
            return
        }
        let target = NSRect(x: (window.frame.midX - PanelChrome.searchWidth / 2).rounded(),
                            y: window.frame.maxY - height, width: PanelChrome.searchWidth, height: height)
        frameAnimator.run(window, to: target, spring: Motion.shrink)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.fadeOut) { [weak self] in
            guard let self, token == self.transition else { return }
            done(self.frameAnimator.motion(of: window))
        }
    }


    /// The history changed (a copy, a paste, a delete): the list follows if it's showing the history.
    func historyChanged() {
        guard isVisible else { return }
        if phase == .recent {
            showRecent(keepSelection: true)
        } else {
            refresh()
        }
        statusChanged()
    }

    func statusChanged() {
        statusVersion += 1
    }

    // MARK: Searching

    private func showRecent(keepSelection: Bool = false) {
        let clips = app.index.clips
        let pinned = clips.filter(\.pinned).map { PanelRow(clip: $0) }
        let recent = clips.lazy.filter { !$0.pinned }.prefix(Self.recentLimit).map { PanelRow(clip: $0) }
        var sections: [PanelSection] = []
        if !pinned.isEmpty { sections.append(PanelSection(id: "pinned", title: "Pinned", rows: pinned)) }
        sections.append(PanelSection(id: "recent", title: pinned.isEmpty ? nil : "Recent", rows: Array(recent),
                                     incoming: app.incoming))
        set(sections, phase: .recent, keepSelection: keepSelection)
    }

    private func queryChanged() {
        typedAt = .now
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A space typed (or taken off) at the end: the same search, shown already or on its way. Doing it again put
        // the cached meaning results in at once on every space, a whole new list mid-typing (30–60 ms). Meaning
        // results still on their way wait for a pause in the typing all the same.
        if mode == .history, text == searchedText {
            if phase == .words { scheduleMeaning(text) }
            return
        }
        generation += 1
        navigated = false
        meaningTask?.cancel()
        if mode == .snippets { return showSnippets() }
        searchedText = text
        // The letter shows first, the list a frame later: its layout (10–50 ms with a long history) held the letter
        // back until it was done. Typing faster than that lays the list out once for several letters.
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search(text) }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    /// A search still waiting for its frame runs now: a key right after a letter (↩, ↓, ⌘1) acts on its results.
    private func flushSearch() {
        if let work = pendingSearch {
            work.cancel()
            pendingSearch = nil
            search(searchedText ?? "")
        }
        // A key acting on the results acts on the ones for what's typed, none if that found none: not on rows kept
        // from before it.
        releaseHeld()
    }

    private func search(_ text: String) {
        pendingSearch = nil
        guard !text.isEmpty else {
            showRecent()
            return
        }
        // "Image:", "Files: invoice": that kind only, the words after it searched among them.
        let (kinds, words) = ClipKind.filter(in: text)
        if let kinds, words.isEmpty {   // a kind alone: the latest of it
            let rows = app.index.clips.lazy.filter { $0.isKept(by: kinds) }.prefix(Self.recentLimit)
                .map { PanelRow(clip: $0) }
            set([PanelSection(id: "results", title: nil, rows: Array(rows))], phase: .wordsOnly, keepSelection: navigated)
            return
        }
        let started = Date()
        // Meaning search needs a few letters to mean anything; one or two are a word prefix.
        let wantsMeaning = words.count >= 3 && app.modelState == .ready
        if wantsMeaning, let vector = app.engine.cachedQuery(words) {
            show(only(kinds, app.index.search(words, vector: vector, limit: limit(kinds))), phase: .meaning)
            log("search \"\(text)\": cached meaning in \(ms(started, Date()))")
            return
        }
        show(only(kinds, app.index.search(words, limit: limit(kinds))), phase: wantsMeaning ? .words : .wordsOnly)
        if wantsMeaning { scheduleMeaning(text) }
    }

    /// Kept to one kind, the search goes deeper first (the others would fill the results), then down to the usual.
    private func limit(_ kinds: Set<ClipKind>?) -> Int { kinds == nil ? Self.resultLimit : Self.recentLimit }

    private func only(_ kinds: Set<ClipKind>?, _ results: [SearchResult]) -> [SearchResult] {
        guard let kinds else { return results }
        return Array(results.lazy.filter { $0.clip.isKept(by: kinds) }.prefix(Self.resultLimit))
    }

    /// What's typed without a kind filter ("Image: roadmap" → "roadmap"): the words the rows and the preview mark.
    var searchWords: String { ClipKind.filter(in: query).words }

    /// The meaning results for `text`, in place of the word results once the typing pauses.
    private func scheduleMeaning(_ text: String) {
        generation += 1
        let current = generation
        meaningTask?.cancel()
        let started = Date()
        let showAt = ContinuousClock.now + Self.typingPause
        let (kinds, words) = ClipKind.filter(in: text)
        meaningTask = Task {
            let vector = await app.engine.query(words)
            guard !Task.isCancelled, current == generation, let vector else { return }
            let embedded = Date()
            // The search (~5 ms with a long history, on this thread) once the typing pauses: searched before, it was
            // thrown away by nearly every next keystroke, and cost each one its time.
            try? await Task.sleep(until: showAt, tolerance: .milliseconds(2), clock: .continuous)
            // Not in the middle of the switch from search: a list update there costs it frames.
            while frameAnimator.isRunning, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            guard !Task.isCancelled, current == generation else { return }
            let results = only(kinds, app.index.search(words, vector: vector, limit: limit(kinds)))
            show(results, phase: .meaning)
            log("search \"\(text)\": embed \(ms(started, embedded)), \(results.count) results by \(ms(started, Date()))")
        }
    }

    /// The current query again, against the changed history (keeping the selection).
    private func refresh() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let vector = phase == .meaning ? app.engine.cachedQuery(text) : nil
        set([PanelSection(id: "results", title: nil, rows: rows(app.index.search(text, vector: vector, limit: Self.resultLimit)))],
            phase: phase, keepSelection: true)
    }

    private func show(_ results: [SearchResult], phase: PanelPhase) {
        set([PanelSection(id: "results", title: nil, rows: rows(results))], phase: phase, keepSelection: navigated)
    }

    private func rows(_ results: [SearchResult]) -> [PanelRow] {
        results.map { result in
            let urls = result.clip.copiedURLs
            // Which of several files matched (one file's pieces aren't files).
            let file = result.file.flatMap { urls.count > 1 && urls.indices.contains($0) ? urls[$0].lastPathComponent : nil }
            return PanelRow(clip: result.clip, weak: !result.strong, words: result.words, file: file)
        }
    }

    /// What typing shows: its results, or, when they're none while the typing goes on, the rows already there,
    /// dimmed, until it pauses (then "No matches"). Typed letter by letter, a sentence finds nothing until its last
    /// words are whole, and the list emptied and "No matches" blinked in on nearly every letter.
    private func set(_ sections: [PanelSection], phase: PanelPhase, keepSelection: Bool) {
        guard phase != .recent, !rows.isEmpty, sections.allSatisfy(\.rows.isEmpty),
              ContinuousClock.now < typedAt + Self.emptyHold else {
            return apply(sections, phase: phase, keepSelection: keepSelection)
        }
        held = (sections, phase, keepSelection)
        if !stale { withAnimation(.easeOut(duration: 0.12)) { stale = true } }
        if phase != self.phase { self.phase = phase }
        updateSpinner()
        guard releaseTask == nil else { return }
        releaseTask = Task { [weak self] in
            // Each keystroke since moves the pause further out.
            while !Task.isCancelled, let due = self.map({ $0.typedAt + Self.emptyHold }), ContinuousClock.now < due {
                try? await Task.sleep(until: due, tolerance: .milliseconds(10), clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            self?.releaseHeld()
        }
    }

    /// What typing that found nothing held back, shown now.
    private func releaseHeld() {
        guard let held else { return }
        apply(held.sections, phase: held.phase, keepSelection: held.keepSelection)
    }

    /// Assigns only what changed: each assignment re-renders the panel, and the meaning results are often the word
    /// results again.
    private func apply(_ sections: [PanelSection], phase: PanelPhase, keepSelection: Bool) {
        held = nil
        releaseTask?.cancel()
        releaseTask = nil
        if stale { stale = false }
        let words = phase == .recent ? "" : searchWords
        if words != shownWords { shownWords = words }
        let previous = selection
        let changed = sections != self.sections
        if changed {
            self.sections = sections
            rows = sections.flatMap(\.rows)
            shortcuts = Dictionary(uniqueKeysWithValues: rows.prefix(9).enumerated().map { ($1.id, $0 + 1) })
        }
        if phase != self.phase { self.phase = phase }
        let ids = rows.map(\.id)
        if !(keepSelection && previous.map(ids.contains) == true) {
            if selection != ids.first { selection = ids.first }
            if changed { resultsVersion += 1 }
        }
        updateSpinner()
        selectionChanged()
    }

    /// Debug runs: the spinner up or not, to look at.
    func debugSpinner(_ on: Bool) { searching = on }

    private func updateSpinner() {
        guard phase == .words else {
            spinnerTask?.cancel()
            spinnerTask = nil
            if searching { searching = false }
            return
        }
        guard spinnerTask == nil, !searching else { return }
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, self.phase == .words else { return }
            self.searching = true
            self.spinnerTask = nil
        }
    }

    // MARK: Keys

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.window else { return event }
            self.shiftTap.cancel()
            // Turning into search: what's typed is search's (its field, set up underneath), Esc closes; nothing else
            // acts on the history going (↩ pasted a clip).
            if self.handingOver, event.keyCode != 53 {
                self.app.typeDuringSwitch(event)
                return nil
            }
            return self.handle(event) ? nil : event
        }
        shiftTap.start(in: { [weak self] in self?.window }) { [weak self] in self?.shiftTapped() }
        // Clicking anywhere else (or ⌘Tab) takes the key away: the panel goes, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.handingOver, !self.dragging else { return }
                // Quick Look's preview loading took the focus: it comes back.
                if self.quickLook.tookFocus() {
                    DispatchQueue.main.async { self.window?.makeKey() }
                    return
                }
                // Clicking into Quick Look keeps the history up (the new key window is known a moment later).
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

    /// A tap of ⇧: Quick Look, or closes it. In the history, not while writing a snippet, nor while an input method is
    /// composing (some switch modes on a ⇧ tap).
    private func shiftTapped() {
        guard mode == .history, !editingSnippet, (field?.currentEditor() as? NSTextView)?.hasMarkedText() != true
        else { return }
        toggleQuickLook()
    }

    /// True when the key was handled here (it then doesn't reach the search field).
    private func handle(_ event: NSEvent) -> Bool {
        // An input method is composing (Japanese, Chinese…): its keys until it's done.
        if (field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection(KeyModifiers.relevant)
        // Writing a snippet: its keys are the editor's (↩ a new line, ⇥ on to the text); Esc back to the search.
        if editingSnippet {
            guard event.keyCode == 53 else { return false }
            if let field { window?.makeFirstResponder(field) }
            return true
        }
        let snippets = mode == .snippets
        switch Int(event.keyCode) {
        case 53:  // Esc: closes Quick Look, then a folder, then the panel (⇥ leaves the snippets); what's typed stays
            if quickLook.isVisible {
                quickLook.close()
            } else if snippets, snippetFolder != nil {
                closeFolder()
            } else {
                hide()
            }
            return true
        case 48 where modifiers.isEmpty || modifiers == .shift:  // ⇥: the snippets, and back
            toggleSnippets()
            return true
        case 45 where modifiers == .command:  // ⌘N: a new snippet (in the open folder)
            newSnippet()
            return true
        case 45 where modifiers == [.command, .shift]:  // ⇧⌘N: a new folder of snippets
            newFolder()
            return true
        case 124 where snippets && modifiers.isEmpty:  // →: into the selected folder (the cursor at the end)
            guard let folder = selectedFolder, caretAtEnd else { return false }
            openFolder(folder)
            return true
        case 123 where snippets && modifiers.isEmpty, 51 where snippets && modifiers.isEmpty:  // ← ⌫: out of it
            guard snippetFolder != nil, query.isEmpty else { return false }
            closeFolder()
            return true
        case 1 where modifiers == .command && !snippets:  // ⌘S: the clip, kept as a snippet
            saveAsSnippet()
            return true
        case 49 where modifiers.isEmpty:  // Space: typed, and closes Quick Look (a tap of ⇧ or ⌘Y opens it)
            // Never a leading space: it searched for nothing, and looked like an empty field that wasn't.
            guard !snippets, quickLook.isVisible else { return query.isEmpty }
            quickLook.close()
            return true
        case 16 where modifiers == .command && !snippets:  // ⌘Y: Quick Look, as in Finder (or a tap of ⇧)
            // Once a press: held, the key repeats, and each repeat toggled it again.
            if !event.isARepeat { toggleQuickLook() }
            return true
        case 123 where !snippets && modifiers.isEmpty && quickLook.showsSeveral,
             124 where !snippets && modifiers.isEmpty && quickLook.showsSeveral:  // ← →: Quick Look's files
            quickLook.step(by: event.keyCode == 124 ? 1 : -1)
            return true
        case 125 where snippets && modifiers == [.command, .option],
             126 where snippets && modifiers == [.command, .option]:  // ⌥⌘↓ ⌥⌘↑: the selected one down or up a place
            moveSelectedSnippetRow(by: event.keyCode == 125 ? 1 : -1)
            return true
        case 125 where snippets, 126 where snippets:  // ↓ ↑ through the snippets
            guard modifiers.isEmpty || modifiers == .command else { return false }
            let step = modifiers == .command ? Int.max / 2 : 1
            moveSnippetSelection(by: event.keyCode == 125 ? step : -step)
            return true
        case 125, 126:  // ↓ ↑
            if modifiers == .command {
                moveSelection(to: event.keyCode == 125 ? .max : 0)
            } else if modifiers.isEmpty {
                moveSelection(by: event.keyCode == 125 ? 1 : -1)
            } else {
                return false
            }
            return true
        case 121, 116:  // page down / up
            if snippets { moveSnippetSelection(by: event.keyCode == 121 ? 8 : -8) } else {
                moveSelection(by: event.keyCode == 121 ? 8 : -8)
            }
            return true
        case 36 where snippets && selectedFolder != nil, 76 where snippets && selectedFolder != nil:  // ↩ opens it
            guard modifiers.isEmpty, let folder = selectedFolder else { return false }
            openFolder(folder)
            return true
        case 36, 76:  // ↩
            switch modifiers {
            case []: paste(plain: false)
            case .shift: paste(plain: true)
            case .command: copyOnly()
            default: return false
            }
            return true
        case 35 where modifiers == .command && !snippets:  // ⌘P
            flushSearch()
            if let clip = selectedClip { app.togglePin(clip) }
            return true
        case let code where modifiers == .command && Self.numberKeys[code] != nil:  // ⌘1…⌘9
            flushSearch()
            let number = Self.numberKeys[code]!
            let numbered = snippetRows.compactMap(\.snippet)   // folders aren't numbered
            if snippets, number <= numbered.count {
                snippetSelection = .snippet(numbered[number - 1].id)
                paste(plain: false)
            } else if !snippets, number <= rows.count {
                selection = rows[number - 1].id
                paste(plain: false)
            }
            return true
        case 8 where modifiers == .command:  // ⌘C: the preview's selection, or Quick Look's; else the field's, via the window
            return copyPreviewSelection() || quickLook.copySelection()
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

    /// Key codes of 1…9 on the main row (kVK_ANSI_1…9 aren't in order).
    private static let numberKeys: [Int: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    func moveSelection(by step: Int) {
        flushSearch()
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
        selectionChanged()
    }

    private func moveSelection(to index: Int) {
        flushSearch()
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        selection = ids[max(0, min(ids.count - 1, index))]
        navigated = true
        selectionChanged()
    }

    /// Quick Look follows the selection; the pictures next to it get decoded before ↑/↓ gets there.
    private func selectionChanged() {
        quickLook.follow(QuickLook.items(for: selectedClip))
        prefetchPreviews()
    }

    /// The previews of the pictures next to the selection, decoded before ↑/↓ gets there.
    private func prefetchPreviews() {
        let rows = rows
        guard let index = rows.firstIndex(where: { $0.id == selection }) else { return }
        let near = rows[max(0, index - 2)...min(rows.count - 1, index + 2)]
        ImageCache.shared.prefetch(near.compactMap(\.clip.image), pixels: Pictures.previewPixels)
    }

    func select(_ id: Int64) {
        flushSearch()
        selection = id
        navigated = true
        selectionChanged()
    }

    // MARK: Actions

    /// ↩: onto the pasteboard and into the app you were in. Without Accessibility access it's copied, and macOS is
    /// asked for that access.
    func paste(plain: Bool) {
        flushSearch()
        if mode == .snippets {
            guard let snippet = selectedSnippet else { return }
            app.copy(snippet)
        } else {
            guard let clip = selectedClip else { return }
            app.copy(clip, plain: plain)
        }
        guard Paster.canPaste || DebugHooks.enabled else {
            // It's on the clipboard; macOS asks (once) to let Pastemind press ⌘V from now on.
            Paster.requestAccess()
            hide()
            return
        }
        hide()
        // The app you came from gets the key back as the panel goes; ⌘V once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { Paster.pressCommandV() }
    }

    /// What's selected in the preview's text (a picture's text, a part of a clip), on the clipboard: false when nothing is.
    @discardableResult
    func copyPreviewSelection() -> Bool {
        guard let text = window?.firstResponder as? NSTextView, !text.isEditable, text !== field?.currentEditor()
        else { return false }
        let string = text.string as NSString
        let parts = text.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map { string.substring(with: $0) }
        guard !parts.isEmpty else { return false }
        let pasteboard = Pasteboards.main
        pasteboard.clearContents()
        pasteboard.setString(parts.joined(separator: "\n"), forType: .string)
        flash("Copied")
        return true
    }

    private func copyOnly() {
        flushSearch()
        if mode == .snippets {
            guard let snippet = selectedSnippet else { return }
            app.copy(snippet)
        } else {
            guard let clip = selectedClip else { return }
            app.copy(clip, plain: false)
        }
        hide()
    }

    // MARK: Snippets

    /// ⇥: the snippets, or back to the history, with what's typed.
    func toggleSnippets() {
        flushSearch()
        quickLook.close(zooming: false)   // the pane is going to the snippets
        mode = mode == .snippets ? .history : .snippets
        if mode == .snippets {
            showSnippets()
        } else {
            queryChanged()
        }
        statusChanged()
    }

    /// The first snippet selected (↩ pastes it at once), below the folders; a folder if there's no snippet.
    private func showSnippets(keepSelection: Bool = false) {
        snippetRows = Snippet.rows(query, in: snippetFolder, snippets: app.snippets, folders: app.snippetFolders)
        if !(keepSelection && snippetRows.contains { $0.id == snippetSelection }) {
            snippetSelection = (snippetRows.first { $0.snippet != nil } ?? snippetRows.first)?.id
            resultsVersion += 1
        }
    }

    func selectSnippet(_ id: SnippetRow.ID) {
        snippetSelection = id
        navigated = true
    }

    /// ↩ or → on a folder (a double click): its snippets alone, the field searching them.
    func openFolder(_ folder: SnippetFolder) {
        snippetFolder = folder.id
        query = ""
        showSnippets()
        statusChanged()
    }

    /// Esc, ← or ⌫ in a folder: back to the top, on the folder.
    func closeFolder() {
        guard let folder = snippetFolder else { return }
        snippetFolder = nil
        query = ""
        showSnippets()
        snippetSelection = .folder(folder)
        statusChanged()
    }

    /// The field's cursor at the end of what's typed (→ there goes into a folder rather than moving it).
    private var caretAtEnd: Bool {
        guard let editor = field?.currentEditor() else { return true }
        let range = editor.selectedRange
        return range.length == 0 && range.location == (editor.string as NSString).length
    }

    private func moveSnippetSelection(by step: Int) {
        let ids = snippetRows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = snippetSelection.flatMap { ids.firstIndex(of: $0) } ?? -1
        snippetSelection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
    }

    /// ⌘N: a new snippet, named after what's typed (if anything), the cursor in its name.
    func newSnippet() {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = mode == .snippets ? snippetFolder : nil
        guard let snippet = app.addSnippet(title: typed, text: "", folder: folder) else { return }
        if mode != .snippets { mode = .snippets }
        query = ""
        showSnippets()
        snippetSelection = .snippet(snippet.id)
        focusTitleOf = snippet.id
        statusChanged()
    }

    /// ⇧⌘N: a new folder at the top, named after what's typed (or "New Folder"), the cursor in its name.
    func newFolder() {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder = app.addSnippetFolder(name: typed.isEmpty ? "New Folder" : typed) else { return }
        if mode != .snippets { mode = .snippets }
        snippetFolder = nil
        query = ""
        showSnippets()
        snippetSelection = .folder(folder.id)
        focusFolderNameOf = folder.id
        statusChanged()
    }

    /// Into `folder` (nil: out of any): gone from the list when that's not where it shows, the next one selected.
    func moveSnippet(_ snippet: Snippet, to folder: Int64?) {
        guard var moved = app.snippets.first(where: { $0.id == snippet.id }), moved.folder != folder else { return }
        moved.folder = folder
        moved.position = app.firstSnippetPosition   // first in the folder it goes to
        let index = snippetRows.firstIndex { $0.id == .snippet(snippet.id) } ?? 0
        app.updateSnippet(moved)
        showSnippets(keepSelection: true)
        if !snippetRows.contains(where: { $0.id == .snippet(snippet.id) }) {
            let next = snippetRows.indices.contains(index) ? snippetRows[index] : snippetRows.last
            snippetSelection = next?.id
        }
        let name = folder.flatMap { id in app.snippetFolders.first { $0.id == id }?.name }
        flash(name.map { "Moved to “\($0)”" } ?? "Moved out of the folder")
    }

    /// The rows one dragged within the list goes among: the folders, or the snippets (side by side, each kind in an
    /// order of its own). None while something's typed: the order is the match's then.
    func reorderRange(for row: Int) -> Range<Int>? {
        guard mode == .snippets, query.trimmingCharacters(in: .whitespaces).isEmpty, snippetRows.indices.contains(row)
        else { return nil }
        let folder = snippetRows[row].folder != nil
        let kind = snippetRows.indices.filter { (snippetRows[$0].folder != nil) == folder }
        guard let first = kind.first, let last = kind.last else { return nil }
        return first..<(last + 1)
    }

    /// Dropped at `index` (between rows: 0 above the first), or moved there by ⌥⌘↑ ⌥⌘↓: the new order kept.
    func moveSnippetRow(_ row: Int, to index: Int) {
        guard let range = reorderRange(for: row) else { return }
        let target = min(max(index, range.lowerBound), range.upperBound)
        guard target != row, target != row + 1 else { return }   // where it is
        let moved = snippetRows[row].id
        var ids = snippetRows[range].map(\.id)
        ids.remove(at: row - range.lowerBound)
        ids.insert(moved, at: (target > row ? target - 1 : target) - range.lowerBound)
        if case .folder = moved {
            app.orderSnippetFolders(ids.compactMap { if case .folder(let id) = $0 { id } else { nil } })
        } else {
            app.orderSnippets(ids.compactMap { if case .snippet(let id) = $0 { id } else { nil } })
        }
        showSnippets(keepSelection: true)
        snippetSelection = moved
    }

    /// ⌥⌘↑ ⌥⌘↓: the selected snippet or folder a place up or down.
    private func moveSelectedSnippetRow(by step: Int) {
        guard let row = snippetRows.firstIndex(where: { $0.id == snippetSelection }) else { return }
        moveSnippetRow(row, to: step > 0 ? row + 2 : row - 1)
    }

    /// Its editor renamed it.
    func renameFolder(_ folder: SnippetFolder) {
        app.renameSnippetFolder(folder)
        if let index = snippetRows.firstIndex(where: { $0.id == .folder(folder.id) }),
           case .folder(_, let count) = snippetRows[index] {
            snippetRows[index] = .folder(folder, count: count)
        }
    }

    /// Its snippets stay, at the top.
    func deleteFolder(_ folder: SnippetFolder) {
        app.deleteSnippetFolder(folder)
        showSnippets()
        flash("Folder deleted · its snippets are here")
        focusSearch()
    }

    /// The cursor back in the search field (from an editor).
    func focusSearch() {
        if let field { window?.makeFirstResponder(field) }
    }

    // MARK: Dragging out

    /// A clip's being dragged out: the panel stays though another app may take the key meanwhile.
    @ObservationIgnored private var dragging = false

    func dragBegan() { dragging = true }

    /// Dropped where it was taken, it counts as pasted (the newest copy, at the top; a snippet once more pasted) and
    /// the panel goes, as after a paste; not, it stays (taking the key back). What was dragged is what's selected: a
    /// row selects as the button goes down, and the preview is the selected clip's.
    func dragEnded(dropped: Bool) {
        dragging = false
        if dropped {
            if mode == .snippets {
                if let snippet = selectedSnippet { app.markUsed(snippet) }
            } else if let clip = selectedClip {
                app.markUsed(clip)
            }
            hide()
        } else if isVisible, window?.isKeyWindow != true {
            window?.makeKey()
        }
    }

    /// ⌘S: the selected clip, kept as a snippet.
    func saveAsSnippet() {
        flushSearch()
        guard let clip = selectedClip else { return }
        guard clip.kind != .image, clip.kind != .file else { return flash("Only text can be a snippet") }
        guard app.addSnippet(title: Snippet.title(for: clip.text), text: clip.text) != nil else { return }
        flash("Saved as a snippet · ⇥ for snippets")
    }

    /// The editor changed its name or text: kept, and the list shows the new name (in place: the list doesn't reorder
    /// as you type). Its folder stays as it is now (the editor may hold it from before a move).
    func updateSnippet(_ snippet: Snippet) {
        var snippet = snippet
        snippet.folder = app.snippets.first { $0.id == snippet.id }?.folder
        app.updateSnippet(snippet)
        if let index = snippetRows.firstIndex(where: { $0.id == .snippet(snippet.id) }) {
            snippetRows[index] = .snippet(snippet)
        }
    }

    func deleteSnippet(_ snippet: Snippet) {
        let ids = snippetRows.map(\.id)
        if let index = ids.firstIndex(of: .snippet(snippet.id)) {
            snippetSelection = index + 1 < ids.count ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
        }
        app.deleteSnippet(snippet)
        snippetRows.removeAll { $0.id == .snippet(snippet.id) }
        // The folders' counts.
        snippetRows = snippetRows.map { row in
            guard case .folder(let folder, _) = row else { return row }
            return .folder(folder, count: app.snippets.filter { $0.folder == folder.id }.count)
        }
        statusChanged()
        focusSearch()
    }

    /// The cursor is in the snippet editor (its name or text), not the search field.
    private var editingSnippet: Bool {
        guard mode == .snippets, let responder = window?.firstResponder as? NSTextView else { return false }
        return responder !== field?.currentEditor()
    }

    /// How many clips clearing `range` would delete now.
    private func flash(_ text: String) {
        note = text
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            note = nil
        }
    }

    // MARK: Window

    private func makeStack() {
        let header = NSHostingView(rootView: ClipboardHeaderView(controller: self))
        let body = NSHostingView(rootView: ClipboardBodyView(controller: self))
        header.sizingOptions = []
        body.sizingOptions = []
        let stack = PanelStack(header: header, body: body, width: Self.width, height: Self.height)
        host.window.quickLook = quickLook
        quickLook.sourceFrame = { [weak self] in self?.previewFrame($0) ?? .zero }
        quickLook.transitionImage = { [weak self] in self?.previewImage($0) }
        quickLook.lifted = { [weak self] lifted, index in
            guard let self else { return }
            liftedFile = lifted && showsFileGrid ? quickLookFile(index)?.path : nil
            self.lifted = lifted
        }
        quickLook.liftPicture = { [weak self] in self?.liftPicture() }
        self.stack = stack
        host.add(stack, for: .clipboard, height: Self.height) { [weak self] in self?.leave() }
    }

    /// The window's frame while the panel is up.
    var currentFrame: NSRect? { isVisible ? window?.frame : nil }

}

/// The floating panel. It becomes key (you type into it) without activating Pastemind.
/// The modifiers a shortcut is told by: ⇧ ⌃ ⌥ ⌘. Events carry other bits besides (Caps Lock, Fn, the keypad's, and
/// some undocumented: a plain Space came with bit 29 set, missed its shortcut, and was typed).
enum KeyModifiers {
    static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
}

/// A tap of ⇧ alone, the panels' Quick Look key (Space stays a space): either ⇧ down and up again
/// within `limit`, nothing else pressed or clicked meanwhile. Its monitor sees ⇧ and clicks; the panel's key monitor
/// calls `cancel` for every key (a capital, ⇧⇥), since a key it takes reaches no other monitor.
final class ShiftTap {
    static let limit: CFTimeInterval = 0.35
    private var down: CFTimeInterval?
    private var monitor: Any?

    /// Watching `window`'s events while it's up; `tapped` on a tap.
    func start(in window: @escaping () -> NSWindow?, tapped: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let window = window(), window.isVisible, event.window === window else { return event }
            if event.type != .flagsChanged {
                self.down = nil
            } else if self.changed(event) {
                tapped()
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        down = nil
    }

    func cancel() { down = nil }

    /// A modifier went down or up: true when that was ⇧ coming up from a tap.
    private func changed(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(KeyModifiers.relevant)
        let isShift = event.keyCode == 56 || event.keyCode == 60   // left, right
        if isShift, modifiers == .shift {
            down = CACurrentMediaTime()
            return false
        }
        defer { self.down = nil }
        guard isShift, modifiers.isEmpty, let pressed = down else { return false }
        return CACurrentMediaTime() - pressed < Self.limit
    }
}

final class PanelWindow: NSPanel {
    /// The clipboard history's: Quick Look finds its controller in the key window's responder chain.
    weak var quickLook: QuickLook?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The edit keys, by key (any layout: ⌘C is the C key, whatever letter it types), to whatever text has the keyboard (the
    /// field, the preview's text, a snippet): Pastemind has no menu bar, so no Edit menu to make actions of them.
    private static let editKeys: [UInt16: (NSEvent.ModifierFlags, Selector)] = [
        8: (.command, #selector(NSText.copy(_:))), 9: (.command, #selector(NSText.paste(_:))),
        7: (.command, #selector(NSText.cut(_:))), 0: (.command, #selector(NSText.selectAll(_:))),
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(KeyModifiers.relevant)
        if let (wanted, action) = Self.editKeys[event.keyCode], modifiers == wanted, enables(action),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        if event.keyCode == 6, modifiers == .command || modifiers == [.command, .shift],   // ⌘Z, ⇧⌘Z
           NSApp.sendAction(modifiers == .command ? Selector(("undo:")) : Selector(("redo:")), to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether an Edit menu's item for the action would be enabled: one sent without asking is taken anyway, and a
    /// text's copy with nothing selected empties the clipboard.
    private func enables(_ action: Selector) -> Bool {
        guard let target = NSApp.target(forAction: action, to: nil, from: self) else { return false }
        guard let validation = target as? NSMenuItemValidation else { return true }
        return validation.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

}

nonisolated func ms(_ from: Date, _ to: Date) -> String {
    String(format: "%.1f ms", to.timeIntervalSince(from) * 1000)
}
