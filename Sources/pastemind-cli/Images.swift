import Foundation
import LlamaRuntime
import PastemindKit
import Vision

// pastemind-cli images <mmproj> <budget> <picture>…   pictures through EmbeddingGemma 2's image encoder, among the eval's
//                                                    text clips: timings, and queries (in several languages) that each
//                                                    name one picture by its file name

/// Queries and the picture each one is about (its file name without the extension).
let pictureQueries: [(String, String)] = [
    ("owl", "Owl"), ("сова", "Owl"),
    ("colorful parrot", "Parrot"), ("попугай", "Parrot"),
    ("penguin", "Penguin"), ("пингвин", "Penguin"),
    ("striped animal", "Zebra"), ("полосатое животное", "Zebra"),
    ("bird of prey", "Eagle"), ("орёл", "Eagle"),
    ("red rose", "Red Rose"), ("красная роза", "Red Rose"),
    ("sunflower", "Sunflower"), ("подсолнух", "Sunflower"),
    ("guitar", "Guitar"), ("гитара", "Guitar"),
    ("piano", "Piano"), ("пианино", "Piano"),
    ("vinyl record player", "Turntable"), ("проигрыватель пластинок", "Turntable"),
    ("basketball", "Basketball"), ("баскетбольный мяч", "Basketball"),
    ("billiards", "8ball"), ("бильярд", "8ball"),
    ("planet earth from space", "Earth"), ("земля из космоса", "Earth"),
    ("cactus", "Cactus"), ("кактус", "Cactus"),
    ("lightning", "Lightning"), ("молния", "Lightning"),
    ("snowflake", "Snowflake"), ("снежинка", "Snowflake"),
    ("grocery receipt", "receipt"), ("чек из магазина", "receipt"),
    ("swift code in an editor", "code"), ("код в редакторе", "code"),
    ("boarding pass", "boarding"), ("посадочный талон", "boarding"),
    ("bar chart of revenue", "chart"), ("график выручки", "chart"),
    ("chat with Anna", "chat"), ("переписка про ужин", "chat"),
    ("slide with quarterly plans", "roadmap"), ("слайд с планами на квартал", "roadmap"),
    ("clipboard history app window", "c_list"), ("окно истории буфера обмена", "c_list"),
]

/// Text queries the eval's clips answer: pictures mustn't push in ahead of them.
let textQueries = ["ssh into the server", "адрес офиса", "sql query for orders", "hosting invoice"]

func images(_ arguments: [String]) throws {
    guard arguments.count >= 3, let budget = Int(arguments[1]), ImagePixels.budgets.contains(budget) else {
        print("usage: pastemind-cli images <mmproj> <budget: \(ImagePixels.budgets)> <picture>…")
        exit(2)
    }
    let embedder = try loadEmbedder()
    let projector = URL(fileURLWithPath: arguments[0])
    try embedder.openImages(projector: projector)
    print("image encoder loaded in \(ms(embedder.imageLoadSeconds)) (\(projector.lastPathComponent))")
    print("footprint with both: \(footprintMB()) MB")

    let texts = corpus.map { Prompts.document($0) }
    let textVectors = try embedder.embed(texts)

    var names: [String] = []
    var plain: [[Float]] = []      // the picture alone
    var withText: [[Float]] = []   // the picture with its text (Vision), when it has some
    var chosen: [[Float]] = []     // the picture with its text when that's enough to say something, as the app does
    var ocr: [String] = []
    var decode: [Double] = [], encode: [Double] = [], encodeText: [Double] = []
    for path in arguments.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let (pixels, decodeTime) = time { ImagePixels(url: url, budget: budget) }
        guard let pixels else { print("can't read \(path)"); continue }
        let (vector, encodeTime) = try time { try embedder.embed(image: pixels) }
        let text = recognizedText(url)
        var combined = vector
        if !text.isEmpty {
            let prompt = Prompts.document(LlamaEmbedder.marker + "\n" + String(text.prefix(Clip.embeddingCharacters)))
            let (both, bothTime) = try time { try embedder.embed(image: pixels, prompt: prompt) }
            combined = both
            encodeText.append(bothTime)
        }
        names.append(url.deletingPathExtension().lastPathComponent)
        plain.append(vector)
        withText.append(combined)
        chosen.append(text.count >= textMinimum ? combined : vector)
        ocr.append(text)
        decode.append(decodeTime)
        encode.append(encodeTime)
        print(String(format: "  %-14@ %4d×%-4d  decode %@, encode %@%@", names.last! as NSString, pixels.width, pixels.height,
                     ms(decodeTime), ms(encodeTime), text.isEmpty ? "" : ", text: \(text.count) chars"))
    }
    func median(_ values: [Double]) -> String { values.isEmpty ? "-" : ms(values.sorted()[values.count / 2]) }
    print("budget \(budget): decode median \(median(decode)), picture median \(median(encode)), "
          + "with its text median \(median(encodeText)); footprint \(footprintMB()) MB")

    for (label, pictures) in [("picture alone", plain), ("picture + its text", withText),
                              ("picture + its text from \(textMinimum) characters", chosen)] {
        print("\n== \(label)")
        var top1 = 0, top3 = 0, aheadOfText = 0
        var right: [Float] = [], wrongBest: [Float] = [], textBest: [Float] = []
        for (query, expected) in pictureQueries {
            let q = try embedder.embed([Prompts.query(query)])[0]
            let cosines = pictures.map { dot($0, q) }
            let textCosines = textVectors.map { dot($0, q) }
            guard let target = names.firstIndex(of: expected) else { continue }
            let order = cosines.indices.sorted { cosines[$0] > cosines[$1] }
            let rank = order.firstIndex(of: target)!
            if rank == 0 { top1 += 1 }
            if rank < 3 { top3 += 1 }
            if cosines[target] > textCosines.max()! { aheadOfText += 1 }
            right.append(cosines[target])
            wrongBest.append(order.filter { $0 != target }.map { cosines[$0] }.first!)
            textBest.append(textCosines.max()!)
            let top = order.prefix(3).map { String(format: "%.3f %@", cosines[$0], names[$0]) }.joined(separator: " | ")
            print(String(format: "%@ %-30@ rank %2d  right %.3f  best text %.3f   %@", rank == 0 ? "✓" : "✗",
                         query as NSString, rank + 1, cosines[target], textCosines.max()!, top))
        }
        let n = right.count
        print("top-1 \(top1)/\(n), top-3 \(top3)/\(n), ahead of every text clip \(aheadOfText)/\(n)")
        print(String(format: "cosines: right %.3f–%.3f (median %.3f), best wrong picture median %.3f, best text clip median %.3f",
                     right.min()!, right.max()!, right.sorted()[n / 2], wrongBest.sorted()[n / 2], textBest.sorted()[n / 2]))
        print("text queries (the right text clip vs the best picture):")
        for query in textQueries {
            let q = try embedder.embed([Prompts.query(query)])[0]
            let textCosines = textVectors.map { dot($0, q) }
            let best = textCosines.indices.max { textCosines[$0] < textCosines[$1] }!
            let picture = pictures.indices.max { dot(pictures[$0], q) < dot(pictures[$1], q) }!
            print(String(format: "  %-24@ text %.3f %@ | picture %.3f %@", query as NSString, textCosines[best],
                         String(corpus[best].prefix(30)) as NSString, dot(pictures[picture], q), names[picture] as NSString))
        }
    }

    // The app's ranking (words, meaning, the bars) over the text clips and the pictures together.
    print("\n== ClipIndex over \(corpus.count) text clips and \(names.count) pictures")
    let now = Date()
    var clips = corpus.enumerated().map { offset, text in
        Clip(id: Int64(offset), kind: ClipClassifier.kind(of: text), text: text,
             lastCopied: now.addingTimeInterval(-Double(offset) * 3600))
    }
    let pictureBase = Int64(1000)
    for (offset, name) in names.enumerated() {
        clips.append(Clip(id: pictureBase + Int64(offset), kind: .image, text: ocr[offset],
                          lastCopied: now.addingTimeInterval(-Double(offset) * 1800), image: name))
    }
    let index = ClipIndex()
    index.load(clips, vectors: zip(clips.prefix(corpus.count), textVectors).map { ($0.id, $1) }
                   + chosen.enumerated().map { (pictureBase + Int64($0.offset), $0.element) })
    func shown(_ results: [SearchResult]) -> String {
        results.prefix(3).map { r in
            String(format: "%.3f", r.meaning ?? 0) + (r.words ? "w" : "") + (r.strong ? "" : "°") + " "
                + (r.clip.kind == .image ? r.clip.image ?? "" : String(r.clip.title.prefix(20)))
        }.joined(separator: " | ")
    }
    var top1 = 0
    for (query, expected) in pictureQueries {
        let q = try embedder.embed([Prompts.query(query)])[0]
        let results = index.search(query, vector: q, now: now)
        let rank = results.firstIndex { $0.clip.image == expected }
        if rank == 0 { top1 += 1 }
        print(String(format: "%@ %-30@ rank %@  %2d results, %2d strong   %@", rank == 0 ? "✓" : "✗", query as NSString,
                     rank.map { "\($0 + 1)" } ?? "-", results.count, results.filter(\.strong).count, shown(results)))
    }
    print("pictures top-1 \(top1)/\(pictureQueries.count)")
    var textTop1 = 0
    for (query, expected) in queries {
        let q = try embedder.embed([Prompts.query(query)])[0]
        let results = index.search(query, vector: q, now: now)
        if results.first?.clip.id == Int64(expected) { textTop1 += 1 } else {
            print(String(format: "✗ text %-30@ %@", query as NSString, shown(results)))
        }
    }
    print("text queries top-1 \(textTop1)/\(queries.count) with the pictures in")
    for query in unanswered {
        let q = try embedder.embed([Prompts.query(query)])[0]
        let results = index.search(query, vector: q, now: now)
        print(String(format: "  unanswered %-24@ %2d results   %@", query as NSString, results.count, shown(results)))
    }

    embedder.closeImages()
    print("\nfootprint after closing the image encoder: \(footprintMB()) MB")
}

/// Text Vision read in a picture goes into its vector from this many characters: less is mostly noise (a photo's "8ball").
private let textMinimum = 40

private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 } }

/// What Vision reads in a picture, as the app does.
private func recognizedText(_ url: URL) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    guard (try? VNImageRequestHandler(url: url).perform([request])) != nil else { return "" }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

private func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}
