import Foundation
import LlamaRuntime
import PastemindKit

// pastemind-cli bench             model load, query and clip embedding times, search over 10k clips
// pastemind-cli eval              a small clipboard corpus (several languages) with queries: ranks and cosines
// pastemind-cli images <mmproj> <budget> <picture>…   pictures through the image encoder: timings, ranks (Images.swift)
// pastemind-cli files <mmproj> <file>…                copied files by what's in them, against their names (Files.swift)
// pastemind-cli groups <vision> <audio> <folder>     the test files copied a few at a time: one vector, or each file's
// pastemind-cli recent                               how many recent files search would read, by kind (no names)
// pastemind-cli launch <query>    the launcher: apps, System Settings panes and files, ranked, with timings
// pastemind-cli search <query>    the real history (~/Library/Application Support/Pastemind, or $PASTEMIND_HOME)
// pastemind-cli crowd | lift | words   the corpus among short clips, phrases and one-word queries: the typical
//                                       query's settings (Probe.swift)
// pastemind-cli probe | compare | dropped …   the real history, as numbers only (Probe.swift)

func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }

func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
}

/// `$PASTEMIND_TEXT_MODEL`: another text model file to try (a lighter quantization, say).
func loadEmbedder() throws -> LlamaEmbedder {
    if let chosen = ProcessInfo.processInfo.environment["PASTEMIND_TEXT_MODEL"], !chosen.isEmpty {
        return try loadEmbedder(URL(fileURLWithPath: chosen))
    }
    guard let path = ModelFiles.text.located else {
        throw EmbedderError("no \(ModelFiles.text.name) in \(AppPaths.models.path): open Pastemind once, or download "
                            + ModelFiles.text.url.absoluteString)
    }
    return try loadEmbedder(path)
}

/// The means of `Prompts.typicalQueries`' and `typicalWords`' vectors, as the app makes them.
func typicalQuery(_ embedder: LlamaEmbedder) throws -> (phrase: [Float], word: [Float]) {
    func mean(_ texts: [String]) throws -> [Float] {
        let vectors = try embedder.embed(texts.map(Prompts.query))
        var mean = [Float](repeating: 0, count: ModelFiles.dimension)
        for vector in vectors { for i in mean.indices { mean[i] += vector[i] / Float(vectors.count) } }
        return mean
    }
    return (try mean(Prompts.typicalQueries), try mean(Prompts.typicalWords))
}

extension ClipIndex {
    func setTypical(_ typical: (phrase: [Float], word: [Float])?) {
        typicalQuery = typical?.phrase
        typicalWord = typical?.word
    }
}

func loadEmbedder(_ path: URL) throws -> LlamaEmbedder {
    let (embedder, seconds) = try time { try LlamaEmbedder.best(model: path) }
    print("model loaded on the \(embedder.device.rawValue) in \(ms(seconds)) (\(path.lastPathComponent))")
    return embedder
}

let corpus: [String] = [
    "https://github.com/ggml-org/llama.cpp/pull/1234",
    "https://www.figma.com/design/abc123/Onboarding-flow?node-id=12-345",
    "ssh deploy@10.0.4.17 -p 2222",
    "192.168.1.254",
    "anna.weber@example.com",
    "+44 20 7946 0958",
    "#F2A22A",
    "Hi Tom, thanks for the quick review. I pushed the fix for the timezone bug, could you take another look?",
    "Привет! Скинь, пожалуйста, адрес офиса, завтра заеду за документами.",
    "Счёт № 4417 на оплату хостинга за октябрь, сумма 12 400 ₽",
    "func retry<T>(times: Int, _ body: () async throws -> T) async rethrows -> T {\n    for _ in 1..<times { if let v = try? await body() { return v } }\n    return try await body()\n}",
    "SELECT user_id, count(*) FROM orders WHERE created_at > now() - interval '7 days' GROUP BY 1 ORDER BY 2 DESC;",
    "docker compose -f docker-compose.prod.yml up -d --build",
    "API_KEY_PLACEHOLDER: sk-test-not-a-real-key",
    "Meeting notes: launch moved to Thursday, marketing needs final screenshots by Tuesday.",
    "Рецепт: 200 г муки, 2 яйца, 300 мл молока, щепотка соли. Жарить на сухой сковороде.",
    "TypeError: Cannot read properties of undefined (reading 'map') at ProductList.render (ProductList.tsx:42)",
    "Track number: 1Z999AA10123456784 (UPS, expected Friday)",
    "The quick brown fox jumps over the lazy dog",
    "Берлин, Фридрихштрассе 43, 3 этаж, офис 12",
    "git rebase -i HEAD~5",
    "Your verification code is 482913",
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
    "https://maps.app.goo.gl/Q7vKbQ2zYx",
    "Flight LH 2051 Munich → Lisbon, departs 07:45, gate G28",
]

let queries: [(String, Int)] = [
    ("pull request on github", 0), ("design mockup link", 1), ("server login command", 2), ("router ip", 3),
    ("my email", 4), ("phone number", 5), ("orange color", 6), ("message to Tom about the bug", 7),
    ("попросил адрес офиса", 8), ("invoice for hosting", 9), ("retry function swift", 10),
    ("sql query orders last week", 11), ("start containers in production", 12),
    ("when is the launch", 14), ("блины рецепт", 15), ("javascript error undefined map", 16),
    ("package tracking", 17), ("адрес в Берлине", 19), ("squash commits", 20), ("2fa code", 21),
    ("map location link", 23), ("рейс в Лиссабон", 24), ("plane ticket", 24), ("сумма счёта", 9),
]

/// Queries the corpus has no answer to: search should come back empty for them, not with the least unrelated clips.
let unanswered: [String] = [
    "car insurance", "guitar chords", "birthday gift ideas", "weather tomorrow", "pizza delivery", "football score",
    "cat photo", "vacation photos", "doctor appointment", "медицинская справка", "налоговая декларация", "plane",
]

/// How the best cosine stands out from the rest: the best, 2nd and 5th, the median, and the best's distance from the
/// mean in standard deviations.
func spread(_ cosines: [Float]) -> (best: Float, z: Float, text: String) {
    let sorted = cosines.sorted(by: >)
    let mean = cosines.reduce(0, +) / Float(cosines.count)
    let sd = sqrt(cosines.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(cosines.count))
    let z = (sorted[0] - mean) / max(sd, 1e-6)
    let fifth = sorted[min(4, sorted.count - 1)]
    let median = sorted[sorted.count / 2]
    let mad = cosines.map { abs($0 - median) }.sorted()[cosines.count / 2]
    let q75 = sorted[sorted.count / 4]
    let q90 = sorted[sorted.count / 10]
    let text = String(format: "best %.3f med %.3f  b-med %.3f  robz %.2f  b-q75 %.3f  b-q90 %.3f  (q90-med)/(b-med) %.2f",
                      sorted[0], median, sorted[0] - median, (sorted[0] - median) / max(mad, 1e-6),
                      sorted[0] - q75, sorted[0] - q90, (q90 - median) / max(sorted[0] - median, 1e-6))
    _ = fifth
    return (sorted[0], z, text)
}

func eval() throws {
    let embedder = try loadEmbedder()
    let index = ClipIndex()
    let now = Date()
    let clips = corpus.enumerated().map { offset, text in
        Clip(id: Int64(offset), kind: ClipClassifier.kind(of: text), text: text,
             lastCopied: now.addingTimeInterval(-Double(offset) * 3600))
    }
    let (vectors, seconds) = try time { try embedder.embed(clips.map { Prompts.document($0.embeddingText!) }) }
    print("embedded \(clips.count) clips in \(ms(seconds)) (\(ms(seconds / Double(clips.count))) each)")
    index.load(clips, vectors: zip(clips, vectors).map { ($0.id, $1) })
    index.setTypical(try typicalQuery(embedder))
    var top1 = 0, top3 = 0
    var queryTimes: [Double] = []
    var margins: [String] = []
    for (query, expected) in queries {
        let (vector, embedTime) = try time { try embedder.embed([Prompts.query(query)])[0] }
        queryTimes.append(embedTime)
        let cosines = vectors.map { zip($0, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        let others = cosines.enumerated().filter { $0.offset != expected }.map(\.element).sorted(by: >)
        margins.append(String(format: "%.2f vs %.2f/%.2f/%.2f", cosines[expected], others[0], others[1], others[4]))
        let results = index.search(query, vector: vector, now: now)
        let rank = results.firstIndex { $0.clip.id == Int64(expected) }
        if rank == 0 { top1 += 1 }
        if let rank, rank < 3 { top3 += 1 }
        let shown = results.prefix(3).map { r in
            String(format: "%.2f", r.meaning ?? 0) + (r.words ? "w" : "") + " " + String(r.clip.title.prefix(28))
        }.joined(separator: " | ")
        print(String(format: "%@ %-34@ rank %@  (%d results)  %@", rank == 0 ? "✓" : "✗", query as NSString,
                     rank.map { "\($0 + 1)" } ?? "-", results.count, shown))
    }
    print("expected cosine vs other clips' 1st/2nd/5th best:")
    for (margin, query) in zip(margins, queries) { print("  \(margin)  \(query.0)") }
    print("how the best stands out, answered:")
    for (query, _) in queries {
        let vector = try embedder.embed([Prompts.query(query)])[0]
        let cosines = vectors.map { zip($0, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        print("  \(spread(cosines).text)  \(query)")
    }
    print("unanswered:")
    for query in unanswered {
        let vector = try embedder.embed([Prompts.query(query)])[0]
        let cosines = vectors.map { zip($0, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        let results = index.search(query, vector: vector, now: now)
        print("  \(spread(cosines).text)  \(query)  (\(results.count) results)")
    }
    queryTimes.sort()
    print("top-1 \(top1)/\(queries.count), top-3 \(top3)/\(queries.count); query embed median "
          + ms(queryTimes[queryTimes.count / 2]))
}

func bench() throws {
    let embedder = try loadEmbedder()
    var times: [Double] = []
    for i in 0..<30 { times.append(try time { _ = try embedder.embed([Prompts.query("router ip \(i)")]) }.1) }
    times.sort()
    print("query embed: median \(ms(times[15])), p90 \(ms(times[27]))")
    let doc = Prompts.document(String(repeating: "A paragraph of copied text about something. ", count: 30))
    for round in 1...3 {
        let (_, one) = try time { _ = try embedder.embed([doc]) }
        let (_, batch) = try time { _ = try embedder.embed(Array(repeating: Prompts.document("a short copied line"), count: 32)) }
        print("round \(round): one 1.3k-char clip \(ms(one)), 32 short clips in one batch \(ms(batch))")
    }

    let index = ClipIndex()
    let now = Date()
    var clips: [Clip] = []
    var rows: [(id: Int64, vector: [Float])] = []
    for i in 0..<10_000 {
        let text = corpus[i % corpus.count] + " #\(i) " + String(repeating: "filler words here ", count: i % 20)
        clips.append(Clip(id: Int64(i), kind: .text, text: text, lastCopied: now.addingTimeInterval(-Double(i) * 60)))
        var v = (0..<ModelFiles.dimension).map { _ in Float.random(in: -1...1) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        v = v.map { $0 / norm }
        rows.append((Int64(i), v))
    }
    let (_, loadTime) = time { index.load(clips, vectors: rows) }
    index.setTypical(try typicalQuery(embedder))
    print("index of 10k clips loaded in \(ms(loadTime))")
    let q = try embedder.embed([Prompts.query("server login")])[0]
    var words: [Double] = [], hybrid: [Double] = []
    for _ in 0..<20 {
        words.append(time { _ = index.search("deploy", vector: nil) }.1)
        hybrid.append(time { _ = index.search("server login", vector: q) }.1)
    }
    words.sort(); hybrid.sort()
    print("search 10k: words \(ms(words[10])), words + meaning \(ms(hybrid[10]))")
    for (label, query, vector) in [("no match, words", "zzqqxx", nil), ("no match, +vector", "zzqqxx", q),
                                   ("2 words no match", "server login", nil), ("400 matches", "deploy", nil),
                                   ("short 'a'", "a", nil)] as [(String, String, [Float]?)] {
        var t: [Double] = []
        var n = 0
        for _ in 0..<20 { t.append(time { n = index.search(query, vector: vector).count }.1) }
        t.sort()
        print("  \(label): \(ms(t[10])) (\(n) results)")
    }
}

func search(_ query: String) throws {
    let store = try ClipStore()
    let index = ClipIndex()
    index.load(try store.all(), vectors: try store.vectors())
    print("\(index.count) clips, \(index.embeddedCount) with vectors")
    let embedder = try loadEmbedder()
    index.setTypical(try typicalQuery(embedder))
    let (vector, embedTime) = try time { try embedder.embed([Prompts.query(query)])[0] }
    let (results, searchTime) = time { index.search(query, vector: vector) }
    print("embed \(ms(embedTime)), search \(ms(searchTime))")
    let cosines = try store.vectors().map { row in zip(row.vector, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
    if !cosines.isEmpty { print(spread(cosines).text) }
    for r in results.prefix(15) {
        print(String(format: "%.3f  cos %.2f %@  %@", r.score, r.meaning ?? 0, r.words ? "w" : " ",
                     String(r.clip.title.prefix(80)) as NSString))
    }
}

func launch(_ query: String) {
    let (catalog, catalogTime) = time { LaunchCatalog.load() }
    let apps = catalog.filter { $0.kind == .app }.count
    print("catalog: \(apps) apps, \(catalog.count - apps) settings panes in \(ms(catalogTime))")
    let (instant, rankTime) = time { LaunchRanker.rank(query, items: catalog) }
    print("apps + panes ranked in \(ms(rankTime))")
    let parsed = LaunchQuery(query)
    let (files, fileTime) = time { SpotlightFiles.search(parsed.text) }
    print("spotlight: \(files.count) files in \(ms(fileTime))\(parsed.filesOnly ? " (files only)" : "")")
    let ranked = LaunchRanker.merge(parsed, catalog: catalog, files: files)
    for result in ranked.prefix(15) {
        print(String(format: "%.3f  %-7@ %@  —  %@", result.score, result.item.kind.rawValue as NSString,
                     result.item.name as NSString, result.item.subtitle as NSString))
    }
    _ = instant
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "bench": try bench()
    case "eval": try eval()
    case "images": try images(Array(arguments.dropFirst()))
    case "files": try await files(Array(arguments.dropFirst()))
    case "groups": try await groups(Array(arguments.dropFirst()))
    case "filecrowd": try await fileCrowd(Array(arguments.dropFirst()))
    case "pieces": try await pieces(Array(arguments.dropFirst()))
    case "filedropped" where arguments.count == 3: try fileDropped(arguments[1], keywords: arguments[2].split(separator: ",").map(String.init))
    case "agree" where arguments.count >= 4: try agree(Array(arguments.dropFirst()))
    case "splitcheck" where arguments.count >= 5: try await splitCheck(Array(arguments.dropFirst()))
    case "recent":   // how many recent files search would read, by kind (no names)
        let (found, seconds) = time { RecentFiles.find() }
        let kinds = Dictionary(grouping: found) { URL(fileURLWithPath: $0.path).pathExtension.lowercased() }
            .mapValues(\.count).sorted { $0.value > $1.value }.prefix(15)
        print("\(found.count) recent files in \(ms(seconds)) under \(RecentFiles.scopes.count) folders; "
              + kinds.map { "\($0.key.isEmpty ? "-" : $0.key) \($0.value)" }.joined(separator: ", "))
        let (all, allSeconds) = time { RecentFiles.everything() }
        let allKinds = Dictionary(grouping: all) { URL(fileURLWithPath: $0.path).pathExtension.lowercased() }
            .mapValues(\.count).sorted { $0.value > $1.value }.prefix(15)
        print("\(all.count) files in the whole home folder in \(ms(allSeconds)); "
              + allKinds.map { "\($0.key.isEmpty ? "-" : $0.key) \($0.value)" }.joined(separator: ", "))
    case "launch" where arguments.count > 1: launch(arguments.dropFirst().joined(separator: " "))
    case "search" where arguments.count > 1: try search(arguments.dropFirst().joined(separator: " "))
    case "crowd": try crowd()
    case "lift": try lift()
    case "words": try words()
    case "dropped" where arguments.count == 3: try dropped(arguments[1], keywords: arguments[2].split(separator: ",").map(String.init))
    case "compare" where arguments.count > 1: try compare(Array(arguments.dropFirst()))
    case "probe" where arguments.count > 1: try probe(arguments.dropFirst().joined(separator: " "))
    default:
        print("usage: pastemind-cli bench | eval | images <mmproj> <budget> <picture>… | files <mmproj> <file>… | recent | launch <query> | search <query>")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
