import AppKit
import QuickLookUI
import SwiftUI
import PastemindKit

/// Quick Look for the clipboard history: a tap of ⇧ (or ⌘Y) shows the selected picture or files in the system's
/// preview panel, zooming out of the preview pane. The history keeps the keyboard (it never activates Pastemind, so a
/// paste still lands in the app you were in) and drives the panel: ↑/↓ move it along, ←/→ go through several copied
/// files, ⇧, Space or Esc close it. Search has one of its own, for the selected file, zooming out of its row's icon.
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// A file to show, with the title the panel puts over it. Quick Look reads it off the main thread.
    nonisolated final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(_ url: URL, title: String? = nil) {
            previewItemURL = url
            previewItemTitle = title
        }
    }

    private var items: [Item] = []
    /// The item shown first.
    private var startIndex = 0
    /// Where the zoom of an item (by its place in the items) comes from and goes back to, on screen, and what it zooms.
    var sourceFrame: (Int) -> NSRect = { _ in .zero }
    var transitionImage: (Int) -> NSImage? = { _ in nil }
    /// The picture (of the item at the index) is out in the panel, from the moment it zooms out until it has zoomed
    /// back in: the pane hides its own meanwhile, so there's one picture, moving.
    var lifted: (Bool, Int) -> Void = { _, _ in }
    /// A picture to lift out of the pane (see `PictureLift`): as the pane shows it, and the file's size in pixels.
    var liftPicture: () -> (image: NSImage, pixels: CGSize)? = { nil }
    private let lift = PictureLift()
    private var showing = false
    /// Asked for again while still zooming back in, which the panel takes no notice of: up again once it's in.
    private var reopening = false
    private weak var host: NSWindow?
    /// Closing with the history: no zoom back into a window that's going, the panel fades.
    private var fades = false
    private var reopenTimer: Timer?
    private var reopenAsked: CFTimeInterval = 0
    private var swapTimer: Timer?
    /// Which item the panel shows: its place in the pane stays empty as it goes from one to the next.
    private var indexObservation: NSKeyValueObservation?
    private var swapping: (lifted: Bool, index: Int, picture: CGRect, started: CFTimeInterval, sawCopy: Bool)?

    /// What Quick Look shows for a clip: the picture's file (titled "Image · Zed · Today at 17:56", not by its
    /// stored name), the files that are still there, or code and text (written to a file for it). Nothing for links
    /// and colours.
    static func items(for clip: Clip?) -> [Item] {
        guard let clip else { return [] }
        let title = [clip.typeName, clip.appName, When.long(clip.lastCopied)].compactMap { $0 }.joined(separator: " · ")
        switch clip.kind {
        case .image:
            guard let name = clip.image else { return [] }
            return [Item(AppPaths.images.appendingPathComponent(name), title: title)]
        case .file:
            return clip.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map { Item($0) }
        case .code, .text:
            return textFile(for: clip).map { [Item($0, title: title)] } ?? []
        default:
            return []
        }
    }

    /// Where code and text go for Quick Look, which shows files: the user's own temporary folder, emptied at launch.
    static let codeFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Pastemind Quick Look",
                                                                                         isDirectory: true)

    /// Code coloured as the preview has it (a web page, light or dark as the system is), when it is; else text.
    private static func textFile(for clip: Clip) -> URL? {
        let colours = clip.kind == .code && Settings.highlightsCode
        let syntax = colours ? CodeHighlighter.shared.known(clip.text, appID: clip.appID) : nil
        let url = codeFolder.appendingPathComponent("\(clip.id).\(syntax == nil ? "txt" : "html")")
        do {
            try FileManager.default.createDirectory(at: codeFolder, withIntermediateDirectories: true)
            let contents = syntax.map { SyntaxColors.html(clip.text, $0.spans) } ?? clip.text
            try Data(contents.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Up, or coming up; not on its way out (it's still on screen for the zoom or fade out, and ordering it out again
    /// then turns the fade around: it came back and stayed).
    var isVisible: Bool { showing && QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    var isKey: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isKeyWindow }

    /// The preview is drawn by a system service in a process of its own, and as it loads it takes the keyboard focus
    /// with it: the history loses the key once, and takes it back. Any later loss is a click elsewhere.
    private var focusLossUntil: CFTimeInterval = 0

    /// The history just lost the keyboard: true if that was the preview loading (once per showing, and soon after).
    func tookFocus() -> Bool {
        guard isVisible, CACurrentMediaTime() < focusLossUntil else { return false }
        focusLossUntil = 0
        return true
    }

    /// The item the panel shows.
    private var current: Int {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return startIndex }
        let index = QLPreviewPanel.shared().currentPreviewItemIndex
        return items.indices.contains(index) ? index : 0
    }

    /// Shown over `window`, without taking the keyboard from it, from the item at `index`.
    func show(_ items: [Item], over window: NSWindow, at index: Int = 0) {
        guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.items = items
        startIndex = items.indices.contains(index) ? index : 0
        host = window
        if isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = startIndex
        } else if panel.isVisible {
            // Still zooming back in from the last time, when ordering it front does nothing: up again once it's in.
            showing = true
            reopening = true
            reopenAsked = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reopenIfIn() }
            }
            RunLoop.main.add(timer, forMode: .common)
            reopenTimer?.invalidate()
            reopenTimer = timer
        } else {
            open(panel)
        }
    }

    private func reopenIfIn() {
        guard reopening else {
            reopenTimer?.invalidate()
            reopenTimer = nil
            return
        }
        let panel = QLPreviewPanel.shared()!
        guard !panel.isVisible || CACurrentMediaTime() - reopenAsked > 0.6 else { return }
        reopenTimer?.invalidate()
        reopenTimer = nil
        reopening = false
        open(panel)
    }

    private func open(_ panel: QLPreviewPanel) {
        // It mustn't take the keyboard: Pastemind isn't the active app, and the key would go to whatever is.
        panel.becomesKeyOnlyIfNeeded = true
        focusLossUntil = CACurrentMediaTime() + 2
        showing = true
        let start = sourceFrame(startIndex)
        if let host, start != .zero, let picture = liftPicture(), let screen = host.screen ?? NSScreen.main {
            // A picture: Quick Look fades in, and the picture flies over to it (its own zoom out of the pane lands in
            // an empty panel). The pane's goes once the flying one covers it.
            fades = true
            lift.fly(picture.image, from: start, pixels: picture.pixels, on: screen,
                     level: NSWindow.Level(rawValue: host.level.rawValue + 2)) { [weak self] in self?.lifted(true, 0) }
        } else {
            fades = false
        }
        panel.updateController()
        panel.currentPreviewItemIndex = startIndex
        indexObservation = panel.observe(\.currentPreviewItemIndex) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.moved() } }
        }
        if let host { panel.level = NSWindow.Level(rawValue: host.level.rawValue + 1) }
        // It holds the main thread here until the picture's loaded (~30 to 300 ms), or half a second: called from a
        // main-queue block, what it waits for can't run meanwhile (see DebugHooks).
        panel.orderFront(nil)
        if let host { panel.level = NSWindow.Level(rawValue: host.level.rawValue + 1) }
        if !lift.isActive { swap(lifted: true) }
    }

    /// On to the next item (or back), round from the last to the first.
    func step(by offset: Int) {
        guard isVisible, items.count > 1 else { return }
        QLPreviewPanel.shared().currentPreviewItemIndex = (current + offset + items.count) % items.count
        moved()
    }

    /// The panel went on to another item (←/→ here, or its own arrows): that one's place empties instead, and the
    /// zoom back goes to it.
    private func moved() {
        guard showing, swapping == nil, !lift.isActive else { return }
        lifted(true, current)
    }

    var showsSeveral: Bool { isVisible && items.count > 1 }

    /// The selection moved: the panel follows it (and goes for a clip with nothing to show).
    func follow(_ items: [Item]) {
        guard isVisible else { return }
        guard !items.isEmpty else { return close() }
        self.items = items
        startIndex = 0
        lift.dissolve()   // the picture it was bringing over isn't the one coming
        QLPreviewPanel.shared().reloadData()
    }

    /// Without `zooming` (the history is closing too) it fades where it is.
    func close(zooming: Bool = true) {
        guard isVisible else { return }
        if reopening {   // it's on its way in already
            reopening = false
            showing = false
            return
        }
        if lift.isActive {
            // The picture still on its way, or waiting for the panel to have it: it goes back the way it came, and
            // Quick Look (nothing of it to zoom back yet) fades.
            fades = true
            showing = false
            QLPreviewPanel.shared().orderOut(nil)
            let start = sourceFrame(0)
            guard zooming, start != .zero else {
                lift.remove()
                return lifted(false, 0)
            }
            lift.back(to: start) { [weak self] in self?.lifted(false, 0) }
            return
        }
        fades = !zooming
        QLPreviewPanel.shared().orderOut(nil)
        land()
    }

    private func land() {
        indexObservation = nil
        showing = false
        swap(lifted: false)
    }

    /// Swaps the pane's picture for Quick Look's copy of it, or back, while the copy covers it: so neither is ever
    /// missing, nor both seen. (Out, only a file's icon now: a picture flies out itself, see `PictureLift`.) Out, the
    /// copy appears 10 to 60 ms after the panel's asked for (later reopened right
    /// after a close), on the picture, opaque, then grows round it as it fades: hidden then, the picture showed
    /// through it. Back, it covers the picture about half
    /// way into the zoom, at once when closed mid-zoom (it jumps there and stays 70 to 170 ms), late in a slow one.
    /// Fixed delays missed some of these, leaving the place empty for a moment.
    private func swap(lifted: Bool) {
        stopSwap()
        let index = current
        let target = sourceFrame(index)
        guard !fades || lifted, target != .zero, let screen = NSScreen.screens.first else {
            return self.lifted(lifted, index)
        }
        // In the window server's coordinates: from the top left of the main screen.
        let picture = CGRect(x: target.minX, y: screen.frame.maxY - target.maxY, width: target.width, height: target.height)
        swapping = (lifted, index, picture, CACurrentMediaTime(), false)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.swapIfCovered() }
        }
        RunLoop.main.add(timer, forMode: .common)
        swapTimer = timer
        swapIfCovered()
    }

    private func swapIfCovered() {
        guard var state = swapping else { return }
        let waited = CACurrentMediaTime() - state.started
        let copies = Self.copies()
        state.sawCopy = state.sawCopy || !copies.isEmpty
        let covered = copies.contains { copy in
            if state.lifted {   // fading from the start, and growing from a few points below the picture's top
                let over = copy.frame.intersection(state.picture)
                return copy.alpha > 0.5 && over.width * over.height > 0.9 * state.picture.width * state.picture.height
            }
            return copy.alpha > 0.95 && copy.frame.insetBy(dx: -1.5, dy: -1.5).contains(state.picture)
        }
        // Or there's nothing to swap with: the copy's gone, or never came.
        let done = covered || (state.lifted ? waited > 0.2 : (copies.isEmpty && (state.sawCopy || waited > 0.3)) || waited > 1)
        guard done else {
            swapping = state
            return
        }
        stopSwap()
        lifted(state.lifted, state.index)
    }

    private func stopSwap() {
        swapTimer?.invalidate()
        swapTimer = nil
        swapping = nil
    }

    /// Quick Look's copies of the picture on screen, the window server's frame for them: AppKit's never moves with
    /// the zoom.
    private static func copies() -> [(frame: CGRect, alpha: Double)] {
        NSApp.windows.filter { $0.className == "QLTransitionWindow" && $0.windowNumber > 0 }.compactMap { window in
            guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber))
                    as? [[String: Any]])?.first,
                  info[kCGWindowIsOnscreen as String] as? Bool == true,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (frame, info[kCGWindowAlpha as String] as? Double ?? 0)
        }
    }

    // MARK: Control (through the app's delegate, which the panel finds at the end of any window's responder chain)

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        if showing, !reopening { land() }   // closed by itself: its close button, or Esc once a click made it key
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index]
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        fades ? .zero : sourceFrame(index(of: item))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        transitionImage(index(of: item))
    }

    private func index(of item: (any QLPreviewItem)?) -> Int {
        items.firstIndex { $0 === item } ?? current
    }
}

/// Where a view of the preview pane is on screen, for Quick Look's zoom: an empty AppKit view put behind it, read as
/// the zoom starts, so the frame is the one drawn, whatever the layout made of it.
final class ScreenAnchor {
    fileprivate weak var view: NSView?

    var frame: NSRect? {
        guard let view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct AnchorView: NSViewRepresentable {
    let anchor: ScreenAnchor

    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Marker {
        let view = Marker()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: Marker, context: Context) { anchor.view = view }
}

/// Quick Look's own zoom out of the pane sets off before its first frame is drawn (the picture leapt out a quarter
/// grown), and lands in an empty panel: the picture shows up there only once it's loaded, a few hundred ms later and at
/// another size. Instead Quick Look fades in, and the picture flies out of its place to where Quick Look will show it
/// (worked out as Quick Look does), waits there over the panel until the panel has it, and dissolves into it. Closed
/// before then, it flies back.
final class PictureLift {
    private var window: NSPanel?
    private let picture = CALayer()
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    /// When the flight is within half a pixel of where it's going.
    private var arrives: CFTimeInterval = 0
    private var pixels = CGSize.zero
    private var screenFrame = NSRect.zero
    private var visible = NSRect.zero
    /// Quick Look's panel's size, as the window server last had it.
    private var size = CGSize.zero
    /// Quick Look's panel as worked out, and as it first came up (before it has the picture: 810×543, empty).
    private var expected = NSRect.zero
    private var first: NSRect?
    private var firstSeen: CFTimeInterval = 0
    /// The panel the flying picture is heading for.
    private var target = NSRect.zero
    private var resized = false
    private var fading = false
    /// Quick Look's panel kept off screen until it has the picture: before resizing to it, it draws itself for a frame
    /// at the size it came up at (810×543, empty), round a smaller picture. Hidden any other way (its alpha it sets back
    /// itself; its views hidden, it never loads the picture), that frame showed, or nothing did.
    private var parked = false
    private var unparked: CFTimeInterval = 0
    private var checked: CFTimeInterval = 0
    private var samples: [NSColor] = []
    private var onCovered: (() -> Void)?
    private static let parking = NSPoint(x: -20000, y: -20000)
    /// Bumped by every flight, so one that's overtaken doesn't finish.
    private var flight = 0

    static let spring = Spring(response: 0.3)
    static let backSpring = Spring(response: 0.26)
    static let radius: CGFloat = 8

    var isActive: Bool { window?.isVisible == true && !fading }

    /// `covered`: once it's on screen over the pane's picture (a new window takes a frame or two to be drawn: the pane's
    /// went first, and for a frame there was neither), for the pane to hide its own.
    func fly(_ image: NSImage, from start: NSRect, pixels: CGSize, on screen: NSScreen, level: NSWindow.Level,
             covered: @escaping () -> Void) {
        let window = self.window ?? makeWindow()
        self.window = window
        // From where it is, should it be flying back still.
        let current = window.isVisible ? picture.presentation()?.frame : nil
        screenFrame = screen.frame
        visible = screen.visibleFrame
        window.setFrame(screen.frame, display: false)
        window.level = level
        self.pixels = pixels
        let frames = Self.frames(pixels: pixels, on: screen)
        expected = frames.panel
        target = frames.panel
        first = nil
        resized = false
        fading = false
        parked = false
        flight += 1
        started = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.removeAllAnimations()
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        picture.contents = cgImage
        samples = cgImage.map(Self.samples) ?? []
        picture.contentsScale = screen.backingScaleFactor
        picture.opacity = 1
        picture.cornerRadius = Self.radius
        picture.frame = current ?? local(start)
        CATransaction.commit()
        window.orderFrontRegardless()
        CATransaction.flush()
        // A timer: Quick Look's panel coming up runs the main thread's loop in its own mode meanwhile, and work queued
        // for the main thread waits half a second for it.
        // It sets off a frame after that, once the pane's is gone: moving at once, a picture smaller in Quick Look than
        // in the pane showed the pane's round it for a few frames.
        let token = flight
        onCovered = covered
        arrives = .infinity
        RunLoop.main.add(Timer(timeInterval: 0.035, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, token == self.flight else { return }
                self.onCovered?()
                self.onCovered = nil
            }
        }, forMode: .common)
        RunLoop.main.add(Timer(timeInterval: 0.055, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, token == self.flight, !self.fading else { return }
                self.move(to: frames.image, spring: Self.spring)
            }
        }, forMode: .common)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer?.invalidate()
        self.timer = timer
    }

    /// Back to `rect` (the pane's picture), then `done` (the pane shows its own again) and gone.
    func back(to rect: NSRect, done: @escaping () -> Void) {
        stopPolling()
        fading = true   // Quick Look's panel fades out where it is, parked or not
        move(to: rect, spring: Self.backSpring)
        let token = flight
        // Within half a pixel (ωt ≈ 9) before the pane's shows under it: a few points off, it stepped into place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9 / Self.backSpring.omega) { [weak self] in
            guard let self, token == self.flight else { return }
            done()
            // A frame later: the pane's picture is drawn by then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                guard token == self.flight else { return }
                self.window?.orderOut(nil)
            }
        }
    }

    /// Quick Look's panel back on screen, where it puts itself: the middle of the screen's visible part. (Its size
    /// from the window server: AppKit's lags behind it.)
    private func unpark() {
        guard parked else { return }
        parked = false
        QLPreviewPanel.shared().setFrameOrigin(Self.centered(size, in: visible).origin)
    }

    private static func centered(_ size: CGSize, in visible: NSRect) -> NSRect {
        NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    /// Fades into what's under it.
    func dissolve() {
        guard isActive else { return }
        stopPolling()
        unpark()
        fading = true
        let token = flight
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = picture.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.flight else { return }
                self.window?.orderOut(nil)
            }
        }
        picture.opacity = 0
        picture.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    func remove() {
        stopPolling()
        flight += 1
        fading = false
        window?.orderOut(nil)
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Watches Quick Look's panel (the window server's frame: AppKit's lags) for it to have the picture: it changes
    /// size then, from the one it comes up at to the picture's, the one worked out (or another: the picture goes
    /// there). Then, once the flight's in, the picture dissolves into the panel's.
    private func poll() {
        let now = CACurrentMediaTime()
        guard let (frame, _) = panelFrame() else {
            if now - started > 1.5 { dissolve() }
            return
        }
        size = frame.size
        guard let first else {
            first = frame
            firstSeen = now
            // Usually up with the picture already: it holds the main thread for it to load (~30 to 300 ms) before it
            // shows. Off screen all the same until the flying one is in: under it, the panel's own showed round it.
            resized = Self.near(frame.size, expected.size)
            parked = true
            QLPreviewPanel.shared().setFrameOrigin(Self.parking)
            return
        }
        if !Self.near(frame.size, first.size) || (!resized && now - firstSeen > 0.35) {
            // It has the picture: resized to it, or up at a size of its own that stays (not the one worked out). The
            // flying one goes where the panel will show it.
            resized = true
            self.first = frame
            let placed = Self.centered(frame.size, in: visible)
            if !Self.near(placed, target) {
                target = placed
                move(to: Self.imageFrame(in: placed, pixels: pixels), spring: Self.spring)
            }
        }
        guard now - started < 2 else { return dissolve() }
        guard resized, now >= arrives else { return }
        // In: Quick Look's panel round it, and the picture dissolves into the panel's once that's drawn (a moment after
        // the panel's up: it comes from another process). Till then the empty panel is under the flying one.
        if parked {
            unpark()
            unparked = now
            return
        }
        // Reading its pixels takes 2 to 7 ms: at most every 30 ms (a picture it never matches, one with transparent
        // parts, would otherwise hold the main thread till the timeout).
        guard now - checked > 0.03 else { return }
        checked = now
        if Self.drawn(QLPreviewPanel.shared().windowNumber, frame: frame, like: samples, pixels: pixels)
            || now - unparked > 0.8 {
            dissolve()
        }
    }

    /// The picture's colours at a few points, to tell when Quick Look's panel shows it.
    private static let probes: [CGPoint] = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.65)]

    private static func samples(of image: CGImage) -> [NSColor] {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return probes.compactMap { rep.colorAt(x: Int($0.x * CGFloat(side)), y: Int($0.y * CGFloat(side))) }
    }

    /// Whether Quick Look's panel (`frame`, AppKit's coordinates) shows the picture yet: its own pixels (an app may
    /// read its own windows), the ones under the flying picture, against the picture's. The call is gone from the
    /// SDK's Swift interface, hence the lookup; without it, the timeout decides.
    private static func drawn(_ number: Int, frame: NSRect, like samples: [NSColor], pixels: CGSize) -> Bool {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard number > 0, samples.count == probes.count, let main = NSScreen.screens.first,
              let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return false }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let image = imageFrame(in: frame, pixels: pixels)
        for (probe, expected) in zip(probes, samples) {
            // The window server's coordinates: from the top left of the main screen.
            let point = CGPoint(x: image.minX + probe.x * image.width,
                                y: main.frame.maxY - (image.maxY - probe.y * image.height))
            guard let patch = create(CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
                                     1 << 3, UInt32(number), 1 << 0)?.takeRetainedValue(),
                  let color = NSBitmapImageRep(cgImage: patch).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB),
                  let wanted = expected.usingColorSpace(.deviceRGB),
                  color.alphaComponent > 0.95,
                  abs(color.redComponent - wanted.redComponent) < 0.12,
                  abs(color.greenComponent - wanted.greenComponent) < 0.12,
                  abs(color.blueComponent - wanted.blueComponent) < 0.12 else { return false }
        }
        return true
    }

    private func panelFrame() -> (NSRect, Double)? {
        // Numbered once it's on screen.
        guard QLPreviewPanel.sharedPreviewPanelExists(), case let number = QLPreviewPanel.shared().windowNumber,
              number > 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number))
                as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              let main = NSScreen.screens.first else { return nil }
        // From the window server's top-left to AppKit's bottom-left.
        let cocoa = NSRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        return (cocoa, info[kCGWindowAlpha as String] as? Double ?? 0)
    }

    private func move(to rect: NSRect, spring: Spring) {
        let target = local(rect)
        let from = picture.presentation() ?? picture
        let position = spring.animation(keyPath: "position")
        position.fromValue = NSValue(point: from.position)
        position.toValue = NSValue(point: CGPoint(x: target.midX, y: target.midY))
        let bounds = spring.animation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: from.bounds)
        bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: target.size))
        for animation in [position, bounds] { animation.preferredFrameRateRange = Motion.frameRate }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.position = CGPoint(x: target.midX, y: target.midY)
        picture.bounds = CGRect(origin: .zero, size: target.size)
        picture.add(position, forKey: "position")
        picture.add(bounds, forKey: "bounds")
        CATransaction.commit()
        // In, near enough to dissolve into Quick Look's (it carries on meanwhile): a critically damped spring has under
        // 1% of the way left at ωt = 7.
        arrives = CACurrentMediaTime() + 7 / spring.omega
    }

    private func local(_ rect: NSRect) -> CGRect { rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                             defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = NSView()
        view.layer = CALayer()
        view.wantsLayer = true
        picture.contentsGravity = .resize
        picture.masksToBounds = true
        picture.cornerCurve = .continuous
        view.layer?.addSublayer(picture)
        window.contentView = view
        return window
    }

    /// Where Quick Look puts a picture (measured on macOS 26): its pixels, scaled down to fit a panel at most the
    /// screen less 102 points each way; the picture area at least 360×180 (a small one in its middle); 5 points of
    /// panel round it, 38 above for the title; the panel in the middle of the screen's visible part.
    static func frames(pixels: CGSize, on screen: NSScreen) -> (panel: NSRect, image: NSRect) {
        let full = screen.frame
        let visible = screen.visibleFrame
        let content = CGSize(width: full.width - 102 - 10, height: full.height - 102 - 43)
        let scale = min(1, content.width / max(pixels.width, 1), content.height / max(pixels.height, 1))
        let image = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        let area = CGSize(width: max(image.width, 360), height: max(image.height, 180))
        let size = CGSize(width: area.width + 10, height: area.height + 43)
        let panel = centered(size, in: visible)
        return (panel, imageFrame(in: panel, pixels: pixels))
    }

    /// The picture in a panel of Quick Look's: fit (never enlarged) to its picture area, in the middle.
    static func imageFrame(in panel: NSRect, pixels: CGSize) -> NSRect {
        let area = NSRect(x: panel.minX + 5, y: panel.minY + 5, width: panel.width - 10, height: panel.height - 43)
        let scale = min(1, area.width / max(pixels.width, 1), area.height / max(pixels.height, 1))
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        return NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private static func near(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    private static func near(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3
            && abs(a.height - b.height) < 3
    }
}
