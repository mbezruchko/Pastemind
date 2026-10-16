import Foundation
import LlamaRuntime
import PastemindKit

// pastemind-cli probe <query>   the real history's closest clips to a query, as numbers only (cosine, length, script):
//                               never their text

func probe(_ query: String) throws {
    let store = try ClipStore()
    let clips = Dictionary(try store.all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // $PROBE_BEFORE_MINUTES: the history as it was that many minutes ago (clips copied since left out).
    let before = Double(ProcessInfo.processInfo.environment["PROBE_BEFORE_MINUTES"] ?? "") ?? 0
    let cutoff = Date().addingTimeInterval(-before * 60)
    let rows = try store.vectors().filter { clips[$0.id].map { $0.firstCopied <= cutoff } ?? false }
    let embedder = try loadEmbedder()
    let q = try embedder.embed([Prompts.query(query)])[0]
    let reference = try embedder.embed(Prompts.typicalQueries.map { Prompts.query($0) })
    var mean = [Float](repeating: 0, count: q.count)
    for v in reference { for i in v.indices { mean[i] += v[i] / Float(reference.count) } }

    func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    func script(_ text: String) -> String {
        var cyr = 0, lat = 0
        for s in text.unicodeScalars {
            if (0x400...0x4FF).contains(s.value) { cyr += 1 } else if s.properties.isAlphabetic, s.isASCII { lat += 1 }
        }
        return cyr > lat * 3 ? "cyr" : lat > cyr * 3 ? "lat" : (cyr + lat == 0 ? "—" : "mix")
    }
    let hub = rows.map { dot($0.vector, mean) }
    let hubMedian = hub.sorted()[hub.count / 2]
    print("\(rows.count) clips with vectors; hub (cos to mean query) median \(String(format: "%.3f", hubMedian))")
    for alpha: Float in [0, 0.5, 1] {
        let scores = rows.indices.map { dot(rows[$0].vector, q) - alpha * (hub[$0] - hubMedian) }
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        let best = sorted.last!
        let gate = max(0.6, best - 0.1, median + 0.078)
        print(String(format: "α %.1f: best %.3f median %.3f gate %.3f  shown %d", alpha, best, median, gate,
                     scores.filter { $0 >= gate }.count))
        for i in rows.indices.sorted(by: { scores[$0] > scores[$1] }).prefix(8) {
            let clip = clips[rows[i].id]!
            print(String(format: "   %.3f (cos %.3f, hub %.3f) %5d chars %@ %@ %6.0f min ago%@", scores[i],
                         dot(rows[i].vector, q), hub[i], clip.text.count, script(clip.text), clip.kind.rawValue,
                         -clip.firstCopied.timeIntervalSinceNow / 60, scores[i] >= gate ? "  shown" : ""))
        }
    }
}

// pastemind-cli crowd   the evaluation's corpus among many short clips (a word, a short phrase, a chat line), as a real
//                       history has them: how each weight of the typical-query correction ranks and gates

/// Short clips that answer none of the queries: they come close to any short query, whatever it asks.
let crowdClips: [String] = [
    "историю", "Готово", "спасибо", "да, давай", "ок", "потом посмотрю", "Картинки", "настройки", "проверь ещё раз",
    "работает", "не работает", "вот так лучше", "сделай поменьше", "почему так медленно", "это баг или фича",
    "в целом норм", "переименуй", "черновик", "ссылка ниже", "Распознанные слова", "Файлы и папки", "Новая вкладка",
    "окно открывается слишком медленно", "давай оставим как есть до релиза", "можно сделать иконку чуть темнее",
    "пусть ищет и по названию файла", "проверь на маленьком экране тоже", "в прошлый раз это тоже ломалось",
    "модель грузится только когда нужна", "кнопка слева от поля", "тут слишком большой отступ", "по-моему лишнее",
    "ok", "done", "thanks!", "LGTM", "see above", "TODO", "fixed", "nil", "true", "README.md", "main", "v2",
    "Untitled", "final_final_v3", "hello world", "test", "asdf", "foo bar", "npm install", "Settings",
    "this looks off on dark mode", "can we make it smaller", "let's ship it tomorrow", "works for me",
    "not sure about the spacing here", "moved to the next sprint", "same as before", "see the comment above",
]

let crowdUnanswered: [String] = unanswered + [
    "лицензия фотошопа", "подписка спотифай", "страховка квартиры", "билеты в кино", "курс биткоина",
    "день рождения мамы", "отпуск в турции", "ремонт стиральной машины", "абонемент в спортзал", "netflix subscription",
    "gym membership", "dentist", "movie tickets", "photoshop license",
]

func crowd() throws {
    let embedder = try loadEmbedder()
    let now = Date()
    let typical = try embedder.embed(Prompts.typicalQueries.map { Prompts.query($0) })
    var center = [Float](repeating: 0, count: ModelFiles.dimension)
    for v in typical { for i in v.indices { center[i] += v[i] / Float(typical.count) } }
    let word = try typicalQuery(embedder).word
    let asked = try embedder.embed(queries.map { Prompts.query($0.0) })
    let unasked = try embedder.embed(crowdUnanswered.map { Prompts.query($0) })

    for (label, texts) in [("corpus", corpus), ("corpus + crowd", corpus + crowdClips)] {
        let clips = texts.enumerated().map { offset, text in
            Clip(id: Int64(offset), kind: ClipClassifier.kind(of: text), text: text,
                 lastCopied: now.addingTimeInterval(-Double(offset) * 3600))
        }
        let vectors = try embedder.embed(clips.map { Prompts.document($0.embeddingText!) })
        let index = ClipIndex()
        index.load(clips, vectors: zip(clips, vectors).map { ($0.id, $1) })
        index.typicalQuery = center
        print("\(label): \(clips.count) clips")
        index.typicalWord = try typicalQuery(embedder).word
        let settings: [(Float, Float, Float)] = [(0, 0, 0.078), (0.5, 0.05, 0), (0.5, 0.045, 0), (0.5, 0.055, 0),
            (0.25, 0.05, 0), (0.75, 0.05, 0), (1, 0.05, 0)]
        for (weight, minLift, aboveTypical) in settings {
            index.tuning.typicalQueryWeight = weight
            index.tuning.minLift = minLift
            index.tuning.aboveTypical = aboveTypical == 0 ? -1 : aboveTypical
            if minLift == 0 { index.setTypical(nil) } else { index.typicalQuery = center; index.typicalWord = word }
            func margin(_ q: [Float]) -> Float {
                let closeness = vectors.map { zip($0, center).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
                let usual = closeness.sorted()[closeness.count / 2]
                let s = vectors.indices.map { i in
                    zip(vectors[i], q).reduce(Float(0)) { $0 + $1.0 * $1.1 } - weight * (closeness[i] - usual)
                }.sorted()
                return s.last! - s[s.count / 2]
            }
            var top1 = 0, top3 = 0, misses: [String] = []
            var answeredMargins: [Float] = []
            for ((query, expected), vector) in zip(queries, asked) {
                let results = index.search(query, vector: vector, now: now)
                let rank = results.firstIndex { $0.clip.id == Int64(expected) }
                if rank == 0 { top1 += 1 } else { misses.append(query) }
                if let rank, rank < 3 { top3 += 1 }
                answeredMargins.append(margin(vector))
            }
            var leaks: [String] = []
            var unansweredMargins: [Float] = []
            for (query, vector) in zip(crowdUnanswered, unasked) {
                let n = index.search(query, vector: vector, now: now).count
                if n > 0 { leaks.append("\(query) (\(n))") }
                unansweredMargins.append(margin(vector))
            }
            answeredMargins.sort(); unansweredMargins.sort()
            print(String(format: "  lift ≥ %.3f, median+%.3f, weight %.2f: top-1 %d/%d top-3 %d, unanswered with results %d/%d;"
                         + " best−median answered min %.3f (2nd %.3f), unanswered max %.3f (2nd %.3f)",
                         minLift, aboveTypical, weight, top1, queries.count, top3, leaks.count, crowdUnanswered.count, answeredMargins[0],
                         answeredMargins[1], unansweredMargins.last!, unansweredMargins[unansweredMargins.count - 2]))
            if !misses.isEmpty { print("    missed: " + misses.joined(separator: ", ")) }
            if !leaks.isEmpty { print("    shown for: " + leaks.joined(separator: ", ")) }
        }
    }
}

// pastemind-cli lift   per clip: its cosine to the query minus its mean cosine to the typical queries; the answer's
//                      against the best of the rest, answered and unanswered, with and without the crowd
func lift() throws {
    let embedder = try loadEmbedder()
    let typical = try embedder.embed(Prompts.typicalQueries.map { Prompts.query($0) })
    var center = [Float](repeating: 0, count: ModelFiles.dimension)
    for v in typical { for i in v.indices { center[i] += v[i] / Float(typical.count) } }
    func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    let texts = corpus + crowdClips
    let vectors = try embedder.embed(texts.map { Prompts.document($0) })
    let hub = vectors.map { dot($0, center) }
    print("hub (mean cosine to typical queries): corpus \(String(format: "%.3f–%.3f", hub[..<corpus.count].min()!, hub[..<corpus.count].max()!)), crowd \(String(format: "%.3f–%.3f", hub[corpus.count...].min()!, hub[corpus.count...].max()!))")
    var answered: [Float] = [], others: [Float] = []
    var relAnswered: [Float] = [], relUnanswered: [Float] = []
    print("answered: lift of the answer | best lift of another clip (which)")
    for (query, expected) in queries {
        let q = try embedder.embed([Prompts.query(query)])[0]
        let lifts = vectors.indices.map { dot(vectors[$0], q) - hub[$0] }
        let other = lifts.indices.filter { $0 != expected }.max { lifts[$0] < lifts[$1] }!
        let median = lifts.sorted()[lifts.count / 2]
        relAnswered.append(lifts[expected] - median)
        answered.append(lifts[expected]); others.append(lifts[other])
        print(String(format: "  %.3f (cos %.3f) | %.3f %@   %@", lifts[expected], dot(vectors[expected], q),
                     lifts[other], String(texts[other].prefix(30)) as NSString, query as NSString))
    }
    var unansweredBest: [Float] = []
    print("unanswered: best lift (cos) which")
    for query in crowdUnanswered {
        let q = try embedder.embed([Prompts.query(query)])[0]
        let lifts = vectors.indices.map { dot(vectors[$0], q) - hub[$0] }
        let best = lifts.indices.max { lifts[$0] < lifts[$1] }!
        unansweredBest.append(lifts[best])
        relUnanswered.append(lifts[best] - lifts.sorted()[lifts.count / 2])
        print(String(format: "  %.3f (cos %.3f) %@   %@", lifts[best], dot(vectors[best], q),
                     String(texts[best].prefix(30)) as NSString, query as NSString))
    }
    answered.sort(); unansweredBest.sort(); others.sort(); relAnswered.sort(); relUnanswered.sort()
    print(String(format: "lift above the query's median lift: answers min %.3f, 2nd %.3f, 3rd %.3f; unanswered best max %.3f, 2nd %.3f, 3rd %.3f",
                 relAnswered[0], relAnswered[1], relAnswered[2], relUnanswered.last!,
                 relUnanswered[relUnanswered.count - 2], relUnanswered[relUnanswered.count - 3]))
    print(String(format: "answer lift min %.3f, 2nd %.3f, median %.3f; unanswered best lift max %.3f, 2nd %.3f, median %.3f",
                 answered[0], answered[1], answered[answered.count / 2], unansweredBest.last!,
                 unansweredBest[unansweredBest.count - 2], unansweredBest[unansweredBest.count / 2]))
}

// pastemind-cli compare <query>…   the real history searched the old way (no typical query) and the new: how many
//                                  results, how many strong, whether the first is the same (numbers only, no text)
func compare(_ asked: [String]) throws {
    let store = try ClipStore()
    let index = ClipIndex()
    index.load(try store.all(), vectors: try store.vectors())
    let embedder = try loadEmbedder()
    let typical = try typicalQuery(embedder)
    print("\(index.count) clips, \(index.embeddedCount) with vectors")
    for query in asked {
        let vector = try embedder.embed([Prompts.query(query)])[0]
        index.setTypical(nil)
        let old = index.search(query, vector: vector)
        index.setTypical(typical)
        let new = index.search(query, vector: vector)
        func line(_ r: [SearchResult]) -> String {
            "\(r.count) (\(r.filter(\.words).count) words, \(r.filter { $0.strong && !$0.words }.count) strong by meaning)"
        }
        let dropped = old.filter { o in !new.contains { $0.id == o.id } }.count
        print(String(format: "%-28@ old %@ → new %@; first %@, dropped %d", query as NSString, line(old) as NSString,
                     line(new) as NSString, old.first?.id == new.first?.id ? "same" : "differs", dropped))
    }
}

// pastemind-cli dropped <query> <keyword,…>   what the new search leaves out that the old showed: cosine, lift, length,
//                                            and whether it has one of the keywords (never its text)
func dropped(_ query: String, keywords: [String]) throws {
    let store = try ClipStore()
    let index = ClipIndex()
    index.load(try store.all(), vectors: try store.vectors())
    let vectorsByID = Dictionary(try store.vectors().map { ($0.id, $0.vector) }, uniquingKeysWith: { a, _ in a })
    let embedder = try loadEmbedder()
    let typical = try typicalQuery(embedder)
    let vector = try embedder.embed([Prompts.query(query)])[0]
    index.setTypical(nil)
    let old = index.search(query, vector: vector)
    index.setTypical(typical)
    let new = index.search(query, vector: vector)
    func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    let center = query.contains(" ") ? typical.phrase : typical.word
    let allLifts = vectorsByID.values.map { dot($0, vector) - dot($0, center) }.sorted()
    print(String(format: "lift over all clips: median %.3f, q90 %.3f, max %.3f", allLifts[allLifts.count / 2],
                 allLifts[allLifts.count * 9 / 10], allLifts.last!))
    for (label, results) in [("kept", new), ("dropped", old.filter { o in !new.contains { $0.id == o.id } })] {
        print("\(label):")
        for r in results {
            let v = vectorsByID[r.id] ?? []
            let has = keywords.contains { r.clip.text.localizedCaseInsensitiveContains($0) }
            print(String(format: "  cos %.3f lift %.3f %5d chars %@%@%@", v.isEmpty ? 0 : dot(v, vector),
                         v.isEmpty ? 0 : dot(v, vector) - dot(v, center), r.clip.text.count, r.clip.kind.rawValue,
                         r.words ? " words" : "", has ? "  HAS KEYWORD" : ""))
        }
    }
}

// pastemind-cli words   one-word queries (no word match with their answer) on the corpus among short clips: the
//                       answer's lift and the best lift when nothing answers, against typical queries of phrases, of
//                       single words, or the closer of the two
let oneWordAnswered: [(String, Int)] = [
    ("телефон", 5), ("почта", 4), ("блины", 15), ("рейс", 24), ("цвет", 6), ("контейнеры", 12), ("hexcolor", 6),
    ("pancakes", 15), ("flight", 24), ("parcel", 17), ("deployment", 12), ("exception", 16), ("roadmap", 14),
    ("берлин", 19), ("хостинг", 9),
]
let oneWordUnanswered: [String] = [
    "лицензия", "погода", "страховка", "гитара", "футбол", "подписка", "кошка", "отпуск", "license", "weather",
    "insurance", "guitar", "netflix", "dentist", "birthday",
]

func words() throws {
    let embedder = try loadEmbedder()
    func mean(_ texts: [String]) throws -> [Float] {
        let vectors = try embedder.embed(texts.map(Prompts.query))
        var m = [Float](repeating: 0, count: ModelFiles.dimension)
        for v in vectors { for i in m.indices { m[i] += v[i] / Float(vectors.count) } }
        return m
    }
    func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    let phrases = try mean(Prompts.typicalQueries), single = try mean(Prompts.typicalWords)
    let texts = corpus + crowdClips
    let vectors = try embedder.embed(texts.map { Prompts.document($0) })
    let closeness: [(String, [Float])] = [
        ("phrases", vectors.map { dot($0, phrases) }),
        ("words", vectors.map { dot($0, single) }),
        ("closer of both", vectors.map { max(dot($0, phrases), dot($0, single)) }),
    ]
    for (label, close) in closeness {
        var answers: [Float] = [], rivals: [Float] = [], nothing: [Float] = []
        var lines: [String] = []
        for (query, expected) in oneWordAnswered {
            let q = try embedder.embed([Prompts.query(query)])[0]
            let lifts = vectors.indices.map { dot(vectors[$0], q) - close[$0] }
            let rank = lifts.indices.sorted { lifts[$0] > lifts[$1] }.firstIndex(of: expected)!
            answers.append(lifts[expected])
            rivals.append(lifts.indices.filter { $0 != expected }.map { lifts[$0] }.max()!)
            lines.append(String(format: "%@ %.3f#%d", query, lifts[expected], rank + 1))
        }
        var worst: [String] = []
        for query in oneWordUnanswered {
            let q = try embedder.embed([Prompts.query(query)])[0]
            let lifts = vectors.indices.map { dot(vectors[$0], q) - close[$0] }
            let best = lifts.indices.max { lifts[$0] < lifts[$1] }!
            nothing.append(lifts[best])
            worst.append(String(format: "%@ %.3f (%@)", query, lifts[best], String(texts[best].prefix(16))))
        }
        answers.sort(); nothing.sort()
        print(String(format: "%@: answers' lift min %.3f, 2nd %.3f, median %.3f; nothing answers: best lift max %.3f, 2nd %.3f, median %.3f",
                     label, answers[0], answers[1], answers[answers.count / 2], nothing.last!, nothing[nothing.count - 2],
                     nothing[nothing.count / 2]))
        print("   " + lines.joined(separator: ", "))
        print("   " + worst.joined(separator: ", "))
    }
    // As the app searches, with its defaults.
    let now = Date()
    let clips = texts.enumerated().map { offset, text in
        Clip(id: Int64(offset), kind: ClipClassifier.kind(of: text), text: text,
             lastCopied: now.addingTimeInterval(-Double(offset) * 3600))
    }
    let index = ClipIndex()
    index.load(clips, vectors: zip(clips, vectors).map { ($0.id, $1) })
    let typical = try typicalQuery(embedder)
    for withTypical in [false, true] {
    index.setTypical(withTypical ? typical : nil)
    var found: [String] = [], missed: [String] = [], leaked: [String] = []
    for (query, expected) in oneWordAnswered {
        let results = index.search(query, vector: try embedder.embed([Prompts.query(query)])[0], now: now)
        (results.first?.id == Int64(expected) ? { found.append(query) } : { missed.append("\(query) (\(results.count))") })()
    }
    for query in oneWordUnanswered {
        let n = index.search(query, vector: try embedder.embed([Prompts.query(query)])[0], now: now).count
        if n > 0 { leaked.append("\(query) (\(n))") }
    }
    let word = try typicalQuery(embedder).word
    for (query, expected) in oneWordAnswered.prefix(8) {
        let q = try embedder.embed([Prompts.query(query)])[0]
        let cos = vectors.map { dot($0, q) }, close = vectors.map { dot($0, word) }
        let usual = close.sorted()[close.count / 2]
        let adjusted = cos.indices.map { cos[$0] - 0.5 * (close[$0] - usual) }
        let sorted = adjusted.sorted()
        print(String(format: "  %@: answer cos %.3f lift %.3f adjusted %.3f; best adjusted %.3f, median %.3f → gate %.3f",
                     query, cos[expected], cos[expected] - close[expected], adjusted[expected], sorted.last!,
                     sorted[sorted.count / 2], max(0.6, sorted.last! - 0.1, sorted[sorted.count / 2] + 0.078)))
    }
    print("app (\(withTypical ? "typical query" : "old: median")): one-word answers first \(found.count)/\(oneWordAnswered.count) (missed: \(missed.joined(separator: ", "))); "
          + "with no answer, results for \(leaked.count)/\(oneWordUnanswered.count) \(leaked.joined(separator: ", "))")
    }
}

