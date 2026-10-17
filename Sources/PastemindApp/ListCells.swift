import AppKit
import PastemindKit

/// The rows of the panels' lists, as they were in SwiftUI, point for point: a 30-point icon, the title over a quieter
/// line, the ⌘ number at the right.
///
/// The titles show no match in bold: SwiftUI's bold over their medium weight changed nothing (seen 2026-10-14), so
/// they never did; the subtitle's matches are bold.
enum RowStyle {
    static let title = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let subtitle = NSFont.systemFont(ofSize: 11)
    static let subtitleBold = NSFont.systemFont(ofSize: 11, weight: .bold)
    static let shortcut = Draw.roundedFont(size: 11, monospacedDigits: true)
    static let header = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let keycap = Draw.roundedFont(size: 10.5, weight: .semibold)
    static let icon: CGFloat = 30

    /// The ⌘ number, right-aligned to `right` and centered on `midY`: its left edge.
    @discardableResult
    static func drawShortcut(_ number: Int, right: CGFloat, midY: CGFloat, font: NSFont = shortcut,
                             color: NSColor = .tertiaryLabelColor, in cell: ListCell) -> CGFloat {
        let text = Draw.text("⌘\(number)", font: font, color: color)
        let width = Draw.width(text)
        let x = cell.pixel(right - width)
        Draw.line(text, x: x, top: cell.pixel(midY - Draw.lineHeight(font) / 2), width: width + 1)
        return x
    }

    /// A key as a small cap ("↩"), right-aligned to `right` and centered on `midY`: its left edge.
    @discardableResult
    static func drawKeycap(_ key: String, right: CGFloat, midY: CGFloat, in cell: ListCell) -> CGFloat {
        let text = Draw.text(key, font: keycap, color: .secondaryLabelColor)
        let textWidth = Draw.width(text)
        let lineHeight = Draw.lineHeight(keycap)
        let width = max(17, textWidth) + (key.count > 1 ? 8 : 0)
        let height = max(17, lineHeight)
        let frame = NSRect(x: cell.pixel(right - width), y: cell.pixel(midY - height / 2), width: width, height: height)
        NSColor.labelColor.opacity(0.07).setFill()
        Draw.rounded(frame, radius: 4.5).fill()
        Draw.border(frame, radius: 4.5, color: NSColor.labelColor.opacity(0.08))
        Draw.line(text, x: cell.pixel(frame.midX - textWidth / 2), top: cell.pixel(frame.midY - lineHeight / 2),
                  width: textWidth + 1)
        return frame.minX
    }
}

/// "PINNED", "RECENT" over the clipboard history's sections.
final class SectionCell: ListCell {
    static let height: CGFloat = 8 + Draw.lineHeight(RowStyle.header) + 3
    private var title = NSAttributedString()

    override var interactive: Bool { false }

    func configure(_ title: String) {
        self.title = Draw.text(title.uppercased(), font: RowStyle.header, color: .secondaryLabelColor, tracking: 0.6)
        needsDisplay = true
    }

    override func drawRow(in rect: NSRect) {
        Draw.line(title, x: rect.minX + 10, top: rect.minY + 8, width: rect.width - 20)
    }
}

/// A clip in the history: its icon, its first line (the match in bold), and where and when it came from, or the
/// matching line when the match is further in.
final class ClipCell: ListCell {
    static let height: CGFloat = 6 + Draw.lineHeight(RowStyle.title) + 2 + Draw.lineHeight(RowStyle.subtitle) + 6
    private var row: PanelRow?
    private var shortcut: Int?
    private var title = NSAttributedString()
    private var subtitle = NSAttributedString()
    /// The picture's small copy, once decoded; for a video, a GIF or a picture copied as a file, Quick Look's.
    private var thumbnail: NSImage?
    /// Whose thumbnail it is: the picture's name, or the file's path.
    private var thumbnailKey: String?

    func configure(_ row: PanelRow, query: String, shortcut: Int?) {
        let clip = row.clip
        let typed = query.trimmingCharacters(in: .whitespaces)
        let media = Thumbnails.mediaPath(of: clip)
        let key = clip.kind == .image ? clip.image : media
        if thumbnailKey != key || key == nil { thumbnail = nil }
        thumbnailKey = key
        self.row = row
        self.shortcut = shortcut
        title = Draw.text(Self.listTitle(clip), font: RowStyle.title, color: .labelColor)
        subtitle = Self.subtitle(row, typed: typed)
        alphaValue = row.weak && !selected ? 0.55 : 1
        if clip.kind == .image, let name = clip.image, thumbnail == nil {
            thumbnail = ImageCache.shared.cached(name, pixels: Pictures.iconPixels)
            if thumbnail == nil {
                Task { [weak self] in
                    let image = await ImageCache.shared.load(name, pixels: Pictures.iconPixels)
                    guard let self, self.thumbnailKey == name else { return }
                    self.thumbnail = image
                    self.needsDisplay = true
                }
            }
        }
        if let media, thumbnail == nil {
            thumbnail = Thumbnails.shared.cached(media, side: RowStyle.icon)
            if thumbnail == nil {
                Task { [weak self] in
                    let image = await Thumbnails.shared.load(media, side: RowStyle.icon)
                    guard let self, self.thumbnailKey == media else { return }
                    self.thumbnail = image
                    self.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    override func selectionChanged() {
        super.selectionChanged()
        alphaValue = row?.weak == true && !selected ? 0.55 : 1
    }

    /// A link without its scheme and "www.": the narrow column shows where it goes, not "https://www.". A video
    /// file's name after "File: ".
    static func listTitle(_ clip: Clip) -> String {
        // A video copied as a file: its cover shows a frame of it, the title that it's a file.
        if Thumbnails.isMedia(clip), !clip.isPictureFile { return "File: " + clip.title }
        guard clip.kind == .link else { return clip.title }
        var link = clip.title
        for prefix in ["https://", "http://"] where link.hasPrefix(prefix) { link.removeFirst(prefix.count) }
        if link.hasPrefix("www.") { link.removeFirst(4) }
        return link
    }

    /// The matching line when the match isn't in the title; else the app it was copied in and how long ago.
    private static func subtitle(_ row: PanelRow, typed: String) -> NSAttributedString {
        let clip = row.clip
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        // The title already shows (and highlights) a match in the first line; a meaning match has no words to show.
        if !typed.isEmpty, row.words, clip.kind != .link, clip.kind != .image || !clip.text.isEmpty,
           clip.title.range(of: typed, options: options) == nil,
           let line = Excerpt.line(clip.text, query: typed) {
            return Draw.text(line, font: RowStyle.subtitle, color: .secondaryLabelColor,
                             query: typed.trimmingCharacters(in: .whitespacesAndNewlines), bold: RowStyle.subtitleBold)
        }
        // "Zed · 4h", the app's name in bold when it's what was found. (What it is: the title and the icon say.) Of
        // several files, the one that was found instead.
        let line = NSMutableAttributedString()
        if let file = row.file {
            line.append(Draw.text(file + " · ", font: RowStyle.subtitle, color: .secondaryLabelColor))
        } else if let app = clip.appName {
            line.append(Draw.text(app, font: RowStyle.subtitle, color: .secondaryLabelColor, query: typed,
                                  bold: RowStyle.subtitleBold))
            line.append(Draw.text(" · ", font: RowStyle.subtitle, color: .secondaryLabelColor))
        }
        line.append(Draw.text(When.short(clip.lastCopied), font: RowStyle.subtitle, color: .secondaryLabelColor))
        return line
    }

    override func drawRow(in rect: NSRect) {
        guard let row else { return }
        let clip = row.clip
        let side = RowStyle.icon
        let icon = NSRect(x: rect.minX + 8, y: rect.minY + pixel((rect.height - side) / 2), width: side, height: side)
        drawIcon(clip, in: icon)
        // Right to left, 10 points apart: the ⌘ number, the pin, at least 4 points of nothing, the text.
        var right = rect.maxX - 8
        if let shortcut {
            right = RowStyle.drawShortcut(shortcut, right: right, midY: rect.midY,
                                          color: selected ? .secondaryLabelColor : .tertiaryLabelColor, in: self) - 10
        }
        if clip.pinned, let pin = Draw.symbolImage("pin.fill", size: 9, weight: .regular) {
            let frame = NSRect(x: pixel(right - pin.size.width), y: rect.minY, width: pin.size.width, height: rect.height)
            right = Draw.symbol("pin.fill", size: 9, weight: .regular, color: .secondaryLabelColor, centeredIn: frame) - 10
        }
        right -= 4 + 10
        let x = icon.maxX + 10
        let titleHeight = Draw.lineHeight(RowStyle.title)
        let top = rect.minY + pixel((rect.height - titleHeight - 2 - Draw.lineHeight(RowStyle.subtitle)) / 2)
        Draw.line(title, x: x, top: top, width: right - x)
        Draw.line(subtitle, x: x, top: top + titleHeight + 2, width: right - x)
    }

    /// The picture for an image clip, a swatch for a color, the file's icon for files, else what it is; and on every
    /// one the app it came from, as a badge.
    private func drawIcon(_ clip: Clip, in rect: NSRect) {
        switch clip.kind {
        case .image:
            if let thumbnail {
                drawPicture(thumbnail, in: rect)
            } else {
                Draw.tile(rect, symbol: Icons.symbol(for: clip.kind), tint: Icons.tint(for: clip.kind))
            }
        case .color:
            // The kind's tiles' size and corners, as the pictures.
            (ColorParser.color(clip.text).map { NSColor($0) } ?? .systemGray).setFill()
            Draw.rounded(rect, radius: Draw.tileRadius(rect)).fill()
            Draw.border(rect, radius: Draw.tileRadius(rect), color: NSColor.labelColor.opacity(0.15))
        case .file:
            if let thumbnail {
                drawPicture(thumbnail, in: rect)
            } else if let url = clip.fileURLs.first {
                Icons.file(url).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                                     hints: nil)
            } else {
                Draw.tile(rect, symbol: Icons.symbol(for: clip.kind), tint: Icons.tint(for: clip.kind))
            }
        default:
            Draw.tile(rect, symbol: Icons.symbol(for: clip.kind), tint: Icons.tint(for: clip.kind))
        }
        drawBadge(clip.appID, on: rect)
    }

    /// A picture's (or a video's) small copy, the kind's tiles' size and corners, with a faint line round it as the
    /// colour swatches have: a dark screenshot melted into the row without one.
    private func drawPicture(_ image: NSImage, in rect: NSRect) {
        Draw.fill(image, in: rect, radius: Draw.tileRadius(rect))
        Draw.border(rect, radius: Draw.tileRadius(rect), color: NSColor.labelColor.opacity(0.15))
    }
}

extension ListCell {
    /// The app's icon over the bottom right corner, a little outside it.
    func drawBadge(_ appID: String?, on rect: NSRect) {
        let side = rect.width * 0.55
        guard let badge = Icons.app(appID, side: side) else { return }
        let frame = NSRect(x: pixel(rect.maxX - side + rect.width * 0.16),
                           y: pixel(rect.maxY - side + rect.width * 0.16), width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        badge.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A copy on its way into the history (a browser still encoding a picture, a big picture being saved): where its row
/// will be, at once, with a spinner on the icon, the app it comes from and "now".
final class IncomingCell: ListCell {
    private let spinner = NSProgressIndicator()
    private var appID: String?
    private var title = Draw.text("Copying…", font: RowStyle.title, color: .secondaryLabelColor)
    private var subtitle = NSAttributedString()

    override var interactive: Bool { false }

    required init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ source: CaptureSource) {
        appID = source.appID
        subtitle = Draw.text([source.appName, "now"].compactMap { $0 }.joined(separator: " · "),
                             font: RowStyle.subtitle, color: .secondaryLabelColor)
        spinner.startAnimation(nil)
        needsDisplay = true
    }

    private var icon: NSRect {
        let rect = content, side = RowStyle.icon
        return NSRect(x: rect.minX + 8, y: rect.minY + pixel((rect.height - side) / 2), width: side, height: side)
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        spinner.frame = NSRect(x: icon.midX - side / 2, y: icon.midY - side / 2, width: side, height: side)
    }

    override func drawRow(in rect: NSRect) {
        let icon = self.icon
        NSColor.labelColor.opacity(0.06).setFill()
        Draw.rounded(icon, radius: Draw.tileRadius(icon)).fill()
        Draw.border(icon, radius: Draw.tileRadius(icon), color: NSColor.labelColor.opacity(0.1))
        drawBadge(appID, on: icon)
        let x = icon.maxX + 10, right = rect.maxX - 8 - 14
        let titleHeight = Draw.lineHeight(RowStyle.title)
        let top = rect.minY + pixel((rect.height - titleHeight - 2 - Draw.lineHeight(RowStyle.subtitle)) / 2)
        Draw.line(title, x: x, top: top, width: right - x)
        Draw.line(subtitle, x: x, top: top + titleHeight + 2, width: right - x)
    }
}

/// A snippet: its name (the match in bold) over its first line.
final class SnippetCell: ListCell {
    static let height: CGFloat = 45
    private var shortcut: Int?
    private var title = NSAttributedString()
    private var subtitle = NSAttributedString()

    /// `folder`: the name of the one it's in, shown before its text (found at the top).
    func configure(_ snippet: Snippet, folder: String? = nil, shortcut: Int?) {
        self.shortcut = shortcut
        title = Draw.text(snippet.title.isEmpty ? "Untitled" : snippet.title, font: RowStyle.title, color: .labelColor)
        let text = snippet.text.isEmpty ? "Empty" : Clip.firstLine(of: snippet.text)
        subtitle = Draw.text(folder.map { "\($0) · \(text)" } ?? text, font: RowStyle.subtitle,
                             color: .secondaryLabelColor)
        needsDisplay = true
    }

    override func drawRow(in rect: NSRect) {
        let side = RowStyle.icon
        let icon = NSRect(x: rect.minX + 8, y: rect.minY + pixel((rect.height - side) / 2), width: side, height: side)
        Draw.tile(icon, symbol: "text.quote", tint: .systemGray)   // gray, as text and code: the symbol tells it
        var right = rect.maxX - 8
        if selected {
            right = RowStyle.drawKeycap("↩", right: right, midY: rect.midY, in: self) - 10
        } else if let shortcut {
            right = RowStyle.drawShortcut(shortcut, right: right, midY: rect.midY, in: self) - 10
        }
        right -= 4 + 10
        let x = icon.maxX + 10
        let titleHeight = Draw.lineHeight(RowStyle.title)
        let top = rect.minY + pixel((rect.height - titleHeight - 2 - Draw.lineHeight(RowStyle.subtitle)) / 2)
        Draw.line(title, x: x, top: top, width: right - x)
        Draw.line(subtitle, x: x, top: top + titleHeight + 2, width: right - x)
    }
}

/// A folder of snippets: its name and how many it has; ↩ (or a double click) opens it.
final class FolderCell: ListCell {
    private var title = NSAttributedString()
    private var subtitle = NSAttributedString()

    func configure(_ folder: SnippetFolder, count: Int) {
        title = Draw.text(folder.name.isEmpty ? "Untitled folder" : folder.name, font: RowStyle.title,
                          color: .labelColor)
        subtitle = Draw.text(count == 0 ? "Empty" : count == 1 ? "1 snippet" : "\(count) snippets",
                             font: RowStyle.subtitle, color: .secondaryLabelColor)
        needsDisplay = true
    }

    override func drawRow(in rect: NSRect) {
        let side = RowStyle.icon
        let icon = NSRect(x: rect.minX + 8, y: rect.minY + pixel((rect.height - side) / 2), width: side, height: side)
        Draw.tile(icon, symbol: "folder.fill", tint: .systemGray)
        var right = rect.maxX - 8
        if selected {
            right = RowStyle.drawKeycap("↩", right: right, midY: rect.midY, in: self) - 10
        } else {
            let chevron = NSRect(x: right - 17, y: rect.minY, width: 17, height: rect.height)
            right = Draw.symbol("chevron.right", size: 11, weight: .semibold, color: .tertiaryLabelColor,
                                centeredIn: chevron) - 10
        }
        right -= 4 + 10
        let x = icon.maxX + 10
        let titleHeight = Draw.lineHeight(RowStyle.title)
        let top = rect.minY + pixel((rect.height - titleHeight - 2 - Draw.lineHeight(RowStyle.subtitle)) / 2)
        Draw.line(title, x: x, top: top, width: right - x)
        Draw.line(subtitle, x: x, top: top + titleHeight + 2, width: right - x)
    }
}

/// An app, pane or file in search: its icon, its name with the typed letters in bold, and where it is; a file found by
/// what's in it says so before where it is.
final class LaunchCell: ListCell {
    static let title = NSFont.systemFont(ofSize: 15, weight: .medium)
    static let subtitle = NSFont.systemFont(ofSize: 11.5)
    static let shortcut = Draw.roundedFont(size: 12, monospacedDigits: true)
    static let side: CGFloat = 34
    private var item: LaunchItem?
    private var byContent = false
    private var shortcut: Int?
    private var title = NSAttributedString()
    private var path = ""
    /// The file's Quick Look picture, once made.
    private var thumbnail: NSImage?

    func configure(_ result: LaunchResult, shortcut: Int?) {
        let item = result.item
        if self.item?.path != item.path { thumbnail = nil }
        self.item = item
        byContent = result.byContent
        self.shortcut = shortcut
        title = Draw.text(item.name, font: Self.title, color: .labelColor)
        if item.kind == .file, thumbnail == nil {
            let path = item.path
            thumbnail = Thumbnails.shared.cached(path, side: Self.side)
            if thumbnail == nil {
                Task { [weak self] in
                    let image = await Thumbnails.shared.load(path, side: Self.side)
                    guard let self, self.item?.path == path else { return }
                    self.thumbnail = image
                    self.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    private func iconFrame(in rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 11, y: rect.minY + pixel((rect.height - Self.side) / 2), width: Self.side, height: Self.side)
    }

    override func drawRow(in rect: NSRect) {
        guard let item else { return }
        let side = Self.side
        let icon = iconFrame(in: rect)
        if let thumbnail {
            drawThumbnail(thumbnail, in: icon)
        } else {
            Icons.path(item.path, side: side).draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1,
                                                   respectFlipped: true, hints: nil)
        }
        var right = rect.maxX - 11
        if selected {
            right = RowStyle.drawKeycap("↩", right: right, midY: rect.midY, in: self) - 12
        } else if let shortcut {
            right = RowStyle.drawShortcut(shortcut, right: right, midY: rect.midY, font: Self.shortcut, in: self) - 12
        }
        right -= 8 + 12
        let x = icon.maxX + 12
        let titleHeight = Draw.lineHeight(Self.title)
        let top = rect.minY + pixel((rect.height - titleHeight - 2 - Draw.lineHeight(Self.subtitle)) / 2)
        Draw.line(title, x: x, top: top, width: right - x)
        let subtitle = NSMutableAttributedString()
        if byContent {
            subtitle.append(Draw.text("By content · ", font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                      color: selected ? NSColor.labelColor.opacity(0.9) : .controlAccentColor,
                                      truncation: .byTruncatingMiddle))
        }
        subtitle.append(Draw.text(item.subtitle, font: Self.subtitle,
                                  color: selected ? NSColor.labelColor.opacity(0.75) : .secondaryLabelColor,
                                  truncation: .byTruncatingMiddle))
        Draw.line(subtitle, x: x, top: top + titleHeight + 2, width: right - x)
    }

    /// The icon or the file's picture as the row draws it, and where (in the cell): Quick Look zooms out of it and back
    /// into it. A bitmap: Quick Look draws an image drawn on demand as a black box.
    func picture(scale: CGFloat) -> (frame: NSRect, image: NSImage)? {
        guard let item else { return nil }
        let icon = iconFrame(in: content)
        let frame = thumbnail.map { Self.fitted($0.size, in: icon) } ?? icon
        guard frame.width > 0, frame.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * scale),
                                         pixelsHigh: Int(frame.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        rep.size = frame.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: frame.size)
        if let thumbnail {
            Draw.fill(thumbnail, in: rect, radius: Self.radius(icon))
        } else {
            Icons.path(item.path).draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: frame.size)
        image.addRepresentation(rep)
        return (frame, image)
    }

    private static func fitted(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(rect.width / size.width, rect.height / size.height)
        return NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                      width: size.width * scale, height: size.height * scale)
    }

    private static func radius(_ icon: NSRect) -> CGFloat { max(3, icon.width * 0.06) }

    /// A file's Quick Look picture fitted in the icon's square, its corners rounded, on a faint shadow.
    private func drawThumbnail(_ image: NSImage, in rect: NSRect) {
        let fitted = Self.fitted(image.size, in: rect)
        guard fitted.width > 0 else { return }
        let radius = Self.radius(rect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        // The shadow of the rounded picture as a whole, not of each thing drawn.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        Draw.fill(image, in: fitted, radius: radius)
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }
}
