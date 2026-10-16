import Foundation
import LlamaRuntime
import PastemindKit

// pastemind-cli agree <text model A> <text model B> <mmproj> [picture…]   how close two text models' vectors are for the
//                                                                        same inputs (documents, queries, pictures),
//                                                                        and their speed

func agree(_ arguments: [String]) throws {
    let models = arguments.prefix(2).map { URL(fileURLWithPath: $0) }
    let projector = URL(fileURLWithPath: arguments[2])
    let pictures = arguments.dropFirst(3).compactMap { ImagePixels(url: URL(fileURLWithPath: $0), budget: 140) }
    let documents = corpus.map { Prompts.document($0) }
    let asked = (queries.map(\.0) + unanswered).map { Prompts.query($0) }
    var vectors: [[[Float]]] = []
    for model in models {
        let embedder = try loadEmbedder(model)
        var made = try embedder.embed(documents) + embedder.embed(asked)
        try embedder.openImages(projector: projector)
        for picture in pictures { made.append(try embedder.embed(image: picture)) }
        var times: [Double] = []
        for i in 0..<30 { times.append(try time { _ = try embedder.embed([Prompts.query("router ip \(i)")]) }.1) }
        let (_, clip) = try time { _ = try embedder.embed([Prompts.document(String(repeating: "A paragraph of copied text. ", count: 45))]) }
        let (_, picture) = try time { if let first = pictures.first { _ = try embedder.embed(image: first) } }
        times.sort()
        print("  query \(ms(times[15])), 1.3k-character clip \(ms(clip)), picture \(ms(picture))")
        embedder.close()
        vectors.append(made)
    }
    func cosines(_ range: Range<Int>) -> [Float] {
        range.map { i in zip(vectors[0][i], vectors[1][i]).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
    }
    let d = documents.count, q = asked.count
    for (label, range) in [("documents", 0..<d), ("queries", d..<(d + q)), ("pictures", (d + q)..<vectors[0].count)]
    where !range.isEmpty {
        let c = cosines(range)
        print(String(format: "%@: cosine A↔B mean %.4f, min %.4f (%d)", label, c.reduce(0, +) / Float(c.count),
                     c.min()!, c.count))
    }
}

// pastemind-cli splitcheck <whole mmproj> <vision mmproj> <audio mmproj> <file>…   the split encoders against the whole
//                                                                                   file: the same vectors?

func splitCheck(_ arguments: [String]) async throws {
    let (whole, vision, audio) = (URL(fileURLWithPath: arguments[0]), URL(fileURLWithPath: arguments[1]),
                                  URL(fileURLWithPath: arguments[2]))
    var made: [[[Float]]] = [[], []]
    for (index, (images, sound)) in [(whole, whole), (vision, audio)].enumerated() {
        let embedder = try loadEmbedder()
        for path in arguments.dropFirst(3) {
            guard let contents = await CopiedFileReader.read([URL(fileURLWithPath: path)], pictures: true, sound: true,
                                                             budget: 140), !contents.media.isEmpty else { continue }
            let heard = contents.media.contains { if case .sound = $0 { return true } else { return false } }
            if heard { try embedder.openSound(projector: sound) } else { try embedder.openImages(projector: images) }
            made[index].append(try embedder.embed(contents.media, prompt: contents.prompt))
        }
        embedder.close()
    }
    let cosines = zip(made[0], made[1]).map { zip($0, $1).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
    print(String(format: "%d inputs: cosine whole↔split min %.6f, mean %.6f", cosines.count, cosines.min() ?? 0,
                 cosines.reduce(0, +) / Float(max(cosines.count, 1))))
}
