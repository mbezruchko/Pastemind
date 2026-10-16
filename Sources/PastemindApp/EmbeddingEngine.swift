import Foundation
import LlamaRuntime
import QuartzCore
import PastemindKit

/// The model, on a thread of its own: query vectors for the panel (always first: one waiting query is answered before
/// the next batch of clips), and vectors for new clips in small batches behind them. Pictures, and copied files' pictures
/// and sound, go through its image and audio encoders, one clip at a time (~0.2 s a picture, ~0.5 s a video's frames),
/// into the same space as text: each encoder (~0.1–0.3 s to load, 200–330 MB) is in only while there's something
/// waiting that needs it.
///
/// It's in memory (about 300 MB) only while it's wanted: from when the clipboard history opens until it has gone
/// unused for `idleTime`, and while it reads a pile of clips. Out of it, it costs nothing. Clips copied meanwhile wait
/// for it (words find them at once): until the history opens next, or `wakeBacklog` of them have piled up. It loads
/// again in about half a second, starting as the history opens, so it's back before a query has its three letters.
nonisolated final class EmbeddingEngine: @unchecked Sendable {
    enum State: Equatable, Sendable {
        /// No model yet (downloading).
        case idle
        /// The model is on disk, and loads whenever it's wanted.
        case ready
        case failed(String)
    }

    /// What a clip's vector is made from.
    enum Input: Sendable {
        case text(String)
        /// A picture's file, the text Vision read in it when there's enough to go with it, and the text its vector is
        /// made from should the picture not read.
        case picture(URL, text: String?, fallback: String?)
        /// Copied files: a prompt with their pictures or sound at its markers (`CopiedFileReader`), what went in (for
        /// the log), and their names should those not read.
        case files(prompt: String, media: [LlamaEmbedder.Media], summary: String, fallback: String?)
        /// Several copied files one at a time (`files` each, its name the fallback): a vector of each, besides the
        /// clip's own. Waits in the queue apart from that one.
        case fileParts([Input])
        /// A long copied document's pieces past its start (`CopiedFileReader.pieces`): a vector of each, besides the
        /// clip's own. Waits in the queue apart from that one.
        case pieces([String])

        var needsImages: Bool {
            switch self {
            case .text, .pieces: return false
            case .picture: return true
            case .files(_, let media, _, _): return media.contains { if case .picture = $0 { true } else { false } }
            case .fileParts(let parts): return parts.contains(where: \.needsImages)
            }
        }

        var needsSound: Bool {
            switch self {
            case .files(_, let media, _, _): return media.contains { if case .sound = $0 { true } else { false } }
            case .fileParts(let parts): return parts.contains(where: \.needsSound)
            default: return false
            }
        }

        var fallback: String? {
            switch self {
            case .text, .fileParts, .pieces: return nil
            case .picture(_, _, let fallback), .files(_, _, _, let fallback): return fallback
            }
        }

        /// Where it waits: a clip's files one at a time, or its pieces, apart from the clip's own vector.
        func key(of id: Int64) -> Int64 {
            switch self {
            case .fileParts, .pieces: ~id
            default: id
            }
        }
    }

    /// How files may be read now (`FilePolicy`).
    enum FilePace: Sendable {
        /// Not at all (search by contents is off or paused, Low Power Mode, the Mac hot or its battery low).
        case no
        /// Recent ones, one every `pacedGap` seconds: you're working, or it's on battery (a tenth of the GPU).
        case paced
        /// All of them, one after another: the Mac is idle on power.
        case fast
    }

    /// Which files go first, and when they may go.
    enum FileTier: Int, Sendable, Comparable {
        /// Just opened or saved: at once, unpaced.
        case opened
        /// Changed or opened in the last 60 days: paced while you work.
        case recent
        /// The rest of the home folder: only while the Mac is idle on power.
        case background

        static func < (a: FileTier, b: FileTier) -> Bool { a.rawValue < b.rawValue }
    }

    /// A file for search waiting for the model: what its vector is made from, its pieces' prompts (a long document),
    /// and what's made of it so far (while files are paced, its pieces go a few at a time, each turn behind queries
    /// and clips).
    struct FileWork: Sendable {
        let path: String
        let input: Input
        let pieces: [String]
        var tier: FileTier
        var vector: [Float]? = nil
        /// The next piece to go.
        var next = 0
        var made: [[Float]] = []
    }

    struct Made: Sendable {
        let id: Int64
        let vector: [Float]
        /// From what's in it (a picture, a file's contents), not only its text or names.
        let fromContent: Bool
        /// Each copied file's (`Input.fileParts`), and then no `vector`.
        var parts: [[Float]]? = nil
    }

    private let lock = NSLock()
    /// User-interactive: Pastemind is a background app (the panel never activates it), and at a lower QoS macOS runs the
    /// model's CPU threads on the efficiency cores (CPU queries took 120–160 ms at user-initiated, 40–65 here).
    private let queue = DispatchQueue(label: "pastemind.embedder", qos: .userInteractive)
    private var embedder: LlamaEmbedder?   // used only on `queue`
    private var model: URL?
    /// The image and audio encoders' files, once they're on disk (one file for both, from earlier installs).
    private var imageProjector: URL?
    private var soundProjector: URL?
    /// The image encoder wouldn't load: pictures go by their text.
    private var picturesFailed = false
    /// The audio encoder wouldn't load: sound goes by its file's name.
    private var soundFailed = false
    /// `embedder` is there: set on `queue`.
    private var loaded = false
    /// When the history last opened or searched.
    private var lastUsed: CFTimeInterval = -.infinity
    /// Unloads the model once it has gone unused for `idleTime` (on `queue`).
    private let sleepTimer: DispatchSourceTimer
    private var loads = 0   // on `queue`
    private var state = State.idle
    private var pendingQuery: (prompt: String, done: @Sendable ([Float]?) -> Void)?
    private var pendingClips: [(id: Int64, input: Input)] = []
    /// Recent files for search (`FileIndexer`), behind queries and clips, and only while `filesMayRun` says so.
    private var pendingFiles: [FileWork] = []
    /// More recent files are being read: the encoders stay in between them.
    private var filesComing = false
    /// Paced, the next recent file waits till then.
    private var filesResumeAt: CFTimeInterval = 0
    static let pacedGap: CFTimeInterval = 2
    /// A long document's pieces a paced turn takes (about a fifth of a second), and how many share a batch.
    static let piecesPerTurn = 4
    /// After a file just opened, the model stays this long: the next one opened needn't wait for it to load (shorter
    /// with 8 GB or less, where its few hundred MB count more).
    private var lingerUntil: CFTimeInterval = 0
    static let smallMemory = ProcessInfo.processInfo.physicalMemory <= 8 << 30
    static let openedLinger: CFTimeInterval = smallMemory ? 20 : 60
    private var queued: Set<Int64> = []
    private var pumping = false
    /// `Prompts.typicalQueries`' and `Prompts.typicalWords`' vectors (the history's and files' typical queries): made
    /// once, the first time the model's in with no query waiting.
    private var typicalQuery: (phrases: [[Float]], words: [[Float]])?
    private var typicalQueryTried = false
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private static let cacheSize = 256
    /// A batch of clips stops growing past this many characters, so a waiting query never waits long.
    private static let batchCharacters = 1600
    private static let batchClips = 8
    /// Unused this long (no history opened, no query), the model goes. Back in about half a second, from the
    /// history opening, before the first query needs it.
    static let idleTime: CFTimeInterval = 5 * 60
    /// Clips copied while the model is out wait for it, unless this many have piled up: it loads for them, reads
    /// them, and goes again.
    static let wakeBacklog = 32
    /// The image encoder's soft tokens per picture: 140 reads the scene as well as 280 in half the time (~0.2 s on an
    /// M1 Pro; pastemind-cli images), and a screenshot's text comes in as text.
    static let pictureBudget = 140

    /// New vectors for clips, on the main thread.
    private let onVectors: @MainActor @Sendable ([Made]) -> Void
    /// A recent file's vector (nil: nothing in it read), on the main thread.
    /// A file's vector (nil: nothing in it read) and its pieces' (nil: still to come; then again with them).
    private let onFileVector: @MainActor @Sendable (String, [Float]?, [[Float]]?) -> Void
    /// Whether recent files may be read now (idle, on power): asked before each, from the model's thread.
    private let filesPace: @Sendable () -> FilePace
    private let onState: @MainActor @Sendable (State) -> Void
    /// The typical queries' vectors, of phrases and of single words, on the main thread.
    private let onTypicalQuery: @MainActor @Sendable (_ phrases: [[Float]], _ words: [[Float]]) -> Void

    init(onVectors: @escaping @MainActor @Sendable ([Made]) -> Void,
         onFileVector: @escaping @MainActor @Sendable (String, [Float]?, [[Float]]?) -> Void,
         filesPace: @escaping @Sendable () -> FilePace,
         onState: @escaping @MainActor @Sendable (State) -> Void,
         onTypicalQuery: @escaping @MainActor @Sendable (_ phrases: [[Float]], _ words: [[Float]]) -> Void) {
        self.onVectors = onVectors
        self.onFileVector = onFileVector
        self.filesPace = filesPace
        self.onState = onState
        self.onTypicalQuery = onTypicalQuery
        sleepTimer = DispatchSource.makeTimerSource(queue: queue)
        sleepTimer.setEventHandler { [weak self] in self?.sleepIfUnused() }
        sleepTimer.schedule(deadline: .distantFuture)
        sleepTimer.resume()
    }

    var currentState: State { lock.withLock { state } }

    /// The model's on disk: it loads when it's first wanted.
    func prepare(_ model: URL) {
        lock.withLock { self.model = model }
        set(.ready)
        schedule()
    }

    /// The image encoder's on disk: pictures go in by what's in them from now on.
    func preparePictures(_ projector: URL) {
        lock.withLock { imageProjector = projector }
    }

    /// The audio encoder's on disk: recordings go in by what's said in them from now on.
    func prepareSound(_ projector: URL) {
        lock.withLock { soundProjector = projector }
    }

    /// Pictures are read by the image encoder (else by their text alone).
    var readsPictures: Bool { lock.withLock { imageProjector != nil && !picturesFailed } }
    /// Sound is heard by the audio encoder (else audio files go by their names).
    var readsSound: Bool { lock.withLock { soundProjector != nil && !soundFailed } }

    /// The clipboard history opened: the model loads, if it's out, for the search that may follow.
    func wake() {
        lock.withLock { lastUsed = CACurrentMediaTime() }
        schedule()
    }

    private func set(_ state: State) {
        lock.withLock { self.state = state }
        let onState = self.onState
        DispatchQueue.main.async { MainActor.assumeIsolated { onState(state) } }
    }

    /// A vector already made for this query (typing back and forth), without waiting.
    func cachedQuery(_ text: String) -> [Float]? {
        lock.withLock { cache[Prompts.query(text)] }
    }

    /// Debug runs: as if the history had gone unused all along (the model goes now, or once it's done).
    func forgetUse() {
        lock.withLock { lastUsed = -.infinity }
        queue.async { self.sleepIfUnused() }
    }

    /// The query's vector (loading the model first, if it's out), or nil when there's no model or a newer query took
    /// this one's place.
    func query(_ text: String) async -> [Float]? {
        let prompt = Prompts.query(text)
        let hit = lock.withLock { () -> [Float]? in
            lastUsed = CACurrentMediaTime()
            return cache[prompt]
        }
        if let hit { return hit }
        guard currentState == .ready else { return nil }
        return await withCheckedContinuation { continuation in
            let replaced = lock.withLock { () -> (@Sendable ([Float]?) -> Void)? in
                let old = pendingQuery?.done
                pendingQuery = (prompt, { continuation.resume(returning: $0) })
                return old
            }
            replaced?(nil)
            schedule()
        }
    }

    /// Clips to embed; one already waiting is made from the newer input instead.
    func enqueue(_ clips: [(id: Int64, input: Input)]) {
        guard !clips.isEmpty else { return }
        lock.withLock {
            for clip in clips {
                let key = clip.input.key(of: clip.id)
                if queued.contains(key), let waiting = pendingClips.firstIndex(where: { $0.id == key }) {
                    pendingClips[waiting] = (key, clip.input)
                } else if !queued.contains(key) {
                    queued.insert(key)
                    pendingClips.append((key, clip.input))
                }
            }
        }
        schedule()
    }

    /// A file to read for search, behind queries and clips, in its tier's place; `pieces`: a long document's.
    func enqueueFile(_ path: String, _ input: Input, pieces: [String] = [], tier: FileTier) {
        lock.withLock {
            pendingFiles.removeAll { $0.path == path }
            let place = pendingFiles.firstIndex { $0.tier > tier } ?? pendingFiles.count
            pendingFiles.insert(FileWork(path: path, input: input, pieces: pieces, tier: tier), at: place)
            if tier == .opened { lingerUntil = CACurrentMediaTime() + Self.openedLinger }
        }
        schedule()
    }

    /// Recent files waiting for the model.
    var fileBacklog: Int { lock.withLock { pendingFiles.count } }

    /// The indexer is reading more (or done): the encoders needn't go between files.
    func filesComing(_ coming: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { filesComing = coming }
            return filesComing != coming
        }
        guard changed, !coming else { return }
        queue.async {
            if let embedder = self.embedder { self.closeEncodersNotNeeded(embedder) }
            self.scheduleSleep()
        }
    }

    /// Recent files that won't be needed after all (search by contents turned off).
    func dropFiles() {
        lock.withLock { pendingFiles.removeAll() }
    }

    /// Whether waiting work may start now (the Mac went idle): asked again.
    func poke() { schedule() }

    /// Clips waiting for the model, or being read.
    var queuedCount: Int { lock.withLock { queued.count } }

    /// Clips being read now: none while the model is out (those waiting for it wait quietly).
    var backlog: Int { lock.withLock { loaded || pumping ? pendingClips.count : 0 } }

    /// Frees the model before the process exits. Left to exit's static destructors, llama.cpp's Metal backend aborts
    /// on resources still held (crash reports 2026-10-13, Quit from the menu). Waits for an embedding in flight.
    func close() {
        lock.withLock {
            pendingClips.removeAll()
            pendingFiles.removeAll()
            pendingQuery?.done(nil)
            pendingQuery = nil
            state = .idle
        }
        queue.sync {
            sleepTimer.cancel()
            embedder?.close()
            embedder = nil
            lock.withLock { loaded = false }
        }
    }

    private func schedule() {
        let start = lock.withLock { () -> Bool in
            guard !pumping, state == .ready, hasWork else { return false }
            pumping = true
            return true
        }
        if start { queue.async { self.pump() } }
    }

    /// Under the lock: the history's open, or was a moment ago.
    private var inUse: Bool { CACurrentMediaTime() - lastUsed < Self.idleTime }

    /// Under the lock: there's something for the model to do now, loading first if it's out.
    private var hasWork: Bool {
        if pendingQuery != nil || (!loaded && inUse) { return true }
        if !pendingClips.isEmpty, loaded || inUse || pendingClips.count >= Self.wakeBacklog { return true }
        return filesReady
    }

    /// Under the lock: a file waiting will go now or within `pacedGap` (not one waiting for the Mac to go idle).
    private func filesSoon(_ pace: FilePace) -> Bool {
        guard let next = pendingFiles.first, pace != .no else { return false }
        return next.tier != .background || pace == .fast
    }

    /// Under the lock: the next file may go now (just opened; recent, as its pace allows; the rest, only fast).
    private var filesReady: Bool {
        guard let next = pendingFiles.first else { return false }
        let pace = filesPace()
        switch next.tier {
        case .opened: return pace != .no
        case .recent: return pace != .no && CACurrentMediaTime() >= filesResumeAt
        case .background: return pace == .fast
        }
    }

    private enum Job {
        case query(String, @Sendable ([Float]?) -> Void)
        case typicalQuery
        case texts([(id: Int64, text: String)])
        /// A picture or copied files: one clip through an encoder.
        case one(id: Int64, Input)
        /// A recent file, for search (or more of its pieces).
        case file(FileWork)
    }

    /// On `queue`: the model in, if it's out; queries first, then clips a few at a time, until there's nothing left.
    private func pump() {
        if embedder == nil, !load() { return }
        defer { scheduleSleep() }
        while let job = nextJob() {
            guard let embedder else { break }
            switch job {
            case .query(let prompt, let done):
                answer(prompt, done, embedder)
            case .typicalQuery:
                let started = CACurrentMediaTime()
                let prompts = (Prompts.typicalQueries + Prompts.typicalWords).map(Prompts.query)
                let vectors = (try? embedder.embed(prompts)) ?? []
                guard vectors.count == prompts.count else {
                    log("typical query failed: \(vectors.count) of \(prompts.count) vectors")
                    break
                }
                let phrases = Array(vectors.prefix(Prompts.typicalQueries.count))
                let words = Array(vectors.dropFirst(Prompts.typicalQueries.count))
                lock.withLock { typicalQuery = (phrases, words) }
                log(String(format: "typical query made in %.0f ms", (CACurrentMediaTime() - started) * 1000))
                let onTypicalQuery = self.onTypicalQuery
                DispatchQueue.main.async { MainActor.assumeIsolated { onTypicalQuery(phrases, words) } }
            case .texts(let batch):
                var vectors = (try? embedder.embed(batch.map { Prompts.document($0.text) })) ?? []
                if vectors.count != batch.count {
                    // One bad input mustn't sink the batch: one at a time, skipping what fails.
                    vectors = []
                    for clip in batch {
                        vectors.append((try? embedder.embed([Prompts.document(clip.text)]).first) ?? [])
                    }
                }
                let made = zip(batch, vectors).filter { !$0.1.isEmpty }
                    .map { Made(id: $0.0.id, vector: $0.1, fromContent: false) }
                deliver(made, done: batch.map(\.id))
            case .one(let key, .fileParts(let parts)):
                var vectors: [[Float]] = []
                for part in parts {
                    answerWaitingQuery(embedder)   // a file can take half a second: a query doesn't wait for them all
                    let name: String? = if case .text(let name) = part { name } else { part.fallback }
                    if let vector = contentVector(part, embedder) {
                        vectors.append(vector)
                    } else if let name, let vector = try? embedder.embed([Prompts.document(name)]).first {
                        vectors.append(vector)
                    } else {
                        vectors.append([Float](repeating: 0, count: ModelFiles.dimension))   // in its place, matching nothing
                    }
                }
                deliver([Made(id: ~key, vector: [], fromContent: true, parts: vectors)], done: [key])
                closeEncodersNotNeeded(embedder)
            case .one(let key, .pieces(let prompts)):
                let started = CACurrentMediaTime()
                let vectors = embed(pieces: prompts, embedder)
                log(String(format: "%d pieces: %.0f ms", prompts.count, (CACurrentMediaTime() - started) * 1000))
                deliver([Made(id: ~key, vector: [], fromContent: true, parts: vectors)], done: [key])
            case .one(let id, let input):
                var made: Made?
                if let vector = contentVector(input, embedder) {
                    made = Made(id: id, vector: vector, fromContent: true)
                } else if let fallback = input.fallback, let vector = try? embedder.embed([Prompts.document(fallback)]).first {
                    made = Made(id: id, vector: vector, fromContent: false)
                }
                deliver(made.map { [$0] } ?? [], done: [id])
                closeEncodersNotNeeded(embedder)
            case .file(var work):
                let onFileVector = self.onFileVector
                let path = work.path
                let first = work.vector == nil
                if first { work.vector = contentVector(work.input, embedder) }
                if let vector = work.vector {
                    // A long document's pieces: all of them while the Mac is idle, a few a turn otherwise.
                    let take = filesPace() == .fast ? work.pieces.count : Self.piecesPerTurn
                    let upTo = min(work.pieces.count, work.next + take)
                    work.made += embed(pieces: Array(work.pieces[work.next..<upTo]), embedder)
                    work.next = upTo
                    if work.next < work.pieces.count {
                        // Searchable by its start meanwhile; the rest waits its turn (a just-opened one's, paced).
                        if first { DispatchQueue.main.async { MainActor.assumeIsolated { onFileVector(path, vector, nil) } } }
                        work.tier = max(work.tier, .recent)
                        lock.withLock {
                            guard !pendingFiles.contains(where: { $0.path == path }) else { return }   // changed since
                            let place = pendingFiles.firstIndex { $0.tier >= work.tier } ?? pendingFiles.count
                            pendingFiles.insert(work, at: place)
                        }
                    } else {
                        let pieces = work.made
                        if !pieces.isEmpty { log("\(pieces.count) pieces of a document read") }
                        DispatchQueue.main.async { MainActor.assumeIsolated { onFileVector(path, vector, pieces) } }
                    }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onFileVector(path, nil, []) } }
                }
                if filesPace() == .paced {   // the next one in a moment (unless it's just opened): queries and clips meanwhile
                    lock.withLock { filesResumeAt = CACurrentMediaTime() + Self.pacedGap }
                    queue.asyncAfter(deadline: .now() + Self.pacedGap) { self.schedule() }
                }
                closeEncodersNotNeeded(embedder)
            }
        }
    }

    private func answer(_ prompt: String, _ done: @Sendable ([Float]?) -> Void, _ embedder: LlamaEmbedder) {
        let vector = try? embedder.embed([prompt]).first
        if let vector { remember(prompt, vector) }
        done(vector)
    }

    /// On `queue`: pieces' vectors, a few to a batch, a waiting query answered between them; what fails is left out.
    private func embed(pieces prompts: [String], _ embedder: LlamaEmbedder) -> [[Float]] {
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: prompts.count, by: Self.piecesPerTurn) {
            answerWaitingQuery(embedder)
            let group = Array(prompts[start..<min(prompts.count, start + Self.piecesPerTurn)])
            if let made = try? embedder.embed(group), made.count == group.count {
                vectors += made
            } else {
                vectors += group.compactMap { try? embedder.embed([$0]).first }
            }
        }
        return vectors
    }

    private func answerWaitingQuery(_ embedder: LlamaEmbedder) {
        let waiting = lock.withLock { () -> (prompt: String, done: @Sendable ([Float]?) -> Void)? in
            defer { pendingQuery = nil }
            return pendingQuery
        }
        if let waiting { answer(waiting.prompt, waiting.done, embedder) }
    }

    /// Each encoder goes with the last clip or file waiting that needs it: kept between files only while more are
    /// being read and may go now (the reader can wait for the Mac to go idle for hours), and with 8 GB or less only
    /// while they go one after another.
    private func closeEncodersNotNeeded(_ embedder: LlamaEmbedder) {
        let pace = filesPace()
        let (coming, soon) = lock.withLock { (filesComing, filesSoon(pace)) }
        let filesNow = soon || (coming && pace != .no)
        let keep = (coming || soon) && (Self.smallMemory ? pace == .fast : pace != .no)
        let (images, sound) = lock.withLock {
            let inputs = pendingClips.map(\.input) + (filesNow ? pendingFiles.map(\.input) : [])
            return (keep || inputs.contains { $0.needsImages }, keep || inputs.contains { $0.needsSound })
        }
        if !images { embedder.closeImages() }
        if !sound { embedder.closeSound() }
    }

    private func deliver(_ made: [Made], done: [Int64]) {
        lock.withLock { for id in done { queued.remove(id) } }
        let onVectors = self.onVectors
        DispatchQueue.main.async { MainActor.assumeIsolated { onVectors(made) } }
    }

    /// On `queue`: a picture's or files' vector, the encoders they need loaded first; nil when they don't read or an
    /// encoder doesn't load (then this clip, and every one after it that needs it, goes by its text or names).
    private func contentVector(_ input: Input, _ embedder: LlamaEmbedder) -> [Float]? {
        if input.needsImages, !open(.images, embedder) { return nil }
        if input.needsSound, !open(.sound, embedder) { return nil }
        let started = CACurrentMediaTime()
        func took() -> Double { (CACurrentMediaTime() - started) * 1000 }
        switch input {
        case .text:
            return nil
        case .picture(let url, let text, _):
            guard let pixels = ImagePixels(url: url, budget: Self.pictureBudget),
                  let vector = try? embedder.embed(image: pixels, prompt: Prompts.picture(marker: LlamaEmbedder.marker,
                                                                                           text: text)) else {
                log("picture \(url.lastPathComponent) didn't read")
                return nil
            }
            log(String(format: "picture %d×%d%@: %.0f ms", pixels.width, pixels.height,
                       text == nil ? "" : " with its text", took()))
            return vector
        case .fileParts, .pieces:
            return nil
        case .files(let prompt, let media, let summary, _):
            let vector = media.isEmpty ? (try? embedder.embed([prompt]))?.first : try? embedder.embed(media, prompt: prompt)
            guard let vector else {
                log("files (\(summary)) didn't read")
                return nil
            }
            log(String(format: "files (%@): %.0f ms", summary, took()))
            return vector
        }
    }

    private enum Encoder { case images, sound }

    /// On `queue`: the encoder in, if it isn't; false when it won't load (and isn't tried again this run).
    private func open(_ encoder: Encoder, _ embedder: LlamaEmbedder) -> Bool {
        if encoder == .images ? embedder.readsImages : embedder.readsSound { return true }
        let projector = lock.withLock {
            encoder == .images ? (picturesFailed ? nil : imageProjector) : (soundFailed ? nil : soundProjector)
        }
        guard let projector else { return false }
        do {
            if encoder == .images {
                try embedder.openImages(projector: projector)
                log(String(format: "image encoder loaded in %.2f s", embedder.imageLoadSeconds))
            } else {
                try embedder.openSound(projector: projector)
                log(String(format: "audio encoder loaded in %.2f s", embedder.soundLoadSeconds))
            }
            return true
        } catch {
            lock.withLock { if encoder == .images { picturesFailed = true } else { soundFailed = true } }
            log("\(encoder == .images ? "image" : "audio") encoder failed: \(error)")
            return false
        }
    }

    /// On `queue`. When it can't load, there's no meaning search: the waiting query gets nil, and words carry on.
    private func load() -> Bool {
        do {
            guard let model = lock.withLock({ self.model }) else { throw EmbedderError("no model") }
            let embedder = try LlamaEmbedder.best(model: model)
            self.embedder = embedder
            loads += 1
            let reason = lock.withLock { () -> String in
                loaded = true
                return pendingQuery != nil ? "for a query" : inUse ? "the history opened"
                    : "\(pendingClips.count) clips to read"
            }
            log("model on the \(embedder.device.rawValue.uppercased()), loaded in "
                + String(format: "%.2f s", embedder.loadSeconds) + " (\(loads == 1 ? "first" : "again"): \(reason))")
            return true
        } catch {
            let query = lock.withLock { () -> (@Sendable ([Float]?) -> Void)? in
                defer { pendingQuery = nil }
                pumping = false
                return pendingQuery?.done
            }
            query?(nil)
            set(.failed("\(error)"))
            return false
        }
    }

    /// On `queue`, with nothing left to do: the model goes once it has gone unused for `idleTime` (now, when it only
    /// came in to read a pile of clips).
    private func scheduleSleep() {
        let wait = lock.withLock { max(lastUsed + Self.idleTime, lingerUntil) - CACurrentMediaTime() }
        sleepTimer.schedule(deadline: .now() + max(wait, 0))
    }

    /// On `queue`.
    private func sleepIfUnused() {
        enum Verdict { case sleep, later, soon, busy }
        var unused: CFTimeInterval = 0
        // Between recent files, while more are being read and may be embedded, it stays (else it went and came back
        // for each one the reader was slower than it).
        let pace = filesPace()
        let (coming, soon) = lock.withLock { (filesComing, filesSoon(pace)) }
        let filesNext = soon || (coming && pace != .no)
        let verdict = lock.withLock { () -> Verdict in
            guard loaded, !pumping else { return .busy }   // out already, or the pump schedules this again
            guard !inUse, CACurrentMediaTime() >= lingerUntil else { return .later }
            if filesNext { return .soon }
            loaded = false
            unused = CACurrentMediaTime() - lastUsed
            return .sleep
        }
        switch verdict {
        case .busy: return
        case .later: return scheduleSleep()
        case .soon: return sleepTimer.schedule(deadline: .now() + 2)
        case .sleep:
            embedder?.close()
            embedder = nil
            log(unused.isFinite ? String(format: "model unloaded: the history unused for %.0f s", unused)
                : "model unloaded: the history not opened since launch")
        }
    }

    private func nextJob() -> Job? {
        lock.withLock {
            if let query = pendingQuery {
                pendingQuery = nil
                return .query(query.prompt, query.done)
            }
            if typicalQuery == nil, !typicalQueryTried {
                typicalQueryTried = true
                return .typicalQuery
            }
            if pendingClips.isEmpty {
                guard filesReady else {
                    pumping = false
                    return nil
                }
                return .file(pendingFiles.removeFirst())
            }
            if case .text = pendingClips[0].input {} else {
                let next = pendingClips.removeFirst()
                return .one(id: next.id, next.input)
            }
            var batch: [(id: Int64, text: String)] = []
            var characters = 0
            while let next = pendingClips.first, case .text(let text) = next.input, batch.count < Self.batchClips,
                  batch.isEmpty || characters + text.count <= Self.batchCharacters {
                batch.append((pendingClips.removeFirst().id, text))
                characters += text.count
            }
            return .texts(batch)
        }
    }

    private func remember(_ prompt: String, _ vector: [Float]) {
        lock.withLock {
            if cache[prompt] == nil { cacheOrder.append(prompt) }
            cache[prompt] = vector
            if cacheOrder.count > Self.cacheSize { cache[cacheOrder.removeFirst()] = nil }
        }
    }
}
