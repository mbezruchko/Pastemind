import Accelerate
import Foundation

public struct SearchResult: Sendable, Identifiable, Hashable {
    public let clip: Clip
    public let score: Double
    /// The typed words are in it.
    public let words: Bool
    /// Cosine similarity to the query, when there was a query vector and the clip has one.
    public let meaning: Float?
    /// Among the best: a word match, or close to the best cosine. The rest are shown dimmed.
    public let strong: Bool
    /// Copied files found by one of them, not by them all together: which (in `clip.fileURLs`).
    public var file: Int?
    public var id: Int64 { clip.id }
}

/// A vector's place: a clip's own, or one of its copied files' (`part` 1 for the first file, and so on).
struct VectorKey: Hashable {
    let id: Int64
    let part: Int
    static func clip(_ id: Int64) -> VectorKey { VectorKey(id: id, part: 0) }
}

/// The history in memory, for search at typing speed: the clips (most recent first), their text folded into one buffer
/// for word matching, and their vectors as one float32 matrix. Ten thousand clips search in about a millisecond.
public final class ClipIndex {
    /// Calibrated on EmbeddingGemma 2 with the search prompt (pastemind-cli eval, 2026-10-13): a clip that answers the query
    /// scores 0.68–0.87, the best unrelated one 0.62–0.80, so what counts is the distance from the best, not a fixed bar.
    /// And how far the best stands above the typical clip (2026-10-15, the eval's queries with no answer and a real
    /// history): 0.079–0.23 above the median cosine when something answers, 0.03–0.077 when nothing does ("plane").
    /// A short clip (a word, "thanks", a chat line) comes close to any short query, though: among 60 of them (2026-10-16,
    /// pastemind-cli crowd and lift), 4 of the 24 queries lost their answer to one and 10 of 26 with no answer showed
    /// some. What tells them apart is how much closer a clip is to the query than to the typical query: 0.060–0.21
    /// for an answer, at most 0.047 for the best clip when nothing answers (and −0.02–0.02 for the single words a
    /// real history showed for a query for a software license). A query of one word brings every clip closer, short ones most: its
    /// typical query is of single words, and 15 one-word queries with an answer found 8 first (4 before) while 15
    /// with none showed nothing (7 did). That bar does the median's job better, so the median goes once it's there.
    /// (A clip's closeness as the mean of its k nearest typical queries instead tells them apart no better.)
    public struct Tuning: Sendable {
        /// Weight of a word match against the cosine.
        public var wordWeight = 0.4
        /// Some of the query's words (3+ letters) in a meaning match: up to this much more.
        public var partialWordWeight = 0.06
        /// A meaning-only result must reach this cosine…
        public var minMeaning: Float = 0.6
        /// …and be within this much of the best one…
        public var meaningSpread: Float = 0.1
        /// …and within this much to be a strong one (the rest are shown dimmed).
        public var strongSpread: Float = 0.045
        /// …and stand this far above the typical clip (the median cosine): with nothing that answers the query, the
        /// best of the rest only just tops the crowd, and nothing's shown rather than the least unrelated clips. Only
        /// until the typical query's known (`minLift` then).
        public var aboveTypical: Float = 0.078
        /// Fewer clips with vectors than this, and the median says little: no such bar.
        public var typicalMinimum = 8
        /// A clip close to the typical query (a word or two, a short phrase) comes close to every query, whatever it
        /// asks: its cosine goes down by this much of how much closer to the typical query it is than the typical clip.
        public var typicalQueryWeight: Float = 0.5
        /// A meaning-only result must be this much closer to the query than to the typical query: a clip that's as
        /// close to anything you might ask (a single word, "thanks") answers none of it.
        public var minLift: Float = 0.05
        /// …and for a query of one word, which says less about what it wants, this much.
        public var minLiftOneWord: Float = 0.06
        /// Recency breaks near-ties: a clip from now gets this much, one from a few days ago about a third of it.
        public var recencyWeight = 0.03
        public var recencyDays = 3.0
        public init() {}
    }

    /// Most recently copied first.
    public private(set) var clips: [Clip] = []
    public var tuning = Tuning()
    /// The mean of `Prompts.typicalQueries`' vectors (not normalized: a clip's dot product with it is its mean cosine to
    /// them), from the model that made the clips' vectors.
    public var typicalQuery: [Float]? { didSet { closeness = [:] } }
    /// The same for a query of one word: the mean of `Prompts.typicalWords`' vectors.
    public var typicalWord: [Float]? { didSet { closeness = [:] } }
    /// Each vector's dot product with the typical query (by whether the query is one word), in the vector index's
    /// order, and their median: made again once a vector comes or goes.
    private var closeness: [Bool: (rows: [Float], median: Float)] = [:]
    private var byID: [Int64: Clip] = [:]
    private var corpus = FoldedCorpus()
    private let vectors = VectorIndex<VectorKey>()
    /// Copied files with a vector of each besides the one of them all: how many.
    private var partCounts: [Int64: Int] = [:]
    /// The apps clips came from, folded for matching (a few dozen; one that no clip is from any more matches nothing).
    private var apps: [String: [UInt8]] = [:]

    public init() {}

    public var count: Int { clips.count }
    public var embeddedCount: Int { vectors.ids.filter { $0.part == 0 }.count }

    public func load(_ clips: [Clip], vectors rows: [(id: Int64, vector: [Float])],
                     parts: [(id: Int64, parts: [[Float]])] = []) {
        self.clips = clips
        byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        corpus = FoldedCorpus()
        apps = [:]
        for clip in clips {
            corpus.add(clip.id, Self.fold(Self.searchable(clip)))
            noteApp(of: clip)
        }
        vectors.removeAll()
        partCounts = [:]
        for row in rows where byID[row.id] != nil { vectors.set(.clip(row.id), row.vector) }
        for row in parts { setParts(row.parts, for: row.id) }
        closeness = [:]
    }

    /// A new clip, or one copied again: it goes to the top.
    public func upsert(_ clip: Clip) {
        if let old = byID[clip.id] {
            clips.removeAll { $0.id == clip.id }
            refresh(old, to: clip)
        } else {
            corpus.add(clip.id, Self.fold(Self.searchable(clip)))
        }
        noteApp(of: clip)
        byID[clip.id] = clip
        let at = clips.firstIndex { $0.lastCopied <= clip.lastCopied } ?? clips.count
        clips.insert(clip, at: at)
    }

    /// The same clip with something changed in place (pinned, or the text an image turned out to have).
    public func update(_ clip: Clip) {
        guard let old = byID[clip.id], let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        refresh(old, to: clip)
        clips[index] = clip
        byID[clip.id] = clip
    }

    public func remove(_ ids: Set<Int64>) {
        clips.removeAll { ids.contains($0.id) }
        for id in ids {
            byID[id] = nil
            corpus.remove(id)
            vectors.remove(.clip(id))
            removeParts(of: id)
        }
        closeness = [:]
    }

    /// New text means new words and a new vector.
    private func refresh(_ old: Clip, to clip: Clip) {
        if old.text != clip.text {
            vectors.remove(.clip(clip.id))
            removeParts(of: clip.id)
            closeness = [:]
            corpus.remove(clip.id)
            corpus.add(clip.id, Self.fold(Self.searchable(clip)))
        }
    }

    private func noteApp(of clip: Clip) {
        if let name = clip.appName, apps[name] == nil { apps[name] = Self.fold(name) }
    }

    public func clip(id: Int64) -> Clip? { byID[id] }

    /// The typical queries' vectors, of phrases and of single words: `typicalQuery` and `typicalWord`, their means.
    public func setTypical(phrases: [[Float]], words: [[Float]]) {
        func mean(_ vectors: [[Float]]) -> [Float]? {
            let usable = vectors.filter { $0.count == ModelFiles.dimension }
            guard !usable.isEmpty else { return nil }
            var mean = [Float](repeating: 0, count: ModelFiles.dimension)
            for vector in usable { for i in mean.indices { mean[i] += vector[i] / Float(usable.count) } }
            return mean
        }
        typicalQuery = mean(phrases)
        typicalWord = mean(words)
    }

    public func setVector(_ vector: [Float], for id: Int64) {
        guard byID[id] != nil, vector.count == ModelFiles.dimension else { return }
        vectors.set(.clip(id), vector)
        closeness = [:]
    }

    public func hasVector(_ id: Int64) -> Bool { vectors.contains(.clip(id)) }

    /// A vector of each copied file, in `clip.fileURLs` order: the clip is found by any of them, as well as by its own.
    public func setParts(_ parts: [[Float]], for id: Int64) {
        guard byID[id] != nil else { return }
        removeParts(of: id)
        for (offset, vector) in parts.enumerated() where vector.count == ModelFiles.dimension {
            vectors.set(VectorKey(id: id, part: offset + 1), vector)
        }
        partCounts[id] = parts.count
        closeness = [:]
    }

    public func hasParts(_ id: Int64) -> Bool { partCounts[id] != nil }

    private func removeParts(of id: Int64) {
        guard let count = partCounts.removeValue(forKey: id) else { return }
        for part in 0..<count { vectors.remove(VectorKey(id: id, part: part + 1)) }
    }

    // MARK: Search

    /// Word matches (the whole query as typed, or every word of it, anywhere in the text) and, with `vector`, meaning
    /// matches. What has the query in it comes first, the most recent first (as the history lists it: "http" puts the
    /// link copied a minute ago above yesterday's); then the app's name or every word apart, also the most recent
    /// first; then what's only close in meaning, the closest first. Meaning results arriving don't reorder the words'.
    public func search(_ query: String, vector: [Float]? = nil, limit: Int = 80, now: Date = Date()) -> [SearchResult] {
        let phrase = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !phrase.isEmpty else { return [] }
        let words = phrase.split(separator: UInt8(ascii: " ")).map(Array.init).filter { !$0.isEmpty }

        // Words: the phrase as typed, then (for several words) every word somewhere in the clip.
        var wordScores: [Int64: Double] = [:]
        corpus.forEachMatch(of: phrase) { id, offset, previous in
            wordScores[id] = offset == 0 ? 1.15 : (Self.isBoundary(previous) ? 1.08 : 1)
        }
        if words.count > 1, let anchor = words.max(by: { $0.count < $1.count }) {
            let others = words.filter { $0 != anchor }
            corpus.forEachMatch(of: anchor) { id, _, _ in
                guard wordScores[id] == nil else { return }
                if others.allSatisfy({ corpus.contains($0, in: id) }) { wordScores[id] = 0.7 }
            }
        }
        // The app it was copied in, by the start of its name or of a word in it: "handy" finds what came from Handy,
        // just under what has the word in it. With several words, the others must be in the text ("zed deploy").
        var appMatches: [String: (phrase: Bool, words: Set<Int>)] = [:]
        for (name, folded) in apps {
            let phraseMatch = Self.startsWord(phrase, in: folded)
            let matched = words.count > 1 ? Set(words.indices.filter { Self.startsWord(words[$0], in: folded) }) : []
            if phraseMatch || !matched.isEmpty { appMatches[name] = (phraseMatch, matched) }
        }
        if !appMatches.isEmpty {
            for clip in clips where wordScores[clip.id] == nil {
                guard let name = clip.appName, let match = appMatches[name] else { continue }
                if match.phrase {
                    wordScores[clip.id] = 0.9
                } else if words.indices.allSatisfy({ match.words.contains($0) || corpus.contains(words[$0], in: clip.id) }) {
                    wordScores[clip.id] = 0.7
                }
            }
        }

        // Meaning: one matrix-vector product, then what's close enough to the best.
        var scores: [Float] = []
        var meaningful: [Int64: Float] = [:]
        var matchedFile: [Int64: Int] = [:]
        var best: Float = 0
        if let vector, vector.count == ModelFiles.dimension, vectors.count > 0 {
            scores = vectors.scores(vector)
            var lifts: [Float]?
            let oneWord = words.count == 1
            if let typical = oneWord ? typicalWord ?? typicalQuery : typicalQuery, typical.count == vector.count {
                if closeness[oneWord] == nil {
                    let rows = vectors.scores(typical)
                    closeness[oneWord] = (rows, rows.sorted()[rows.count / 2])
                }
                let (rows, usual) = closeness[oneWord]!
                lifts = zip(scores, rows).map { $0 - $1 }
                if tuning.typicalQueryWeight > 0, scores.count >= tuning.typicalMinimum {
                    for row in scores.indices { scores[row] -= tuning.typicalQueryWeight * (rows[row] - usual) }
                }
            }
            var bestRow: vDSP_Length = 0
            vDSP_maxvi(scores, 1, &best, &bestRow, vDSP_Length(scores.count))
            // The bar over the median only until the typical query's there: it does the same job better (a query of
            // one word brings every clip closer, the median with them).
            var typical = -Float.infinity
            if lifts == nil, scores.count >= tuning.typicalMinimum {
                let sorted = scores.sorted()
                typical = sorted[sorted.count / 2] + tuning.aboveTypical
            }
            let gate = max(tuning.minMeaning, best - tuning.meaningSpread, typical)
            let minLift = words.count == 1 ? tuning.minLiftOneWord : tuning.minLift
            for (row, score) in scores.enumerated() where score >= gate && (lifts?[row] ?? 1) >= minLift {
                let key = vectors.ids[row]
                guard score > meaningful[key.id] ?? -.infinity else { continue }
                meaningful[key.id] = score
                matchedFile[key.id] = key.part > 0 ? key.part - 1 : nil
            }
        }
        let hasMeaning = !scores.isEmpty
        let strongBar = best - tuning.strongSpread
        let partialWords = words.filter { $0.count >= 3 }

        // Score the candidates cheaply; only the ones shown become results.
        var candidates: [(score: Double, id: Int64, words: Bool, cosine: Float?, group: Int, copied: Date)] = []
        candidates.reserveCapacity(wordScores.count + meaningful.count)
        func consider(_ id: Int64, wordScore: Double, cosine known: Float?) {
            guard let clip = byID[id] else { return }
            var cosine = known
            if cosine == nil, hasMeaning {
                let keys = [VectorKey.clip(id)] + (0..<(partCounts[id] ?? 0)).map { VectorKey(id: id, part: $0 + 1) }
                cosine = keys.compactMap { vectors.row(of: $0).map { scores[$0] } }.max()
            }
            let age = max(now.timeIntervalSince(clip.lastCopied), 0) / 86_400
            let recency = exp(-age / tuning.recencyDays)
            let score: Double
            if hasMeaning {
                var partial = 0.0
                if wordScore == 0, !partialWords.isEmpty {
                    let found = partialWords.filter { corpus.contains($0, in: id) }.count
                    partial = tuning.partialWordWeight * Double(found) / Double(partialWords.count)
                }
                // A word match the model hasn't seen yet still ranks, on a middling cosine.
                score = Double(cosine ?? 0.6) + tuning.wordWeight * wordScore + partial + tuning.recencyWeight * recency
            } else {
                score = wordScore + 0.3 * recency
            }
            // The query in the text (1–1.15: at its start, a word's, anywhere); the app's name (0.9); every word (0.7).
            let group = wordScore >= 1 ? 3 : wordScore >= 0.9 ? 2 : wordScore > 0 ? 1 : 0
            candidates.append((score, id, wordScore > 0, cosine, group, clip.lastCopied))
        }
        func before(_ a: (score: Double, id: Int64, words: Bool, cosine: Float?, group: Int, copied: Date),
                    _ b: (score: Double, id: Int64, words: Bool, cosine: Float?, group: Int, copied: Date)) -> Bool {
            if a.group != b.group { return a.group > b.group }
            if a.group > 0 || a.score == b.score { return a.copied > b.copied }
            return a.score > b.score
        }
        for (id, wordScore) in wordScores { consider(id, wordScore: wordScore, cosine: meaningful[id]) }
        for (id, cosine) in meaningful where wordScores[id] == nil { consider(id, wordScore: 0, cosine: cosine) }

        return candidates.sorted(by: before).prefix(limit).compactMap { candidate -> SearchResult? in
            guard let clip = byID[candidate.id] else { return nil }
            let strong = candidate.words || !hasMeaning || (candidate.cosine ?? 0) >= strongBar
            return SearchResult(clip: clip, score: candidate.score, words: candidate.words, meaning: candidate.cosine,
                                strong: strong, file: candidate.words ? nil : matchedFile[candidate.id])
        }
    }

    /// `word` at the start of `text` or of a word in it.
    private static func startsWord(_ word: [UInt8], in text: [UInt8]) -> Bool {
        guard !word.isEmpty, word.count <= text.count else { return false }
        for start in 0...(text.count - word.count) where start == 0 || isBoundary(text[start - 1]) {
            if text[start..<(start + word.count)].elementsEqual(word) { return true }
        }
        return false
    }

    private static func isBoundary(_ byte: UInt8) -> Bool {
        // ASCII space and punctuation; a UTF-8 continuation or lead byte is part of a letter.
        byte < 0x80 && !(byte >= 0x30 && byte <= 0x39) && !(byte >= 0x61 && byte <= 0x7A) && !(byte >= 0x41 && byte <= 0x5A)
    }

    /// What words match against: the text, and for a picture the word "image" too (so "image" finds the pictures,
    /// copied as files too).
    static func searchable(_ clip: Clip) -> String {
        clip.kind == .image || clip.isPictureFile ? "image " + clip.text : clip.text
    }

    /// Word matching reads this much of a clip: enough for anything you'd remember, without slowing on huge pastes.
    static let foldedCharacters = 20_000

    /// Lowercased, without accents and width variants, whitespace collapsed to single spaces: "Café  Ünïcode" and
    /// "cafe unicode" match.
    public static func fold(_ text: String) -> [UInt8] {
        let folded = text.prefix(foldedCharacters)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(folded.utf8.count)
        var space = false
        for byte in folded.utf8 {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0 {
                space = true
            } else {
                if space, !bytes.isEmpty { bytes.append(0x20) }
                space = false
                bytes.append(byte)
            }
        }
        return bytes
    }
}

/// Every clip's folded text in one buffer, each followed by a zero byte (which folded text never has), so one scan finds
/// a word in all of them. The scan jumps between occurrences of the word's rarest byte with memchr (SIMD), which is
/// far faster than macOS's memmem (measured 2026-10-13: 0.13 ms vs 4.5 ms over 4 MB).
struct FoldedCorpus {
    private var bytes: [UInt8] = []
    private var starts: [Int] = []        // where each entry begins
    private var owners: [Int64] = []      // each entry's clip, or -1 once removed
    private var entries: [Int64: Int] = [:]
    private var frequency = [Int](repeating: 0, count: 256)
    private var dead = 0

    mutating func add(_ id: Int64, _ text: [UInt8]) {
        if let entry = entries[id] { kill(entry) }
        entries[id] = starts.count
        starts.append(bytes.count)
        owners.append(id)
        bytes.append(contentsOf: text)
        bytes.append(0)
        for byte in text { frequency[Int(byte)] += 1 }
    }

    mutating func remove(_ id: Int64) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        kill(entry)
        if dead > 256, dead > starts.count / 2 { compact() }
    }

    private mutating func kill(_ entry: Int) {
        owners[entry] = -1
        dead += 1
    }

    private mutating func compact() {
        var fresh = FoldedCorpus()
        for (entry, owner) in owners.enumerated() where owner >= 0 {
            let end = entry + 1 < starts.count ? starts[entry + 1] - 1 : bytes.count - 1
            fresh.add(owner, Array(bytes[starts[entry]..<end]))
        }
        self = fresh
    }

    /// Calls `body` with each clip whose text has `needle`, the offset of the first occurrence, and the byte before it.
    func forEachMatch(of needle: [UInt8], _ body: (Int64, Int, UInt8) -> Void) {
        guard !needle.isEmpty, needle.count <= bytes.count else { return }
        let anchor = needle.indices.min { frequency[Int(needle[$0])] < frequency[Int(needle[$1])] }!
        bytes.withUnsafeBufferPointer { buffer in
            needle.withUnsafeBufferPointer { pin in
                let base = buffer.baseAddress!
                var from = 0
                while let at = Self.find(pin, anchor: anchor, in: base, from: from, count: buffer.count) {
                    let entry = entryIndex(containing: at)
                    let start = starts[entry]
                    let next = entry + 1 < starts.count ? starts[entry + 1] : buffer.count
                    if owners[entry] >= 0 {
                        body(owners[entry], at - start, at > start ? base[at - 1] : 0x20)
                    }
                    from = next
                }
            }
        }
    }

    /// The clip's text has `needle`.
    func contains(_ needle: [UInt8], in id: Int64) -> Bool {
        guard let entry = entries[id] else { return false }
        let start = starts[entry]
        let end = entry + 1 < starts.count ? starts[entry + 1] : bytes.count
        let anchor = needle.indices.min { frequency[Int(needle[$0])] < frequency[Int(needle[$1])] } ?? 0
        return bytes.withUnsafeBufferPointer { buffer in
            needle.withUnsafeBufferPointer { pin in
                Self.find(pin, anchor: anchor, in: buffer.baseAddress!, from: start, count: end) != nil
            }
        }
    }

    /// The first offset at or after `from` (and before `count`) where `needle` starts.
    private static func find(_ needle: UnsafeBufferPointer<UInt8>, anchor: Int, in base: UnsafePointer<UInt8>,
                             from: Int, count: Int) -> Int? {
        let length = needle.count
        let key = Int32(needle[anchor])
        var position = from + anchor             // where the anchor byte may be
        let last = count - length + anchor       // the last place it can be with the needle still fitting
        while position <= last {
            guard let hit = memchr(base + position, key, last - position + 1) else { return nil }
            let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) - anchor
            if memcmp(base + at, needle.baseAddress!, length) == 0 { return at }
            position = at + anchor + 1
        }
        return nil
    }

    private func entryIndex(containing offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Vectors as rows of one contiguous float32 matrix: a query is one matrix-vector product, split across cores when the
/// history is big (it's bound by memory bandwidth: 10k rows are 30 MB).
final class VectorIndex<Key: Hashable> {
    private(set) var ids: [Key] = []
    private var rows: [Key: Int] = [:]
    private var matrix: [Float] = []
    private let dimension: Int
    private static var chunkRows: Int { 2048 }

    init(dimension: Int = ModelFiles.dimension) { self.dimension = dimension }

    var count: Int { ids.count }

    func contains(_ id: Key) -> Bool { rows[id] != nil }

    func row(of id: Key) -> Int? { rows[id] }

    func set(_ id: Key, _ vector: [Float]) {
        precondition(vector.count == dimension)
        if let row = rows[id] {
            matrix.replaceSubrange(row * dimension..<(row + 1) * dimension, with: vector)
        } else {
            rows[id] = ids.count
            ids.append(id)
            matrix.append(contentsOf: vector)
        }
    }

    /// Swaps the last row into the removed one's place.
    func remove(_ id: Key) {
        guard let row = rows.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if row != last {
            let moved = ids[last]
            matrix.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                (base + row * dimension).update(from: base + last * dimension, count: dimension)
            }
            ids[row] = moved
            rows[moved] = row
        }
        ids.removeLast()
        matrix.removeLast(dimension)
    }

    func removeAll() {
        ids.removeAll()
        rows.removeAll()
        matrix.removeAll()
    }

    /// Dot products with every row (the cosine: both sides are L2-normalized), in `ids` order.
    func scores(_ query: [Float]) -> [Float] {
        let count = ids.count
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        let dimension = self.dimension
        let chunks = (count + Self.chunkRows - 1) / Self.chunkRows
        matrix.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { query in
                out.withUnsafeMutableBufferPointer { out in
                    // Each chunk writes its own rows of `out`: no two touch the same memory.
                    nonisolated(unsafe) let (m, q, o) = (matrix.baseAddress!, query.baseAddress!, out.baseAddress!)
                    let chunkRows = Self.chunkRows
                    let multiply: @Sendable (Int) -> Void = { chunk in
                        let first = chunk * chunkRows
                        let rows = min(chunkRows, count - first)
                        vDSP_mmul(m + first * dimension, 1, q, 1, o + first, 1, vDSP_Length(rows), 1,
                                  vDSP_Length(dimension))
                    }
                    if chunks == 1 { multiply(0) } else { DispatchQueue.concurrentPerform(iterations: chunks, execute: multiply) }
                }
            }
        }
        return out
    }
}
