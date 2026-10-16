import Accelerate
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// A recent file, known by what's in it.
public struct IndexedFile: Sendable, Hashable {
    public let id: Int64
    public let path: String
    /// When its contents last changed: read again when that moves.
    public let modified: Date
    /// When it was last opened, as Spotlight knows.
    public let lastUsed: Date?

    public init(id: Int64, path: String, modified: Date, lastUsed: Date?) {
        self.id = id
        self.path = path
        self.modified = modified
        self.lastUsed = lastUsed
    }
}

/// Files' vectors in memory, for search's meaning matches: one matrix-vector product, then what stands out the way
/// meaning matches in the history must (`ClipIndex.Tuning`). Kept to their first `dimension` numbers (EmbeddingGemma 2
/// is trained for that: 256 lose little), so tens of thousands of files take a few tens of MB. A long document has a
/// vector of each piece past its start too (`CopiedFiles.pieces`): it's as close to a query as its closest one.
public final class FileIndex {
    public static let dimension = 256
    /// The history's: on the 18 test files among short text files, and among 1,486 real ones (2026-10-16, pastemind-cli
    /// filecrowd and filedropped), the same bars found the answer first 29 of 32 times (27 before) and 10 of 12 for
    /// one-word queries (7), showed none of the short files for 41 queries with no answer, and dropped photos that
    /// only came close (lift 0.01–0.04) to a query for a tax return.
    public var tuning = ClipIndex.Tuning()
    private var files: [Int64: IndexedFile] = [:]
    /// Each file's own vector (`part` 0), and its pieces' (1 for the first, and so on).
    private let vectors = VectorIndex<VectorKey>(dimension: FileIndex.dimension)
    private var pieceCounts: [Int64: Int] = [:]
    /// The typical query at this length (the mean of `Prompts.typicalQueries`' vectors, each shortened as files'
    /// are), and the typical one-word query (`Prompts.typicalWords`'): a file as close to it as to the query answers
    /// nothing in particular (`ClipIndex.typicalQuery`).
    private var typicalQuery: [Float]?
    private var typicalWord: [Float]?
    /// Each vector's dot product with the typical query (by whether the query is one word), in the vector index's
    /// order, and the files' own vectors' median: made again once a file comes or goes.
    private var closeness: [Bool: (rows: [Float], median: Float)] = [:]
    /// The rows of files' own vectors, not their pieces': made again once a file comes or goes.
    private var ownRows: [Int]?

    public init() {}

    public var count: Int { files.count }

    /// `pieces`: long documents' pieces' vectors, by file.
    public func load(_ rows: [(file: IndexedFile, vector: [Float])], pieces: [Int64: [[Float]]] = [:]) {
        files = [:]
        pieceCounts = [:]
        vectors.removeAll()
        for row in rows { set(row.file, vector: row.vector, pieces: pieces[row.file.id] ?? []) }
    }

    /// Its vector, and its pieces' (full length as the model makes them, or shortened as the store keeps them).
    public func set(_ file: IndexedFile, vector: [Float], pieces: [[Float]] = []) {
        guard vector.count == ModelFiles.dimension else { return }
        files[file.id] = file
        vectors.set(VectorKey(id: file.id, part: 0), Self.shortened(vector))
        removePieces(of: file.id)
        let pieces = pieces.filter { $0.count >= Self.dimension }
        for (offset, piece) in pieces.enumerated() {
            vectors.set(VectorKey(id: file.id, part: offset + 1), Self.shortened(piece))
        }
        if !pieces.isEmpty { pieceCounts[file.id] = pieces.count }
        closeness = [:]
        ownRows = nil
    }

    /// How many pieces' vectors it has.
    public func pieceCount(_ id: Int64) -> Int { pieceCounts[id] ?? 0 }

    private func removePieces(of id: Int64) {
        guard let count = pieceCounts.removeValue(forKey: id) else { return }
        for part in 1...count { vectors.remove(VectorKey(id: id, part: part)) }
    }

    /// The typical queries' vectors, of phrases and of single words (full length, as the model makes them).
    public func setTypical(phrases: [[Float]], words: [[Float]]) {
        func mean(_ vectors: [[Float]]) -> [Float]? {
            let short = vectors.filter { $0.count == ModelFiles.dimension }.map(Self.shortened)
            guard !short.isEmpty else { return nil }
            var mean = [Float](repeating: 0, count: Self.dimension)
            for vector in short { for i in mean.indices { mean[i] += vector[i] / Float(short.count) } }
            return mean
        }
        typicalQuery = mean(phrases)
        typicalWord = mean(words)
        closeness = [:]
    }

    /// The first `dimension` numbers, unit length again.
    public static func shortened(_ vector: [Float]) -> [Float] {
        let head = Array(vector.prefix(dimension))
        let norm = head.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? head.map { $0 / norm } : head
    }

    public func remove(_ ids: Set<Int64>) {
        for id in ids {
            files[id] = nil
            vectors.remove(VectorKey(id: id, part: 0))
            removePieces(of: id)
        }
        closeness = [:]
        ownRows = nil
    }

    /// The files closest in meaning to the query: above `minMeaning`, within `meaningSpread` of the best, and closer
    /// to the query than to the typical one by `minLift` (until that's known, standing above the typical file); best
    /// first. `oneWord`: the query is a single word, which has its own typical query. `piece`: what came closest, the
    /// file's own vector (0) or one of its pieces' (1 for the first).
    public func search(_ query: [Float], oneWord: Bool = false,
                       limit: Int) -> [(file: IndexedFile, cosine: Float, piece: Int)] {
        guard query.count == ModelFiles.dimension, vectors.count > 0 else { return [] }
        var scores = vectors.scores(Self.shortened(query))
        if ownRows == nil { ownRows = vectors.ids.indices.filter { vectors.ids[$0].part == 0 } }
        let own = ownRows ?? []
        /// The middle of what files' own vectors score: pieces, hundreds to a long document, don't move it.
        func median(_ rows: [Float]) -> Float {
            let sorted = own.map { rows[$0] }.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        var lifts: [Float]?
        if tuning.minLift > 0 || tuning.typicalQueryWeight > 0,
           let typical = oneWord ? typicalWord ?? typicalQuery : typicalQuery {
            if closeness[oneWord] == nil {
                let rows = vectors.scores(typical)
                closeness[oneWord] = (rows, median(rows))
            }
            let (rows, usual) = closeness[oneWord]!
            lifts = zip(scores, rows).map { $0 - $1 }
            if tuning.typicalQueryWeight > 0 {
                for row in scores.indices { scores[row] -= tuning.typicalQueryWeight * (rows[row] - usual) }
            }
        }
        var best: Float = 0
        var bestRow: vDSP_Length = 0
        vDSP_maxvi(scores, 1, &best, &bestRow, vDSP_Length(scores.count))
        var typical = -Float.infinity
        if lifts == nil, own.count >= tuning.typicalMinimum {
            typical = median(scores) + tuning.aboveTypical
        }
        let gate = max(tuning.minMeaning, best - tuning.meaningSpread, typical)
        let minLift = oneWord ? tuning.minLiftOneWord : tuning.minLift
        var found: [Int64: (cosine: Float, piece: Int)] = [:]
        for (row, score) in scores.enumerated() where score >= gate && (lifts?[row] ?? 1) >= minLift {
            let key = vectors.ids[row]
            if score > found[key.id]?.cosine ?? -.infinity { found[key.id] = (score, key.part) }
        }
        return found.compactMap { id, match in files[id].map { (file: $0, cosine: match.cosine, piece: match.piece) } }
            .sorted { $0.cosine > $1.cosine }
            .prefix(limit)
            .map { $0 }
    }
}

/// The files search reads by what's in them: what changed lately where you work (the Desktop, Downloads, Documents,
/// and wherever screenshots go), and what you opened lately anywhere in your home folder, from Spotlight's index (or by
/// looking through those folders where Spotlight has nothing).
public enum RecentFiles {
    public struct Candidate: Sendable, Hashable {
        public let path: String
        public let modified: Date
        public let lastUsed: Date?

        public init(path: String, modified: Date, lastUsed: Date?) {
            self.path = path
            self.modified = modified
            self.lastUsed = lastUsed
        }

        /// When it was last touched, changed or opened: the newest go first.
        public var touched: Date { max(modified, lastUsed ?? .distantPast) }
    }

    public static let days = 60
    public static let limit = 3000

    /// A debug run keeps to the folders `$PASTEMIND_FILE_SCOPE` names (colon-separated), opened files included.
    public static var debugScoped: Bool { !(ProcessInfo.processInfo.environment["PASTEMIND_FILE_SCOPE"] ?? "").isEmpty }

    /// Where what changed is read (opened files are read from anywhere in the home folder).
    public static var scopes: [URL] {
        if let chosen = ProcessInfo.processInfo.environment["PASTEMIND_FILE_SCOPE"], !chosen.isEmpty {
            return chosen.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        let fm = FileManager.default
        var folders = [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let screenshots = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            if !folders.contains(where: { screenshots.path.hasPrefix($0.path) }) { folders.append(screenshots) }
        }
        return folders
    }

    /// The newest `limit` files changed in the last `days` under `scopes` or opened anywhere in the home folder, as
    /// `keeps` lets through.
    /// `opened`: files opened anywhere in the home folder too.
    public static func find(in scopes: [URL] = scopes, opened: Bool = !debugScoped, days: Int = days,
                            limit: Int = limit, now: Date = Date()) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = "(kMDItemFSContentChangeDate >= $time.today(-\(days)) || kMDItemLastUsedDate >= $time.today(-\(days)))"
        var found = spotlight(scopes, recent, limit: limit * 2)
        if found.isEmpty { found = walk(scopes, since: cutoff) }
        if opened {
            found += spotlight([URL(fileURLWithPath: NSHomeDirectory())], "kMDItemLastUsedDate >= $time.today(-\(days))",
                               limit: limit)
        }
        var seen: Set<String> = []
        return Array(found.filter { keeps($0, since: cutoff) && seen.insert($0.path).inserted }
            .sorted { $0.touched > $1.touched }.prefix(limit))
    }

    /// Recent, and not: private (`CopiedFiles.isPrivate`), hidden or inside an app, under ~/Library (other apps' data,
    /// which macOS asks about before it's read), or build output that was never opened.
    public static func keeps(_ candidate: Candidate, since cutoff: Date) -> Bool {
        let library = NSHomeDirectory() + "/Library/"
        return candidate.touched >= cutoff && !candidate.path.hasPrefix(library)
            && !CopiedFiles.isPrivate(URL(fileURLWithPath: candidate.path))
            && (candidate.lastUsed != nil || !SpotlightFiles.isNoise(candidate.path))
            && !candidate.path.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".app") }
    }

    /// Everything else in the home folder worth reading, newest first: pictures, videos, sound, PDFs and documents. Not
    /// in ~/Library, apps or packages, nor (unless opened) in code projects, build output, or folders that look like
    /// datasets (200 or more of a kind side by side); no SVGs (icons), no loose code or data. A few seconds of
    /// Spotlight's time: looked for now and then, not on every change.
    public static func everything(limit: Int = 30_000) -> [Candidate] {
        let kinds = ["public.image", "public.movie", "public.audio", "com.adobe.pdf", "public.composite-content"]
            .map { "kMDItemContentTypeTree == \"\($0)\"" }
            + ["public.plain-text", "net.daringfireball.markdown", "public.rtf", "public.html"]
            .map { "kMDItemContentType == \"\($0)\"" }
        let text = "(" + kinds.joined(separator: " || ") + ") && kMDItemContentType != \"public.svg-image\""
        let home = URL(fileURLWithPath: NSHomeDirectory())
        // The home folder's own folders but ~/Library and hidden ones: Spotlight needn't list what's left out anyway.
        let folders = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "Library" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let looked = debugScoped ? scopes : folders
        var found = spotlight(looked, text, limit: 500_000, types: true).map(\.candidate)
        // Where Spotlight has nothing: the folders themselves, keeping to the kinds the query asks for.
        if found.isEmpty {
            found = walk(looked, since: .distantPast).filter { candidate in
                let ext = (candidate.path as NSString).pathExtension.lowercased()
                return group(of: ext) != "document" || documentExtensions.contains(ext)
            }
        }
        return Array(sift(found, home: home.path).sorted { $0.touched > $1.touched }.prefix(limit))
    }

    /// Files that just appeared or changed anywhere in the home folder (Spotlight tells of them as they do), as the
    /// whole-home look would take them: of the kinds it reads (by their extensions), and `sift`ed. A burst of 200 or
    /// more of a kind in one folder is a dataset here too.
    public static func appeared(_ found: [Candidate], home: String = NSHomeDirectory()) -> [Candidate] {
        let kinds = found.filter { candidate in
            let ext = (candidate.path as NSString).pathExtension.lowercased()
            return group(of: ext) != "document" || documentExtensions.contains(ext)
        }
        return sift(kinds, home: home)
    }

    /// What of `found` is worth reading (see `everything`), cheapest tests first: 200,000 paths come in here.
    static func sift(_ found: [Candidate], home: String) -> [Candidate] {
        let noise = Set(SpotlightFiles.noise.map { Substring($0) })
        let survivors = found.filter { candidate in
            let parts = candidate.path.split(separator: "/")
            for part in parts.dropLast() {
                if part.first == "." { return false }
                if part.contains("."), packageSuffixes.contains(where: { part.hasSuffix($0) }) { return false }
                if candidate.lastUsed == nil, noise.contains(part) { return false }
            }
            return true
        }
        // A folder holding 200 or more of a kind (frames, a downloaded dataset, a site's images) is a dataset.
        func crowd(_ path: String) -> String {
            (path as NSString).deletingLastPathComponent + "|" + group(of: (path as NSString).pathExtension.lowercased())
        }
        var crowds: [String: Int] = [:]
        for candidate in survivors { crowds[crowd(candidate.path), default: 0] += 1 }
        var projects: [String: Bool] = [:]
        func inProject(_ path: String) -> Bool {
            var folder = (path as NSString).deletingLastPathComponent
            var visited: [String] = []
            var answer = false
            while folder.count > home.count {
                if let known = projects[folder] {
                    answer = known
                    break
                }
                visited.append(folder)
                if projectMarkers.contains(where: { FileManager.default.fileExists(atPath: folder + "/" + $0) }) {
                    answer = true
                    break
                }
                folder = (folder as NSString).deletingLastPathComponent
            }
            for seen in visited { projects[seen] = answer }
            return answer
        }
        return survivors
            .filter { $0.lastUsed != nil || crowds[crowd($0.path), default: 0] < 200 }
            .filter { $0.lastUsed != nil || !inProject($0.path) }
            .filter { keeps($0, since: .distantPast) }
    }

    /// Documents the whole-home look reads (as its Spotlight query asks for them).
    static let documentExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "rtfd", "html", "htm", "doc", "docx",
                                                  "odt", "pages", "key", "numbers", "pptx", "ppt", "xlsx", "xls", "epub"]

    /// Which crowd a file's extension puts it in ("image", "video", "audio", "pdf" or "document").
    public static func group(of ext: String) -> String {
        if ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "raw", "dng", "cr2", "nef",
            "arw"].contains(ext) { return "image" }
        if ["mov", "mp4", "m4v", "webm", "mkv", "avi"].contains(ext) { return "video" }
        if ["m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "opus"].contains(ext) { return "audio" }
        return ext == "pdf" ? "pdf" : "document"
    }

    /// What makes a folder a code project: its files are code and assets, found by code search, not this.
    static let projectMarkers = [".git", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod",
                                 "Gemfile", "pom.xml", "build.gradle", "composer.json"]
    static let packageSuffixes = [".app", ".photoslibrary", ".bundle", ".framework", ".xcodeproj", ".xcworkspace",
                                  ".xcassets", ".playground", ".lproj", ".imageset", ".appiconset", ".musiclibrary",
                                  ".tvlibrary", ".fcpbundle", ".logicx", ".band"]

    private static func spotlight(_ scopes: [URL], _ recent: String, limit: Int) -> [Candidate] {
        spotlight(scopes, recent, limit: limit, types: false).map(\.candidate)
    }

    private static func spotlight(_ scopes: [URL], _ recent: String, limit: Int,
                                  types: Bool) -> [(candidate: Candidate, type: String?)] {
        let text = recent + " && kMDItemContentType != \"public.folder\""
            + " && kMDItemContentType != \"com.apple.application-bundle\""
        let attributes = [kMDItemFSContentChangeDate, kMDItemLastUsedDate, kMDItemContentType] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, attributes, nil) else { return [] }
        MDQuerySetSearchScope(query, scopes.map(\.path) as CFArray, 0)
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        func value(_ attribute: CFString, _ index: Int) -> Any? {
            MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index).map {
                Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue()
            }
        }
        var found: [(Candidate, String?)] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  let modified = value(kMDItemFSContentChangeDate, index) as? Date else { continue }
            found.append((Candidate(path: path, modified: modified, lastUsed: value(kMDItemLastUsedDate, index) as? Date),
                          types ? value(kMDItemContentType, index) as? String : nil))
        }
        return found
    }

    /// Where Spotlight has nothing (it's off, or a folder it doesn't index): the folders themselves, four deep, no
    /// further than 50,000 entries.
    private static func walk(_ scopes: [URL], since cutoff: Date) -> [Candidate] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isPackageKey]
        var found: [Candidate] = []
        var visited = 0
        for scope in scopes {
            guard let walker = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walker {
                visited += 1
                if visited > 50_000 { return found }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true, values.isPackage != true {
                    if walker.level >= 4 || SpotlightFiles.noise.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard let modified = values.contentModificationDate, modified >= cutoff else { continue }
                found.append(Candidate(path: url.path, modified: modified, lastUsed: nil))
            }
        }
        return found
    }
}
