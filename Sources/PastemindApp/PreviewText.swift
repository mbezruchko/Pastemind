import AppKit
import PastemindKit
import SwiftUI

/// A clip's text in the preview, selectable, with the typed words marked. An NSTextView: TextKit 2 lays out only what's
/// on screen, and the marks are rendering attributes, drawn without laying anything out again, so typing costs the same
/// for a long clip as for a short one. SwiftUI's Text laid all of it out, matches in bold, on every keystroke: over a
/// second for 7,000 characters (measured 2026-10-13).
struct PreviewText: NSViewRepresentable {
    let text: String
    let query: String
    var font: NSFont = .systemFont(ofSize: 13.5)
    var color: NSColor = .labelColor
    var lineSpacing: CGFloat = 0
    /// Long lines wrap; code keeps them and scrolls sideways.
    var wraps = true
    /// The text is this link: a click on it opens it (in the default browser, for a web address).
    var link: URL?
    var inset = NSSize(width: 0, height: 0)
    /// Code's colours (see `CodeHighlighter`), for this text.
    var syntax: SyntaxHighlight?

    /// The most marks drawn: past this the text is mostly marks anyway.
    private static let maxMarks = 500

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wraps
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if wraps {
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
        } else {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
        }
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let shown = context.coordinator
        if shown.text != text || shown.syntax != syntax {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let link { attributes[.link] = link }
            let string = NSMutableAttributedString(string: text, attributes: attributes)
            if let syntax { SyntaxColors.apply(syntax.spans, to: string) }
            textView.textStorage?.setAttributedString(string)
            shown.syntax = syntax
            let sameText = shown.text == text
            // A link reads as one, without the underline; the pointer turns to a hand over it.
            textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
            shown.text = text
            shown.query = nil
            if !sameText {   // another clip's text: from its top (its colours coming in leave it where it is)
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if shown.query != typed {
            shown.query = typed
            mark(typed, in: textView)
        }
    }

    func makeCoordinator() -> Shown { Shown() }

    /// What the view holds, so an update that changes nothing does nothing.
    final class Shown {
        var text: String?
        var query: String?
        var syntax: SyntaxHighlight?
    }

    /// The occurrences of the query (or, when it isn't there whole, of its words) on a tint, the first one scrolled to.
    private func mark(_ typed: String, in textView: NSTextView) {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
        let ranges = typed.isEmpty ? [] : Self.matches(of: typed, in: textView.string as NSString)
        var location = content.documentRange.location
        var offset = 0
        for range in ranges {
            // From the previous match on, not from the top every time.
            guard let start = content.location(location, offsetBy: range.location - offset),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { break }
            layout.addRenderingAttribute(.backgroundColor, value: Self.markColor, for: textRange)
            location = start
            offset = range.location
        }
        textView.needsDisplay = true
        if let first = ranges.first { textView.scrollRangeToVisible(first) }
    }

    private static let markColor = NSColor.controlAccentColor.withAlphaComponent(0.38)

    /// In order, not overlapping, at most `maxMarks`.
    static func matches(of query: String, in text: NSString) -> [NSRange] {
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let parts = text.range(of: query, options: options).location != NSNotFound
            ? [query] : query.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        var ranges: [NSRange] = []
        for part in parts {
            var start = 0
            while start < text.length, ranges.count < maxMarks {
                let found = text.range(of: part, options: options,
                                       range: NSRange(location: start, length: text.length - start))
                guard found.location != NSNotFound, found.length > 0 else { break }
                ranges.append(found)
                start = found.location + found.length
            }
        }
        ranges.sort { $0.location < $1.location }
        var kept: [NSRange] = []
        for range in ranges where range.location >= (kept.last.map { $0.location + $0.length } ?? 0) {
            kept.append(range)
        }
        return kept
    }
}
