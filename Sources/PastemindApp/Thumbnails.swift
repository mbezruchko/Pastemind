import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import PastemindKit

/// Quick Look's pictures of files (a document's first page, a photo, a video's frame), made by the system's
/// thumbnail service and kept while the app runs. Files without one keep their icon.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 400 }

    /// The preview's cover of a video, a GIF or a picture copied as a file (as wide as the pane, give or take).
    static let coverSide: CGFloat = 480
    /// Several copied files' pictures in the preview's grid.
    static let gridSide: CGFloat = 240

    /// A file clip's first file when it's a video, a GIF or a picture (and still there): shown by a frame of it, a
    /// cover, not the file type's icon.
    static func mediaPath(of clip: Clip) -> String? {
        guard isMedia(clip), let url = clip.fileURLs.first, FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url.path
    }

    /// A file clip whose first file is a video, a GIF or a picture, by its extension.
    static func isMedia(_ clip: Clip) -> Bool {
        guard clip.kind == .file, let url = clip.fileURLs.first,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .image)
    }

    func cached(_ path: String, side: CGFloat) -> NSImage? {
        cache.object(forKey: "\(path)@\(side)" as NSString)
    }

    func load(_ path: String, side: CGFloat) async -> NSImage? {
        if let image = cached(path, side: side) { return image }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: side, height: side), scale: 2,
                                                   representationTypes: [.lowQualityThumbnail, .thumbnail])
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: "\(path)@\(side)" as NSString)
        return image
    }
}
