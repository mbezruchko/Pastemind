import Foundation

/// What of copied files may go into their vector, decided by name alone, before anything is read.
public enum CopiedFiles {
    /// Text read from files, all of them together: about 400 tokens, which with four pictures fits the model's input.
    public static let textCharacters = 1200
    /// Pictures from files, all of them together (a video gives three frames).
    public static let maxPictures = 4
    /// Sound: the model hears 30 seconds.
    public static let soundSeconds = 30.0
    /// Several copied files get a vector each too, the first this many: one vector of them all blurs each (the
    /// evaluation's 32 queries found their copy first 12 times by it alone, 29 with each file's).
    public static let maxParts = 12
    /// A long document's text past what its own vector reads goes in pieces, a vector each: this long, the next
    /// starting `pieceOverlap` before one ends (what straddles two is whole in one), no more than `maxPieces` of them.
    public static let pieceCharacters = 1200
    public static let pieceOverlap = 200
    public static let maxPieces = 100
    /// A shorter last piece joins the one before: a short text comes close to every query a little (as short clips do).
    public static let minPieceCharacters = 400
    /// The most of a document read for its pieces.
    public static var piecesReach: Int { textCharacters + maxPieces * (pieceCharacters - pieceOverlap) }
    /// A scan's pages read by OCR (`TextRecognition`), at most: about a second each, five while you work.
    public static let scanPages = 50

    /// What the reader reads, by version: 2, scans by OCR (before, by their first page's picture).
    public static let readerVersion = 2

    /// Read before the reader read what's in it: read again. A scan read by its picture: a PDF without pieces (a short
    /// one with text is read again too, cheaply: there's no telling them apart without reading).
    public static func readAgain(_ url: URL, readBy version: Int, pieces: Int) -> Bool {
        version < 2 && pieces == 0 && url.pathExtension.lowercased() == "pdf"
    }

    /// What kinds of document have pieces: prose (PDFs, Word, RTF, OpenDocument, web pages, text and Markdown), not
    /// code, data or logs, whose start says what they are.
    public static func hasPieces(_ url: URL) -> Bool {
        ["pdf", "doc", "docx", "rtf", "rtfd", "odt", "wordml", "html", "htm", "txt", "text", "md", "markdown"]
            .contains(url.pathExtension.lowercased())
    }

    /// `text` past its first `textCharacters` (the document's own vector reads those) in pieces, split at spaces, its
    /// runs of blank space closed up as the vector's text has them.
    public static func pieces(of text: String) -> [String] {
        let words = Array(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        guard words.count > textCharacters + minPieceCharacters / 2 else { return [] }
        let end = min(words.count, piecesReach)
        /// The nearest space at or before `index` (within a fifth of a piece), else `index`.
        func space(before index: Int) -> Int {
            var at = index
            while at > index - pieceCharacters / 5, at > 0, words[at - 1] != " " { at -= 1 }
            return at == 0 || words[at - 1] == " " ? at : index
        }
        var found: [Range<Int>] = []
        var start = space(before: textCharacters - pieceOverlap)
        while start < end, found.count < maxPieces {
            var stop = start + pieceCharacters >= end ? end : space(before: start + pieceCharacters)
            if end - stop < minPieceCharacters { stop = end }   // the rest is too short to stand alone
            found.append(start..<stop)
            if stop == end { break }
            start = space(before: stop - pieceOverlap)
        }
        return found.map { String(words[$0]).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Never read: keys, certificates, password stores, credentials (their names still go in).
    public static func isPrivate(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if privateExtensions.contains(ext) || privateNames.contains(name) || name.hasPrefix(".env") { return true }
        if name.hasPrefix("id_") && (ext.isEmpty || ext == "pub") { return true }   // id_rsa, id_ed25519
        return url.pathComponents.contains { privateFolders.contains($0.lowercased()) }
    }

    private static let privateExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "cer", "crt", "der", "p8", "keychain", "keychain-db", "kdbx", "kdb", "1pif",
        "opvault", "agilekeychain", "gpg", "pgp", "asc", "sig", "ovpn", "mobileprovision", "provisionprofile",
    ]
    private static let privateNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".pgpass", "credentials", "credentials.json", "known_hosts", "authorized_keys",
        "secrets.json", "secrets.yml", "secrets.yaml",
    ]
    private static let privateFolders: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", "keychains", ".password-store"]

    /// Their names, the title they go into the vector under.
    public static func title(of urls: [URL]) -> String {
        let names = urls.map(\.lastPathComponent)
        let shown = names.prefix(12).joined(separator: ", ")
        return names.count > 12 ? shown + " and \(names.count - 12) more" : shown
    }
}
