import AppKit
import IOKit.ps
import LlamaRuntime
import PastemindKit

/// Files by what's in them, for search, in three tiers (`EmbeddingEngine.FileTier`): a file you open, or one that's
/// saved or appears anywhere in the home folder (of the kinds the whole-home look reads), is read at once (Spotlight
/// tells of it in a second or two: `OpenedFiles`; past ten at once, they're read in turn); what changed or was opened in the last 60 days
/// (`RecentFiles.find`, looked for as files change, as search opens and every ten minutes) is read a file every couple
/// of seconds while you work; the rest of the home folder worth reading (`RecentFiles.everything`, looked for every six
/// hours) only while the Mac is idle on power. A long document has a vector of each piece past its start too
/// (`CopiedFiles.pieces`). Only the vectors are kept. Off until it's turned on (search offers it, or Settings), which
/// asks macOS for the Desktop, Documents and Downloads once.
final class FileIndexer {
    let index = FileIndex()
    private unowned let app: AppController
    private let store: ClipStore
    private let engine: EmbeddingEngine
    /// What's been read, by path (nothing read: no vector).
    private var known: [String: (file: IndexedFile, hasVector: Bool)] = [:]
    /// Read and waiting for the model: when they changed and were last opened, for when their vectors come.
    private var waiting: [String: RecentFiles.Candidate] = [:]
    /// Saved or appeared outside what the recent look covers since the last whole-home look, and when they were seen:
    /// read with the recent files, and kept till the next whole-home look has them.
    private var appeared: [String: (file: RecentFiles.Candidate, seen: Date)] = [:]
    /// The latest looks: the recent files, and the rest of the home folder (empty till the first full look).
    private var recent: [RecentFiles.Candidate] = []
    private var rest: [RecentFiles.Candidate] = []
    private var fullLook: Date?
    /// When the look under way began: its recent files are as they were then.
    private var scanStarted = Date.distantPast
    private var reading: Task<Void, Never>?
    private var scanning = false
    private var rescan = false
    private var watcher: FolderWatcher?
    private var opened: OpenedFiles?
    private var timers: [Timer] = []
    private var pendingScan: DispatchWorkItem?
    private var lastScan = Date.distantPast
    static let fullLookEvery: TimeInterval = 6 * 3600
    nonisolated private static let launched = Date()

    init(app: AppController, store: ClipStore, engine: EmbeddingEngine) {
        self.app = app
        self.store = store
        self.engine = engine
    }

    var count: Int { index.count }
    var isOn: Bool { Settings.searchFileContents == true }

    /// How far the reading is ("reading files: 4,200 of 21,000"), for the menu and Settings; nil when it's all read.
    var progressLine: String? {
        guard isOn else { return nil }
        let all = Set(recent.map(\.path) + rest.map(\.path))
        guard !all.isEmpty else { return nil }
        let done = all.filter { known[$0] != nil }.count
        guard done < all.count else { return nil }
        let line = "reading files: \(done.formatted()) of \(all.count.formatted())"
        return Settings.filesPaused ? line + " (paused)" : line
    }

    /// Once the model is on disk: what was read before, then a look for what's new.
    func start() {
        let rows = (try? store.indexedFiles()) ?? []
        // Read before it had to be turned on: it's on.
        if Settings.searchFileContents == nil, !rows.isEmpty { Settings.searchFileContents = true }
        index.load(rows.compactMap { row in row.vector.map { (row.file, $0) } },
                   pieces: Dictionary(rows.filter { !$0.pieces.isEmpty }.map { ($0.file.id, $0.pieces) },
                                      uniquingKeysWith: { first, _ in first }))
        // A document read before its pieces were (or while they were), or before the reader read what's in it (a scan
        // by OCR): read again, found as it was till then.
        let read = rows.filter { row in
            let url = URL(fileURLWithPath: row.file.path)
            return row.current && (row.piecesRead || row.vector == nil || !CopiedFiles.hasPieces(url))
                && !CopiedFiles.readAgain(url, readBy: row.reader, pieces: row.pieces.count)
        }
        known = Dictionary(read.map { ($0.file.path, ($0.file, $0.vector != nil)) }, uniquingKeysWith: { first, _ in first })
        log("files: \(index.count) by what's in them")
        guard isOn else { return }
        watch()
        scan()
    }

    /// Turned on (search's offer, Settings): macOS asked for the three folders it guards, once, together; then the
    /// first look. Off: nothing read is kept.
    func enabledChanged() {
        if isOn {
            Task.detached(priority: .userInitiated) {
                for folder in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
                    guard let url = FileManager.default.urls(for: folder, in: .userDomainMask).first else { continue }
                    _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)   // macOS asks here
                }
                await MainActor.run { self.start() }
            }
            return
        }
        reading?.cancel()
        reading = nil
        engine.dropFiles()
        engine.filesComing(false)
        waiting = [:]
        appeared = [:]
        recent = []
        rest = []
        fullLook = nil
        watcher = nil
        opened = nil
        timers.forEach { $0.invalidate() }
        timers = []
        try? store.deleteFiles(ids: known.values.map(\.file.id))
        known = [:]
        index.load([])
    }

    /// Paused or resumed from the menu.
    func pauseChanged() { engine.poke() }

    /// The image and audio encoders came: files nothing was read in (pictures, sound, previews) are read again.
    func encodersArrived() {
        guard isOn else { return }
        let unread = known.values.filter { !$0.hasVector }.map(\.file.id)
        try? store.deleteFiles(ids: unread)
        known = known.filter(\.value.hasVector)
        scan()
    }

    private func watch() {
        guard watcher == nil else { return }
        watcher = FolderWatcher(RecentFiles.scopes.map(\.path)) { [weak self] in self?.scheduleScan() }
        opened = OpenedFiles { [weak self] files in self?.readNow(files) }
        timers = [
            // Opening a file changes no file: what was opened lately is looked for now and then.
            Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scan() }
            },
            // Waiting files start once the Mac goes idle: the model is asked again now and then.
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.engine.fileBacklog > 0 else { return }
                    self.engine.poke()
                }
            },
        ]
    }

    /// Files changing come in bursts (a download, a save): one look ten seconds after they settle.
    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// Search opened: files opened since the last look join (opening one isn't a change FSEvents tells of).
    func refreshIfStale() {
        guard isOn, Date().timeIntervalSince(lastScan) > 60 else { return }
        scan()
    }

    /// The recent files (a fraction of a second of Spotlight's time), and every six hours the whole home folder (a few
    /// seconds), the first time a minute after launch.
    private func scan() {
        guard isOn else { return }
        lastScan = Date()
        if scanning {
            rescan = true
            return
        }
        scanning = true
        let started = Date()
        scanStarted = started
        let full = fullLook.map { Date().timeIntervalSince($0) > Self.fullLookEvery } ?? true
        Task.detached(priority: .utility) {
            let recent = RecentFiles.find()
            let quick = Date().timeIntervalSince(started)
            guard full else {
                await MainActor.run { self.found(recent, nil, in: quick) }
                return
            }
            // The recent ones now; the whole home folder after, not in the launch's first minute (the app, and the
            // Mac at login, have other things to do then).
            await MainActor.run { self.found(recent, nil, in: quick, more: true) }
            let wait = 60 - Date().timeIntervalSince(FileIndexer.launched)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let looked = Date()
            let rest = RecentFiles.everything()
            await MainActor.run { self.found(recent, rest, in: Date().timeIntervalSince(looked)) }
        }
    }

    /// `more`: the whole home folder is still being looked through (the look isn't over).
    private func found(_ recent: [RecentFiles.Candidate], _ rest: [RecentFiles.Candidate]?, in seconds: TimeInterval,
                       more: Bool = false) {
        if !more { scanning = false }
        defer {
            if rescan, !more {
                rescan = false
                scan()
            }
        }
        guard isOn else { return }
        if rest != nil {
            // The whole home folder has what appeared before the look began (or left it out on purpose); what came
            // since stays, as its recent files are from then.
            let started = scanStarted
            appeared = appeared.filter { $0.value.seen >= started }
        }
        let recentPaths = Set(recent.map(\.path))
        let live = appeared.values.map(\.file).filter {
            !recentPaths.contains($0.path) && FileManager.default.fileExists(atPath: $0.path)
        }
        let recent = recent + live
        self.recent = recent
        if let rest {
            let recentPaths = Set(recent.map(\.path))
            self.rest = rest.filter { !recentPaths.contains($0.path) }
            fullLook = Date()
        }
        // What's no longer found goes, once the whole home folder has been looked through.
        var gone: [String: (file: IndexedFile, hasVector: Bool)] = [:]
        if fullLook != nil {
            let paths = Set(recent.map(\.path) + self.rest.map(\.path))
            gone = known.filter { !paths.contains($0.key) }
            if !gone.isEmpty {
                try? store.deleteFiles(ids: gone.values.map(\.file.id))
                index.remove(Set(gone.values.map(\.file.id)))
                for path in gone.keys { known[path] = nil }
            }
        }
        func unread(_ candidate: RecentFiles.Candidate) -> Bool {
            guard waiting[candidate.path] == nil else { return false }
            guard let read = known[candidate.path] else { return true }
            return abs(read.file.modified.timeIntervalSince(candidate.modified)) > 1
        }
        // Once each: what's recent now may have been in the rest when the home folder was last looked through.
        let recentNow = Set(recent.map(\.path))
        let toRead = recent.filter(unread).map { ($0, EmbeddingEngine.FileTier.recent) }
            + self.rest.filter { !recentNow.contains($0.path) && unread($0) }.map { ($0, EmbeddingEngine.FileTier.background) }
        log(String(format: "files: %d recent and %d more found in %.1f s, %d to read, %d gone", recent.count,
                   self.rest.count, seconds, toRead.count, gone.count))
        guard !toRead.isEmpty else { return }
        read(toRead)
    }

    /// One at a time, a few ahead of the model (what's read waits in memory, pictures and sound, until it's
    /// embedded); the rest of the home folder only once the Mac is idle on power.
    private func read(_ files: [(RecentFiles.Candidate, EmbeddingEngine.FileTier)]) {
        reading?.cancel()
        let (pictures, sound) = (engine.readsPictures, engine.readsSound)
        let engine = self.engine
        reading = Task.detached(priority: .utility) {
            defer { engine.filesComing(false) }
            for (file, tier) in files {
                while engine.fileBacklog >= 4 || (tier == .background && FilePolicy.pace() != .fast) {
                    if engine.fileBacklog == 0 { engine.filesComing(false) }   // not reading now: the model may go
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(tier == .background ? 10 : 1))
                }
                if Task.isCancelled { return }
                engine.filesComing(true)
                let url = URL(fileURLWithPath: file.path)
                // A scan's OCR on a low-power core unless the Mac is idle on power.
                let contents = await TextRecognition.$gentle.withValue(FilePolicy.pace() != .fast) {
                    await CopiedFileReader.read([url], pictures: pictures, sound: sound, budget: EmbeddingEngine.pictureBudget)
                }
                let pieces = contents == nil ? [] : FileIndexer.pieces(of: url)
                await MainActor.run { self.read(file, contents, pieces: pieces, tier: tier) }
            }
        }
    }

    /// Just opened, saved or appeared: read now, ahead of the rest, and embedded without waiting its turn. A burst (an
    /// archive unpacked) isn't "just opened": past ten files, they wait their turn, read with the recent files.
    private func readNow(_ files: [RecentFiles.Candidate]) {
        let cutoff = Date().addingTimeInterval(-Double(RecentFiles.days) * 86_400)
        let fresh = files.filter { file in
            guard RecentFiles.keeps(file, since: cutoff), waiting[file.path] == nil else { return false }
            guard let read = known[file.path] else { return true }
            return abs(read.file.modified.timeIntervalSince(file.modified)) > 1
        }
        guard isOn, !fresh.isEmpty else { return }
        // Kept with the recent files till the whole-home look has them (else the next look would drop them again).
        let now = Date()
        for file in fresh { appeared[file.path] = (file, now) }
        guard fresh.count <= 10 else { return scheduleScan() }
        let (pictures, sound) = (engine.readsPictures, engine.readsSound)
        Task.detached(priority: .userInitiated) {
            for file in fresh {
                let url = URL(fileURLWithPath: file.path)
                let contents = await CopiedFileReader.read([url], pictures: pictures, sound: sound,
                                                           budget: EmbeddingEngine.pictureBudget)
                let pieces = contents == nil ? [] : FileIndexer.pieces(of: url)
                await MainActor.run { self.read(file, contents, pieces: pieces, tier: .opened) }
            }
        }
        log("files: \(fresh.count) just opened, saved or appeared, read now")
    }

    private func read(_ file: RecentFiles.Candidate, _ contents: CopiedFileReader.Contents?, pieces: [String],
                      tier: EmbeddingEngine.FileTier) {
        guard isOn else { return }
        // A recording opened or worked with lately: the audio encoder comes (once), and it's read again then.
        if tier != .background, !engine.readsSound,
           RecentFiles.group(of: (file.path as NSString).pathExtension.lowercased()) == "audio" {
            app.needSound()
        }
        // Read already (just opened while the whole lot was being read): not again.
        if let read = known[file.path], abs(read.file.modified.timeIntervalSince(file.modified)) <= 1 { return }
        guard let contents else {
            // Not even opened (macOS hasn't let Pastemind into that folder yet): tried again on the next look.
            guard Self.opens(file.path) else { return }
            // Nothing in it reads: not again till it changes.
            if let saved = try? store.saveFile(path: file.path, modified: file.modified, used: file.lastUsed, vector: nil) {
                known[file.path] = (saved, false)
            }
            return
        }
        waiting[file.path] = file
        engine.enqueueFile(file.path, .files(prompt: contents.prompt, media: contents.media, summary: contents.summary,
                                             fallback: nil), pieces: pieces, tier: tier)
    }

    /// A document's pieces: a long scan's OCR (a second a page) on a low-power core unless the Mac is idle on power.
    nonisolated static func pieces(of url: URL) -> [String] {
        TextRecognition.$gentle.withValue(FilePolicy.pace() != .fast) { CopiedFileReader.pieces(of: url) }
    }

    private static func opens(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return false }
        if isFolder.boolValue { return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        try? handle.close()
        return true
    }

    /// From the model: its vector, and its pieces' (nil: still to come, and it waits for them).
    func received(_ path: String, _ vector: [Float]?, pieces: [[Float]]?) {
        guard let file = waiting[path] else { return }
        if pieces != nil { waiting[path] = nil }
        guard isOn, let saved = try? store.saveFile(path: path, modified: file.modified, used: file.lastUsed,
                                                    vector: vector, pieces: pieces) else { return }
        if pieces != nil { known[path] = (saved, vector != nil) }
        if let vector { index.set(saved, vector: vector, pieces: pieces ?? []) }
        if waiting.isEmpty, engine.fileBacklog == 0 { log("files: \(index.count) by what's in them") }
    }

    /// Search's meaning matches among the files, best first (still there).
    func matches(for vector: [Float], oneWord: Bool, limit: Int) -> [LaunchItem] {
        index.search(vector, oneWord: oneWord, limit: limit).compactMap { match in
            let url = URL(fileURLWithPath: match.file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            return LaunchItem(kind: .file, name: url.lastPathComponent,
                              aliases: stem != url.lastPathComponent ? [stem] : [], path: url.path, url: url,
                              lastUsed: match.file.lastUsed)
        }
    }
}

/// How files may be read now: not at all with search by contents off or paused, in Low Power Mode, with the Mac hot,
/// or on battery under 20%; all of them, one after another, once the Mac has sat idle a minute on power; the recent
/// ones paced (one every couple of seconds, a tenth of the GPU) otherwise. Asked from the model's thread.
/// `PASTEMIND_FILES_NOW=1` (debug runs): one after another, always; `=paced`: paced, always.
nonisolated enum FilePolicy {
    static func pace() -> EmbeddingEngine.FilePace {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Settings.searchFileContentsKey) as? Bool == true,
              !defaults.bool(forKey: Settings.filesPausedKey) else { return .no }
        switch ProcessInfo.processInfo.environment["PASTEMIND_FILES_NOW"] {
        case "1": return .fast
        case "paced": return .paced
        default: break
        }
        let info = ProcessInfo.processInfo
        guard !info.isLowPowerModeEnabled, info.thermalState != .serious, info.thermalState != .critical else { return .no }
        let power = Self.power
        guard power.plugged || power.level >= 0.2 else { return .no }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput) >= 60
        return idle && power.plugged ? .fast : .paced
    }

    /// On power, and the battery's charge (1 without one).
    private static var power: (plugged: Bool, level: Double) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, 1) }
        let plugged = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) != kIOPSBatteryPowerValue
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (plugged, Double(current) / Double(max))
        }
        return (plugged, 1)
    }
}

/// Files you open (Spotlight's last-used date moves as an app opens one), save or put anywhere, as they happen: a live
/// Spotlight query over the home folder (a debug run's `RecentFiles.scopes`), on the main thread. What was opened in
/// the last ten minutes anywhere, or changed then where `RecentFiles.scopes` are, goes to `found`; changed then
/// elsewhere in the home folder, as the whole-home look would take it (`RecentFiles.appeared`).
final class OpenedFiles: NSObject {
    nonisolated(unsafe) private let query = NSMetadataQuery()   // used on the main thread, stopped in deinit
    private let found: ([RecentFiles.Candidate]) -> Void

    init(_ found: @escaping ([RecentFiles.Candidate]) -> Void) {
        self.found = found
        super.init()
        let since = Date().addingTimeInterval(-86_400) as NSDate
        query.predicate = NSPredicate(format: "(kMDItemLastUsedDate >= %@ || kMDItemFSContentChangeDate >= %@)"
            + " && kMDItemContentType != 'public.folder' && kMDItemContentType != 'com.apple.application-bundle'",
            since, since)
        query.searchScopes = RecentFiles.debugScoped ? RecentFiles.scopes : [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 1
        NotificationCenter.default.addObserver(self, selector: #selector(updated(_:)),
                                               name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    deinit {
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func updated(_ note: Notification) {
        let info = note.userInfo ?? [:]
        take((info[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? [])
            + (info[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []))
    }

    /// The first results: what changed while it was gathering them (at launch) comes in here, not as an update.
    @objc private func gathered(_ note: Notification) {
        query.disableUpdates()
        let items = query.results.compactMap { $0 as? NSMetadataItem }
        query.enableUpdates()
        take(items)
    }

    private func take(_ items: [NSMetadataItem]) {
        let now = Date()
        let scopes = RecentFiles.scopes.map { $0.path + "/" }
        var files: [RecentFiles.Candidate] = []
        var elsewhere: [RecentFiles.Candidate] = []
        for item in items {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date else { continue }
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let candidate = RecentFiles.Candidate(path: path, modified: modified, lastUsed: used)
            let opened = used.map { now.timeIntervalSince($0) < 600 } ?? false
            let saved = now.timeIntervalSince(modified) < 600
            if opened || saved && scopes.contains(where: { path.hasPrefix($0) }) {
                files.append(candidate)
            } else if saved {
                elsewhere.append(candidate)
            }
        }
        files += RecentFiles.appeared(elsewhere)
        if !files.isEmpty { found(files) }
    }
}

/// FSEvents on some folders, all the way down: `changed` on the main queue, a few seconds after things change.
final class FolderWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?   // set once, freed in deinit
    private let changed: () -> Void

    init?(_ paths: [String], changed: @escaping () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil,
                                           release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
