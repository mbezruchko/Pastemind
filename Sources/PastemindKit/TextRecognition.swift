import Foundation

/// Text in scans and pictures, read by `pastemind-ocr` (Vision) in a process of its own: Vision keeps its models
/// (~250 MB) for as long as the process that used them lives, and the helper's go as it exits. A page takes about a
/// second of one core.
public enum TextRecognition {
    /// Read at background priority, on a low-power core (about five times slower): reading files while you work.
    @TaskLocal public static var gentle = false

    /// The helper, beside the running executable (Pastemind.app/Contents/MacOS; .build/release for the CLI).
    static let helper: URL? = {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent().appendingPathComponent("pastemind-ocr")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    public static var available: Bool { helper != nil }

    /// A PDF's pages' text from page `first` (counted from 0), at most `pages` of them, stopping once there's
    /// `characters` of it; a picture's, as one page. Nil when it couldn't be read: no helper, or it failed or hung.
    public static func pages(of url: URL, first: Int = 0, pages: Int = 1, characters: Int = .max) -> [String]? {
        guard let helper else { return nil }
        let process = Process()
        process.executableURL = helper
        process.arguments = [url.path, String(first), String(pages), String(characters)] + (gentle ? ["--gentle"] : [])
        process.qualityOfService = .utility
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Far longer than a page takes is stuck.
        let limit = Double(pages) * (gentle ? 20 : 5) + 15
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        var found = String(decoding: data, as: UTF8.self).components(separatedBy: "\u{0C}\n")
        if found.last?.isEmpty == true { found.removeLast() }
        return found
    }
}
