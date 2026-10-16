import AppKit
import PastemindKit
import SwiftUI

enum Brand {
    static let indigo = Color(red: 0.36, green: 0.42, blue: 0.98)
    static let violet = Color(red: 0.60, green: 0.36, blue: 0.96)
    static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The search field: a borderless NSTextField, so it takes the keyboard the moment the panel opens. Its placeholder is
/// drawn over it by `PlaceholderView` (AppKit's can't animate), so a new one crossfades in.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var placeholder: String
    var onMake: (NSTextField) -> Void
    var onPlaceholder: (PlaceholderView) -> Void = { _ in }

    func makeNSView(context: Context) -> FieldContainer {
        let container = FieldContainer(fontSize: fontSize)
        container.field.delegate = context.coordinator
        container.placeholder.set(placeholder, animated: false)
        context.coordinator.placeholder = placeholder
        onMake(container.field)
        onPlaceholder(container.placeholder)
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView container: FieldContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: container.fittingHeight)
    }

    func updateNSView(_ container: FieldContainer, context: Context) {
        if container.field.stringValue != text { container.field.stringValue = text }
        // Only SwiftUI's changes here: a panel may set one itself (the other panel's, to turn from).
        if context.coordinator.placeholder != placeholder {
            context.coordinator.placeholder = placeholder
            container.placeholder.set(placeholder, animated: container.window?.isVisible == true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var placeholder: String?
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// The field with its placeholder under it, shown while there's nothing in the field.
final class FieldContainer: NSView {
    let field = PromptField()
    let placeholder: PlaceholderView

    init(fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        placeholder = PlaceholderView(font: font)
        super.init(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.onChange = { [weak self] in self?.updatePlaceholder() }
        addSubview(placeholder)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The field's own height: SwiftUI centers it in the row.
    var fittingHeight: CGFloat { field.intrinsicContentSize.height }

    override func layout() {
        super.layout()
        // Centered, should it be given more height than it needs (a text field draws its text at the top).
        let frame = NSRect(x: 0, y: ((bounds.height - fittingHeight) / 2).rounded(), width: bounds.width,
                           height: fittingHeight)
        field.frame = frame
        placeholder.frame = frame
    }

    /// While typing, the editor holds the text (marked text included): it counts.
    func updatePlaceholder() {
        let text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        placeholder.isHidden = !text.isEmpty
    }
}

/// An NSTextField that says when its text changes, typed or set.
final class PromptField: NSTextField {
    var onChange: () -> Void = {}

    override var stringValue: String {
        get { super.stringValue }
        set {
            super.stringValue = newValue
            onChange()
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onChange()
    }
}

/// The field's placeholder, brighter than AppKit's gray (as Spotlight's). A new one crossfades in like the symbol:
/// the old text blurs away as the new one sharpens in place, so search's prompt turning into the clipboard's (or
/// into "Search files") reads as the one line changing, not as a jump. In place: drifting a few points up as they
/// swapped, on a spring, the line seemed to twitch.
final class PlaceholderView: NSView {
    private let font: NSFont
    private var current: String?
    private var shown: NSTextField?

    init(font: NSFont) {
        self.font = font
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go to the field under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ text: String, animated: Bool) {
        guard text != current else { return }
        current = text
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = PanelChrome.fieldPlaceholder
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        label.wantsLayer = true
        label.layerUsesCoreImageFilters = true
        addSubview(label)
        let outgoing = shown
        shown = label
        guard animated, let outgoing, !Motion.reduced, let incomingLayer = label.layer,
              let outgoingLayer = outgoing.layer else {
            outgoing?.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { outgoing.removeFromSuperview() }
        Self.animate(incomingLayer, from: (0, 3), to: (1, 0))
        Self.animate(outgoingLayer, from: (1, 0), to: (0, 3))
        CATransaction.commit()
    }

    /// Opacity and blur radius, from one state to the other (on the panels' grow spring).
    private static func animate(_ layer: CALayer, from: (Float, CGFloat), to: (Float, CGFloat)) {
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(to.1, forKey: kCIInputRadiusKey)
        layer.filters = [blur]
        layer.opacity = to.0
        let fade = Motion.grow.animation(keyPath: "opacity")
        fade.fromValue = from.0
        fade.toValue = to.0
        let soften = Motion.grow.animation(keyPath: "filters.blur.inputRadius")
        soften.fromValue = from.1
        soften.toValue = to.1
        let group = CAAnimationGroup()
        group.animations = [fade, soften]
        group.duration = fade.duration
        group.isRemovedOnCompletion = true
        group.preferredFrameRateRange = Motion.frameRate
        layer.add(group, forKey: "swap")
    }
}

/// Clicks without SwiftUI's double-tap delay: one click selects at once, a second one acts. Also reports the pointer
/// over it (the panels never activate the app, so this tracks always, not only when active).
struct ClickArea: NSViewRepresentable {
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
    }

    final class ClickView: NSView {
        var onClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        private var tracking: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            event.clickCount >= 2 ? onDoubleClick() : onClick()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}

/// Tells when the pointer comes over it and leaves, its clicks left to what's on top (a SwiftUI button). Tracked
/// always: the panels never activate the app.
struct HoverArea: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: HoverView, context: Context) { view.onHover = onHover }

    final class HoverView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        private var tracking: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}

/// A key as a small cap, for the hints in the footer and the rows: "⌘", "↩".
struct Keycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 17, minHeight: 17)
            .padding(.horizontal, key.count > 1 ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The background of a list row: the selection, or a faint one under the pointer.
struct RowBackground: View {
    let selected: Bool
    let hovered: Bool
    var radius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.26) : hovered ? Color.primary.opacity(0.05) : Color.clear)
    }
}

/// App icons by bundle identifier, and icons by path, looked up once.
enum Icons {
    private static var apps: [String: NSImage] = [:]

    static func app(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = apps[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        apps[bundleID] = icon
        return icon
    }

    private static var appPaths: [String: String?] = [:]

    /// The app's icon drawn once at the size it's shown (see `path(_:side:)`): a list row's badge, the preview's.
    static func app(_ bundleID: String?, side: CGFloat) -> NSImage? {
        guard let bundleID else { return nil }
        if appPaths[bundleID] == nil {
            appPaths[bundleID] = .some(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path)
        }
        guard let location = appPaths[bundleID] ?? nil else { return nil }
        return path(location, side: side)
    }

    static func file(_ url: URL) -> NSImage {
        path(url.path)
    }

    // NSCache is thread-safe, and so is NSWorkspace's icon lookup: icons are drawn ahead of time off the main thread.
    nonisolated(unsafe) private static let paths = NSCache<NSString, NSImage>()
    nonisolated(unsafe) private static let drawn = NSCache<NSString, NSImage>()

    /// The icon drawn once at the size it's shown (a single 2× bitmap). A full icon carries representations up to
    /// 1024 px, decoded and scaled on its first draw on the main thread: dozens of those at once cost frames.
    nonisolated static func path(_ path: String, side: CGFloat) -> NSImage {
        let key = "\(path)@\(side)" as NSString
        if let image = drawn.object(forKey: key) { return image }
        let full = Self.path(path)
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return full }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        drawn.setObject(image, forKey: key)
        return image
    }

    /// A file's, folder's, app's or settings pane's icon, as Finder draws it. A symlink gets its target's icon, as
    /// Spotlight shows it: /Applications/Safari.app links into the system's cryptex, and drew with an alias arrow.
    nonisolated static func path(_ path: String) -> NSImage {
        if let icon = paths.object(forKey: path as NSString) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        paths.setObject(icon, forKey: path as NSString)
        return icon
    }

    /// A quiet color per kind, for the clip's tile.
    static func tint(for kind: ClipKind) -> NSColor {
        switch kind {
        case .code, .text, .link: .systemGray   // the symbol tells them apart; colours stood out of the list
        case .color: .systemPink
        case .image: .systemTeal
        case .file: .systemIndigo
        }
    }

    static func symbol(for kind: ClipKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .color: "paintpalette"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

/// Pictures decoded at the size they're drawn, kept while the app runs (a few hundred KB each at most). One asked for
/// again before it's ready (by the preview and the prefetch) decodes once.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private var loading: [String: Task<CGImage?, Never>] = [:]

    init() { cache.countLimit = 300 }

    func cached(_ name: String, pixels: Int) -> NSImage? {
        cache.object(forKey: "\(name)@\(pixels)" as NSString)
    }

    func load(_ name: String, pixels: Int) async -> NSImage? {
        if let image = cached(name, pixels: pixels) { return image }
        let key = "\(name)@\(pixels)"
        let task = loading[key] ?? Task.detached(priority: .userInitiated) { Pictures.decode(name, pixels: pixels) }
        loading[key] = task
        let decoded = await task.value
        loading[key] = nil
        if let image = cached(name, pixels: pixels) { return image }
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Decodes what's about to be drawn, so ↑/↓ finds it ready.
    func prefetch(_ names: [String], pixels: Int) {
        for name in names where cached(name, pixels: pixels) == nil {
            Task { _ = await load(name, pixels: pixels) }
        }
    }
}

/// "#F2A22A", "#abc", "rgb(…)" → a color to draw.
enum ColorParser {
    static func color(_ text: String) -> Color? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) {
            let hasAlpha = hex.count == 8
            let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
            return Color(red: r, green: g, blue: b, opacity: a)
        }
        if trimmed.hasPrefix("rgb") {
            let numbers = trimmed.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
            guard numbers.count >= 3 else { return nil }
            return Color(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255,
                         opacity: numbers.count > 3 ? numbers[3] : 1)
        }
        return nil
    }
}

/// Times for the list: "now", "5m", "3h", "Yesterday", "Mon", "12 Oct".
enum When {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func long(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
    }
}

/// Where the query is in a clip's text, for highlighting: the line it's on, cut around it.
enum Excerpt {
    static func line(_ text: String, query: String, width: Int = 70) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        // A match further in than this can't be shown in one line anyway, and each search scans this far.
        let haystack = String(text.prefix(10_000))
        let found = find(needle, in: haystack)
            ?? needle.split(separator: " ").lazy.compactMap { find(String($0), in: haystack) }.first
        guard let found else { return nil }
        let lineStart = haystack[..<found.lowerBound].lastIndex(where: \.isNewline).map { haystack.index(after: $0) }
            ?? haystack.startIndex
        let lineEnd = haystack[found.upperBound...].firstIndex(where: \.isNewline) ?? haystack.endIndex
        var start = lineStart
        if haystack.distance(from: lineStart, to: found.lowerBound) > width / 3 {
            start = haystack.index(found.lowerBound, offsetBy: -(width / 3))
        }
        let end = haystack.index(start, offsetBy: width, limitedBy: lineEnd) ?? lineEnd
        let prefix = start > lineStart ? "…" : ""
        return prefix + haystack[start..<end].trimmingCharacters(in: .whitespaces)
    }

    /// Where `needle` is in `text`, case, accents and width aside. An ASCII needle in ASCII text (most of them) is
    /// found byte by byte, case aside, far faster than Foundation's collation-aware search, which the rest get.
    static func find(_ needle: String, in text: String) -> Range<String.Index>? {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return nil }
        if pattern.allSatisfy({ $0 < 0x80 }) {
            var text = text
            let hit = text.withUTF8 { bytes -> (offset: Int?, ascii: Bool) in
                let lower = pattern.map(Self.lowered)
                var ascii = true
                let count = bytes.count, length = lower.count
                guard count >= length else { return (nil, bytes.allSatisfy { $0 < 0x80 }) }
                var index = 0
                while index <= count - length {
                    let byte = bytes[index]
                    if byte >= 0x80 { ascii = false }
                    if Self.lowered(byte) == lower[0] {
                        var matched = 1
                        while matched < length, Self.lowered(bytes[index + matched]) == lower[matched] { matched += 1 }
                        if matched == length { return (index, ascii) }
                    }
                    index += 1
                }
                if ascii { ascii = bytes[index...].allSatisfy { $0 < 0x80 } }
                return (nil, ascii)
            }
            if let offset = hit.offset {
                let start = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
                return start..<text.utf8.index(start, offsetBy: pattern.count)
            }
            // Not there as bytes; in ASCII text, not there at all (an accent could only match in non-ASCII text).
            if hit.ascii { return nil }
        }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
    }

    private static func lowered(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// What's set in bold: each occurrence of the query in `plain` (or, when it isn't there whole, of its words of two
    /// letters and more), in order, not overlapping.
    static func matches(of query: String, in plain: String) -> [Range<String.Index>] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let parts = plain.range(of: query, options: options) != nil
            ? [query] : query.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        var ranges: [Range<String.Index>] = []
        for part in parts {
            var searchStart = plain.startIndex
            while let range = plain.range(of: part, options: options, range: searchStart..<plain.endIndex) {
                ranges.append(range)
                searchStart = range.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var kept: [Range<String.Index>] = []
        for range in ranges where range.lowerBound >= (kept.last?.upperBound ?? plain.startIndex) {
            kept.append(range)
        }
        return kept
    }
}

/// The field row both panels share, Spotlight-style: a quiet monochrome symbol saying which panel this is, the field,
/// then what goes on the right (a spinner, the options button).
struct PanelHeader<Trailing: View>: View {
    let symbol: String
    @Binding var text: String
    let placeholder: String
    let onField: (NSTextField) -> Void
    var onSymbol: (SymbolLayerView) -> Void = { _ in }
    var onPlaceholder: (PlaceholderView) -> Void = { _ in }
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Spotlight's spacing: the magnifier 20 points in, the text from 60.
        HStack(spacing: 10) {
            FieldSymbol(name: symbol, onMake: onSymbol)
                .frame(width: 32, height: 32)
            SearchField(text: $text, fontSize: PanelChrome.fieldFontSize, placeholder: placeholder, onMake: onField,
                        onPlaceholder: onPlaceholder)
            trailing
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: PanelChrome.fieldHeight)
        .background(PanelDragArea())
    }
}

/// A divider that stops short of the panel's edges, as Spotlight draws them.
struct InsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

/// A small capsule control's look: Liquid Glass on macOS 26 (as the options button's), before then a faint fill and
/// rim. `tint`: a colour through it (red: a delete that asks to be clicked again). `interactive`: the glass answers
/// the pointer (a SwiftUI button's; one clicked through an AppKit view never hears it).
struct CapsuleChrome: ViewModifier {
    var tint: Color?
    var interactive = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(Glass.chrome(tint: tint, interactive: interactive), in: .capsule)
        } else {
            content
                .background(Capsule().fill(tint?.opacity(0.12) ?? Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(tint?.opacity(0.3) ?? Color.primary.opacity(0.08)))
        }
    }
}

extension View {
    func capsuleChrome(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(CapsuleChrome(tint: tint, interactive: interactive))
    }
}

@available(macOS 26.0, *)
extension Glass {
    /// The controls' glass: regular, a colour through it, answering the pointer.
    static func chrome(tint: Color? = nil, interactive: Bool = false) -> Glass {
        let glass = tint.map { Glass.regular.tint($0.opacity(0.3)) } ?? .regular
        return glass.interactive(interactive)
    }
}

/// A destructive action asking to be clicked again, the same wherever it is: a trash can and the question in red, on
/// red glass, 24 points high ("Delete?" for a snippet or folder, "Clear (18)?" for the history).
struct ConfirmLabel: View {
    let title: String
    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "trash")
                .font(.system(size: 10.5, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(Color.red)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .capsuleChrome(tint: .red, interactive: true)
        .contentShape(Capsule())
    }
}

/// A small round button in the field row (the options menu).
struct CircleIcon: View {
    let symbol: String
    var size: CGFloat = 28
    /// A colour for something to see to (recording paused); nil: as quiet as the rest.
    var tint: Color?
    /// Its glass answers the pointer (in a SwiftUI button).
    var interactive = false

    var body: some View {
        let icon = Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
        if #available(macOS 26.0, *) {   // a drop of Liquid Glass
            icon
                .glassEffect(Glass.chrome(tint: tint, interactive: interactive), in: .circle)
                .contentShape(Circle())
        } else {
            icon
                .background(Circle().fill(tint?.opacity(0.16) ?? Color.primary.opacity(0.07)))
                .overlay(Circle().strokeBorder(tint?.opacity(0.4) ?? Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
    }
}

/// "…": Settings, pausing the recording, quitting: there even with the menu bar icon hidden.
/// While recording's paused it's "!" in orange instead, saying so on hover, its menu's Settings in orange too (the
/// switch is there, as orange). An AppKit menu: SwiftUI's menus drop their items' colours.
///
/// "…" goes a moment after the panel opens (at once with typing), and comes back while the pointer's over the panel;
/// "!" stays. On macOS 26
/// it's a drop of Liquid Glass, going and coming as one (shrinking into nothing); before, it fades.
struct OptionsButton: View {
    let app: AppController
    /// The panel's `opened`: each time it opens, the button's there again for a moment, but not when `quietly`
    /// (switching between the panels).
    let opened: Int
    var quietly = false
    /// What's typed in the panel's field: typing sends the button away at once.
    let query: String
    /// The panel is searching: a spinner where the button is, under it while it's there.
    var busy = false
    @AppStorage("paused") private var paused = false   // follows every switch for it (Settings, the menus)
    @State private var resting = false
    @State private var pointerOver = false
    /// Where the pointer was as typing sent the button away: over the panel, it brings it back only once it moves.
    @State private var stillPointer: NSPoint?
    @State private var menuUp = false
    @State private var anchor = OptionsMenu.Anchor()   // one for the button's life (a let was made anew each update)
    private static let shownFor: Duration = .seconds(1.5)
    private static let side: CGFloat = 28

    private var shown: Bool { paused || pointerOver || menuUp || !resting }

    var body: some View {
        ZStack {
            OptionsMenu.AnchorView(anchor: anchor)   // where the menu goes, whether the button's here or not
            if busy {
                ProgressView().controlSize(.small)
                    .opacity(shown ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: shown)
            }
            if #available(macOS 26.0, *) { glassButton } else { fadingButton }
        }
        .frame(width: Self.side, height: Self.side)
        .help(paused ? "Recording is paused: new copies aren't saved. Resume it here or in Settings." : "Options")
        .onChange(of: query) { _, _ in
            resting = true
            stillPointer = NSEvent.mouseLocation
            pointerOver = false
        }
        .task(id: opened) {
            var instantly = Transaction()
            instantly.disablesAnimations = true   // there as the panel opens, not coming in
            withTransaction(instantly) {
                resting = quietly
                stillPointer = nil
            }
            // Whether the pointer's over the panel, looked at while it's up (tracking areas missed it being there
            // as the panel opened, and the way out then).
            let start = ContinuousClock.now
            while !Task.isCancelled {
                guard let window = anchor.view?.window, window.isVisible else {
                    if ContinuousClock.now - start > .seconds(1) { break }   // closed (or not up yet)
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let location = NSEvent.mouseLocation
                if let still = stillPointer, still != location { stillPointer = nil }
                let over = stillPointer == nil && (OptionsMenu.debugPointerOver ?? window.frame.contains(location))
                if over != pointerOver { pointerOver = over }
                if !resting, ContinuousClock.now - start >= Self.shownFor { resting = true }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func openMenu() {
        menuUp = true   // the pointer goes off the panel onto the menu
        OptionsMenu.popUp(app: app, below: anchor.view)
        menuUp = false
    }

    /// A drop of glass: going, it shrinks and blurs away; coming, it swells out of a blur with a little bounce.
    /// (Glass's own transitions, in a GlassEffectContainer, brought it in so, but took it away in one frame.)
    @available(macOS 26.0, *)
    private var glassButton: some View {
        Button(action: openMenu) {
            Image(systemName: paused ? "exclamationmark" : "ellipsis")
                .font(.system(size: Self.side * 0.45, weight: .semibold))
                .foregroundStyle(paused ? AnyShapeStyle(OptionsMenu.pausedColor) : AnyShapeStyle(.secondary))
                .frame(width: Self.side, height: Self.side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(paused ? .regular.tint(OptionsMenu.pausedColor.opacity(0.3)).interactive()
                            : .regular.interactive(), in: .circle)
        .scaleEffect(shown ? 1 : 0.3)
        .blur(radius: shown ? 0 : 5)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(shown ? .spring(duration: 0.4, bounce: 0.35) : .spring(duration: 0.55, bounce: 0), value: shown)
    }

    private var fadingButton: some View {
        Button(action: openMenu) {
            CircleIcon(symbol: paused ? "exclamationmark" : "ellipsis", tint: paused ? OptionsMenu.pausedColor : nil)
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: shown ? 0.15 : 0.35), value: shown)
    }
}

enum OptionsMenu {
    static let pausedColor = Color(nsColor: .systemOrange)
    /// The menu up now (debug runs close it).
    static weak var shown: NSMenu?
    /// Debug runs: the pointer taken as over the panels, or not, wherever it is (nil: where it is).
    static var debugPointerOver: Bool?

    /// Under the button, its left edges lined up, as a SwiftUI menu button's.
    static func popUp(app: AppController, below view: NSView?) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let settings = item("Settings…") { app.openSettings() }
        if Settings.paused {
            settings.attributedTitle = NSAttributedString(string: settings.title, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemOrange,
            ])
        }
        menu.addItem(settings)
        menu.addItem(item(Settings.paused ? "Resume Recording" : "Pause Recording") { Settings.paused.toggle() })
        menu.addItem(.separator())
        menu.addItem(item("Quit Pastemind") { NSApp.terminate(nil) })
        shown = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }

    private static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.choose), keyEquivalent: "")
        item.target = action
        item.representedObject = action   // the target's weak
        return item
    }

    private final class Action: NSObject {
        let run: () -> Void

        init(_ run: @escaping () -> Void) {
            self.run = run
        }

        @objc func choose() { run() }
    }

    /// Where the button is, for the menu.
    final class Anchor {
        weak var view: NSView?
    }

    struct AnchorView: NSViewRepresentable {
        let anchor: Anchor

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
}
