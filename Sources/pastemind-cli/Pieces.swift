import Foundation
import LlamaRuntime
import PastemindKit

// pastemind-cli pieces <folder> [real] [vision=<mmproj>] ["query=>file"…]   long documents with and without their
//                                         pieces' vectors (CopiedFiles.pieces): how often a query about something past
//                                         their start finds them, among the evaluation's notes (or, with "real", your
//                                         files' vectors: no names); queries given replace the built-in ones; with the
//                                         vision encoder, scans go in as the app reads them (their first page's picture)

let pieceQueries: [(String, String)] = [
    ("можно ли держать собаку в съёмной квартире", "arenda.pdf"),
    ("через сколько дней вернут залог после выезда", "arenda.pdf"),
    ("штраф за курение в квартире", "arenda.pdf"),
    ("кто платит за ремонт сантехники", "arenda.pdf"),
    ("за сколько дней предупредить хозяина о выезде", "arenda.pdf"),
    ("пени за просрочку оплаты аренды", "arenda.pdf"),
    ("можно ли сдавать квартиру посуточно", "arenda.pdf"),
    ("какая техника есть в квартире", "arenda.pdf"),
    ("limit download speed", "curl.pdf"),
    ("resume an interrupted download", "curl.pdf"),
    ("send cookies from a file with the request", "curl.pdf"),
    ("retry the request on transient errors", "curl.pdf"),
    ("upload a file to an ftp server", "curl.pdf"),
    ("keep the ssh connection alive when idle", "ssh_config.pdf"),
    ("connect through a jump host", "ssh_config.pdf"),
    ("forward my ssh agent to the server", "ssh_config.pdf"),
    ("turn off host key checking", "ssh_config.pdf"),
    ("ignore duplicate commands in shell history", "zshoptions.pdf"),
    ("share history between terminal sessions", "zshoptions.pdf"),
    ("correct misspelled commands", "zshoptions.pdf"),
    ("extended globbing patterns", "zshoptions.pdf"),
    ("run a job every few minutes", "launchd.plist.pdf"),
    ("restart the job if it crashes", "launchd.plist.pdf"),
    ("run a task at a specific time every day", "launchd.plist.pdf"),
    ("write the job's output to a log file", "launchd.plist.pdf"),
    ("delete files on the destination that are not in the source", "rsync.pdf"),
    ("exclude files matching a pattern from sync", "rsync.pdf"),
    ("show what would be copied without copying", "rsync.pdf"),
    ("preserve file permissions and timestamps", "rsync.pdf"),
]

func pieces(_ arguments: [String]) async throws {
    guard let folderPath = arguments.first else {
        print("usage: pastemind-cli pieces <folder> [real] [vision=<mmproj>] [\"query=>file\"…]")
        exit(2)
    }
    let embedder = try loadEmbedder()
    let vision = arguments.first { $0.hasPrefix("vision=") }.map { String($0.dropFirst("vision=".count)) }
    if let vision { try embedder.openImages(projector: URL(fileURLWithPath: vision)) }
    let folder = URL(fileURLWithPath: folderPath)
    let names = (try FileManager.default.contentsOfDirectory(atPath: folder.path)).filter { !$0.hasPrefix(".") }.sorted()
    var rows: [(file: IndexedFile, vector: [Float])] = []
    var pieceVectors: [Int64: [[Float]]] = [:]
    for (offset, name) in names.enumerated() {
        let url = folder.appendingPathComponent(name)
        guard let contents = await CopiedFileReader.read([url], pictures: vision != nil, sound: false, budget: 140)
        else { continue }
        let id = Int64(offset + 1)
        let vector = contents.media.isEmpty ? try embedder.embed([contents.prompt])[0]
            : try embedder.embed(contents.media, prompt: contents.prompt)
        rows.append((IndexedFile(id: id, path: url.path, modified: Date(), lastUsed: nil), vector))
        if vision != nil { print("\(name): \(contents.summary)") }
        let (prompts, readTime) = time { CopiedFileReader.pieces(of: url) }
        let (vectors, embedTime) = try time { try embedder.embed(prompts) }
        pieceVectors[id] = vectors
        print(String(format: "%@: %d pieces, read %@, embedded %@ (%.1f ms a piece)", name, prompts.count, ms(readTime),
                     ms(embedTime), prompts.isEmpty ? 0 : embedTime * 1000 / Double(prompts.count)))
    }
    let tests = Set(rows.map(\.file.id))
    let given: [(String, String)] = arguments.dropFirst().compactMap { argument in
        guard let split = argument.range(of: "=>") else { return nil }
        return (String(argument[..<split.lowerBound]), String(argument[split.upperBound...]))
    }
    let queries = given.isEmpty ? pieceQueries : given
    if arguments.count > 1, arguments[1] == "real" {
        let stored = try ClipStore().indexedFiles().compactMap { row in row.vector.map { (row.file, $0) } }
        rows += stored.map { (IndexedFile(id: 1_000_000 + $0.0.id, path: "", modified: $0.0.modified, lastUsed: nil), $0.1) }
        print("\(stored.count) of your files' vectors as the crowd (no names)")
    } else {
        let texts = corpus + crowdClips
        let vectors = try embedder.embed(texts.indices.map { Prompts.files(title: "note-\($0).txt", markers: [], text: texts[$0]) })
        rows += vectors.indices.map { (IndexedFile(id: Int64(1000 + $0), path: "", modified: Date(), lastUsed: nil), vectors[$0]) }
    }
    let typical = try typicalVectors(embedder)
    var queryVectors: [String: [Float]] = [:]
    for query in queries.map(\.0) + crowdUnanswered {
        queryVectors[query] = try embedder.embed([Prompts.query(query)])[0]
    }
    for withPieces in [false, true] {
        let index = FileIndex()
        index.load(rows, pieces: withPieces ? pieceVectors : [:])
        index.setTypical(phrases: typical.phrases, words: typical.words)
        var first = 0, shown = 0, crowdRows = 0
        print(withPieces ? "with pieces:" : "without:")
        for (query, expected) in queries {
            let results = index.search(queryVectors[query]!, oneWord: !query.contains(" "), limit: 20)
            let hit = results.firstIndex { URL(fileURLWithPath: $0.file.path).lastPathComponent == expected }
            if hit == 0 { first += 1 }
            if hit != nil { shown += 1 }
            crowdRows += results.filter { !tests.contains($0.file.id) }.count
            let piece = hit.map { results[$0].piece } ?? -1
            let wrong = results.prefix(hit ?? 3).filter { tests.contains($0.file.id) }
                .map { URL(fileURLWithPath: $0.file.path).lastPathComponent }
            print("  \(hit.map { "#\($0 + 1)" } ?? "--") \(piece > 0 ? "piece \(piece)" : piece == 0 ? "start" : "")"
                  + "\t\(query)\(wrong.isEmpty ? "" : "  (above: \(wrong.joined(separator: ", ")))")")
        }
        var leaks = 0, leakRows = 0
        for query in crowdUnanswered {
            let results = index.search(queryVectors[query]!, oneWord: !query.contains(" "), limit: 20)
                .filter { tests.contains($0.file.id) }
            if !results.isEmpty { leaks += 1 }
            leakRows += results.count
            if !results.isEmpty {
                print("    \(query) → " + results.prefix(3).map {
                    URL(fileURLWithPath: $0.file.path).lastPathComponent + " piece \($0.piece)"
                        + String(format: " %.3f", $0.cosine)
                }.joined(separator: " | "))
            }
        }
        print(String(format: "  first %d shown %d /%d · crowd rows beside answers %d · no-answer queries showing a "
                     + "document %d/%d (%d rows)", first, shown, queries.count, crowdRows, leaks,
                     crowdUnanswered.count, leakRows))
    }
}
