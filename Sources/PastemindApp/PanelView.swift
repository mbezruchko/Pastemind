import AppKit
import PastemindKit
import SwiftUI
import UniformTypeIdentifiers

/// The clipboard history's field row.
struct ClipboardHeaderView: View {
    @Bindable var controller: PanelController

    var body: some View {
        PanelHeader(symbol: controller.symbol, text: $controller.query, placeholder: controller.placeholder,
                    onField: { controller.field = $0 }, onSymbol: { controller.symbolView = $0 },
                    onPlaceholder: { controller.placeholderView = $0 }) {
            OptionsButton(app: controller.app, opened: controller.opened, quietly: controller.openedQuietly,
                          query: controller.query, busy: controller.searching)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PanelChrome.fieldHeight)
        .background(PanelChrome.tint)
    }
}

/// The clipboard history's body: the list and the preview, or the snippets (the part that comes and goes when
/// switching). What an action did shows a moment at the bottom.
struct ClipboardBodyView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(spacing: 0) {
            InsetDivider()
            content
                .frame(maxHeight: .infinity)
        }
        .frame(width: PanelController.width, height: PanelController.height - PanelChrome.fieldHeight)
        .background(PanelChrome.tint)
        .overlay(alignment: .bottom) {
            if let note = controller.note {
                NoteToast(text: note)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: controller.note)
    }

    @ViewBuilder private var content: some View {
        if controller.mode == .snippets {
            SnippetsContent(controller: controller)
        } else if controller.rows.isEmpty {
            EmptyState(controller: controller)
        } else {
            HStack(spacing: 0) {
                ClipList(controller: controller)
                    .frame(width: PanelController.listWidth)
                Divider()
                Group {
                    if let clip = controller.selectedClip {
                        // No .id per clip: moving along the list keeps the preview's text view and gives it the
                        // next clip's text, instead of building a new one each step.
                        ClipPreview(clip: clip, query: controller.shownWords, rich: clip.richType != nil,
                                    anchor: controller.pictureAnchor, lifted: controller.lifted,
                                    fileAnchor: controller.fileAnchor, liftedFile: controller.liftedFile,
                                    lookAt: controller.look(at:),
                                    dragBegan: controller.dragBegan, dragEnded: controller.dragEnded)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Rows kept from before while the typing since found nothing: not what ↩ would paste.
            .opacity(controller.stale ? 0.45 : 1)
        }
    }
}

/// The pointing hand over something that opens a link (macOS 15 on; the arrow before).
private struct LinkPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.pointerStyle(.link) } else { content }
    }
}

/// What an action just did ("Saved as a snippet"), a moment over the bottom of the panel.
/// A note for a moment, floating over the bottom of the panel: a drop of Liquid Glass on macOS 26, before then a
/// capsule of material with a shadow.
private struct NoteToast: View {
    let text: String

    var body: some View {
        let label = Text(text)
            .font(.system(size: 11.5))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 26)
        Group {
            if #available(macOS 26.0, *) {
                label
                    .foregroundStyle(.primary)
                    .glassEffect(.regular, in: .capsule)
            } else {
                label
                    .foregroundStyle(.secondary)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct EmptyState: View {
    let controller: PanelController

    var body: some View {
        VStack(spacing: 8) {
            if controller.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Brand.gradient)
                    .padding(.bottom, 4)
                Text("Nothing copied yet").font(.system(size: 15, weight: .semibold))
                Text("Copy something anywhere and it shows up here. Press \(controller.hotkeyDisplay) to come back.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            } else if controller.phase == .words {
                Text("Searching…").foregroundStyle(.secondary)
            } else {
                Text("No matches").font(.system(size: 15, weight: .semibold))
                Text(controller.app.modelState == .ready
                     ? "Try other words, or say what the clip was about."
                     : "Meaning search starts once the model is ready (\(controller.app.modelLine)).")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The history, or the results: an AppKit list (see `ListView`), its rows drawn as the SwiftUI ones were.
private struct ClipList: View {
    let controller: PanelController

    var body: some View {
        // Read here, so a change to any of them updates the list.
        ClipTable(controller: controller, shown: .init(
            sections: controller.sections, query: controller.shownWords,
            shortcuts: controller.shortcuts, selection: controller.selection, resultsVersion: controller.resultsVersion))
    }
}

private struct ClipTable: NSViewRepresentable {
    struct Shown {
        var sections: [PanelSection]
        var query: String
        var shortcuts: [Int64: Int]
        var selection: Int64?
        var resultsVersion: Int
    }

    let controller: PanelController
    let shown: Shown

    func makeNSView(context: Context) -> ListView {
        // The first row as far from the divider above as from the sides.
        let list = ListView(layout: .init(inset: 8, top: 8, bottom: 8, gap: 1))
        list.source = context.coordinator
        return list
    }

    func updateNSView(_ list: ListView, context: Context) {
        context.coordinator.update(shown, list)
    }

    func makeCoordinator() -> Rows { Rows(controller: controller) }

    final class Rows: ListSource {
        private enum Item {
            case header(String)
            case incoming(CaptureSource)
            case row(PanelRow)
        }

        private let controller: PanelController
        private var sections: [PanelSection]?
        private var items: [Item] = []
        private var index: [Int64: Int] = [:]
        private var query = ""
        private var shortcuts: [Int64: Int] = [:]
        private var selection: Int64?
        private var resultsVersion = 0

        init(controller: PanelController) { self.controller = controller }

        /// What changed since the last time: new rows (or the same ones for another query) are made again; a moved
        /// selection only redraws two rows.
        func update(_ shown: Shown, _ list: ListView) {
            let (sections, query, shortcuts) = (shown.sections, shown.query, shown.shortcuts)
            let (selection, resultsVersion) = (shown.selection, shown.resultsVersion)
            let changed = sections != self.sections
            if changed {
                self.sections = sections
                items = sections.flatMap { section in
                    (section.title.map { [Item.header($0)] } ?? []) + (section.incoming.map { [Item.incoming($0)] } ?? [])
                        + section.rows.map(Item.row)
                }
                index = [:]
                for (position, item) in items.enumerated() {
                    if case .row(let row) = item { index[row.id] = position }
                }
            }
            let selected = selection.flatMap { index[$0] }
            if changed || query != self.query || shortcuts != self.shortcuts {
                self.query = query
                self.shortcuts = shortcuts
                list.reload(selected: selected)
            } else {
                list.select(selected)
            }
            if resultsVersion != self.resultsVersion {
                list.scrollToTop()
            } else if selection != self.selection, let selected {
                list.scrollToVisible(selected)
            }
            self.selection = selection
            self.resultsVersion = resultsVersion
        }

        var rowCount: Int { items.count }

        func rowHeight(_ row: Int) -> CGFloat {
            if case .header = items[row] { return SectionCell.height }
            return ClipCell.height
        }

        func cell(_ row: Int, in list: ListView) -> ListCell {
            switch items[row] {
            case .header(let title):
                let cell = list.reuse(SectionCell.self)
                cell.configure(title)
                return cell
            case .incoming(let source):
                let cell = list.reuse(IncomingCell.self)
                cell.configure(source)
                return cell
            case .row(let clipRow):
                let cell = list.reuse(ClipCell.self)
                cell.configure(clipRow, query: query, shortcut: shortcuts[clipRow.id])
                return cell
            }
        }

        func click(_ row: Int, count: Int) {
            guard case .row(let clipRow) = items[row] else { return }
            controller.select(clipRow.id)
            if count >= 2 { controller.paste(plain: false) }
        }

        func dragWriters(_ row: Int) -> [NSPasteboardWriting] {
            guard case .row(let clipRow) = items[row] else { return [] }
            return ClipDrag.writers(for: clipRow.clip)
        }

        func dragBegan(_ row: Int) { controller.dragBegan() }
        func dragEnded(_ row: Int, dropped: Bool) { controller.dragEnded(dropped: dropped) }
    }
}

/// The selected clip, big: the whole text (code in monospace), the picture, the color, the files; then where it came
/// from and when.
struct ClipPreview: View {
    let clip: Clip
    let query: String
    let rich: Bool
    /// Marks the picture (or the first file's icon) for Quick Look's zoom; `lifted` while it's out there.
    let anchor: ScreenAnchor
    let lifted: Bool
    /// Several files: each one's place in the grid (by path), the one Quick Look has out, and a click on one.
    var fileAnchor: (String) -> ScreenAnchor = { _ in ScreenAnchor() }
    var liftedFile: String?
    var lookAt: (URL) -> Void = { _ in }
    /// The picture, the files, the colour or the link drag out of here (see `ClipDrag`).
    var dragBegan: () -> Void = {}
    var dragEnded: (Bool) -> Void = { _ in }
    /// The text read from a picture, under it (Settings can hide it).
    @AppStorage(Settings.showsPictureTextKey) private var showsPictureText = false
    @AppStorage(Settings.highlightsCodeKey) private var highlightsCode = true
    /// Code's colours, with the text they're for (the view outlives the clip it shows).
    @State private var syntax: (text: String, highlight: SyntaxHighlight)?
    /// A video's, a GIF's or a picture file's cover, with whose it is.
    @State private var cover: (path: String, image: NSImage)?
    /// The picture decoded for the preview, with whose it is (the view outlives the clip it shows).
    @State private var loaded: (name: String, image: NSImage)?
    /// The preview stops here: nobody reads a megabyte in a preview, and the text view would still hold all of it.
    private static let previewCharacters = 100_000
    static let pictureShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    /// Lifted, a file's icon fades as Quick Look's copy of it does, growing away (from opaque to a tenth in ~150 ms):
    /// gone at once, its place showed empty through the copy. Back, it's there at once, under the copy landing. (A
    /// picture flies out itself, see `PictureLift`: it goes at once, from under the one flying.)
    private var liftFade: Animation? { lifted ? .easeOut(duration: 0.2) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            details
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var showsText: Bool { showsPictureText && !clip.text.isEmpty }

    private func dragSource(_ writers: @autoclosure @escaping () -> [NSPasteboardWriting], image: NSImage?,
                            onClick: (() -> Void)? = nil) -> DragSource {
        DragSource(writers: writers, image: { image }, onClick: onClick, began: dragBegan, ended: dragEnded)
    }

    /// A colour's swatch, to drag.
    private static func swatch(_ clip: Clip) -> NSImage {
        let color = NSColor(ColorParser.color(clip.text) ?? .gray)
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
            return true
        }
    }

    /// This clip's cover, once made (Quick Look's thumbnail service).
    private var fileCover: NSImage? {
        guard let path = Thumbnails.coverPath(of: clip) else { return nil }
        if let cover, cover.path == path { return cover.image }
        return Thumbnails.shared.cached(path, side: Thumbnails.coverSide)
    }

    @ViewBuilder private var main: some View {
        switch clip.kind {
        case .image:
            VStack(alignment: .leading, spacing: 10) {
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFit()
                        .clipShape(Self.pictureShape)
                        .opacity(lifted ? 0 : 1)
                        .background(AnchorView(anchor: anchor))
                        .overlay(dragSource(ClipDrag.writers(for: clip), image: picture))
                        .frame(maxWidth: .infinity, maxHeight: showsText ? 220 : .infinity)
                } else {
                    Spacer()
                }
                if showsText {
                    PreviewText(text: previewText, query: query, font: .systemFont(ofSize: 11),
                                color: .secondaryLabelColor)
                }
            }
            .padding(16)
            .task(id: clip.image) {
                guard let name = clip.image,
                      let image = await ImageCache.shared.load(name, pixels: Pictures.previewPixels) else { return }
                loaded = (name, image)
            }
        case .color:
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ColorParser.color(clip.text) ?? .gray)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                    .overlay(dragSource(ClipDrag.writers(for: clip), image: Self.swatch(clip)))
                    .frame(height: 150)
                Text(clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(16)
        case .file where clip.isPictureFile:
            // A picture copied as its file: shown as a copied picture is, the pane's size, with where it is under it.
            let url = clip.fileURLs[0], copied = clip.copiedURLs[0]
            VStack(alignment: .leading, spacing: 10) {
                if let cover = fileCover {
                    Image(nsImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(Self.pictureShape)
                        .opacity(lifted ? 0 : 1)
                        .animation(liftFade, value: lifted)
                        .background(AnchorView(anchor: anchor))
                        .overlay(dragSource(ClipDrag.writers(forFile: url), image: cover))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(nsImage: Icons.file(url)).resizable().frame(width: 48, height: 48)
                        .background(AnchorView(anchor: anchor))
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(copied.lastPathComponent).font(.system(size: 12, weight: .medium))
                    Text((copied.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .truncationMode(.head)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .task(id: Thumbnails.coverPath(of: clip)) {
                guard let path = Thumbnails.coverPath(of: clip),
                      let image = await Thumbnails.shared.load(path, side: Thumbnails.coverSide) else { return }
                cover = (path, image)
            }
        case .file where clip.fileURLs.count > 1:
            FileGrid(urls: clip.fileURLs, anchor: fileAnchor, lifted: lifted ? liftedFile : nil, lookAt: lookAt,
                     dragBegan: dragBegan, dragEnded: dragEnded)
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // A picture of it on top (a document's first page, a video's frame), where Quick Look opens from.
                    if let cover = fileCover {
                        Image(nsImage: cover)
                            .resizable()
                            .scaledToFit()
                            .clipShape(Self.pictureShape)
                            .opacity(lifted ? 0 : 1)
                            .animation(liftFade, value: lifted)
                            .background(AnchorView(anchor: anchor))
                            .overlay(dragSource(Thumbnails.coverPath(of: clip).map {
                                ClipDrag.writers(forFile: URL(fileURLWithPath: $0))
                            } ?? [], image: cover))
                            .frame(maxWidth: .infinity, maxHeight: 240)
                            .padding(.bottom, 6)
                    }
                    // Each where it was copied from, Pastemind's copy standing in for one that's gone.
                    ForEach(Array(zip(clip.fileURLs, clip.copiedURLs).enumerated()), id: \.element.0) { index, urls in
                        let (url, copied) = urls
                        let anchored = index == 0 && fileCover == nil
                        HStack(spacing: 10) {
                            Image(nsImage: Icons.file(url)).resizable().frame(width: 32, height: 32)
                                .opacity(anchored && lifted ? 0 : 1)
                                .animation(liftFade, value: lifted)
                                .background { if anchored { AnchorView(anchor: anchor) } }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(copied.lastPathComponent).font(.system(size: 13, weight: .medium))
                                Text((copied.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .truncationMode(.head)
                                    .lineLimit(1)
                            }
                        }
                        .overlay(dragSource(ClipDrag.writers(forFile: url), image: Icons.file(url)))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: Thumbnails.coverPath(of: clip)) {
                guard let path = Thumbnails.coverPath(of: clip),
                      let image = await Thumbnails.shared.load(path, side: Thumbnails.coverSide) else { return }
                cover = (path, image)
            }
        case .link:
            // The address, and the site above it, open it in the default browser.
            let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.scheme == nil ? nil : $0 }
            VStack(alignment: .leading, spacing: 10) {
                if let url, let host = url.host {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.blue.opacity(0.14)))
                        Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .fixedSize()
                    .overlay(dragSource(ClipDrag.writers(for: clip),
                                        image: NSImage(systemSymbolName: "link", accessibilityDescription: nil),
                                        onClick: { NSWorkspace.shared.open(url) }))
                    .modifier(LinkPointer())
                    .help(url.absoluteString)
                }
                PreviewText(text: previewText, query: query, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                            color: .secondaryLabelColor, lineSpacing: 2, link: url)
            }
            .padding(18)
        case .code:
            // Code keeps its lines: it scrolls sideways rather than wrap mid-statement.
            // The block Quick Look zooms out of, gone from here meanwhile, as a picture.
            PreviewText(text: previewText, query: query, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                        lineSpacing: 3, wraps: false, inset: NSSize(width: 12, height: 12), syntax: shownSyntax)
            .task(id: "\(clip.id) \(highlightsCode)") {
                guard highlightsCode else { return }
                let text = previewText
                guard let highlight = await CodeHighlighter.shared.highlight(text, appID: clip.appID) else { return }
                syntax = (text, highlight)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(lifted ? 0 : 1)
            .animation(liftFade, value: lifted)
            .background(AnchorView(anchor: anchor))
            .padding(14)
        case .text:
            // What Quick Look zooms out of, gone from here meanwhile, as a picture.
            PreviewText(text: previewText, query: query, lineSpacing: 4, inset: NSSize(width: 18, height: 16))
                .opacity(lifted ? 0 : 1)
                .animation(liftFade, value: lifted)
                .background(AnchorView(anchor: anchor))
        }
    }

    /// What's cached already, so the picture is there from the first frame and nothing below it moves: the preview's
    /// copy, else the icon's (the list drew it) scaled up for the few milliseconds the preview's takes.
    private var picture: NSImage? {
        guard let name = clip.image else { return nil }
        if let loaded, loaded.name == name { return loaded.image }
        return ImageCache.shared.cached(name, pixels: Pictures.previewPixels)
            ?? ImageCache.shared.cached(name, pixels: Pictures.iconPixels)
    }

    private var previewText: String {
        // Its bytes first (known at once): counting the characters of a long paste walks all of it.
        guard clip.text.utf8.count > Self.previewCharacters, clip.text.count > Self.previewCharacters else { return clip.text }
        return clip.text.prefix(Self.previewCharacters) + "\n…"
    }

    private var details: some View {
        HStack(spacing: 8) {
            if let icon = Icons.app(clip.appID, side: 14) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(detailLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// Characters and lines, counted once a clip: a long paste took a millisecond to count on every redraw.
    private static var measured: [Int64: (characters: Int, lines: Int)] = [:]

    private static func measure(_ clip: Clip) -> (characters: Int, lines: Int) {
        if let known = measured[clip.id] { return known }
        let counts = (clip.text.count, clip.text.reduce(1) { $1.isNewline ? $0 + 1 : $0 })
        if measured.count > 500 { measured.removeAll() }
        measured[clip.id] = counts
        return counts
    }

    /// The colours worked out for what's shown now (none for another clip's text, or with Settings' switch off).
    private var shownSyntax: SyntaxHighlight? {
        guard highlightsCode, clip.kind == .code, let syntax, syntax.text == previewText else { return nil }
        return syntax.highlight
    }

    private var detailLine: String {
        var parts = [clip.typeName]
        if let language = shownSyntax?.languageName { parts.append(language) }
        if let app = clip.appName { parts.append(app) }
        parts.append(When.long(clip.lastCopied))
        if clip.copies > 1 { parts.append("copied \(clip.copies)×") }
        switch clip.kind {
        case .image, .file:
            // A file's only when it's a picture; else the type says how many.
            if let width = clip.width, let height = clip.height { parts.append("\(width)×\(height)") }
        default:
            let (characters, lines) = Self.measure(clip)
            parts.append(characters == 1 ? "1 character" : "\(characters.formatted()) characters")
            if lines > 1 { parts.append("\(lines.formatted()) lines") }
            if rich { parts.append("formatted") }
        }
        return parts.joined(separator: " · ")
    }
}

/// Several copied files: a picture of each (Quick Look's thumbnail: a photo, a video's frame, a document's first page;
/// else its icon) over its name. Each drags out on its own, and a click shows it in Quick Look with the others a step
/// away (←/→), zooming out of its picture.
struct FileGrid: View {
    let urls: [URL]
    let anchor: (String) -> ScreenAnchor
    /// The one Quick Look has out (its path): its place stays empty meanwhile.
    let lifted: String?
    let lookAt: (URL) -> Void
    var dragBegan: () -> Void
    var dragEnded: (Bool) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 168), spacing: 12, alignment: .top)],
                      spacing: 14) {
                ForEach(urls, id: \.self) { url in
                    FileTile(url: url, anchor: anchor(url.path), lifted: lifted == url.path, lookAt: lookAt,
                             dragBegan: dragBegan, dragEnded: dragEnded)
                }
            }
            .padding(16)
        }
    }
}

private struct FileTile: View {
    let url: URL
    let anchor: ScreenAnchor
    let lifted: Bool
    let lookAt: (URL) -> Void
    var dragBegan: () -> Void
    var dragEnded: (Bool) -> Void
    /// The thumbnail, with whose it is (the view may be reused for another file).
    @State private var loaded: (path: String, image: NSImage)?
    static let pictureHeight: CGFloat = 96

    private var isVideo: Bool {
        UTType(filenameExtension: url.pathExtension).map { $0.conforms(to: .movie) } ?? false
    }

    private var thumbnail: NSImage? {
        if let loaded, loaded.path == url.path { return loaded.image }
        return Thumbnails.shared.cached(url.path, side: Thumbnails.gridSide)
    }

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let image = thumbnail
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(nsImage: Icons.file(url)).resizable().scaledToFit().frame(width: 64, height: 64)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if image != nil, isVideo {   // a frame of a video, not a photo
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .padding(5)
                }
            }
            .opacity(lifted ? 0 : 1)
            .animation(lifted ? .easeOut(duration: 0.2) : nil, value: lifted)
            .background(AnchorView(anchor: anchor))
            .overlay(DragSource(writers: { ClipDrag.writers(forFile: url) }, image: { image ?? Icons.file(url) },
                                onClick: exists ? { lookAt(url) } : nil, began: dragBegan, ended: dragEnded))
            .frame(maxWidth: .infinity, maxHeight: Self.pictureHeight)
            .frame(height: Self.pictureHeight)
            Text(url.lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .opacity(exists ? 1 : 0.45)   // moved or deleted since
        .help(url.path)
        .task(id: url.path) {
            guard exists, let image = await Thumbnails.shared.load(url.path, side: Thumbnails.gridSide) else { return }
            loaded = (url.path, image)
        }
    }
}
