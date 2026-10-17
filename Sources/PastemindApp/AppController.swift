import AppKit
import LlamaRuntime
import QuickLookUI
import PastemindKit

/// Owns everything: the store and its in-memory index, the model, the clipboard watcher, the hotkey, the panel and the
/// menu bar item.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var store: ClipStore!
    let index = ClipIndex()
    private(set) var engine: EmbeddingEngine!
    /// Recent files by what's in them, for search.
    private(set) var files: FileIndexer!
    private let watcher = ClipboardWatcher()
    let hotkeys = HotkeyCenter()
    /// The one window the clipboard history and search show in, as two modes of one panel.
    private var host: PanelHost!
    private var panel: PanelController!
    private var launcher: LauncherController!
    /// Quick Look is search's (see `beginPreviewPanelControl`).
    private var searchLooks = false
    private var settings: SettingsWindowController!
    private var welcome: WelcomeWindowController!
    /// Sparkle: new versions from GitHub Releases.
    private(set) var updater: Updater!
    private var statusItem: NSStatusItem!
    private var download: ModelDownload?
    /// When each item was last opened from search (read once, again after each launch).
    private var lastOpened: [String: Date]?
    private var pruneTimer: Timer?
    /// The snippets (a few dozen at most): in memory, written through to the store.
    private(set) var snippets: [Snippet] = []
    private(set) var snippetFolders: [SnippetFolder] = []
    /// The clipboard history is turning into search (its body fading): hotkeys wait for it.
    private var switching = false
    private(set) var modelState = EmbeddingEngine.State.idle
    private(set) var downloadProgress: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try AppPaths.prepare()
            store = try ClipStore()
            index.load(try store.all(), vectors: try store.vectors(), parts: try store.parts())
            snippets = try store.snippets()
            snippetFolders = try store.snippetFolders()
        } catch {
            fail("Pastemind can't open its history at \(AppPaths.database.path): \(error)")
            return
        }
        Task.detached(priority: .utility) { Pictures.makeMissingCopies() }
        try? FileManager.default.removeItem(at: QuickLook.codeFolder)   // code written for Quick Look last time
        try? FileManager.default.removeItem(at: PictureFiles.folder)    // pictures dragged or pasted as files last time
        measurePictures()
        let (fileClips, keptBytes) = (fileClips, Settings.keptFilesMegabytes << 20)
        KeptFiles.queue.async {
            KeptFiles.removeAll(except: Set(fileClips.map(\.id)))
            if keptBytes > 0 { KeptFiles.keepEarlier(fileClips, maxBytes: keptBytes) }
        }
        engine = EmbeddingEngine(
            onVectors: { [weak self] vectors in self?.received(vectors) },
            onFileVector: { [weak self] path, vector, pieces in self?.files.received(path, vector, pieces: pieces) },
            filesPace: { FilePolicy.pace() },
            onState: { [weak self] state in self?.modelStateChanged(state) },
            onTypicalQuery: { [weak self] phrases, words in
                self?.index.setTypical(phrases: phrases, words: words)
                self?.files.index.setTypical(phrases: phrases, words: words)
            })
        files = FileIndexer(app: self, store: store, engine: engine)
        host = PanelHost(height: max(PanelController.height, LauncherController.maxHeight))
        panel = PanelController(app: self, host: host)
        launcher = LauncherController(app: self, host: host)
        updater = Updater()
        settings = SettingsWindowController(app: self)
        welcome = WelcomeWindowController(app: self)
        watcher.onCapture = { [weak self] capture, source in self?.record(capture, from: source) }
        watcher.onIncoming = { [weak self] source in self?.setIncoming(source) }
        watcher.start()
        makeStatusItem()
        updateStatusItem()
        makeMainMenu()
        hotkeys.handle(.clipboard) { [weak self] in self?.toggleClipboard() }
        hotkeys.handle(.search) { [weak self] in self?.toggleSearch() }
        applyHotkeys()
        prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        startModel()
        // A new install: the welcome, once (an update with a history has no need of it).
        if !Settings.welcomed, !DebugHooks.enabled {
            Settings.welcomed = true
            if index.count == 0 { welcome.showFirstTime() }
        }
        DebugHooks.install(panel: panel, launcher: launcher, settings: settings, welcome: welcome, app: self) { [weak self] action in
            action == .search ? self?.toggleSearch() : self?.toggleClipboard()
        }
        if ProcessInfo.processInfo.arguments.contains("--show") { panel.show() }
        log("ready: \(index.count) clips, \(index.embeddedCount) with vectors; hotkeys "
            + HotkeyCenter.Action.allCases.map { "\($0.rawValue) \(hotkeyDisplay($0))" }.joined(separator: ", "))
    }

    // MARK: Model

    /// The text model, then the image encoder: each from disk, or downloaded (words meanwhile; then meaning, the
    /// pictures by their text until the encoder's there).
    private func startModel() {
        if let pictures = ModelFiles.pictures.located { engine.preparePictures(pictures) }
        if let sound = ModelFiles.sound.located { engine.prepareSound(sound) }
        if let model = ModelFiles.text.located {
            engine.prepare(model)
            downloadPictureModel()
            return
        }
        fetch(ModelFiles.text) { [weak self] url in
            self?.engine.prepare(url)
            self?.downloadPictureModel()
        }
    }

    private func downloadPictureModel() {
        guard ModelFiles.pictures.located == nil else { return }
        fetch(ModelFiles.pictures) { [weak self] url in
            guard let self else { return }
            engine.preparePictures(url)
            embedMissing()   // the pictures again, by what's in them
            files.encodersArrived()
        }
    }

    /// An audio file to read: the audio encoder (328 MB) comes now, the first time one's wanted.
    func needSound() {
        guard ModelFiles.sound.located == nil, download?.file.name != ModelFiles.sound.name,
              !waitingDownloads.contains(where: { $0.file.name == ModelFiles.sound.name }) else { return }
        fetch(ModelFiles.sound) { [weak self] url in
            guard let self else { return }
            engine.prepareSound(url)
            embedMissing()   // copied recordings again, by what's said in them
            files.encodersArrived()
        }
    }

    /// One download at a time; the rest wait their turn.
    private var waitingDownloads: [(file: ModelFile, done: @MainActor (URL) -> Void)] = []

    private func fetch(_ file: ModelFile, then done: @escaping @MainActor (URL) -> Void) {
        guard download == nil else {
            waitingDownloads.append((file, done))
            return
        }
        let download = ModelDownload(file,
            onProgress: { [weak self] fraction in
                self?.downloadProgress = fraction
                self?.panel.statusChanged()
            },
            onFinish: { [weak self] result in
                guard let self else { return }
                self.download = nil
                self.downloadProgress = nil
                switch result {
                case .success(let url): done(url)
                case .failure(let error) where file.name == ModelFiles.text.name:
                    modelStateChanged(.failed("download failed: \(error.localizedDescription)"))
                case .failure(let error):   // tried again next launch (or need); pictures go by their text meanwhile
                    log("\(file.name) download failed: \(error.localizedDescription)")
                }
                panel.statusChanged()
                if !waitingDownloads.isEmpty {
                    let next = waitingDownloads.removeFirst()
                    fetch(next.file, then: next.done)
                }
            })
        self.download = download
        download.start()
        panel.statusChanged()
    }

    /// Where one of the model's files is: on disk, coming, waiting for the one coming, or not come (the text model's
    /// download failed).
    enum ModelProgress: Equatable {
        case ready, downloading(Double), waiting, failed
    }

    func progress(of file: ModelFile) -> ModelProgress {
        if download?.file.name == file.name { return .downloading(downloadProgress ?? 0) }
        if file.located != nil { return .ready }
        if file.name == ModelFiles.text.name, case .failed = modelState { return .failed }
        return .waiting
    }

    /// The text model's download tried again (it failed).
    func retryModel() {
        guard case .failed = modelState, ModelFiles.text.located == nil, download == nil else { return }
        modelState = .idle
        startModel()
    }

    private func modelStateChanged(_ state: EmbeddingEngine.State) {
        modelState = state
        if state == .ready {
            embedMissing()
            files.start()
        } else if case .failed(let message) = state {
            log("model failed: \(message)")
        }
        panel.statusChanged()
    }

    /// Search's meaning matches among recent files (`limit` of them), or none: search by contents is off, nothing's
    /// been read yet, or the query's too short to mean anything.
    func fileMatches(for words: String, limit: Int) async -> [LaunchItem] {
        guard Settings.searchFileContents == true, words.count >= 3, files.count > 0, modelState == .ready,
              let vector = await engine.query(words) else { return [] }
        return files.matches(for: vector, oneWord: !words.trimmingCharacters(in: .whitespaces).contains(" "), limit: limit)
    }

    /// Search by contents turned on or off (in Settings, or search's offer).
    func setFileSearch(_ on: Bool) {
        guard Settings.searchFileContents != on else { return }
        Settings.searchFileContents = on
        files.enabledChanged()
    }

    /// Every clip without the vector it should have: none yet, or a picture's from its text alone while the image
    /// encoder can read it.
    private func embedMissing() {
        let before = engine.queuedCount
        for clip in index.clips { embed(clip) }
        log("model on disk\(engine.readsPictures ? ", pictures too" : ""); "
            + "\(engine.queuedCount - before) clips to embed")
    }

    private func received(_ vectors: [EmbeddingEngine.Made]) {
        for made in vectors {
            guard var clip = index.clip(id: made.id) else { continue }
            if let parts = made.parts {
                try? store.setParts(id: made.id, parts)
                index.setParts(parts, for: made.id)
                continue
            }
            try? store.setVector(id: made.id, vector: made.vector, fromContent: made.fromContent)
            index.setVector(made.vector, for: made.id)
            if clip.contentVector != made.fromContent {
                clip.contentVector = made.fromContent
                index.update(clip)
            }
        }
        panel.statusChanged()
    }

    // MARK: Recording

    /// The last text copied, and when: the next copy may redo it (`RedoneCopy`).
    private var lastTextCopy: (id: Int64, at: Date)?

    /// A copy on its way into the history (an app still writing it, a picture being saved): the history shows it at
    /// once, as a row of its own, until it's there.
    private(set) var incoming: CaptureSource?
    /// The picture being saved that `incoming` stands for: an earlier one's saving doesn't take it away.
    private var incomingPicture = 0

    private func setIncoming(_ source: CaptureSource?) {
        guard source != incoming else { return }
        incoming = source
        panel.historyChanged()
    }

    private func record(_ capture: Capture, from source: CaptureSource) {
        if case .image = capture {} else { setIncoming(nil) }
        switch capture {
        case .text(let text, let rich):
            let kind = ClipClassifier.kind(of: text)
            let previous = lastTextCopy
            guard let clip = save(kind: kind, text: text, hash: ClipClassifier.hash(kind: kind, text: text),
                                  source: source, rich: rich) else { return }
            lastTextCopy = (clip.id, Date())
            // The selection redone: the copy before goes, this one in its place.
            if Settings.mergesRedoneCopies, let previous, previous.id != clip.id,
               Date().timeIntervalSince(previous.at) < RedoneCopy.window,
               let old = index.clip(id: previous.id), !old.pinned, RedoneCopy.redoes(old.text, with: clip.text) {
                delete(old)
            }
        case .files(let urls):
            let text = urls.map(\.path).joined(separator: "\n")
            let hash = ClipClassifier.hash(kind: .file, text: text)
            guard urls.count == 1, Clip.isPicture(path: text) else {
                save(kind: .file, text: text, hash: hash, source: source)
                return
            }
            // A picture file is titled by its size, as a copied picture is: its header read off the main thread.
            Task.detached(priority: .userInitiated) {
                let size = Pictures.measure(urls[0])
                await MainActor.run {
                    _ = self.save(kind: .file, text: text, hash: hash, source: source, width: size?.width,
                                  height: size?.height, bytes: size?.bytes)
                }
            }
        case .image(let data, let ext):
            // Hashing and writing a big screenshot take a moment: off the main thread, the row there meanwhile.
            incomingPicture += 1
            let picture = incomingPicture
            setIncoming(source)
            Task.detached(priority: .userInitiated) {
                let saved = try? Pictures.save(data, ext: ext)
                await MainActor.run {
                    // The clip takes its row's place in the same refresh.
                    if picture == self.incomingPicture { self.incoming = nil }
                    guard let saved else { return self.panel.historyChanged() }
                    let clip = self.save(kind: .image, text: "", hash: "image:\(saved.hash)", source: source,
                                         image: saved.name, width: saved.width, height: saved.height,
                                         bytes: saved.bytes)
                    if let clip, clip.text.isEmpty { self.readText(of: clip) }
                }
                if let name = saved?.name { Pictures.makeCopies(name) }
            }
        }
    }

    @discardableResult
    private func save(kind: ClipKind, text: String, hash: String, source: CaptureSource,
                      rich: (data: Data, type: String)? = nil, image: String? = nil, width: Int? = nil,
                      height: Int? = nil, bytes: Int? = nil) -> Clip? {
        do {
            let recorded = try store.record(kind: kind, text: text, hash: hash, appID: source.appID,
                                            appName: source.appName, image: image, width: width, height: height,
                                            bytes: bytes, rich: rich?.data, richType: rich?.type)
            index.upsert(recorded.clip)
            if kind == .file { keepFiles(of: recorded.clip) }
            // A new picture's vector waits for Vision to read its text (readText).
            if !(kind == .image && recorded.clip.text.isEmpty) { embed(recorded.clip) }
            panel.historyChanged()
            return recorded.clip
        } catch {
            log("can't record a copy: \(error)")
            return nil
        }
    }

    /// The file clips, and where their files were copied from: for their copies (`KeptFiles`).
    var fileClips: [(id: Int64, urls: [URL])] {
        index.clips.filter { $0.kind == .file }.map { ($0.id, $0.copiedURLs) }
    }

    /// Pastemind's copy of a clip's files (`KeptFiles`), so it still pastes them once they're moved or deleted; made
    /// again on each copy (they may have changed), and dropped if the clip went meanwhile.
    private func keepFiles(of clip: Clip) {
        let (id, text, urls, limit) = (clip.id, clip.text, clip.copiedURLs, Settings.keptFilesMegabytes << 20)
        guard limit > 0 else { return }   // off in Settings
        KeptFiles.queue.async {
            KeptFiles.keep(urls, for: id, maxBytes: limit)
            Task { @MainActor in
                guard self.index.clip(id: id)?.text != text else { return }
                KeptFiles.queue.async { KeptFiles.remove([id]) }
            }
        }
    }

    /// Pictures, and picture files, saved before their sizes were kept (the list shows them): measured once, in the
    /// background. A picture file that's gone stays as it was.
    private func measurePictures() {
        guard let pictures = try? store.unmeasuredPictures(), !pictures.isEmpty else { return }
        Task.detached(priority: .utility) {
            let sizes = pictures.compactMap { picture -> (id: Int64, width: Int?, height: Int?, bytes: Int)? in
                let url = picture.image.map { AppPaths.images.appendingPathComponent($0) } ?? picture.fileURLs.first
                guard let url, let size = Pictures.measure(url) else { return nil }
                return (picture.id, size.width, size.height, size.bytes)
            }
            await MainActor.run {
                for size in sizes {
                    try? self.store.setSize(id: size.id, width: size.width, height: size.height, bytes: size.bytes)
                    guard var clip = self.index.clip(id: size.id) else { continue }
                    (clip.width, clip.height, clip.bytes) = (clip.width ?? size.width, clip.height ?? size.height,
                                                             size.bytes)
                    self.index.update(clip)
                }
                self.panel.historyChanged()
            }
        }
    }

    private func readText(of clip: Clip) {
        guard let name = clip.image else { return }
        let url = AppPaths.images.appendingPathComponent(name)
        Task.detached(priority: .utility) {
            let text = Pictures.text(in: url)
            await MainActor.run {
                guard var current = self.index.clip(id: clip.id) else { return }
                if !text.isEmpty {
                    try? self.store.setText(id: clip.id, text: text)
                    current.text = text
                    current.embedded = false
                    current.contentVector = false
                    self.index.update(current)
                    self.panel.historyChanged()
                }
                self.embed(current)
            }
        }
    }

    /// Into the model's queue, if it hasn't the vector it should: a picture by what's in it (with its text, when
    /// there's enough of it) once the image encoder's there, by its text until then; files by their contents.
    private func embed(_ clip: Clip) {
        if clip.kind == .file {
            if !clip.contentVector { readFiles(of: clip) }
            if clip.fileURLs.count > 1, !index.hasParts(clip.id) { readEachFile(of: clip) }
            if clip.fileURLs.count == 1, let url = clip.fileURLs.first, CopiedFiles.hasPieces(url), !index.hasParts(clip.id) {
                readPieces(of: clip, url)
            }
            return
        }
        if clip.kind == .image, engine.readsPictures, let name = clip.image {
            guard !clip.contentVector else { return }
            let picture = AppPaths.images.appendingPathComponent(name)
            engine.enqueue([(clip.id, .picture(picture, text: clip.textBesidePicture, fallback: clip.embeddingText))])
            return
        }
        guard !index.hasVector(clip.id), let text = clip.embeddingText else { return }
        engine.enqueue([(clip.id, .text(text))])
    }

    /// Copied files by what's in them, read off the main thread; by their names when nothing in them reads (gone,
    /// private, only in iCloud, a kind with nothing to read).
    private func readFiles(of clip: Clip) {
        let urls = clip.fileURLs
        if !engine.readsSound, urls.contains(where: { RecentFiles.group(of: $0.pathExtension.lowercased()) == "audio" }) {
            needSound()
        }
        let (pictures, sound) = (engine.readsPictures, engine.readsSound)
        Task.detached(priority: .utility) {
            let contents = await CopiedFileReader.read(urls, pictures: pictures, sound: sound,
                                                       budget: EmbeddingEngine.pictureBudget)
            await MainActor.run {
                guard let current = self.index.clip(id: clip.id) else { return }
                if let contents {
                    self.engine.enqueue([(current.id, .files(prompt: contents.prompt, media: contents.media,
                                                             summary: contents.summary, fallback: current.embeddingText))])
                } else if !self.index.hasVector(current.id), let names = current.embeddingText {
                    self.engine.enqueue([(current.id, .text(names))])
                }
            }
        }
    }

    /// Several copied files one at a time, a vector of each (`CopiedFiles.maxParts`). Once the encoders they need are
    /// there: made before, a file's pictures or sound would go by its name for good.
    private func readEachFile(of clip: Clip) {
        let urls = Array(clip.fileURLs.prefix(CopiedFiles.maxParts))
        let audio = urls.contains { RecentFiles.group(of: $0.pathExtension.lowercased()) == "audio" }
        if audio, !engine.readsSound { return needSound() }
        guard engine.readsPictures else { return }
        let sound = engine.readsSound
        Task.detached(priority: .utility) {
            var parts: [EmbeddingEngine.Input] = []
            for url in urls {
                let name = url.lastPathComponent
                if let contents = await CopiedFileReader.read([url], pictures: true, sound: sound,
                                                              budget: EmbeddingEngine.pictureBudget) {
                    parts.append(.files(prompt: contents.prompt, media: contents.media,
                                        summary: "\(name): \(contents.summary)", fallback: name))
                } else {
                    parts.append(.text(name))   // nothing in it reads: by its name
                }
            }
            await MainActor.run {
                guard self.index.clip(id: clip.id) != nil else { return }
                self.engine.enqueue([(clip.id, .fileParts(parts))])
            }
        }
    }

    /// A long copied document's pieces past its start, a vector each (`CopiedFiles.pieces`); none, for a short one, is
    /// kept too: it isn't read again.
    private func readPieces(of clip: Clip, _ url: URL) {
        Task.detached(priority: .utility) {
            let pieces = FileIndexer.pieces(of: url)
            await MainActor.run {
                guard self.index.clip(id: clip.id) != nil, !self.index.hasParts(clip.id) else { return }
                if pieces.isEmpty {
                    try? self.store.setParts(id: clip.id, [])
                    self.index.setParts([], for: clip.id)
                } else {
                    self.engine.enqueue([(clip.id, .pieces(pieces))])
                }
            }
        }
    }

    // MARK: Actions from the panel

    /// Puts the clip on the pasteboard and moves it to the top of the history.
    func copy(_ clip: Clip, plain: Bool) {
        let rich = plain || !Settings.pasteRich ? nil : (try? store.rich(id: clip.id)) ?? nil
        Paster.write(clip, rich: rich)
        watcher.skipCurrent()
        markUsed(clip)
    }

    /// Pasted, or dragged into an app: the newest copy now, at the top of the history.
    func markUsed(_ clip: Clip) {
        let now = Date()
        try? store.touch(id: clip.id, at: now)
        var moved = clip
        moved.lastCopied = now
        moved.copies += 1
        index.upsert(moved)
        panel.historyChanged()
    }

    // MARK: Snippets

    func addSnippet(title: String, text: String, folder: Int64? = nil) -> Snippet? {
        guard let snippet = try? store.addSnippet(title: title, text: text, folder: folder) else { return nil }
        snippets.append(snippet)
        return snippet
    }

    func addSnippetFolder(name: String) -> SnippetFolder? {
        guard let folder = try? store.addSnippetFolder(name: name) else { return nil }
        snippetFolders.append(folder)
        return folder
    }

    func renameSnippetFolder(_ folder: SnippetFolder) {
        guard let index = snippetFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        snippetFolders[index] = folder
        try? store.renameSnippetFolder(id: folder.id, name: folder.name)
    }

    /// Its snippets stay, out of it.
    func deleteSnippetFolder(_ folder: SnippetFolder) {
        snippetFolders.removeAll { $0.id == folder.id }
        for index in snippets.indices where snippets[index].folder == folder.id { snippets[index].folder = nil }
        try? store.deleteSnippetFolder(id: folder.id)
    }

    func updateSnippet(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        try? store.updateSnippet(snippet)
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        try? store.deleteSnippet(id: snippet.id)
    }

    /// Dragged into a new order: these snippets (the ones side by side: a folder's, or the ones in none) in it.
    func orderSnippets(_ ids: [Int64]) {
        for (index, id) in ids.enumerated() {
            if let found = snippets.firstIndex(where: { $0.id == id }) { snippets[found].position = Double(index) }
        }
        try? store.orderSnippets(ids)
    }

    /// Dragged into a new order: the folders in it.
    func orderSnippetFolders(_ ids: [Int64]) {
        for (index, id) in ids.enumerated() {
            if let found = snippetFolders.firstIndex(where: { $0.id == id }) { snippetFolders[found].position = Double(index) }
        }
        try? store.orderSnippetFolders(ids)
    }

    /// Before every snippet: where one moved into another folder goes, first there.
    var firstSnippetPosition: Double { (snippets.map(\.position).min() ?? 0) - 1 }

    /// Onto the pasteboard as plain text, without becoming a clip of the history.
    func copy(_ snippet: Snippet) {
        Paster.write(Clip(id: -1, kind: .text, text: snippet.text), rich: nil)
        watcher.skipCurrent()
        markUsed(snippet)
    }

    /// Pasted, or dragged into an app: it counts as pasted once more (it stays where it was put in the list).
    func markUsed(_ snippet: Snippet) {
        let now = Date()
        try? store.useSnippet(id: snippet.id, at: now)
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index].lastUsed = now
            snippets[index].uses += 1
        }
    }

    func delete(_ clip: Clip) {
        removeFiles((try? store.delete(ids: [clip.id])) ?? [], of: [clip.id])
        index.remove([clip.id])
        panel.historyChanged()
    }

    func togglePin(_ clip: Clip) {
        var changed = clip
        changed.pinned.toggle()
        try? store.setPinned(id: clip.id, changed.pinned)
        index.update(changed)
        panel.historyChanged()
    }

    func rich(of clip: Clip) -> (data: Data, type: String)? {
        (try? store.rich(id: clip.id)) ?? nil
    }

    /// Deleted clips' pictures, and their copies of files.
    private func removeFiles(_ images: [String], of ids: [Int64]) {
        for name in images { Pictures.remove(name) }
        KeptFiles.queue.async { KeptFiles.remove(ids) }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(Settings.historyDays) * 86_400)
        guard let ids = try? store.expired(before: cutoff, keep: Settings.maxClips), !ids.isEmpty else { return }
        removeFiles((try? store.delete(ids: ids)) ?? [], of: ids)
        index.remove(Set(ids))
        panel.historyChanged()
        log("pruned \(ids.count) clips")
    }

    // MARK: Hotkeys

    func applyHotkeys() {
        // A debug run takes no global hotkeys: they'd fire alongside the installed Pastemind's (pastemindctl's "hotkey"
        // command presses them instead).
        guard !DebugHooks.enabled else { return }
        hotkeys.apply([.clipboard: Settings.hotkey(.clipboard), .search: Settings.hotkey(.search)])
    }

    func hotkeyDisplay(_ action: HotkeyCenter.Action) -> String {
        hotkeys.combos[action]?.display ?? ""
    }

    /// The clipboard hotkey: closes the clipboard history if it's up; switches search into it in place (the field
    /// stays where it is, with what was typed, and the history appears under it); or opens it.
    private func toggleClipboard() {
        guard !switching else { return }   // a second press while the history turns into search
        if panel.isVisible { return panel.hide() }
        showClipboard()
    }

    /// The search hotkey: the same, the other way round (the history's body goes, the field stays).
    private func toggleSearch() {
        guard !switching else { return }
        if launcher.isVisible { return launcher.hide() }
        showSearch()
    }

    /// From search: the history takes search's place at search's height and grows its body in (Motion). The new
    /// panel shows first, then the old one goes, so no frame is without a panel.
    /// The clipboard history in search's place (its Clipboard button, ⌘3).
    func switchToClipboard() { showClipboard() }

    private func showClipboard() {
        guard let anchor = launcher.topCenter, let size = launcher.currentSize else { return panel.show() }
        // Search lets go of the window as the history takes it.
        panel.show(query: launcher.typedWords, topCenter: anchor, growingFrom: size, fromSymbol: launcher.symbol,
                   fromPlaceholder: launcher.placeholder)
    }

    /// From the history: its body fades as it turns into search's shape (search's width, the height its results will
    /// take) and symbol, then search takes its place and its results come in.
    private func showSearch() {
        guard let anchor = panel.topCenter else { return launcher.show() }
        let carried = panel.query
        let opening = launcher.opening(for: carried)
        switching = true
        panel.collapse(toHeight: opening.height, symbol: opening.symbol, placeholder: opening.placeholder) {
            [weak self] motion in
            guard let self else { return }
            self.switching = false
            self.launcher.completeTakeover(motion: motion)   // the history lets go of the window as search takes it
        }
        // Before the first frame (the motion starts with it, so this only holds it back a few ms): done a frame in,
        // its ~30 ms cost the motion three frames, a jump.
        launcher.beginTakeover(query: carried, topCenter: anchor)
        // Should the switch be cut short (the history closed some other way), hotkeys mustn't stay ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.switching = false }
    }

    /// A key while the history folds into search, which hasn't the keyboard yet: what it types goes into search's field.
    func typeDuringSwitch(_ event: NSEvent) { launcher.typeDuringTakeover(event) }

    /// The history went (Esc, a click elsewhere) while folding into search: search, set up invisible over it and
    /// waiting to take its place without the keyboard yet, goes too (else, still "up", the next press hid it).
    func historyHid() {
        guard launcher.isTakingOver else { return }
        switching = false
        launcher.hide()
    }

    // MARK: Launcher learning

    func launchHistory(for query: String) -> LaunchHistory {
        if lastOpened == nil { lastOpened = (try? store.lastOpened()) ?? [:] }
        return LaunchHistory(picks: (try? store.picks(for: query)) ?? [:], opened: lastOpened ?? [:])
    }

    func recordLaunch(query: String, item: String) {
        try? store.recordLaunch(query: query, item: item)
        lastOpened = nil
    }

    // MARK: Quick Look

    // Quick Look's controller: here, at the end of every window's responder chain, it's found whichever window has the
    // key. In the history's window, Quick Look looked from itself (it takes the key as it opens) on a quick reopen,
    // found none, and showed "No items selected". It calls these on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { self.panel != nil }
    }

    // Search's while search is up (it asked), else the clipboard history's; let go of by the one it was given to.
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            searchLooks = launcher.isVisible
            (searchLooks ? launcher.quickLook : self.panel.quickLook).begin(panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if searchLooks { launcher.quickLookEnded(panel) } else { self.panel.quickLookEnded(panel) }
        }
    }

    // MARK: Menu bar

    /// Shows or hides the menu bar icon, as Settings says (`visible` overrides it in debug runs, unsaved).
    func updateStatusItem(visible: Bool? = nil) {
        statusItem.isVisible = visible ?? Settings.showMenuBarIcon
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.close()
    }

    /// Opening Pastemind while it runs (from Finder, Spotlight or its own search) brings up Settings: the way back when
    /// the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// A main menu, never shown (an accessory app has no menu bar), for Quick Look: what's selected of a picture's text
    /// there (Live Text) is copied by Edit → Copy, as in Finder. The preview is drawn, and its text selected, in a
    /// process of its own, and ⌘C reaches it only through a menu item. The panels take their edit keys themselves.
    private func makeMainMenu() {
        // Without AppKit's own additions to an Edit menu, which it otherwise adds again on each update.
        UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true,
                                                  "NSDisabledCharacterPaletteMenuItem": true])
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        for (title, submenu) in [("Pastemind", NSMenu(title: "Pastemind")), ("Edit", edit)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Pastemind")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        hotkeys.recheck()
        for (action, title, selector) in [(HotkeyCenter.Action.clipboard, "Clipboard History", #selector(openClipboard)),
                                          (.search, "Search", #selector(openSearch))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            if let combo = hotkeys.combos[action] {
                (item.keyEquivalent, item.keyEquivalentModifierMask) = combo.menuEquivalent
            }
            if hotkeys.problems[action] != nil {
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problem")
                item.toolTip = hotkeys.problems[action]
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let reading = files.progressLine {
            let line = NSMenuItem(title: reading.prefix(1).uppercased() + reading.dropFirst(), action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        let pause = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        pause.state = Settings.paused ? .on : .off
        menu.addItem(pause)
        if files.isOn {
            let reading = NSMenuItem(title: "Pause Reading Files", action: #selector(toggleFileReading), keyEquivalent: "")
            reading.state = Settings.filesPaused ? .on : .off
            menu.addItem(reading)
        }
        if !Paster.canPaste {
            menu.addItem(NSMenuItem(title: "Allow Auto-Paste…", action: #selector(allowPaste), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        if updater.isOn {
            menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Pastemind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    /// "1,204 clips · meaning search ready", for the menu and the panel.
    var statusLine: String {
        let clips = index.count == 1 ? "1 clip" : "\(index.count.formatted()) clips"
        return "\(clips) · \(modelLine)"
    }

    var modelLine: String {
        if let downloadProgress, download?.file.name == ModelFiles.text.name {
            return "downloading the model \(Int(downloadProgress * 100))%"
        }
        let line: String
        switch modelState {
        case .idle: line = "loading the model…"
        case .failed: line = "words only (the model didn't load)"
        case .ready:
            let backlog = engine.backlog
            line = backlog > 0 ? "reading \(backlog) clips…" : "meaning search ready"
        }
        guard let downloadProgress else { return line }
        let part = download?.file.name == ModelFiles.sound.name ? "sound" : "picture"
        return line + ", downloading the \(part) model \(Int(downloadProgress * 100))%"
    }

    @objc private func openClipboard() { showClipboard() }

    @objc private func openSearch() { showSearch() }

    @objc func openSettings() {
        panel.hide()
        launcher.hide()
        settings.show()
    }

    @objc private func togglePause() { Settings.paused.toggle() }

    @objc private func checkForUpdates() {
        panel.hide()
        launcher.hide()
        updater.checkNow()
    }

    @objc private func toggleFileReading() {
        Settings.filesPaused.toggle()
        files.pauseChanged()
    }

    @objc private func allowPaste() { Paster.requestAccess() }

    @objc private func clearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear the clipboard history?"
        alert.informativeText = "Every clip except pinned ones is deleted from this Mac. This can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearClips(since: nil)
    }

    /// The clips that clearing since `date` would delete (all of them for nil): not the pinned ones.
    func clearableClips(since date: Date?) -> [Clip] {
        index.clips.filter { clip in !clip.pinned && (date.map { clip.lastCopied >= $0 } ?? true) }
    }

    /// Deletes the unpinned clips copied since `date` (all of them for nil); returns how many went.
    @discardableResult
    func clearClips(since date: Date?) -> Int {
        let ids = clearableClips(since: date).map(\.id)
        guard !ids.isEmpty else { return 0 }
        removeFiles((try? store.delete(ids: ids)) ?? [], of: ids)
        index.remove(Set(ids))
        panel.historyChanged()
        return ids.count
    }

    private func fail(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Pastemind can't start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

/// One line on stderr (Console.app shows it for the bundled app), with a timestamp.
nonisolated func log(_ message: String) {
    let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    FileHandle.standardError.write(Data("[pastemind \(stamp)] \(message)\n".utf8))
}
