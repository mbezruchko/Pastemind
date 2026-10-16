import Foundation
import PastemindKit

/// Downloads one of the model's files once (the text model, 310 MB; the image encoder, 555 MB) into Application
/// Support, checks its SHA-256, and only then gives it its name. Search by words works meanwhile. Its delegate calls
/// arrive on the main queue, where everything here happens.
nonisolated final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let file: ModelFile
    private let onProgress: @MainActor (Double) -> Void
    private let onFinish: @MainActor (Result<URL, Error>) -> Void
    private var session: URLSession?

    init(_ file: ModelFile, onProgress: @escaping @MainActor (Double) -> Void,
         onFinish: @escaping @MainActor (Result<URL, Error>) -> Void) {
        self.file = file
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: file.url).resume()
        log("downloading \(file.url)")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, file.bytes))
        MainActor.assumeIsolated { onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns: move it first, verify after.
        let partial = AppPaths.models.appendingPathComponent(file.name + ".part")
        let result: Result<URL, Error>
        do {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
            guard try ModelFiles.sha256(of: partial) == file.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw CocoaError(.fileReadCorruptFile)
            }
            try? FileManager.default.removeItem(at: file.installed)
            try FileManager.default.moveItem(at: partial, to: file.installed)
            result = .success(file.installed)
        } catch {
            result = .failure(error)
        }
        MainActor.assumeIsolated { onFinish(result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated { onFinish(.failure(error)) }
    }
}
