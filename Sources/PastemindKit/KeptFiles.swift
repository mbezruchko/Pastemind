import Foundation

/// Pastemind's own copy of copied files, so a clip still pastes, drags and shows one that's since been moved or
/// deleted (`Clip.fileURLs`): `Files/<clip>/<n>/<name>`. A clone on APFS (instant, and no space while the original
/// stays as it was), else a copy. It lasts as long as its clip. Not kept: what's over the limit in all (Settings; by
/// default `defaultMaxBytes`: photos, screenshots and documents, not the videos, archives and disk images deleted to
/// free space), files that only
/// live in iCloud (copying would download them), and keys, certificates and password stores (`CopiedFiles.isPrivate`),
/// nor a folder with one inside. Made and removed on `queue`, in order: a clip's copy is never removed after a later one
/// was made.
public enum KeptFiles {
    public static let defaultMaxBytes = 100 << 20
    static let maxItems = 10_000
    public static let queue = DispatchQueue(label: "app.pastemind.kept-files", qos: .utility)

    public static func url(clip id: Int64, index: Int, name: String, in folder: URL = AppPaths.keptFiles) -> URL {
        folder.appendingPathComponent("\(id)/\(index)/\(name)")
    }

    /// A copy of each of `urls` that can be kept, for clip `id`, in place of the one before (a file copied again may
    /// have changed). Returns how many were kept.
    @discardableResult
    public static func keep(_ urls: [URL], for id: Int64, in folder: URL = AppPaths.keptFiles,
                            maxBytes: Int = defaultMaxBytes) -> Int {
        let manager = FileManager.default
        let kept = folder.appendingPathComponent("\(id)")
        var budget = maxBytes
        let chosen = urls.indices.filter { index in
            guard let size = size(of: urls[index], limit: budget) else { return false }
            budget -= size
            return true
        }
        guard !chosen.isEmpty else {
            try? manager.removeItem(at: kept)
            return 0
        }
        let incoming = folder.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: incoming) }
        do {
            for index in chosen {
                let target = incoming.appendingPathComponent("\(index)/\(urls[index].lastPathComponent)")
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: urls[index], to: target)
            }
            try? manager.removeItem(at: kept)
            try manager.moveItem(at: incoming, to: kept)
            return chosen.count
        } catch {
            return 0
        }
    }

    public static func remove(_ ids: some Sequence<Int64>, in folder: URL = AppPaths.keptFiles) {
        for id in ids { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id)")) }
    }

    /// Copies of clips that are gone (deleted while one was being made, or before a crash), and half-made ones.
    public static func removeAll(except ids: Set<Int64>, in folder: URL = AppPaths.keptFiles) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            if let id = Int64(name), ids.contains(id) { continue }
            if name.hasPrefix("."), !name.hasPrefix(".incoming-") { continue }   // the marker below
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Copies for the files of clips recorded before there were any, once (the marker says it's done): those still
    /// where they were copied from.
    public static func keepEarlier(_ clips: [(id: Int64, urls: [URL])], in folder: URL = AppPaths.keptFiles,
                                   maxBytes: Int = defaultMaxBytes) {
        let marker = folder.appendingPathComponent(".earlier")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for clip in clips where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(clip.id)").path) {
            keep(clip.urls, for: clip.id, in: folder, maxBytes: maxBytes)
        }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    /// The copies standing in for files that are gone (moved or deleted): the ones that take space of their own.
    public static func standIns(for clips: [(id: Int64, urls: [URL])], in folder: URL = AppPaths.keptFiles) -> [URL] {
        clips.flatMap { clip in
            clip.urls.indices.compactMap { index -> URL? in
                guard !FileManager.default.fileExists(atPath: clip.urls[index].path) else { return nil }
                let kept = folder.appendingPathComponent("\(clip.id)/\(index)")
                return FileManager.default.fileExists(atPath: kept.path) ? kept : nil
            }
        }
    }

    /// What `urls` take on disk, with all that's in them.
    public static func diskSize(of urls: [URL]) -> Int {
        urls.reduce(0) { total, url in
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            return total + (items?.reduce(0) { sum, item in
                sum + (((item as? URL).flatMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) })?
                    .totalFileAllocatedSize ?? 0)
            } ?? 0)
        }
    }

    /// Removes the copies standing in for files that are gone (Settings): their clips can't paste them after. Returns
    /// what they took.
    @discardableResult
    public static func removeStandIns(for clips: [(id: Int64, urls: [URL])], in folder: URL = AppPaths.keptFiles) -> Int {
        let standIns = standIns(for: clips, in: folder)
        let bytes = diskSize(of: standIns)
        for url in standIns { try? FileManager.default.removeItem(at: url) }
        return bytes
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isUbiquitousItemKey,
                                                 .ubiquitousItemDownloadingStatusKey]

    /// What keeping `url` takes, nil when it can't be kept or takes more than `limit`.
    static func size(of url: URL, limit: Int) -> Int? {
        guard !CopiedFiles.isPrivate(url), let values = try? url.resourceValues(forKeys: Set(keys)),
              local(values) else { return nil }
        guard values.isDirectory == true else { return (values.fileSize ?? 0) <= limit ? values.fileSize ?? 0 : nil }
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return nil }
        var total = 0, count = 0
        for case let item as URL in items {
            count += 1
            guard count <= maxItems, !CopiedFiles.isPrivate(item),
                  let values = try? item.resourceValues(forKeys: Set(keys)), local(values) else { return nil }
            total += values.fileSize ?? 0
            if total > limit { return nil }
        }
        return total
    }

    private static func local(_ values: URLResourceValues) -> Bool {
        values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
    }
}
