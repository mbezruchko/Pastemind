import AppKit
import SwiftUI
import QuickLookUI
import PastemindKit

/// For driving the running app from a terminal (scripts/pastemindctl.swift) when it's started with PASTEMIND_DEBUG=1: show, type,
/// move, snapshot, dump the rows. In debug runs Pastemind reads and writes the pasteboard named by PASTEMIND_PASTEBOARD instead of
/// the real clipboard, and never presses ⌘V.
enum DebugHooks {
    static let enabled = ProcessInfo.processInfo.environment["PASTEMIND_DEBUG"] == "1"
    static let notification = Notification.Name("app.pastemind.debug")
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    static func install(panel: PanelController, launcher: LauncherController, settings: SettingsWindowController,
                        welcome: WelcomeWindowController, app: AppController,
                        hotkey: @escaping @MainActor @Sendable (HotkeyCenter.Action) -> Void) {
        guard enabled else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notification, object: nil,
                                                                       queue: .main) { note in
            let command = note.object as? String ?? ""
            let argument = (note.userInfo?["argument"] as? String) ?? ""
            // From the run loop, as a key press is handled, not from this main-queue block: run from inside one, work
            // that waits for the main queue meanwhile (Quick Look loading its preview while it holds the main thread
            // for it) can't run, and timed out after half a second.
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated {
                switch command {
                case "hotkey": hotkey(argument == "search" ? .search : .clipboard)   // as if pressed
                case "quit": NSApp.terminate(nil)
                case "switch":   // the hotkey, with each busy stretch of the main thread over the next second and when
                    let started = Date()   // it ended (the first one is the switch itself, up to the first frame)
                    let meter = BusyMeter { busy in
                        log(String(format: "switch: busy %.1f ms, ending +%.0f ms", busy, Date().timeIntervalSince(started) * 1000))
                    }
                    hotkey(argument == "search" ? .search : .clipboard)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { meter.stop("switch") }
                case "film": film(windows: [panel.windowNumber], into: argument)   // the panel's one window, either mode
                case "menubar": app.updateStatusItem(visible: argument != "off")       // not saved
                case "model-sleep": app.engine.forgetUse()   // the model unloaded now, as after it went unused
                case "reopen": _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                case "search": launcher.show()
                case "squery": launcher.query = argument; caretToEnd(launcher.field)
                case "sdown": launcher.moveSelection(by: Int(argument) ?? 1)
                case "slook": launcher.toggleQuickLook()   // as a tap of ⇧ or ⌘Y would
                case "stype": type(argument, into: launcher.field, label: "stype")
                case "measure":   // seconds, then a label
                    let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                    measure(Double(parts.first ?? "") ?? 3, label: parts.count > 1 ? parts[1] : "measure")
                case "stab": launcher.toggleFilesFilter()
                case "spin": launcher.debugSpinner(argument != "off"); panel.debugSpinner(argument != "off")   // both panels' spinners
                case "sdump":
                    let frame = launcher.windowNumber.flatMap { NSApp.window(withWindowNumber: $0)?.frame } ?? .zero
                    let shown = launcher.windowNumber.flatMap { NSApp.window(withWindowNumber: $0)?.isVisible } ?? false
                    log("sdump: \(shown ? "shown" : "hidden"), \(launcher.placeholder), window \(launcher.windowNumber ?? -1), query \"\(launcher.query)\" field \"\(launcher.field?.stringValue ?? "-")\", \(launcher.results.count) results, selected \(launcher.selectedResult?.item.name ?? "-"), "
                        + "frame \(frame)")
                    for result in launcher.results.prefix(Int(argument) ?? 10) {
                        log(String(format: "  %.3f %@ %@ — %@%@", result.score, result.item.kind.rawValue,
                                   result.item.name, result.byContent ? "by content · " : "", result.item.subtitle))
                    }
                case "ssnapshot": snapshot(launcher.windowNumber, to: URL(fileURLWithPath: argument))
                case "sshadow": snapshot(launcher.windowNumber, to: URL(fileURLWithPath: argument), shadow: true)
                case "shadow": snapshot(panel.windowNumber, to: URL(fileURLWithPath: argument), shadow: true)
                case "settings": settings.show()
                case "settingssnapshot": snapshot(settings.windowNumber, to: URL(fileURLWithPath: argument))
                case "settingsnote": settings.flash(argument)
                case "welcome": welcome.show()
                case "welcomesnapshot": snapshot(welcome.windowNumber, to: URL(fileURLWithPath: argument))
                case "welcomestate": welcome.debugState(argument)   // start | done | failed: as if so, till the next one
                case "welcomeclose": welcome.close()
                case "welcomepage": welcome.debugPage(Int(argument) ?? 0)
                case "options-pointer":   // on|off: the pointer taken as over the panels or not; auto: where it is
                    OptionsMenu.debugPointerOver = argument == "on" ? true : argument == "off" ? false : nil
                case "options":   // the clipboard panel's options menu, up for that many seconds
                    let window = panel.windowNumber.flatMap { NSApp.window(withWindowNumber: $0) }
                    guard let anchor = window?.contentView.flatMap(optionsAnchor) else { return log("options: none") }
                    let timer = Timer(timeInterval: Double(argument) ?? 2, repeats: false) { _ in
                        MainActor.assumeIsolated { OptionsMenu.shown?.cancelTracking() }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    OptionsMenu.popUp(app: app, below: anchor)
                case "settingsdump": log("settingsdump: \(settings.frames)")
                case "glassonly":   // on|off: the panel's content hidden, its glass alone (the promo's empty glass)
                    if let number = panel.windowNumber, let views = NSApp.window(withWindowNumber: number)?.contentView?.subviews {
                        views.dropFirst().forEach { $0.isHidden = argument == "on" }
                    }
                default: run(command, argument, panel: panel)
                }
            } }
        }
        log("debug hooks on (pasteboard: \(Pasteboards.main.name.rawValue))")
    }

    private static func run(_ command: String, _ argument: String, panel: PanelController) {
        switch command {
        case "show": panel.show()
        case "hide": panel.hide()
        case "query": panel.query = argument; caretToEnd(panel.field)
        case "type": type(argument, into: panel.field, label: "type")
        case "look": panel.toggleQuickLook()   // as a tap of ⇧ or ⌘Y would
        case "lookfilm": panel.toggleQuickLook(); filmScreen(into: argument)   // the zoom in or out, frame by frame
        case "lookagain":   // "<ms>": Quick Look toggled, and again that soon after (a quick open and close, or back)
            panel.toggleQuickLook()
            filmScreen(into: "-", frames: 72) { "lifted \(panel.lifted)" }   // the pane's picture hidden
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(argument) ?? 150) / 1000) {
                panel.toggleQuickLook()
                log("lookagain: toggled again")
            }
        case "selectpreview":   // "<start> <length>": selects that much of the preview's text, as dragging over it would
            let numbers = argument.split(separator: " ").compactMap { Int($0) }
            let window = panel.windowNumber.flatMap { NSApp.window(withWindowNumber: $0) }
            guard numbers.count == 2, let text = window?.contentView.flatMap(firstPreviewText) else {
                return log("selectpreview: no preview text")
            }
            window?.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: numbers[0], length: numbers[1]))
        case "copysel": log("copysel: \(panel.copyPreviewSelection())")   // as ⌘C would
        case "tab": panel.toggleSnippets()   // as ⇥ would
        case "snip-new": panel.newSnippet()   // ⌘N
        case "snip-save": panel.saveAsSnippet()   // ⌘S
        case "snip-folder": panel.newFolder()   // ⇧⌘N
        case "qlkey": QLPreviewPanel.shared()?.makeKey()   // Quick Look takes the key, as a click in it does
        case "qledit":   // Pastemind active and Quick Look key, as a click in it makes them; the Edit menu's items checked
            // ("all": then Select All, and checked again). Copy isn't chosen: it writes to the system's pasteboard.
            NSApp.activate()
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
            func check(_ label: String) {
                let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu
                edit?.update()
                log("qledit \(label): keywin \(NSApp.keyWindow?.className ?? "-") first \(NSApp.keyWindow?.firstResponder?.className ?? "-") "
                    + (edit?.items.map { "\($0.title) \($0.isEnabled)" }.joined(separator: ", ") ?? "no menu"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                check("key")
                guard argument == "all", let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu else { return }
                edit.performActionForItem(at: edit.indexOfItem(withTitle: "Select All"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { check("selected") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { check("later") }
            }
        case "qlviews":   // Quick Look's panel: its views, and what has its keyboard
            let ql = QLPreviewPanel.shared()!
            log("qlviews: style \(ql.styleMask.rawValue) first responder \(ql.firstResponder?.className ?? "-")")
            func walk(_ view: NSView, _ depth: Int) {
                log(String(repeating: "  ", count: depth) + "\(view.className) \(view.frame)\(view.isHidden ? " hidden" : "")")
                for subview in view.subviews where depth < 14 { walk(subview, depth + 1) }
            }
            if let root = ql.contentView?.superview ?? ql.contentView { walk(root, 0) }
            var responder: NSResponder? = ql.firstResponder
            while let current = responder {
                log("  responder \(current.className) copy \(current.responds(to: #selector(NSText.copy(_:)))) selectAll \(current.responds(to: #selector(NSText.selectAll(_:))))")
                responder = current.nextResponder
            }
            for name in ["QLPanelPreviewView", "QLPreviewContainerView", "NSRemoteView"] {
                guard let cls = NSClassFromString(name) else { continue }
                var count: UInt32 = 0
                let methods = class_copyMethodList(cls, &count)
                let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(methods![$0])) }
                free(methods)
                log("  \(name): " + names.filter { $0.range(of: "copy|select|text|live|analys|keyEquivalent|menu", options: [.regularExpression, .caseInsensitive]) != nil }.joined(separator: " "))
            }
        case "qlstate":
            let ql = QLPreviewPanel.shared()!
            log("qlstate: visible \(ql.isVisible) key \(ql.isKeyWindow) items \(ql.dataSource.map { $0.numberOfPreviewItems(in: ql) } ?? -1) item \(ql.currentPreviewItem?.previewItemTitle ?? "-") keywin \(NSApp.keyWindow?.windowNumber ?? -1)")
        case "dropped": panel.dragEnded(dropped: true)   // as if what's selected was dragged into an app that took it
        case "dragpb":   // what dragging the selected clip (or snippet) out carries, put on a pasteboard of its own, logged
            if panel.mode == .snippets, let snippet = panel.selectedSnippet {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.pastemind.dragtest"))
                pasteboard.clearContents()
                let writers = ClipDrag.writers(for: snippet)
                pasteboard.writeObjects(writers)
                let names = writers.compactMap { $0 as? PromisedFile }.map { $0.filePromiseProvider($0, fileNameForType: $0.fileType) }
                log("dragpb: [snippet] string \"\(pasteboard.string(forType: .string)?.prefix(50) ?? "-")\" promise \(names)")
                return
            }
            guard let clip = panel.selectedClip else { return log("dragpb: no clip") }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.pastemind.dragtest"))
            pasteboard.clearContents()
            let writers = ClipDrag.writers(for: clip)
            pasteboard.writeObjects(writers)
            let picture = clip.image.map { AppPaths.images.appendingPathComponent($0) }
            let promised = writers.compactMap { ($0 as? PromisedFile).map { PromisedFile.fileName(for: clip, picture: picture) + " / " + ($0.fileType) } }
            log("dragpb: [\(clip.kind.rawValue)] \(writers.count) items, types \(pasteboard.types?.map(\.rawValue).filter { !$0.hasPrefix("com.apple.pasteboard.promise") && !$0.hasPrefix("dyn.") } ?? [])")
            for item in pasteboard.pasteboardItems ?? [] {
                let string = item.string(forType: .string).map { String($0.prefix(50)) } ?? "-"
                let url = item.string(forType: .URL) ?? item.string(forType: .fileURL) ?? "-"
                let png = item.data(forType: .png)?.count ?? 0
                log("  item: string \"\(string)\" url \(url) png \(png) bytes")
            }
            if !promised.isEmpty { log("  promise: \(promised)") }
        case "snip-move":   // the selected snippet into the folder so named ("-": out of any), as its menu would
            guard let snippet = panel.selectedSnippet else { return log("snip-move: no snippet") }
            panel.moveSnippet(snippet, to: panel.app.snippetFolders.first { $0.name == argument }?.id)
        case "snip-dump":   // the snippets list
            log("snip-dump: folder \(panel.openFolder?.name ?? "-"), query \"\(panel.query)\", placeholder \"\(panel.placeholder)\", selected \(String(describing: panel.snippetSelection))")
            for row in panel.snippetRows {
                switch row {
                case .folder(let folder, let count): log("  [folder] \(folder.name) (\(count))")
                case .snippet(let snippet): log("  [snippet] \(snippet.title) folder \(snippet.folder.map(String.init) ?? "-")")
                }
            }
        case "clear":   // clears a range at once: 5m, 15m, today, all
            let ranges: [String: ClearRange] = ["5m": .fiveMinutes, "15m": .fifteenMinutes, "today": .today, "all": .all]
            if let range = ranges[argument] { _ = panel.app.clearClips(since: range.since()) } else { log("clear: 5m, 15m, today or all") }
        case "pointer", "click":   // "x y" in the window from its top left ("off": the pointer leaves), then a click count
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            let window = panel.windowNumber.flatMap { NSApp.window(withWindowNumber: $0) }
            guard let list = window?.contentView.flatMap(firstList) else { return log("\(command): no list") }
            let point = numbers.count >= 2 ? NSPoint(x: numbers[0], y: numbers[1]) : nil
            if command == "pointer" { list.debugPointer(point) } else if let point {
                list.debugClick(point, count: numbers.count > 2 ? Int(numbers[2]) : 1)
            }
        case "down": panel.moveSelection(by: Int(argument) ?? 1)
        case "up": panel.moveSelection(by: -(Int(argument) ?? 1))
        case "paste": panel.paste(plain: argument == "plain")
        case "snapshot": snapshot(panel.windowNumber, to: URL(fileURLWithPath: argument))
        case "preview-snapshot": previewSnapshot(panel, to: URL(fileURLWithPath: argument))
        case "look-snapshot":   // Quick Look's window alone
            let number = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared().windowNumber : nil
            snapshot(number, to: URL(fileURLWithPath: argument))
            log("look-snapshot: item \(QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared().currentPreviewItemIndex : -1), lifted \(panel.lifted) \(panel.liftedFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-")")
        case "key":   // "<code>": a key down as the panel gets it (123 ←, 124 →)
            if let code = UInt16(argument), let window = NSApp.keyWindow,   // the history's or search's
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)   // through the queue: the panel's key monitor sees it
            }
        case "dump":
            let frame = panel.windowNumber.flatMap { NSApp.window(withWindowNumber: $0)?.frame } ?? .zero
            log("dump: \(panel.isVisible ? "shown" : "hidden"), mode \(panel.mode), query \"\(panel.query)\" field \"\(panel.field?.stringValue ?? "-")\", phase \(panel.phase)\(panel.stale ? " (held)" : ""), \(panel.rows.count) rows, selected \(panel.selectedClip?.title.prefix(40) ?? "-"), "
                + "frame \(frame)")
            for row in panel.rows.prefix(Int(argument) ?? 10) {
                log("  \(row.weak ? "·" : "•") [\(row.clip.kind.rawValue)] \(row.clip.title.prefix(70))")
            }
        default: log("debug: unknown command \(command)")
        }
    }

    private static func firstPreviewText(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, !text.isEditable, !text.isFieldEditor { return text }
        for subview in view.subviews { if let text = firstPreviewText(in: subview) { return text } }
        return nil
    }

    private static func optionsAnchor(in view: NSView) -> NSView? {
        if view is OptionsMenu.AnchorView.Marker { return view }
        for subview in view.subviews { if let found = optionsAnchor(in: subview) { return found } }
        return nil
    }

    private static func firstList(in view: NSView) -> ListView? {
        if let list = view as? ListView { return list }
        for subview in view.subviews { if let list = firstList(in: subview) { return list } }
        return nil
    }

    /// Records every stretch the main thread is busy for more than 4 ms (from waking up to going back to sleep: a
    /// keystroke's search, a SwiftUI update, its commit), and sums them up when stopped.
    private final class BusyMeter {
        private var observer: CFRunLoopObserver?
        private var spans: [Double] = []

        init(onSpan: @escaping (Double) -> Void = { _ in }) {
            var woke = Date()
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue
                | CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, activity in
                if activity == .afterWaiting { woke = Date(); return }
                let busy = Date().timeIntervalSince(woke) * 1000
                guard busy > 4 else { return }
                self?.spans.append(busy)
                onSpan(busy)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func stop(_ label: String) {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
            let sorted = spans.sorted()
            func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            log(String(format: "%@: %d busy stretches > 4 ms, %.0f ms in all, median %.1f, p95 %.1f, worst %.1f ms",
                       label, spans.count, spans.reduce(0, +), percentile(0.5), percentile(0.95), sorted.last ?? 0))
        }
    }

    /// After a whole query is set at once AppKit selects it in the field; typing leaves the caret at the end instead.
    private static func caretToEnd(_ field: NSTextField?) {
        DispatchQueue.main.async {
            guard let editor = field?.currentEditor() else { return }
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }

    /// Types into a panel's field a letter every 70 ms, through its field editor as the keyboard would, logging each
    /// busy stretch with how long after the keystroke it ended (the keystroke's own work, then the results after it).
    private static func type(_ text: String, into field: NSTextField?, label: String) {
        guard let field else { return log("\(label): no field") }
        field.window?.makeFirstResponder(field)
        var typedAt = Date()
        let meter = BusyMeter { busy in
            log(String(format: "%@: busy %.1f ms, ending %.0f ms after the keystroke", label, busy,
                       Date().timeIntervalSince(typedAt) * 1000))
        }
        for (index, character) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(index)) {
                typedAt = Date()
                (field.currentEditor() as? NSTextView)?.insertText(String(character),
                                                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(text.count) + 1) {
            meter.stop("\(label) \(text.count) letters")
        }
    }

    /// The main thread's busy stretches over the next `seconds`, whatever drives it meanwhile (a script).
    private static func measure(_ seconds: Double, label: String) {
        let meter = BusyMeter()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { meter.stop(label) }
    }

    /// The panel as the window server shows it (glass included): an app may always capture its own windows.
    /// CGWindowListCreateImage is gone from the SDK's Swift interface, hence the lookup.
    /// 30 frames, one every 16 ms, of whichever panel is on screen (both, mid-switch), with its height: to look at a
    /// transition frame by frame.
    private static func film(windows: [Int?], into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let started = Date()
        for frame in 0..<30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(frame) / 60) {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                var heights: [String] = []
                for (index, number) in windows.enumerated() {
                    guard let number, let window = NSApp.window(withWindowNumber: number), window.isVisible else { continue }
                    let name = index == 0 ? "panel" : "window\(index)"
                    heights.append("\(name) \(Int(window.frame.height))")
                    snapshot(number, to: URL(fileURLWithPath: folder).appendingPathComponent(
                        String(format: "%02d-%@.png", frame, name)), quiet: true)
                }
                log("film \(frame) +\(elapsed) ms: \(heights.joined(separator: ", "))")
            }
        }
    }

    /// `frames` (48) frames, 16 ms apart, of Pastemind's windows on screen bar Quick Look's panel (composited, nothing else's: the
    /// history and the window Quick Look zooms in), with all its windows listed. Folder "-": the list alone (filming
    /// takes the main thread, and Quick Look's zoom runs on it).
    private static func filmScreen(into folder: String, frames: Int = 48, note: @escaping () -> String = { "" }) {
        typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        if folder != "-" { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let started = Date()
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        for frame in 0..<frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(frame) / 60) {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                let all = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let ours = all.filter { info in
                    (info[kCGWindowOwnerPID as String] as? Int) == pid
                        || (info[kCGWindowOwnerName as String] as? String ?? "").contains("Quick")
                }
                let lines = ours.map { info -> String in
                    let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
                    return String(format: "%@#%d L%d a%.2f %.0f,%.0f %.0fx%.0f",
                                  info[kCGWindowOwnerName as String] as? String ?? "?",
                                  info[kCGWindowNumber as String] as? Int ?? 0, info[kCGWindowLayer as String] as? Int ?? 0,
                                  info[kCGWindowAlpha as String] as? Double ?? 0, bounds["X"] ?? 0, bounds["Y"] ?? 0,
                                  bounds["Width"] ?? 0, bounds["Height"] ?? 0)
                }
                log("lookfilm \(frame) +\(elapsed) ms \(note()): \(lines.joined(separator: " | "))")
                guard folder != "-" else { return }
                let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared().windowNumber : -1
                let ids = ours.compactMap { $0[kCGWindowNumber as String] as? Int }.filter { $0 != panel }
                    .map { UnsafeRawPointer(bitPattern: UInt($0)) }
                let array = ids.withUnsafeBufferPointer { buffer in
                    CFArrayCreate(nil, UnsafeMutablePointer(mutating: buffer.baseAddress), buffer.count, nil)
                }
                guard let array, !ids.isEmpty, let image = createImage(.null, array, 1 << 0)?.takeRetainedValue(),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%02d.png", frame)))
            }
        }
    }

    /// With `shadow`, the window's shadow too (on transparency), to check its shape.
    /// The selected clip's preview pane drawn in a window never put on screen (the panel stays hidden, nothing takes
    /// the keyboard), a second later (thumbnails come in by then), as a PNG.
    private static func previewSnapshot(_ panel: PanelController, to url: URL) {
        guard let clip = panel.selectedClip else { return log("preview-snapshot: nothing selected") }
        let size = NSSize(width: PanelController.width - PanelController.listWidth, height: PanelController.height)
        let view = NSHostingView(rootView: ClipPreview(clip: clip, query: "", rich: false, anchor: ScreenAnchor(),
                                                      lifted: false)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSApp.effectiveAppearance
        window.contentView = view
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return log("preview-snapshot: failed") }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log("preview-snapshot: \(url.path)")
            withExtendedLifetime(window) {}
        }
    }

    private static func snapshot(_ windowNumber: Int?, to url: URL, shadow: Bool = false, quiet: Bool = false) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let number = windowNumber, let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return log("snapshot: no window") }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        guard let image = createImage(.null, 1 << 3, UInt32(number), shadow ? 0 : 1 << 0)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return log("snapshot: capture failed") }
        try? png.write(to: url)
        if !quiet { log("snapshot: \(url.path)") }
    }
}

/// The real clipboard, or a private one in debug runs.
enum Pasteboards {
    static let main: NSPasteboard = {
        if DebugHooks.enabled, let name = ProcessInfo.processInfo.environment["PASTEMIND_PASTEBOARD"], !name.isEmpty {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }()
}
