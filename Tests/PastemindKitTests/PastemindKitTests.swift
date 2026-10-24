import Foundation
import Testing
@testable import PastemindKit

/// Stores for tests, in a folder of this run's that goes as the run ends (SQLite's -wal and -shm files with them); one
/// a crashed run left is cleared by the next.
enum TestDatabase {
    static let folder: URL = {
        let fm = FileManager.default
        let prefix = "pastemind-tests-"
        for name in (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [] where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0 else { continue }
            try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent(name))
        }
        let folder = fm.temporaryDirectory.appendingPathComponent(prefix + "\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestDatabase.folder) }
        return folder
    }()

    static func url() -> URL {
        folder.appendingPathComponent("\(UUID().uuidString).sqlite")
    }
}

@Suite struct ClassifierTests {
    @Test func links() {
        #expect(ClipClassifier.kind(of: "https://github.com/ggml-org/llama.cpp") == .link)
        #expect(ClipClassifier.kind(of: "  www.example.com/path \n") == .link)
        #expect(ClipClassifier.kind(of: "mailto:someone@example.com") == .link)
        #expect(ClipClassifier.kind(of: "https://example.com and more words") != .link)
        #expect(ClipClassifier.kind(of: "file:///etc/hosts") != .link)
    }

    @Test func colors() {
        #expect(ClipClassifier.kind(of: "#F2A22A") == .color)
        #expect(ClipClassifier.kind(of: "#abc") == .color)
        #expect(ClipClassifier.kind(of: "rgb(10, 20, 30)") == .color)
        #expect(ClipClassifier.kind(of: "add") == .text)
        #expect(ClipClassifier.kind(of: "1234567") == .text)
    }

    @Test func code() {
        #expect(ClipClassifier.kind(of: "func f() {\n    return 1\n}") == .code)
        #expect(ClipClassifier.kind(of: "git rebase -i HEAD~5") == .code)
        #expect(ClipClassifier.kind(of: "ssh deploy@10.0.4.17 -p 2222") == .code)
        #expect(ClipClassifier.kind(of: "ssh") == .text)
        #expect(ClipClassifier.kind(of: "Meeting notes: launch moved to Thursday.\nMarketing needs screenshots by Tuesday, as agreed.") == .text)
    }

    @Test func sameTextIsOneClip() {
        #expect(ClipClassifier.hash(kind: .text, text: "a") == ClipClassifier.hash(kind: .code, text: "a"))
        #expect(ClipClassifier.hash(kind: .text, text: "a") != ClipClassifier.hash(kind: .file, text: "a"))
    }
}

@Suite struct WordSearchTests {
    let now = Date()

    func index(_ texts: [String]) -> ClipIndex {
        let index = ClipIndex()
        index.load(texts.enumerated().map { offset, text in
            Clip(id: Int64(offset + 1), kind: .text, text: text, lastCopied: now.addingTimeInterval(-Double(offset)))
        }, vectors: [])
        return index
    }

    @Test func foldIgnoresCaseAccentsAndSpacing() {
        #expect(ClipIndex.fold("Café  Ünïcode\n\tÉTÉ") == ClipIndex.fold("cafe unicode ete"))
        #expect(ClipIndex.fold("Ёлка ЖУК") == ClipIndex.fold("елка жук"))
    }

    @Test func phraseAndWords() {
        let index = index(["The quick brown fox", "quick thinking", "brown bear, quick", "nothing here"])
        #expect(index.search("quick brown").map(\.id) == [1, 3])   // the phrase first, then both words apart
        #expect(Set(index.search("QUICK").map(\.id)) == [1, 2, 3])
        #expect(index.search("zebra").isEmpty)
        #expect(index.search("   ").isEmpty)
    }

    @Test func matchesAnywhereEvenOneLetter() {
        let index = index(["192.168.1.254", "ssh deploy@10.0.4.17", "Привет, мир"])
        #expect(index.search("168.1").map(\.id) == [1])
        #expect(index.search("@10").map(\.id) == [2])
        #expect(index.search("МИР").map(\.id) == [3])
        #expect(Set(index.search("1").map(\.id)) == [1, 2])
    }

    @Test func aPictureFileIsAnImage() {
        let photo = Clip(id: 1, kind: .file, text: "/Users/me/Downloads/IMG_2034.HEIC")
        let pdf = Clip(id: 2, kind: .file, text: "/Users/me/Downloads/lease.pdf")
        let two = Clip(id: 3, kind: .file, text: "/a/one.png\n/a/two.png")
        #expect(photo.isPictureFile && photo.typeName == "Image" && photo.isKept(by: [.image]) && photo.isKept(by: [.file]))
        #expect(!pdf.isPictureFile && pdf.typeName == "File" && !pdf.isKept(by: [.image]))
        #expect(!two.isPictureFile && two.typeName == "2 files")
        // Titled as a copied picture once measured, by its name until then.
        #expect(photo.title == "Image: IMG_2034.HEIC")
        var measured = photo
        (measured.width, measured.height) = (4032, 3024)
        #expect(measured.title == "Image: 4032×3024")
        let index = ClipIndex()
        index.load([photo, pdf, Clip(id: 4, kind: .text, text: "a plain note")], vectors: [])
        #expect(index.search("image").map(\.id) == [1])
    }

    /// As the history lists them: what has the query in it, wherever, the most recent first.
    @Test func theMostRecentMatchRanksFirst() {
        let index = index(["a deploy script", "deploy now"])
        #expect(index.search("deploy").map(\.id) == [1, 2])
    }

    @Test func changesAreSearchable() {
        let index = index(["alpha", "beta"])
        index.upsert(Clip(id: 9, kind: .text, text: "gamma ray", lastCopied: now.addingTimeInterval(10)))
        #expect(index.clips.first?.id == 9)
        #expect(index.search("gamma").map(\.id) == [9])
        var changed = index.clip(id: 1)!
        changed.text = "omega"
        index.update(changed)
        #expect(index.search("alpha").isEmpty)
        #expect(index.search("omega").map(\.id) == [1])
        index.remove([2])
        #expect(index.search("beta").isEmpty)
        #expect(index.count == 2)
    }

    @Test func survivesCompaction() {
        let index = index((0..<600).map { "clip number \($0) xyz\($0)" })
        index.remove(Set((1...500).map { Int64($0) }))
        #expect(index.count == 100)
        #expect(index.search("xyz550").map(\.id) == [551])
        #expect(index.search("xyz10").isEmpty)   // clip 11 ("xyz10") was removed; "xyz100"… too
        #expect(index.search("clip number").count == 80)   // the limit
    }

    @Test func imagesMatchTheWordImage() {
        let index = ClipIndex()
        index.load([Clip(id: 1, kind: .image, text: "", image: "a.png"), Clip(id: 2, kind: .text, text: "hello")],
                   vectors: [])
        #expect(index.search("image").map(\.id) == [1])
    }

    @Test func theAppItCameFromMatches() {
        let index = ClipIndex()
        index.load([
            Clip(id: 1, kind: .text, text: "Nemotron Streaming 3.5", appName: "Handy", lastCopied: now),
            Clip(id: 2, kind: .text, text: "handy tips for later", appName: "Notes", lastCopied: now.addingTimeInterval(-10)),
            Clip(id: 3, kind: .code, text: "git push", appName: "Zed", lastCopied: now.addingTimeInterval(-20)),
            Clip(id: 4, kind: .text, text: "deploy notes", appName: "Zed", lastCopied: now.addingTimeInterval(-30)),
        ], vectors: [])
        #expect(index.search("handy").map(\.id) == [2, 1])   // the word in the text first, then the app
        #expect(index.search("HAN").map(\.id) == [2, 1])
        #expect(index.search("zed deploy").map(\.id) == [4])   // the app, and the other word in the text
        #expect(index.search("ed").isEmpty)                      // not the middle of a name
    }

    @Test func aKindAndAColonFilterTheSearch() {
        #expect(ClipKind.filter(in: "Image:") == ([.image], ""))
        #expect(ClipKind.filter(in: "files: invoice q3") == ([.file], "invoice q3"))
        #expect(ClipKind.filter(in: " CODE :git") == ([.code], "git"))
        #expect(ClipKind.filter(in: "https://apple.com").kinds == nil)
        #expect(ClipKind.filter(in: "note: call Anna") == (nil, "note: call Anna"))
        #expect(ClipKind.filter(in: "image of a cat") == (nil, "image of a cat"))
    }

    @Test func picturesMatchTheWordImage() {
        let index = ClipIndex()
        index.load([Clip(id: 1, kind: .image, text: "", image: "a.png"),
                    Clip(id: 2, kind: .image, text: "Q4 roadmap", image: "b.png"),
                    Clip(id: 3, kind: .text, text: "an image of it")], vectors: [])
        #expect(Set(index.search("image").map(\.id)) == [1, 2, 3])
        #expect(index.search("screenshot").isEmpty)
    }
}

@Suite struct RedoneCopyTests {
    @Test func aCopyThatStartsTheSameRedoesTheOneBefore() {
        #expect(RedoneCopy.redoes("Hello wor", with: "Hello world"))      // longer
        #expect(RedoneCopy.redoes("Hello world, again", with: "Hello world"))   // shorter
        #expect(RedoneCopy.redoes("Hello world", with: "  Hello world\n"))      // spaces before, a line break after
        #expect(!RedoneCopy.redoes("Hello world", with: "Hello world"))   // the same: copied again, not redone
        #expect(!RedoneCopy.redoes("Hello world", with: "Goodbye world"))
        #expect(!RedoneCopy.redoes("world", with: "Hello world"))        // ends the same, starts differently
        #expect(!RedoneCopy.redoes("", with: "Hello"))
    }
}

@Suite struct MeaningSearchTests {
    /// Unit vectors in a few directions, mixed: cosine is easy to predict.
    func vector(_ weights: [Int: Float]) -> [Float] {
        var vector = [Float](repeating: 0, count: ModelFiles.dimension)
        for (axis, weight) in weights { vector[axis] = weight }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / norm }
    }

    @Test func ranksByMeaningAndDropsWhatsFarBehind() {
        let now = Date()
        let index = ClipIndex()
        let clips = (1...4).map { Clip(id: Int64($0), kind: .text, text: "clip \($0)", lastCopied: now) }
        index.load(clips, vectors: [
            (1, vector([0: 1, 1: 0.3])),   // close to the query: cosine 0.96
            (2, vector([0: 1, 1: 0.4])),   // a bit further: 0.93
            (3, vector([0: 1, 1: 3])),     // far: cosine ~0.32
            (4, vector([2: 1])),           // unrelated
        ])
        let results = index.search("something", vector: vector([0: 1]), now: now)
        #expect(results.map(\.id) == [1, 2])
        #expect(results.allSatisfy { !$0.words })
    }

    /// Every link has "http" in it: the one copied a minute ago first, though the model finds yesterday's closer; a
    /// clip only close in meaning after them.
    @Test func wordMatchesGoByRecencyNotMeaning() {
        let now = Date()
        let index = ClipIndex()
        index.load([
            Clip(id: 1, kind: .link, text: "https://scalar.usc.edu/works/adobe", lastCopied: now.addingTimeInterval(-60)),
            Clip(id: 2, kind: .link, text: "http://127.0.0.1:8765/", lastCopied: now.addingTimeInterval(-86_400)),
            Clip(id: 3, kind: .text, text: "protocols", lastCopied: now),
        ], vectors: [(1, vector([0: 1, 1: 1])), (2, vector([0: 1, 1: 0.1])), (3, vector([0: 1, 1: 0.05]))])
        #expect(index.search("http", vector: vector([0: 1]), now: now).map(\.id) == [1, 2, 3])
    }

    @Test func nothingWhenNothingStandsOutOfTheCrowd() {
        let now = Date()
        /// A clip on its own axis at cosine `c` to the query (axis 0).
        func clip(_ id: Int, _ c: Float) -> (Clip, [Float]) {
            (Clip(id: Int64(id), kind: .text, text: "clip \(id)", lastCopied: now), vector([0: c, id: (1 - c * c).squareRoot()]))
        }
        let crowd = (1...11).map { clip($0, 0.64 + Float($0) * 0.003) }   // 0.643–0.673, the median 0.658
        let index = ClipIndex()
        // The best only just above the rest (0.70, 0.04 over the median): no answer, nothing shown.
        index.load((crowd + [clip(12, 0.70)]).map(\.0), vectors: (crowd + [clip(12, 0.70)]).map { ($0.0.id, $0.1) })
        #expect(index.search("plane", vector: vector([0: 1]), now: now).isEmpty)
        // One that stands out (0.80): it alone.
        index.load((crowd + [clip(12, 0.80)]).map(\.0), vectors: (crowd + [clip(12, 0.80)]).map { ($0.0.id, $0.1) })
        #expect(index.search("plane", vector: vector([0: 1]), now: now).map(\.id) == [12])
    }

    @Test func clipsCloseToEveryQueryAnswerNone() {
        let now = Date()
        func clip(_ id: Int, _ v: [Float]) -> (Clip, [Float]) {
            (Clip(id: Int64(id), kind: .text, text: "clip \(id)", lastCopied: now), v)
        }
        let crowd = (30...40).map { clip($0, vector([0: 0.55, $0: 0.84])) }   // cosine 0.55 each: unrelated
        let answer = clip(1, vector([0: 0.8, 20: 0.6]))                       // 0.80, far from the typical query
        let word = clip(2, vector([0: 0.78, 1: 0.6]))                         // 0.79, and as close to any query
        let all = crowd + [answer, word]
        let index = ClipIndex()
        index.load(all.map(\.0), vectors: all.map { ($0.0.id, $0.1) })
        #expect(Set(index.search("plane", vector: vector([0: 1]), now: now).map(\.id)) == [1, 2])
        index.typicalQuery = [Float](repeating: 0, count: ModelFiles.dimension)
        index.typicalQuery![0] = 0.7
        index.typicalQuery![1] = 0.7
        #expect(index.search("plane", vector: vector([0: 1]), now: now).map(\.id) == [1])
    }

    @Test func aQueryOfOneWordHasItsOwnTypicalQuery() {
        let now = Date()
        let crowd = (30...40).map { (Clip(id: Int64($0), kind: .text, text: "clip \($0)", lastCopied: now),
                                     vector([0: 0.55, $0: 0.84])) }
        let word = (Clip(id: 2, kind: .text, text: "clip 2", lastCopied: now), vector([0: 0.78, 1: 0.6]))
        let all = crowd + [word]
        let index = ClipIndex()
        index.load(all.map(\.0), vectors: all.map { ($0.0.id, $0.1) })
        index.typicalQuery = vector([5: 1]).map { $0 * 0.7 }        // phrases: nowhere near the clip
        index.typicalWord = vector([0: 1, 1: 1]).map { $0 * 0.99 }  // single words: as close to it as the query is
        #expect(index.search("plane", vector: vector([0: 1]), now: now).isEmpty)
        #expect(index.search("plane ticket", vector: vector([0: 1]), now: now).map(\.id) == [2])
    }

    @Test func copiedFilesAreFoundByAnyOneOfThem() {
        let now = Date()
        let index = ClipIndex()
        index.load([Clip(id: 1, kind: .file, text: "/a/zebra.heic\n/a/notes.md\n/a/song.m4a", lastCopied: now),
                    Clip(id: 2, kind: .text, text: "something else", lastCopied: now)],
                   vectors: [(1, vector([0: 0.6, 1: 1])),   // all three together: far from the query (0.51)
                             (2, vector([3: 1]))])
        #expect(index.search("zebra photo", vector: vector([0: 1]), now: now).isEmpty)
        index.setParts([vector([4: 1]), vector([0: 1, 5: 0.2]), vector([6: 1])], for: 1)   // the second: 0.98
        let found = index.search("zebra photo", vector: vector([0: 1]), now: now)
        #expect(found.map(\.id) == [1])
        #expect(found[0].file == 1)
        #expect(index.hasParts(1) && index.embeddedCount == 2)
        index.remove([1])
        #expect(index.search("zebra photo", vector: vector([0: 1]), now: now).isEmpty && index.embeddedCount == 1)
    }

    @Test func wordMatchesStayEvenWhenTheModelDisagrees() {
        let now = Date()
        let index = ClipIndex()
        index.load([Clip(id: 1, kind: .text, text: "invoice 4417", lastCopied: now),
                    Clip(id: 2, kind: .text, text: "hosting bill", lastCopied: now)],
                   vectors: [(1, vector([0: 0.75, 5: 1])), (2, vector([0: 1]))])
        let results = index.search("4417", vector: vector([0: 1]), now: now)
        #expect(results.map(\.id) == [1, 2])   // a word match on a middling cosine (0.6) outranks a perfect one
        #expect(results[0].words && results[0].strong)
    }

    @Test func vectorIndexRemovesBySwapping() {
        let vectors = VectorIndex<Int64>()
        vectors.set(1, vector([0: 1]))
        vectors.set(2, vector([1: 1]))
        vectors.set(3, vector([2: 1]))
        vectors.remove(1)
        #expect(vectors.count == 2)
        let scores = vectors.scores(vector([2: 1]))
        #expect(scores[vectors.row(of: 3)!] > 0.99)
        #expect(scores[vectors.row(of: 2)!] < 0.01)
    }

    @Test func manyVectorsInChunks() {
        // More rows than one chunk (2048): the chunks run in parallel and must each land in their own rows.
        let vectors = VectorIndex<Int64>()
        for id in 0..<5000 { vectors.set(Int64(id), vector([id % 7: 1, 7: 0.1])) }
        let scores = vectors.scores(vector([3: 1]))
        #expect(scores.count == 5000)
        for id in [3, 2047 + 4, 4903] where id % 7 == 3 { #expect(scores[vectors.row(of: Int64(id))!] > 0.99) }
        #expect(scores[vectors.row(of: 4904)!] < 0.01)
    }
}

@Suite struct StoreTests {
    func store() throws -> ClipStore {
        let url = TestDatabase.url()
        return try ClipStore(path: url)
    }

    @Test func copyingAgainMovesToTheTop() throws {
        let store = try store()
        let first = try store.record(kind: .text, text: "hello", hash: "h1", appID: "a", appName: "A",
                                     at: Date(timeIntervalSince1970: 100))
        try store.record(kind: .text, text: "other", hash: "h2", appID: nil, appName: nil,
                         at: Date(timeIntervalSince1970: 200))
        let again = try store.record(kind: .text, text: "hello", hash: "h1", appID: "b", appName: "B",
                                     at: Date(timeIntervalSince1970: 300))
        #expect(first.isNew && !again.isNew)
        #expect(again.clip.id == first.clip.id)
        #expect(again.clip.copies == 2)
        #expect(again.clip.appName == "B")
        #expect(try store.all().map(\.text) == ["hello", "other"])
    }

    @Test func eachCopiedFilesVectorRoundTrips() throws {
        let store = try store()
        let files = try store.record(kind: .file, text: "/a/x.png\n/a/y.pdf", hash: "f1", appID: nil, appName: nil)
        let parts: [[Float]] = [(0..<ModelFiles.dimension).map { Float($0 % 7) / 8 },
                                (0..<ModelFiles.dimension).map { -Float($0 % 5) / 8 }]
        try store.setParts(id: files.clip.id, parts)
        let read = try store.parts()
        #expect(read.map(\.id) == [files.clip.id])
        #expect(read[0].parts == parts)   // these values are exact in float16
        // A short document has no pieces: kept as read, not read again.
        let short = try store.record(kind: .file, text: "/a/note.txt", hash: "f2", appID: nil, appName: nil)
        try store.setParts(id: short.clip.id, [])
        #expect(try store.parts().first { $0.id == short.clip.id }?.parts == [])
    }

    @Test func picturesAreTitledBySizeAndWeight() throws {
        let store = try store()
        let picture = try store.record(kind: .image, text: "Q4 roadmap", hash: "i1", appID: nil, appName: "Zed",
                                       image: "a.png", width: 8, height: 4, bytes: 14_000)
        let weight = ByteCountFormatter.string(fromByteCount: 14_000, countStyle: .file)
        #expect(picture.clip.typeName == "Image" && picture.clip.title == "Image: 8×4 (\(weight))")
        let older = try store.record(kind: .image, text: "", hash: "i2", appID: nil, appName: nil, image: "b.png",
                                     width: 2, height: 2)
        #expect(older.clip.title == "Image: 2×2")
        let photo = try store.record(kind: .file, text: "/a/IMG_1.HEIC", hash: "f1", appID: nil, appName: nil)
        _ = try store.record(kind: .file, text: "/a/lease.pdf", hash: "f2", appID: nil, appName: nil)
        #expect(try Set(store.unmeasuredPictures().map(\.id)) == [older.clip.id, photo.clip.id])
        try store.setSize(id: older.clip.id, width: 9, height: 9, bytes: 2_048)
        #expect(try store.clip(id: older.clip.id).map { [$0.width, $0.bytes] } == [2, 2_048])
        // Copied again, measured again (the file may have changed).
        _ = try store.record(kind: .file, text: "/a/IMG_1.HEIC", hash: "f1", appID: nil, appName: nil, width: 8,
                             height: 6, bytes: 99)
        #expect(try store.unmeasuredPictures().isEmpty)
        let small = ByteCountFormatter.string(fromByteCount: 99, countStyle: .file)
        #expect(try store.clip(id: photo.clip.id)?.title == "Image: 8×6 (\(small))")
    }

    /// Stores written while screenshots were told apart have a "screenshot" column (1 for screenshots): left unread.
    @Test func storesWithTheScreenshotColumnStillOpen() throws {
        let url = TestDatabase.url()
        try Database(path: url.path).execute("""
            CREATE TABLE clips(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, hash TEXT NOT NULL UNIQUE,
            app_id TEXT, app_name TEXT, first_copied REAL NOT NULL, last_copied REAL NOT NULL,
            copies INTEGER NOT NULL DEFAULT 1, pinned INTEGER NOT NULL DEFAULT 0, image TEXT, width INTEGER,
            height INTEGER, rich BLOB, rich_type TEXT, vector BLOB, vector_version INTEGER, screenshot INTEGER);
            INSERT INTO clips(kind, text, hash, first_copied, last_copied, image, screenshot)
            VALUES ('image', '', 'x', 1, 1, 'x.png', 1);
            """)
        let store = try ClipStore(path: url)
        #expect(try store.all().first?.typeName == "Image")
        let added = try store.record(kind: .image, text: "", hash: "y", appID: nil, appName: nil, image: "y.png")
        #expect(added.isNew && added.clip.typeName == "Image")
    }

    @Test func vectorsRoundTripAsHalves() throws {
        let store = try store()
        let clip = try store.record(kind: .text, text: "x", hash: "x", appID: nil, appName: nil).clip
        #expect(try store.vectors().isEmpty)
        var vector = [Float](repeating: 0, count: ModelFiles.dimension)
        vector[0] = 0.6
        vector[1] = 0.8
        try store.setVector(id: clip.id, vector: vector)
        let stored = try store.vectors()
        #expect(stored.count == 1)
        #expect(abs(stored[0].vector[1] - 0.8) < 0.001)
        #expect(try store.clip(id: clip.id)?.embedded == true)
        try store.setText(id: clip.id, text: "new text")   // a new text needs a new vector
        #expect(try store.vectors().isEmpty)
    }

    @Test func picturesKeepWhatTheirVectorWasMadeFrom() throws {
        let store = try store()
        let picture = try store.record(kind: .image, text: "", hash: "p", appID: nil, appName: nil, image: "p.png").clip
        #expect(!picture.contentVector)
        var vector = [Float](repeating: 0, count: ModelFiles.dimension)
        vector[0] = 1
        try store.setVector(id: picture.id, vector: vector, fromContent: true)
        #expect(try store.clip(id: picture.id)?.contentVector == true)
        try store.setText(id: picture.id, text: "Q4 roadmap")   // made again, with its text
        #expect(try store.clip(id: picture.id)?.contentVector == false)
        #expect(try store.vectors().isEmpty)
        try store.setVector(id: picture.id, vector: vector)   // from its text alone (no image encoder)
        #expect(try store.clip(id: picture.id)?.contentVector == false)
        #expect(try store.clip(id: picture.id)?.embedded == true)
    }

    @Test func aPicturesTextGoesWithItWhenTheresEnough() {
        let long = "Quarterly revenue, 2026: Q1 320, Q2 410, Q3 380, Q4 520"
        #expect(Clip(id: 1, kind: .image, text: long).textBesidePicture == long)
        #expect(Clip(id: 2, kind: .image, text: "8ball").textBesidePicture == nil)
        #expect(Clip(id: 3, kind: .text, text: long).textBesidePicture == nil)
        #expect(Prompts.picture(marker: "<m>", text: nil) == "<m>")
        #expect(Prompts.picture(marker: "<m>", text: long) == "title: none | text: <m>\n" + long)
    }

    @Test func keysAndPasswordStoresAreNeverRead() {
        for path in ["/Users/me/server.pem", "/Users/me/.ssh/config", "/Users/me/id_ed25519", "/Users/me/vault.kdbx",
                     "/Users/me/project/.env.local", "/Users/me/.aws/config", "/Users/me/Certificates.p12"] {
            #expect(CopiedFiles.isPrivate(URL(fileURLWithPath: path)), "\(path)")
        }
        for path in ["/Users/me/lease.pdf", "/Users/me/keynote-deck.key.png", "/Users/me/identity.txt", "/Users/me/env.md"] {
            #expect(!CopiedFiles.isPrivate(URL(fileURLWithPath: path)), "\(path)")
        }
    }

    @Test func otherAppsFoldersAreTheirData() {
        let home = URL(fileURLWithPath: "/Users/me")
        for path in ["/Users/me/Library/Group Containers/X.ru.keepcoder.Telegram/postbox/media/photo-y.jpg",
                     "/Users/me/Library/Containers/ru.keepcoder.Telegram/Data/tmp/photo.jpg"] {
            #expect(CopiedFiles.isAppData(URL(fileURLWithPath: path), home: home), "\(path)")
        }
        for path in ["/Users/me/Downloads/photo.jpg", "/Users/me/Library/Containers",
                     "/Users/me/Library/ContainersX/a.png", "/Users/other/Library/Containers/app/Data/a.png"] {
            #expect(!CopiedFiles.isAppData(URL(fileURLWithPath: path), home: home), "\(path)")
        }
    }

    @Test func filesGoInUnderTheirNames() {
        let urls = (1...14).map { URL(fileURLWithPath: "/tmp/photo-\($0).jpg") }
        #expect(CopiedFiles.title(of: Array(urls.prefix(2))) == "photo-1.jpg, photo-2.jpg")
        #expect(CopiedFiles.title(of: urls).hasSuffix("photo-12.jpg and 2 more"))
        #expect(Prompts.files(title: "a.pdf", markers: [], text: "rent is due") == "title: a.pdf | text: rent is due")
        #expect(Prompts.files(title: "clip.mp4", markers: ["<m>", "<m>"], text: nil) == "title: clip.mp4 | text: <m> <m>")
    }

    @Test func richAndDelete() throws {
        let store = try store()
        let clip = try store.record(kind: .image, text: "", hash: "i", appID: nil, appName: nil, image: "i.png",
                                    rich: Data([1, 2, 3]), richType: "public.rtf").clip
        #expect(try store.rich(id: clip.id)?.type == "public.rtf")
        #expect(try store.delete(ids: [clip.id]) == ["i.png"])
        #expect(try store.all().isEmpty)
    }

    @Test func expiryKeepsPinned() throws {
        let store = try store()
        let old = try store.record(kind: .text, text: "old", hash: "o", appID: nil, appName: nil,
                                   at: Date(timeIntervalSince1970: 10)).clip
        let pinned = try store.record(kind: .text, text: "pinned", hash: "p", appID: nil, appName: nil,
                                      at: Date(timeIntervalSince1970: 10)).clip
        try store.setPinned(id: pinned.id, true)
        for i in 0..<3 {
            try store.record(kind: .text, text: "new \(i)", hash: "n\(i)", appID: nil, appName: nil,
                             at: Date(timeIntervalSince1970: 1000 + Double(i)))
        }
        #expect(try store.expired(before: Date(timeIntervalSince1970: 500), keep: 100) == [old.id])
        #expect(Set(try store.expired(before: .distantPast, keep: 2)).count == 2)   // "old" and "new 0"
    }
}

@Suite struct LauncherTests {
    func app(_ name: String, aliases: [String] = [], lastUsed: Date? = nil) -> LaunchItem {
        LaunchItem(kind: .app, name: name, aliases: aliases, path: "/Applications/\(name).app",
                   url: URL(fileURLWithPath: "/Applications/\(name).app"), lastUsed: lastUsed)
    }

    @Test func fuzzyMatchesStartsWordsAndInitials() {
        #expect(Fuzzy.score("safari", "Safari") == 1)
        #expect(Fuzzy.score("saf", "Safari") > Fuzzy.score("saf", "Pasta Fan"))
        #expect(Fuzzy.score("store", "App Store") >= 0.8)                 // start of a word
        #expect(Fuzzy.score("vsc", "Visual Studio Code") >= 0.75)          // initials
        #expect(Fuzzy.score("cleaner", "AppCleaner") >= 0.8)               // camelCase words
        #expect(Fuzzy.score("goo chr", "Google Chrome") >= 0.8)            // a prefix of each word
        #expect(Fuzzy.score("wifi", "Wi\u{2011}Fi") > 0.95)                // macOS's non-breaking hyphen
        #expect(Fuzzy.score("sfr", "Safari") > 0.3)                        // letters in order
        #expect(Fuzzy.score("meet", "Game Center") == 0)                   // …but not scattered mid-word
        #expect(Fuzzy.score("meet", "Device Management") == 0)
        #expect(Fuzzy.score("xyz", "Safari") == 0)
        #expect(Fuzzy.score("salck", "Slack") > 0.55)                      // misspelled: letters swapped
        #expect(Fuzzy.score("lsack", "Slack") > 0.55)                      // …the first two too
        #expect(Fuzzy.score("safri", "Safari") > 0.55)                     // a letter missing
        #expect(Fuzzy.score("telegrram", "Telegram") > 0.55)               // one extra
        #expect(Fuzzy.score("stuido", "Visual Studio Code") > 0.5)         // in a word
        #expect(Fuzzy.score("salck", "Slack") < Fuzzy.score("slac", "Slack"))   // below what's typed right
        #expect(Fuzzy.score("sla", "Sublime") < 0.55)                      // not from 3 letters
        #expect(Fuzzy.score("mail", "Maps") == 0)                          // two wrong in four
        #expect(Fuzzy.score("mail", "TV") == 0)                            // a name shorter than the misspelling
        #expect(Fuzzy.score("", "Safari") == 0)
    }

    @Test func rankingPrefersBetterMatchesThenPicks() {
        let items = [app("Terminal"), app("iTerm"), app("Telegram")]
        let (terminal, iterm) = (items[0].id, items[1].id)
        let now = Date()
        func pick(_ count: Int, daysAgo: Double) -> LaunchHistory.Pick {
            LaunchHistory.Pick(count: count, last: now.addingTimeInterval(-daysAgo * 86_400))
        }
        func first(_ query: String, _ history: LaunchHistory) -> String? {
            LaunchRanker.merge(LaunchQuery(query), catalog: items, files: [], history: history).first?.item.name
        }
        #expect(first("ter", LaunchHistory()) == "Terminal")
        // What you picked for these letters before, the last one first however often the other was.
        #expect(first("ter", LaunchHistory(picks: [iterm: pick(1, daysAgo: 0)])) == "iTerm")
        #expect(first("ter", LaunchHistory(picks: [terminal: pick(9, daysAgo: 30), iterm: pick(1, daysAgo: 1)])) == "iTerm")
        #expect(first("ter", LaunchHistory(picks: [terminal: pick(1, daysAgo: 0), iterm: pick(9, daysAgo: 1)])) == "Terminal")
        // Nothing picked for "ter": the last one opened at all (with "it"), as it starts one of its words.
        #expect(first("ter", LaunchHistory(opened: [iterm: now, terminal: now.addingTimeInterval(-86_400)])) == "iTerm")
        #expect(first("ter", LaunchHistory(picks: [terminal: pick(1, daysAgo: 30)], opened: [iterm: now])) == "Terminal")
        // …but not one that only has the letters scattered in it ("sa" in Slack).
        let apps = [app("Safari"), app("Slack")]
        let slackLast = LaunchHistory(opened: [apps[1].id: now])
        #expect(LaunchRanker.merge(LaunchQuery("sa"), catalog: apps, files: [], history: slackLast).first?.item.name
                == "Safari")
        #expect(LaunchRanker.rank("zzz", items: items).isEmpty)
    }

    @Test func recentUseBreaksTies() {
        let items = [app("Calendar"), app("Calculator", lastUsed: Date())]
        #expect(LaunchRanker.rank("cal", items: items).first?.item.name == "Calculator")
    }

    @Test func filesAmongAppsAreFewAndGood() {
        let files = (0..<10).map { i in
            LaunchItem(kind: .file, name: "notes \(i).txt", path: "/Users/me/notes \(i).txt",
                       url: URL(fileURLWithPath: "/Users/me/notes \(i).txt"))
        }
        let mixed = LaunchRanker.merge(LaunchQuery("notes"), catalog: [app("Notes")], files: files)
        #expect(mixed.first?.item.name == "Notes")
        #expect(mixed.filter { $0.item.kind == .file }.count == LaunchRanker.filesAmongApps)
        let onlyFiles = LaunchRanker.merge(LaunchQuery("'notes"), catalog: [app("Notes")], files: files)
        #expect(onlyFiles.count == 10 && onlyFiles.allSatisfy { $0.item.kind == .file })
    }

    @Test func queryPrefixes() {
        #expect(LaunchQuery("safari") == LaunchQuery("safari"))
        #expect(!LaunchQuery("safari").filesOnly)
        #expect(LaunchQuery("'report").filesOnly && LaunchQuery("'report").text == "report")
        #expect(LaunchQuery(" report").filesOnly)
        #expect(LaunchQuery("open report q3").filesOnly && LaunchQuery("open report q3").text == "report q3")
        #expect(!LaunchQuery("opener").filesOnly)
    }

    @Test func noisyPathsAreSkipped() {
        let home = NSHomeDirectory()
        #expect(SpotlightFiles.isNoise(home + "/code/app/node_modules/x/README.md"))
        #expect(SpotlightFiles.isNoise(home + "/.cache/thing.txt"))
        #expect(SpotlightFiles.isNoise(home + "/Library/Preferences/a.plist"))
        #expect(!SpotlightFiles.isNoise(home + "/Documents/Reports/q3.pdf"))
        #expect(SpotlightFiles.escape(#"a"b*c\d"#) == #"a\"b\*c\\d"#)
    }

    @Test func launchesAreLearnedForEveryPrefix() throws {
        let url = TestDatabase.url()
        let store = try ClipStore(path: url)
        let earlier = Date(timeIntervalSince1970: 1_000)
        try store.recordLaunch(query: "Saf", item: "safari", at: earlier)
        try store.recordLaunch(query: "sa", item: "safari", at: earlier.addingTimeInterval(60))
        #expect(try store.picks(for: "s")["safari"]?.count == 2)
        #expect(try store.picks(for: "s")["safari"]?.last == earlier.addingTimeInterval(60))
        #expect(try store.picks(for: "saf")["safari"]?.count == 1)
        #expect(try store.picks(for: "safa").isEmpty)
        #expect(try store.lastOpened() == ["safari": earlier.addingTimeInterval(60)])
    }
}

@Suite struct SnippetTests {
    func store() throws -> ClipStore {
        let url = TestDatabase.url()
        return try ClipStore(path: url)
    }

    @Test func keptEditedUsedAndDeleted() throws {
        let store = try store()
        let email = try store.addSnippet(title: "Work email", text: "me@example.com", at: Date(timeIntervalSince1970: 100))
        let address = try store.addSnippet(title: "Address", text: "Unter den Linden 77\nBerlin",
                                           at: Date(timeIntervalSince1970: 200))
        var edited = email
        edited.text = "michael@example.com"
        try store.updateSnippet(edited)
        try store.useSnippet(id: email.id, at: Date(timeIntervalSince1970: 300))
        let all = try store.snippets()
        #expect(all.first { $0.id == email.id }?.text == "michael@example.com")
        #expect(all.first { $0.id == email.id }?.uses == 1)
        #expect(Snippet.search("", in: all).map(\.id) == [address.id, email.id])   // the newest first; using one keeps it there
        try store.deleteSnippet(id: address.id)
        #expect(try store.snippets().map(\.id) == [email.id])
    }

    @Test func searchPrefersTheTitle() {
        let snippets = [
            Snippet(id: 1, title: "Reply: thanks", text: "Thanks for the email, I'll get back to you."),
            Snippet(id: 2, title: "Email signature", text: "Best, M."),
            Snippet(id: 3, title: "Home address", text: "Unter den Linden 77"),
        ]
        #expect(Snippet.search("email", in: snippets).map(\.id) == [2, 1])   // the title's start, then the text
        #expect(Snippet.search("linden", in: snippets).map(\.id) == [3])
        #expect(Snippet.search("home linden", in: snippets).map(\.id) == [3])
        #expect(Snippet.search("zebra", in: snippets).isEmpty)
        #expect(Snippet.title(for: "  \n  Dear team,\nhere's the plan") == "Dear team,")
    }

    @Test func foldersHoldSnippets() throws {
        let store = try store()
        let work = try store.addSnippetFolder(name: "Work")
        let replies = try store.addSnippetFolder(name: "Replies")
        let email = try store.addSnippet(title: "Main email", text: "me@example.com")
        var standup = try store.addSnippet(title: "Standup", text: "Yesterday, today, blockers", folder: work.id)
        _ = try store.addSnippet(title: "Thanks", text: "Thanks, I'll get back to you", folder: replies.id)
        standup.title = "Standup notes"
        try store.updateSnippet(standup)
        var snippets = try store.snippets()
        let folders = try store.snippetFolders()
        #expect(snippets.first { $0.id == standup.id }?.folder == work.id)   // kept through an edit
        // At the top: the folders (the newest first) with their counts, then the snippets in none.
        let top = Snippet.rows("", in: nil, snippets: snippets, folders: folders)
        #expect(top.map(\.id) == [.folder(replies.id), .folder(work.id), .snippet(email.id)])
        if case .folder(let folder, let count) = top.first { #expect(folder.name == "Replies" && count == 1) }
        // In a folder, its snippets; typed at the top, every folder's, and the folders so named.
        #expect(Snippet.rows("", in: work.id, snippets: snippets, folders: folders).map(\.id) == [.snippet(standup.id)])
        #expect(Snippet.rows("standup", in: nil, snippets: snippets, folders: folders).map(\.id)
                == [.snippet(standup.id)])
        #expect(Snippet.rows("wor", in: nil, snippets: snippets, folders: folders).map(\.id) == [.folder(work.id)])
        #expect(Snippet.rows("email", in: work.id, snippets: snippets, folders: folders).isEmpty)
        // Deleting a folder leaves its snippets, at the top.
        try store.renameSnippetFolder(id: work.id, name: "Office")
        #expect(try store.snippetFolders().first { $0.id == work.id }?.name == "Office")
        try store.deleteSnippetFolder(id: work.id)
        snippets = try store.snippets()
        #expect(snippets.first { $0.id == standup.id }?.folder == nil)
        #expect(try store.snippetFolders().map(\.id) == [replies.id])
    }
}

extension SnippetTests {
    @Test func draggedIntoAnOrderThatStays() throws {
        let store = try store()
        let a = try store.addSnippet(title: "A", text: "a")
        let b = try store.addSnippet(title: "B", text: "b")
        let c = try store.addSnippet(title: "C", text: "c")
        let work = try store.addSnippetFolder(name: "Work")
        let home = try store.addSnippetFolder(name: "Home")
        #expect(Snippet.search("", in: try store.snippets()).map(\.id) == [c.id, b.id, a.id])   // new ones first
        try store.orderSnippets([b.id, c.id, a.id])
        try store.orderSnippetFolders([work.id, home.id])
        let snippets = try store.snippets(), folders = try store.snippetFolders()
        #expect(Snippet.rows("", in: nil, snippets: snippets, folders: folders).map(\.id)
                == [.folder(work.id), .folder(home.id), .snippet(b.id), .snippet(c.id), .snippet(a.id)])
        try store.useSnippet(id: a.id)   // pasting one doesn't move it
        #expect(Snippet.search("", in: try store.snippets()).map(\.id) == [b.id, c.id, a.id])
        let d = try store.addSnippet(title: "D", text: "d")   // and a new one comes first still
        #expect(Snippet.search("", in: try store.snippets()).map(\.id) == [d.id, b.id, c.id, a.id])
    }

    @Test func theOrderFromBeforeIsKept() throws {
        let url = TestDatabase.url()
        do {   // as stores were before snippets had an order: the one used last first, then the newest; folders by name
            let db = try Database(path: url.path)
            try db.execute("""
                CREATE TABLE snippets(id INTEGER PRIMARY KEY, title TEXT NOT NULL, text TEXT NOT NULL, created REAL NOT NULL,
                                      last_used REAL, uses INTEGER NOT NULL DEFAULT 0, folder INTEGER);
                CREATE TABLE snippet_folders(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created REAL NOT NULL);
                INSERT INTO snippets(id, title, text, created, last_used) VALUES (1, 'old', 'x', 100, NULL), (2, 'used', 'x', 50, 500),
                                                                             (3, 'new', 'x', 200, NULL);
                INSERT INTO snippet_folders(id, name, created) VALUES (1, 'Work', 100), (2, 'Home', 200);
                """)
        }
        let store = try ClipStore(path: url)
        #expect(Snippet.search("", in: try store.snippets()).map(\.id) == [2, 3, 1])
        #expect(Snippet.rows("", in: nil, snippets: [], folders: try store.snippetFolders()).map(\.id) == [.folder(2), .folder(1)])
    }
}

@Suite struct SyntaxTests {
    @Test func markupReadsBackIntoTheTextAndItsRuns() {
        let text = "func f() -> String { \"a<b\" } // done"
        let html = "<span class=\"hljs-keyword\">func</span> <span class=\"hljs-title function_\">f</span>() -&gt; "
            + "<span class=\"hljs-type\">String</span> { <span class=\"hljs-string\">&quot;a&lt;b&quot;</span> } "
            + "<span class=\"hljs-comment\">// done</span>"
        let spans = SyntaxMarkup.spans(fromHTML: html, text: text)
        #expect(spans?.map(\.scope) == ["keyword", "title.function_", "type", "string", "comment"])
        let string = spans?.first { $0.scope == "string" }
        #expect(string.map { (text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }
                == "\"a<b\"")
    }

    @Test func nestedRunsComeOuterFirst() {
        let text = "@State var x"
        let html = "<span class=\"hljs-meta\"><span class=\"hljs-keyword\">@State</span></span> var x"
        #expect(SyntaxMarkup.spans(fromHTML: html, text: text)?.map(\.scope) == ["meta", "keyword"])
        #expect(SyntaxMarkup.spans(fromHTML: "<span class=\"hljs-keyword\">var</span>", text: "let") == nil)
        #expect(SyntaxHighlight(language: "cpp", spans: []).languageName == "C++")
    }

    @Test func codeFilesTakeTheirLanguagesExtension() {
        #expect(SyntaxHighlight.fileExtension(for: "swift", text: "") == "swift")
        #expect(SyntaxHighlight.fileExtension(for: "bash", text: "") == "sh")
        #expect(SyntaxHighlight.fileExtension(for: "xml", text: "<div class=\"a\">x</div>") == "html")
        #expect(SyntaxHighlight.fileExtension(for: "xml", text: "<?xml version=\"1.0\"?><plist/>") == "xml")
        #expect(SyntaxHighlight.fileExtension(for: "plaintext", text: "") == nil)
        #expect(TextFileName.make("func embed(_ texts: [String]) throws -> [[Float]] {", extension: "swift", code: true)
                == "func embed texts String throws Float.swift")
        #expect(TextFileName.make("git rebase -i HEAD~3", extension: "sh", code: true) == "git rebase -i HEAD~3.sh")
        #expect(TextFileName.make("Notes: launch moved / Thursday") == "Notes- launch moved - Thursday.txt")
        #expect(TextFileName.make("{ }", extension: "json", code: true) == "Code.json")
    }
}


@Suite struct RecentFileTests {
    func vector(_ weights: [Int: Float]) -> [Float] {
        var vector = [Float](repeating: 0, count: ModelFiles.dimension)
        for (axis, weight) in weights { vector[axis] = weight }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / norm }
    }

    func file(_ id: Int64) -> IndexedFile {
        IndexedFile(id: id, path: "/tmp/file-\(id)", modified: Date(), lastUsed: nil)
    }

    @Test func filesCloseInMeaningComeBestFirst() {
        let index = FileIndex()
        index.load([(file(1), vector([0: 1, 1: 0.4])), (file(2), vector([0: 1, 1: 0.3])), (file(3), vector([2: 1]))])
        #expect(index.search(vector([0: 1]), limit: 5).map(\.file.id) == [2, 1])
        #expect(index.search(vector([0: 1]), limit: 1).map(\.file.id) == [2])
        index.remove([2])
        #expect(index.search(vector([0: 1]), limit: 5).map(\.file.id) == [1])
    }

    @Test func filesCloseToEveryQueryAnswerNone() {
        let index = FileIndex()
        let crowd = (30...40).map { (file(Int64($0)), vector([0: 0.55, $0: 0.84])) }   // unrelated: 0.55
        index.load(crowd + [(file(1), vector([0: 0.8, 20: 0.6])),     // the answer: 0.80, far from the typical query
                            (file(2), vector([0: 0.78, 1: 0.6]))])    // 0.79, and as close to any query
        #expect(Set(index.search(vector([0: 1]), limit: 5).map(\.file.id)) == [1, 2])
        index.setTypical(phrases: [vector([0: 1, 1: 1])], words: [vector([0: 1, 1: 1])])
        #expect(index.search(vector([0: 1]), limit: 5).map(\.file.id) == [1])
        #expect(index.search(vector([0: 1]), oneWord: true, limit: 5).map(\.file.id) == [1])
    }

    @Test func aLongDocumentIsFoundByItsClosestPiece() {
        let index = FileIndex()
        let crowd = (30...40).map { (file(Int64($0)), vector([$0: 1])) }
        // Its start says nothing of the query; its second piece does.
        index.load(crowd + [(file(1), vector([5: 1]))], pieces: [1: [vector([6: 1]), vector([0: 0.9, 7: 0.44])]])
        #expect(index.count == 12 && index.pieceCount(1) == 2)
        let found = index.search(vector([0: 1]), limit: 5)
        #expect(found.map(\.file.id) == [1] && found.first?.piece == 2)
        #expect(index.search(vector([5: 1]), limit: 5).first?.piece == 0)
        // Read again: its new pieces replace the old.
        index.set(file(1), vector: vector([5: 1]), pieces: [vector([8: 1])])
        #expect(index.pieceCount(1) == 1 && index.search(vector([0: 1]), limit: 5).isEmpty)
        index.remove([1])
        #expect(index.count == 11 && index.search(vector([8: 1]), limit: 5).isEmpty)
    }

    @Test func aLongDocumentsTextGoesInPieces() {
        #expect(CopiedFiles.pieces(of: String(repeating: "word ", count: 200)).isEmpty)   // 1,000 characters
        let words = (0..<6000).map { "w\($0)" }
        let text = words.joined(separator: "  \n")   // blank space closes up
        let pieces = CopiedFiles.pieces(of: text)
        let closed = words.joined(separator: " ")
        #expect(pieces.count > 20 && pieces.count <= CopiedFiles.maxPieces)
        #expect(pieces.allSatisfy { closed.contains($0) && !$0.hasPrefix(" ") })
        #expect(pieces.allSatisfy { $0.count <= CopiedFiles.pieceCharacters + CopiedFiles.minPieceCharacters })
        #expect(pieces.dropLast().allSatisfy { $0.count >= CopiedFiles.pieceCharacters * 4 / 5 - 10 })
        // They start inside what the document's own vector reads, follow on with an overlap, and end with it (the
        // short rest joins the last), whole words each.
        let starts = pieces.map { closed.range(of: $0)!.lowerBound.utf16Offset(in: closed) }
        #expect(starts[0] < CopiedFiles.textCharacters && starts == starts.sorted())
        for (piece, next) in zip(pieces, pieces.dropFirst()) {
            #expect(piece.split(separator: " ").suffix(5).contains { next.split(separator: " ").contains($0) })
        }
        #expect(pieces.last!.hasSuffix(words.last!))
        // Past the reach: the first 100 pieces only.
        let book = (0..<40_000).map { "w\($0)" }.joined(separator: " ")
        let capped = CopiedFiles.pieces(of: book)
        #expect(capped.count == CopiedFiles.maxPieces && capped.last!.count >= CopiedFiles.minPieceCharacters)
        #expect(CopiedFiles.hasPieces(URL(fileURLWithPath: "/a/b.PDF")) && !CopiedFiles.hasPieces(URL(fileURLWithPath: "/a/b.json")))
    }

    @Test func readFilesRoundTrip() throws {
        let url = TestDatabase.url()
        let store = try ClipStore(path: url)
        let changed = Date(timeIntervalSince1970: 1_000)
        let read = try store.saveFile(path: "/tmp/a.pdf", modified: changed, used: nil, vector: vector([0: 1]))
        try store.saveFile(path: "/tmp/b.zip", modified: changed, used: nil, vector: nil)   // nothing in it read
        let again = try store.saveFile(path: "/tmp/a.pdf", modified: changed.addingTimeInterval(60), used: changed,
                                       vector: vector([1: 1]))
        #expect(again.id == read.id)
        let rows = try store.indexedFiles().sorted { $0.file.path < $1.file.path }
        #expect(rows.map(\.file.path) == ["/tmp/a.pdf", "/tmp/b.zip"])
        #expect(rows[0].vector?[1] ?? 0 > 0.99 && rows[0].file.lastUsed == changed && rows[0].current)
        #expect(rows[1].vector == nil && rows[1].current)
        #expect(rows[0].piecesRead && rows[0].pieces.isEmpty)
        try store.deleteFiles(ids: [read.id])
        #expect(try store.indexedFiles().map(\.file.path) == ["/tmp/b.zip"])
        // A long document: its vector first, its pieces' still to come; then with them, shortened as the index keeps them.
        try store.saveFile(path: "/tmp/c.pdf", modified: changed, used: nil, vector: vector([0: 1]), pieces: nil)
        var c = try store.indexedFiles().first { $0.file.path == "/tmp/c.pdf" }!
        #expect(c.vector != nil && !c.piecesRead && c.pieces.isEmpty)
        try store.saveFile(path: "/tmp/c.pdf", modified: changed, used: nil, vector: vector([0: 1]),
                           pieces: [vector([1: 1]), vector([2: 0.6, 3: 0.8])])
        c = try store.indexedFiles().first { $0.file.path == "/tmp/c.pdf" }!
        #expect(c.piecesRead && c.pieces.count == 2 && c.pieces.allSatisfy { $0.count == FileIndex.dimension })
        #expect(abs(c.pieces[1][3] - 0.8) < 0.001)
        #expect(c.reader == CopiedFiles.readerVersion)
    }

    /// Scans were read by their first page's picture before OCR: a PDF without pieces read by the old reader is read
    /// again; nothing else is.
    @Test func scansReadAgain() throws {
        let pdf = URL(fileURLWithPath: "/a/scan.PDF"), text = URL(fileURLWithPath: "/a/notes.txt")
        #expect(CopiedFiles.readAgain(pdf, readBy: 1, pieces: 0))
        #expect(!CopiedFiles.readAgain(pdf, readBy: 1, pieces: 3))   // it had text: OCR changes nothing
        #expect(!CopiedFiles.readAgain(pdf, readBy: CopiedFiles.readerVersion, pieces: 0))
        #expect(!CopiedFiles.readAgain(text, readBy: 1, pieces: 0))
        // Rows from before the reader's version was kept: the first reader's.
        let url = TestDatabase.url()
        let store = try ClipStore(path: url)
        try store.saveFile(path: "/tmp/old.pdf", modified: Date(), used: nil, vector: vector([0: 1]))
        let database = try Database(path: url.path)
        try database.execute("UPDATE files SET reader = NULL")
        #expect(try store.indexedFiles().first?.reader == 1)
    }

    /// Where Spotlight has nothing (a temporary folder): the folder itself, without what's old, hidden, private or built.
    @Test func recentFilesWithoutSpotlight() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pastemind-recent-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for path in ["notes.md", "deep/a/b/report.pdf", "old.txt", ".hidden.txt", "server.pem", "node_modules/x.js"] {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)],
                             ofItemAtPath: root.appendingPathComponent("old.txt").path)
        let found = RecentFiles.find(in: [root], opened: false).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        #expect(Set(found) == ["notes.md", "report.pdf"])
    }

    /// The whole home folder, sifted: no datasets, code projects, packages or hidden folders, unless opened.
    @Test func theHomeFolderIsSifted() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pastemind-home-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        var paths = ["\(home)/Pictures/trip/beach.jpg", "\(home)/Documents/lease.pdf", "\(home)/app/src/logo.png",
                     "\(home)/app/Package.swift", "\(home)/Movies/Clip.fcpbundle/render.mov", "\(home)/.hidden/a.png",
                     "\(home)/app/notes-opened.md"]
        paths += (1...200).map { "\(home)/Downloads/dataset/img\($0).png" }
        for path in paths {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data("x".utf8))
        }
        let now = Date()
        let found = paths.filter { !$0.hasSuffix("Package.swift") }.map {
            RecentFiles.Candidate(path: $0, modified: now, lastUsed: $0.contains("opened") ? now : nil)
        }
        let kept = Set(RecentFiles.sift(found, home: home).map { URL(fileURLWithPath: $0.path).lastPathComponent })
        #expect(kept == ["beach.jpg", "lease.pdf", "notes-opened.md"])
    }

    /// Files that just appeared deep in the home folder: read as the whole-home look would take them, by their kind
    /// (no SVGs, code or data), and sifted.
    @Test func filesThatAppearAreTakenAsTheWholeHomeLookWould() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pastemind-appeared-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        let paths = ["\(home)/Work/clients/2026/contract.pdf", "\(home)/Work/notes/plan.docx", "\(home)/Work/a/b/c/d/e/scan.heic",
                     "\(home)/Work/icons/arrow.svg", "\(home)/Work/export/data.json", "\(home)/Work/run.py",
                     "\(home)/app/Package.swift", "\(home)/app/assets/logo.png", "\(home)/.cache/thumb.jpg",
                     "\(home)/Work/download.crdownload"]
        for path in paths {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data("x".utf8))
        }
        let now = Date()
        let found = paths.filter { !$0.hasSuffix("Package.swift") }.map {
            RecentFiles.Candidate(path: $0, modified: now, lastUsed: nil)
        }
        let kept = Set(RecentFiles.appeared(found, home: home).map { URL(fileURLWithPath: $0.path).lastPathComponent })
        #expect(kept == ["contract.pdf", "plan.docx", "scan.heic"])
    }

    @Test func filesByMeaningGoUnderGoodNameMatches() {
        let catalog = [LaunchItem(kind: .app, name: "Safari", path: "/Applications/Safari.app",
                                  url: URL(fileURLWithPath: "/Applications/Safari.app"))]
        let named = LaunchRanker.merge(LaunchQuery("safari"), catalog: catalog, files: [])
        #expect(LaunchRanker.hasStrongMatch(named))
        let lease = LaunchItem(kind: .file, name: "lease.docx", path: "/tmp/lease.docx",
                               url: URL(fileURLWithPath: "/tmp/lease.docx"))
        let merged = LaunchRanker.addMeaning(named, files: [lease, catalog[0]])
        #expect(merged.map(\.item.name) == ["Safari", "lease.docx"])   // Safari isn't added twice
        #expect(merged.map(\.byContent) == [false, true])
        #expect(!LaunchRanker.hasStrongMatch(LaunchRanker.merge(LaunchQuery("договор"), catalog: catalog, files: [])))
    }
}

@Suite struct KeptFilesTests {
    /// A copied file still there is itself; once moved or deleted, Pastemind's copy stands in for it.
    @Test func aGoneFileIsPastedFromItsCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pastemind-kept-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let kept = root.appendingPathComponent("Files")
        let files = ["photo.png": 10, "notes/a.txt": 20, "server.pem": 10, "big.bin": 2_000, "keys/id_ed25519": 10]
        for (path, size) in files {
            let url = root.appendingPathComponent("copied/\(path)")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: url)
        }
        let urls = ["photo.png", "notes", "server.pem", "big.bin", "keys"].map { root.appendingPathComponent("copied/\($0)") }
        // Not a key, nor what's over the limit, nor a folder with a key in it.
        #expect(KeptFiles.keep(urls, for: 7, in: kept, maxBytes: 1_000) == 2)
        let clip = Clip(id: 7, kind: .file, text: urls.map(\.path).joined(separator: "\n"))
        #expect(clip.fileURLs(keptIn: kept) == urls)

        try fm.removeItem(at: urls[0])
        try fm.moveItem(at: urls[1], to: root.appendingPathComponent("moved"))
        try fm.removeItem(at: urls[2])
        let resolved = clip.fileURLs(keptIn: kept)
        #expect(resolved[0] == KeptFiles.url(clip: 7, index: 0, name: "photo.png", in: kept))
        #expect(try Data(contentsOf: resolved[0]).count == 10)
        #expect(fm.fileExists(atPath: resolved[1].appendingPathComponent("a.txt").path))
        #expect(resolved[2] == urls[2])   // never kept: still where it was, gone
        #expect(clip.copiedURLs.map(\.path) == urls.map(\.path) && clip.title == "photo.png + 4 more")

        // Settings removes the copies of what's gone (the photo, the moved folder), not those of files still there.
        let clips = [(id: Int64(7), urls: urls)]
        #expect(KeptFiles.standIns(for: clips, in: kept).count == 2)
        #expect(KeptFiles.diskSize(of: KeptFiles.standIns(for: clips, in: kept)) > 0)
        #expect(KeptFiles.removeStandIns(for: clips, in: kept) > 0)
        #expect(KeptFiles.standIns(for: clips, in: kept).isEmpty)
        #expect(clip.fileURLs(keptIn: kept)[0] == urls[0])
        KeptFiles.keep([root.appendingPathComponent("moved/a.txt")], for: 7, in: kept)

        // Gone with their clips, and the half-made ones; the marker stays.
        try fm.createDirectory(at: kept.appendingPathComponent("9"), withIntermediateDirectories: true)
        try fm.createDirectory(at: kept.appendingPathComponent(".incoming-x"), withIntermediateDirectories: true)
        KeptFiles.keepEarlier([], in: kept)
        KeptFiles.removeAll(except: [7], in: kept)
        #expect(Set(try fm.contentsOfDirectory(atPath: kept.path)) == ["7", ".earlier"])
        KeptFiles.remove([7], in: kept)
        #expect(clip.fileURLs(keptIn: kept)[0] == urls[0])
    }

    /// A link (Telegram copies a picture as one) is kept as the file it links to, so the copy outlives that file.
    @Test func aLinkIsKeptAsItsFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pastemind-kept-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("cache/photo-y")
        let link = root.appendingPathComponent("photo-y.jpg")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 10).write(to: file)
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        let kept = root.appendingPathComponent("Files")
        #expect(KeptFiles.keep([link], for: 3, in: kept) == 1)
        try fm.removeItem(at: file)
        #expect(try Data(contentsOf: KeptFiles.url(clip: 3, index: 0, name: "photo-y.jpg", in: kept)).count == 10)
    }
}
