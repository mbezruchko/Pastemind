import Foundation
import LlamaRuntime
import PastemindKit

// pastemind-cli files <mmproj> <file>…   copied files by what's in them (CopiedFileReader), against their names alone:
//                                       what each reads as, timings, and queries (in several languages) naming one file each

/// Queries and the files that answer them (file names).
let fileQueries: [(String, Set<String>)] = [
    ("lease that allows a cat", ["lease-agreement.docx", "scan-lease-text.pdf"]),
    ("договор аренды, можно ли с котом", ["lease-agreement.docx", "scan-lease-text.pdf"]),
    ("borscht recipe", ["борщ.rtf"]), ("рецепт борща", ["борщ.rtf"]),
    ("when is the launch", ["meeting-notes.md"]), ("когда запуск", ["meeting-notes.md"]),
    ("retry with exponential backoff", ["RetryPolicy.swift"]), ("повтор запроса с задержкой", ["RetryPolicy.swift"]),
    ("hotel booking in Innsbruck", ["trip.html"]), ("бронь отеля", ["trip.html"]),
    ("grocery receipt", ["receipt-scan.pdf"]), ("чек из магазина", ["receipt-scan.pdf"]),
    ("zebra photo", ["IMG_4021.heic"]), ("фото зебры", ["IMG_4021.heic"]),
    ("red flower", ["IMG_4022.heic"]), ("красный цветок", ["IMG_4022.heic"]),
    ("revenue chart", ["Screenshot 2026-10-14 at 10.12.png"]), ("график выручки", ["Screenshot 2026-10-14 at 10.12.png"]),
    ("video of a penguin", ["clip-001.mp4"]), ("видео с пингвином", ["clip-001.mp4"]),
    ("guitar video", ["MOV_0007.mov"]), ("видео с гитарой", ["MOV_0007.mov"]),
    ("clipboard app demo video", ["promo-final.mp4"]), ("ролик про приложение буфера обмена", ["promo-final.mp4"]),
    ("call the dentist", ["memo-1.m4a"]), ("позвонить стоматологу", ["memo-1.m4a"]),
    ("buy milk and bread", ["запись-2.m4a"]), ("купить молоко", ["запись-2.m4a"]),
    ("podcast about sleep", ["podcast-clip.aiff"]), ("разговор про сон", ["podcast-clip.aiff"]),
    ("vacation in Crete", ["Отпуск Крит 2026"]), ("фотки с отпуска на море", ["Отпуск Крит 2026"]),
]

func files(_ arguments: [String]) async throws {
    guard arguments.count >= 2 else {
        print("usage: pastemind-cli files <mmproj> <file>…")
        exit(2)
    }
    let embedder = try loadEmbedder()
    let projector = URL(fileURLWithPath: arguments[0])
    let urls = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    var names: [String] = [], byName: [[Float]] = [], byContent: [[Float]] = []
    for url in urls {
        let title = Prompts.document(CopiedFiles.title(of: [url]))
        let plain = try embedder.embed([title])[0]
        let (contents, readTime) = await timed { await CopiedFileReader.read([url], pictures: true, sound: true, budget: 140) }
        var vector = plain
        var note = "names only"
        if let contents {
            let sound = contents.media.contains { if case .sound = $0 { return true } else { return false } }
            if sound { try embedder.openSound(projector: projector) } else if !contents.media.isEmpty {
                try embedder.openImages(projector: projector)
            }
            let (made, embedTime) = try time {
                contents.media.isEmpty ? try embedder.embed([contents.prompt])[0] : try embedder.embed(contents.media, prompt: contents.prompt)
            }
            vector = made
            note = "\(contents.summary); read \(ms(readTime)), embed \(ms(embedTime))"
        }
        names.append(url.lastPathComponent)
        byName.append(plain)
        byContent.append(vector)
        print(String(format: "  %-36@ %@", url.lastPathComponent as NSString, note))
    }
    print(String(format: "encoders loaded in: images %@, sound %@", ms(embedder.imageLoadSeconds), ms(embedder.soundLoadSeconds)))
    let textVectors = try embedder.embed(corpus.map { Prompts.document($0) })

    for (label, vectors) in [("names only", byName), ("contents", byContent)] {
        print("\n== \(label)")
        var top1 = 0, aheadOfText = 0
        for (query, expected) in fileQueries {
            let q = try embedder.embed([Prompts.query(query)])[0]
            let cosines = vectors.map { dot($0, q) }
            let order = cosines.indices.sorted { cosines[$0] > cosines[$1] }
            guard let rank = order.firstIndex(where: { expected.contains(names[$0]) }) else { continue }
            if rank == 0 { top1 += 1 }
            let bestText = corpus.indices.map { dot(textVectors[$0], q) }.max()!
            if cosines[order[rank]] > bestText { aheadOfText += 1 }
            let top = order.prefix(2).map { String(format: "%.3f %@", cosines[$0], String(names[$0].prefix(22))) }
                .joined(separator: " | ")
            print(String(format: "%@ %-36@ rank %2d  best text %.3f   %@", rank == 0 ? "✓" : "✗", query as NSString,
                         rank + 1, bestText, top))
        }
        print("top-1 \(top1)/\(fileQueries.count), ahead of every text clip \(aheadOfText)/\(fileQueries.count)")
    }
    embedder.closeImages()
    embedder.closeSound()
}

private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 } }

private func timed<T>(_ body: () async -> T) async -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = await body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
}

// pastemind-cli groups <vision mmproj> <audio mmproj> <folder>   the test files copied a few at a time, as one clip
//                                                               each: found by the one vector of them all, or also by
//                                                               a vector of each file (the best of them counts)
let fileGroups: [[String]] = [
    ["IMG_4021.heic", "IMG_4022.heic", "Screenshot 2026-10-14 at 10.12.png", "receipt-scan.pdf", "clip-001.mp4"],
    ["lease-agreement.docx", "борщ.rtf", "meeting-notes.md", "RetryPolicy.swift", "trip.html", "scan-lease-text.pdf"],
    ["memo-1.m4a", "запись-2.m4a", "podcast-clip.aiff", "MOV_0007.mov", "promo-final.mp4", "Отпуск Крит 2026"],
]

func groups(_ arguments: [String]) async throws {
    guard arguments.count == 3 else {
        print("usage: pastemind-cli groups <vision mmproj> <audio mmproj> <folder>")
        exit(2)
    }
    let embedder = try loadEmbedder()
    try embedder.openImages(projector: URL(fileURLWithPath: arguments[0]))
    try embedder.openSound(projector: URL(fileURLWithPath: arguments[1]))
    let folder = URL(fileURLWithPath: arguments[2])
    func vector(_ urls: [URL]) async throws -> [Float] {
        guard let contents = await CopiedFileReader.read(urls, pictures: true, sound: true, budget: 140) else {
            return try embedder.embed([Prompts.document(CopiedFiles.title(of: urls))])[0]
        }
        return contents.media.isEmpty ? try embedder.embed([contents.prompt])[0]
            : try embedder.embed(contents.media, prompt: contents.prompt)
    }
    var whole: [[Float]] = [], parts: [[[Float]]] = []
    for group in fileGroups {
        let urls = group.map { folder.appendingPathComponent($0) }
        whole.append(try await vector(urls))
        var each: [[Float]] = []
        for url in urls { each.append(try await vector([url])) }
        parts.append(each)
    }
    let typical = try typicalQuery(embedder)
    let others = try embedder.embed((corpus + crowdClips).map { Prompts.document($0) })
    func lift(_ v: [Float], _ q: [Float], oneWord: Bool) -> Float { dot(v, q) - dot(v, oneWord ? typical.word : typical.phrase) }
    for (label, useParts) in [("one vector per copy", false), ("plus one per file", true)] {
        var top1 = 0, passing = 0
        var lines: [String] = []
        for (query, expected) in fileQueries {
            let q = try embedder.embed([Prompts.query(query)])[0]
            let oneWord = !query.contains(" ")
            // A clip's score: the best of its vectors by lift (what the gate reads), and its cosine.
            func best(_ g: Int) -> (lift: Float, cos: Float) {
                let vectors = [whole[g]] + (useParts ? parts[g] : [])
                return vectors.map { (lift($0, q, oneWord: oneWord), dot($0, q)) }.max { $0.0 < $1.0 }!
            }
            let target = fileGroups.firstIndex { !$0.filter(expected.contains).isEmpty }!
            let mine = best(target)
            let rivals = fileGroups.indices.filter { $0 != target }.map { best($0).lift }
                + others.map { lift($0, q, oneWord: oneWord) }
            let first = mine.lift > rivals.max()!
            if first { top1 += 1 }
            if mine.lift >= (oneWord ? 0.06 : 0.05) { passing += 1 }
            lines.append(String(format: "%@ %-36@ lift %.3f (cos %.3f), best other %.3f", first ? "✓" : "✗",
                                query as NSString, mine.lift, mine.cos, rivals.max()!))
        }
        var leaks = 0
        for query in crowdUnanswered {
            let q = try embedder.embed([Prompts.query(query)])[0]
            let oneWord = !query.contains(" ")
            let bestGroup = fileGroups.indices.map { g in
                ([whole[g]] + (useParts ? parts[g] : [])).map { lift($0, q, oneWord: oneWord) }.max()!
            }.max()!
            if bestGroup >= (oneWord ? 0.06 : 0.05) {
                leaks += 1
                if useParts {
                    let (g, i) = fileGroups.indices.flatMap { g in parts[g].indices.map { (g, $0) } }
                        .max { lift(parts[$0.0][$0.1], q, oneWord: oneWord) < lift(parts[$1.0][$1.1], q, oneWord: oneWord) }!
                    print(String(format: "  shown for %@: %@ (lift %.3f)", query, fileGroups[g][i],
                                 lift(parts[g][i], q, oneWord: oneWord)))
                }
            }
        }
        // As the app searches: the copies among the corpus and the short clips.
        let now = Date()
        let texts = corpus + crowdClips
        var clips = fileGroups.indices.map { g in
            Clip(id: Int64(g + 1), kind: .file, text: fileGroups[g].map { folder.appendingPathComponent($0).path }
                .joined(separator: "\n"), lastCopied: now)
        }
        clips += texts.indices.map { Clip(id: Int64(100 + $0), kind: ClipClassifier.kind(of: texts[$0]), text: texts[$0],
                                          lastCopied: now.addingTimeInterval(-Double($0) * 3600)) }
        let index = ClipIndex()
        index.load(clips, vectors: fileGroups.indices.map { (Int64($0 + 1), whole[$0]) }
                   + others.indices.map { (Int64(100 + $0), others[$0]) },
                   parts: useParts ? fileGroups.indices.map { (Int64($0 + 1), parts[$0]) } : [])
        index.setTypical(typical)
        var appFirst = 0, appShown = 0, appLeaks = 0
        var named: [String] = []
        for (query, expected) in fileQueries {
            let results = index.search(query, vector: try embedder.embed([Prompts.query(query)])[0], now: now)
            let target = Int64(fileGroups.firstIndex { !$0.filter(expected.contains).isEmpty }! + 1)
            if results.first?.id == target { appFirst += 1 }
            if let hit = results.first(where: { $0.id == target }) {
                appShown += 1
                if let file = hit.file, !expected.contains(fileGroups[Int(target) - 1][file]) {
                    named.append("\(query) → \(fileGroups[Int(target) - 1][file])")
                }
            }
        }
        for query in crowdUnanswered {
            let results = index.search(query, vector: try embedder.embed([Prompts.query(query)])[0], now: now)
            if results.contains(where: { $0.id <= Int64(fileGroups.count) }) { appLeaks += 1 }
        }
        print("   app: the right copy first \(appFirst)/\(fileQueries.count), shown \(appShown)/\(fileQueries.count); "
              + "a copy shown for \(appLeaks)/\(crowdUnanswered.count) with no answer"
              + (named.isEmpty ? "" : "; named another file: " + named.joined(separator: ", ")))
        print("== \(label): the right copy first \(top1)/\(fileQueries.count), over the bar \(passing)/\(fileQueries.count); "
              + "queries with no answer where a copy is over the bar: \(leaks)/\(crowdUnanswered.count)")
        for line in lines { print("  " + line) }
    }
    embedder.closeImages()
    embedder.closeSound()
}

// pastemind-cli filecrowd <vision mmproj> <audio mmproj> <folder> [real]   search by contents (FileIndex) on the test
//                                   files among short text files, or with "real" among the files your search reads
//                                   (numbers only, never their names): the typical-query correction's settings
let fileOneWord: [(String, String)] = [
    ("зебра", "IMG_4021.heic"), ("zebra", "IMG_4021.heic"), ("пингвин", "clip-001.mp4"), ("penguin", "clip-001.mp4"),
    ("чек", "receipt-scan.pdf"), ("receipt", "receipt-scan.pdf"), ("подкаст", "podcast-clip.aiff"),
    ("стоматолог", "memo-1.m4a"), ("отель", "trip.html"), ("гитара", "MOV_0007.mov"), ("аренда", "lease-agreement.docx"),
    ("выручка", "Screenshot 2026-10-14 at 10.12.png"),
]

func typicalVectors(_ embedder: LlamaEmbedder) throws -> (phrases: [[Float]], words: [[Float]]) {
    (try embedder.embed(Prompts.typicalQueries.map(Prompts.query)), try embedder.embed(Prompts.typicalWords.map(Prompts.query)))
}

func fileCrowd(_ arguments: [String]) async throws {
    guard arguments.count >= 3 else {
        print("usage: pastemind-cli filecrowd <vision mmproj> <audio mmproj> <folder> [real]")
        exit(2)
    }
    let embedder = try loadEmbedder()
    try embedder.openImages(projector: URL(fileURLWithPath: arguments[0]))
    try embedder.openSound(projector: URL(fileURLWithPath: arguments[1]))
    let folder = URL(fileURLWithPath: arguments[2])
    let names = (try FileManager.default.contentsOfDirectory(atPath: folder.path)).filter { !$0.hasPrefix(".") }.sorted()
    var rows: [(file: IndexedFile, vector: [Float])] = []
    for (offset, name) in names.enumerated() {
        let url = folder.appendingPathComponent(name)
        guard let contents = await CopiedFileReader.read([url], pictures: true, sound: true, budget: 140) else { continue }
        let vector = contents.media.isEmpty ? try embedder.embed([contents.prompt])[0]
            : try embedder.embed(contents.media, prompt: contents.prompt)
        rows.append((IndexedFile(id: Int64(offset + 1), path: url.path, modified: Date(), lastUsed: nil), vector))
    }
    let tests = Set(rows.map(\.file.id))
    let real = arguments.count > 3 && arguments[3] == "real"
    if real {
        let stored = try ClipStore().indexedFiles().compactMap { row in row.vector.map { (row.file, $0) } }
        rows += stored.map { (IndexedFile(id: 1_000_000 + $0.0.id, path: "", modified: $0.0.modified, lastUsed: nil), $0.1) }
        print("\(stored.count) of your files' vectors as the crowd (no names)")
    } else {
        let texts = corpus + crowdClips
        let vectors = try embedder.embed(texts.indices.map { Prompts.files(title: "note-\($0).txt", markers: [], text: texts[$0]) })
        rows += vectors.indices.map { (IndexedFile(id: Int64(1000 + $0), path: "", modified: Date(), lastUsed: nil), vectors[$0]) }
    }
    embedder.closeImages()
    embedder.closeSound()
    let index = FileIndex()
    index.load(rows)
    let typical = try typicalVectors(embedder)
    index.setTypical(phrases: typical.phrases, words: typical.words)
    let pathOf = Dictionary(rows.map { ($0.file.id, $0.file.path) }, uniquingKeysWith: { a, _ in a })
    let answered = fileQueries.map { ($0.0, $0.1) } + fileOneWord.map { ($0.0, Set([$0.1])) }
    let unanswered = crowdUnanswered + oneWordUnanswered
    var vectors: [String: [Float]] = [:]
    for query in answered.map(\.0) + unanswered { vectors[query] = try embedder.embed([Prompts.query(query)])[0] }
    let settings: [(String, Float, Float, Float)] = [
        ("old (median)", 0, 0, 0), ("lift .03/.04 w.5", 0.5, 0.03, 0.04), ("lift .04/.05 w.5", 0.5, 0.04, 0.05),
        ("lift .05/.06 w.5", 0.5, 0.05, 0.06), ("lift .05/.06 w0", 0, 0.05, 0.06), ("lift .05/.06 w1", 1, 0.05, 0.06),
        ("lift .06/.07 w.5", 0.5, 0.06, 0.07),
    ]
    for (label, weight, minLift, oneWordLift) in settings {
        index.tuning.typicalQueryWeight = weight
        index.tuning.minLift = minLift
        index.tuning.minLiftOneWord = oneWordLift
        var first = 0, shown = 0, oneFirst = 0, oneShown = 0, crowdShown = 0
        for (query, expected) in answered {
            let oneWord = !query.contains(" ")
            let results = index.search(vectors[query]!, oneWord: oneWord, limit: 20)
            let hit = results.firstIndex { expected.contains(URL(fileURLWithPath: pathOf[$0.file.id] ?? "").lastPathComponent) }
            if oneWord {
                if hit == 0 { oneFirst += 1 }
                if hit != nil { oneShown += 1 }
            } else {
                if hit == 0 { first += 1 }
                if hit != nil { shown += 1 }
            }
            crowdShown += results.filter { !tests.contains($0.file.id) }.count
        }
        var leaks = 0, leakRows = 0
        for query in unanswered {
            let results = index.search(vectors[query]!, oneWord: !query.contains(" "), limit: 20)
            if !results.isEmpty { leaks += 1 }
            leakRows += results.count
        }
        if label == "lift .05/.06 w.5", !real {
            for query in unanswered {
                let results = index.search(vectors[query]!, oneWord: !query.contains(" "), limit: 20)
                guard !results.isEmpty else { continue }
                let what = results.prefix(3).map { r -> String in
                    tests.contains(r.file.id) ? URL(fileURLWithPath: pathOf[r.file.id]!).lastPathComponent
                        : "note: " + String((corpus + crowdClips)[Int(r.file.id) - 1000].prefix(24))
                }
                print("    \(query) → \(what.joined(separator: " | "))")
            }
        }
        print(String(format: "%-18@ phrases first %2d shown %2d /%d · one word first %2d shown %2d /%d · crowd rows beside "
                     + "answers %3d · no-answer queries showing something %2d/%d (%d rows)",
                     label as NSString, first, shown, fileQueries.count, oneFirst, oneShown, fileOneWord.count,
                     crowdShown, leaks, unanswered.count, leakRows))
    }
}

// pastemind-cli filedropped <query> <keyword,…>   your files search reads, the old way and with the typical query: what
//                                                stays and what goes, by cosine, lift, extension and whether the path has
//                                                a keyword (never a name)
func fileDropped(_ query: String, keywords: [String]) throws {
    let stored = try ClipStore().indexedFiles().compactMap { row in row.vector.map { (file: row.file, vector: $0) } }
    let embedder = try loadEmbedder()
    let typical = try typicalVectors(embedder)
    let q = try embedder.embed([Prompts.query(query)])[0]
    let oneWord = !query.contains(" ")
    let index = FileIndex()
    index.load(stored)
    let old = index.search(q, oneWord: oneWord, limit: 20)
    index.setTypical(phrases: typical.phrases, words: typical.words)
    index.tuning.typicalQueryWeight = 0.5
    index.tuning.minLift = 0.05
    index.tuning.minLiftOneWord = 0.06
    let new = index.search(q, oneWord: oneWord, limit: 20)
    func short(_ v: [Float]) -> [Float] {
        let head = Array(v.prefix(FileIndex.dimension)); let n = head.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return head.map { $0 / n }
    }
    var center = [Float](repeating: 0, count: FileIndex.dimension)
    let refs = (oneWord ? typical.words : typical.phrases).map(short)
    for r in refs { for i in center.indices { center[i] += r[i] / Float(refs.count) } }
    let qs = short(q)
    let byID = Dictionary(stored.map { ($0.file.id, short($0.vector)) }, uniquingKeysWith: { a, _ in a })
    func line(_ match: (file: IndexedFile, cosine: Float, piece: Int)) -> String {
        let v = byID[match.file.id]!
        let cos = zip(v, qs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let lift = cos - zip(v, center).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let has = keywords.contains { match.file.path.localizedCaseInsensitiveContains($0) }
        return String(format: "cos %.3f lift %.3f .%@%@", cos, lift, (match.file.path as NSString).pathExtension.lowercased(),
                      has ? "  KEYWORD" : "")
    }
    print("\(stored.count) files; \(query): old \(old.count), new \(new.count)")
    print("kept:"); for m in new { print("  " + line(m)) }
    print("dropped:"); for m in old where !new.contains(where: { $0.file.id == m.file.id }) { print("  " + line(m)) }
}
