// swift-tools-version: 6.2
import PackageDescription

// Pastemind: clipboard history for macOS with meaning search (EmbeddingGemma 2 on llama.cpp, Metal). llama.cpp is built
// into Vendor/llama by scripts/build-llama.sh; build.sh wraps the app into build.noindex/Pastemind.app.
let vendor = "\(Context.packageDirectory)/Vendor"

let package = Package(
    name: "Pastemind",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PastemindApp", targets: ["PastemindApp"]),
        .executable(name: "pastemind-cli", targets: ["pastemind-cli"]),
        .executable(name: "pastemind-ocr", targets: ["pastemind-ocr"]),
    ],
    dependencies: [
        // Updates: the appcast, EdDSA-signed, from GitHub Releases (Updater.swift, scripts/release.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // The engine: clips, the store (SQLite), the vector index and hybrid search. No UI, no llama.cpp.
        .target(name: "PastemindKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        // EmbeddingGemma 2's text model on llama.cpp.
        .target(name: "LlamaRuntime", dependencies: ["CLlama", "PastemindKit"],
                linkerSettings: [.unsafeFlags(["-L\(vendor)/llama/lib"])]),
        // The menu bar app: clipboard watcher, hotkey, panel, paste.
        .executableTarget(name: "PastemindApp",
                          dependencies: ["PastemindKit", "LlamaRuntime", .product(name: "Sparkle", package: "Sparkle")],
                          swiftSettings: [.defaultIsolation(MainActor.self)],
                          // Sparkle.framework goes in Contents/Frameworks (build.sh).
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // Text in scans and pictures (Vision), run by the app as a process of its own: its models go when it exits.
        .executableTarget(name: "pastemind-ocr"),
        // Developer CLI: benchmarks and searches from the terminal.
        .executableTarget(name: "pastemind-cli", dependencies: ["PastemindKit", "LlamaRuntime"]),
        .testTarget(name: "PastemindKitTests", dependencies: ["PastemindKit"]),
    ]
)
