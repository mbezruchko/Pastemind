#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Where Pastemind keeps its things: ~/Library/Application Support/Pastemind, or `$PASTEMIND_HOME` (tests and the CLI's experiments).
public enum AppPaths {
    public static var home: URL {
        if let chosen = ProcessInfo.processInfo.environment["PASTEMIND_HOME"], !chosen.isEmpty {
            return URL(fileURLWithPath: chosen)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pastemind")
    }

    public static var database: URL { home.appendingPathComponent("pastemind.sqlite") }
    public static var images: URL { home.appendingPathComponent("Images") }
    /// Smaller copies of the pictures, at the sizes they're drawn.
    public static var thumbnails: URL { home.appendingPathComponent("Thumbnails") }
    public static var models: URL { home.appendingPathComponent("Models") }

    public static func prepare() throws {
        for folder in [home, images, thumbnails, models] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

/// One of EmbeddingGemma 2's files for llama.cpp, from a Hugging Face repository at one pinned revision, checked
/// against its SHA-256. Never F16: the model's activations overflow float16.
public struct ModelFile: Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
    public let repository: String
    public let revision: String
    /// Files that do its job too, from before: an install that has one needn't download this. The same model in
    /// Q8_0, or both encoders in one mmproj.
    public let alternatives: [String]

    public var url: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")!
    }

    public var installed: URL { AppPaths.models.appendingPathComponent(name) }

    /// This file, or one installed before that does its job.
    public var located: URL? {
        ([name] + alternatives).map { AppPaths.models.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum ModelFiles {
    /// Ours: the text model in Q6_K, and the image and audio encoders split apart (`scripts/split-mmproj.py`), made
    /// from ggml-org's files below; see its model card.
    public static let repository = "mbezruchko/embeddinggemma-2-pastemind-GGUF"
    public static let revision = "c0a58f4a78d1ec5dc1395bfa8b1827e40cd711b9"
    /// ggml-org's, which ours were made from (and earlier installs have).
    public static let sourceRepository = "ggml-org/embeddinggemma-2-GGUF"
    public static let sourceRevision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"
    /// The text model: all that search needs. Q6_K: Q8_0's quality in every evaluation, vectors within cosine 0.997.
    public static let text = ModelFile(name: "embeddinggemma-2-Q6_K.gguf", bytes: 245_764_320,
                                       sha256: "a7aae0a994f621421032db719cbc7f67081de72d8774650ae480b9a24e637fd2",
                                       repository: repository, revision: revision,
                                       alternatives: ["embeddinggemma-2-Q8_0.gguf"])
    /// The image encoder, feeding the text model: pictures (and video frames) by what's in them. Downloaded after the
    /// text model.
    public static let pictures = ModelFile(name: "mmproj-embeddinggemma-2-vision-Q8_0.gguf", bytes: 226_342_528,
                                           sha256: "099ef9869f816ca2bd8e665d598db4d4ed43c551b7d1d961a54d16b86693354b",
                                           repository: repository, revision: revision,
                                           alternatives: ["mmproj-embeddinggemma-2-Q8_0.gguf"])
    /// The audio encoder: recordings by what's said in them. Downloaded only once an audio file is copied or opened.
    public static let sound = ModelFile(name: "mmproj-embeddinggemma-2-audio-Q8_0.gguf", bytes: 328_479_328,
                                        sha256: "a838ad159d2b5e708c1b0b8b14e945a763ed194bae24dce2c1c56384df3ff72d",
                                        repository: repository, revision: revision,
                                        alternatives: ["mmproj-embeddinggemma-2-Q8_0.gguf"])
    /// Which vectors the store holds: bumped when the model, its runtime or the prompts change, so old ones embed again.
    public static let vectorVersion = 1
    public static let dimension = 768

    /// The SHA-256 of a file as lowercase hex, read in 8 MB pieces.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool { () -> Bool in
                guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What turns text into vectors (`LlamaEmbedder` in the app, a fake in tests). One thread at a time.
public protocol Embedder: AnyObject {
    /// One L2-normalized vector of `ModelFiles.dimension` floats per input, in order.
    func embed(_ texts: [String]) throws -> [[Float]]
    func close()
}
