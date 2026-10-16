import Accelerate
import CLlama
import Foundation
import PastemindKit

/// EmbeddingGemma 2 on llama.cpp, in this process: an input in, one 768-number vector out, mean-pooled over the input's
/// positions and scaled to unit length. Inputs are text, or text with pictures or a sound in it: the model's own
/// encoders (mtmd, `openImages`, `openSound`) turn those into rows as wide as the text model's token embeddings, which
/// take the place of their marker in the input, so they land in the same space as text.
///
/// The text model attends both ways and keeps nothing between calls, so inputs go together: each is its own sequence in
/// one batch, and one `llama_process` encodes the lot. About 250 MB on the GPU (Metal), or the CPU where there's none;
/// `close()` frees it. One thread at a time.
public final class LlamaEmbedder: Embedder {
    public enum Device: String, Sendable { case gpu, cpu }

    /// What goes in at a marker.
    public enum Media: Sendable {
        case picture(ImagePixels)
        /// Mono samples at `soundSampleRate`: the model hears 30 s at most.
        case sound([Float])

        var isSound: Bool {
            if case .sound = self { return true }
            return false
        }
    }

    /// Where a picture or a sound goes in a prompt.
    public static let marker = String(cString: mtmd_default_marker())
    public static let soundSampleRate = 16_000

    public let device: Device
    public private(set) var loadSeconds = 0.0
    public private(set) var imageLoadSeconds = 0.0
    public private(set) var soundLoadSeconds = 0.0
    public var readsImages: Bool { imageEncoder != nil }
    public var readsSound: Bool { soundEncoder != nil }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var batch: OpaquePointer?
    private var imageEncoder: OpaquePointer?
    private var soundEncoder: OpaquePointer?
    private let vocabulary: OpaquePointer?
    /// The vector's length (the output projection's).
    private let outputWidth: Int
    /// A token embedding's width: what the encoders' rows must be.
    private let rowWidth: Int
    /// The most tokens a batch holds, and so the longest input.
    private let capacity: Int
    private static let inputsPerBatch = 32

    /// `maxTokens`: the longest input (longer text is cut, keeping its end token) and a batch's size.
    public init(model path: URL, device: Device = .gpu, maxTokens: Int = 1024) throws {
        let started = Date()
        _ = Self.setUp
        self.device = device
        var modelOptions = llama_model_default_params()
        modelOptions.n_gpu_layers = device == .gpu ? 999 : 0   // all of them, or none
        guard let model = llama_model_load_from_file(path.path, modelOptions) else {
            throw EmbedderError("can't load \(path.path)")
        }
        var options = llama_context_default_params()
        options.embeddings = true
        options.pooling_type = LLAMA_POOLING_TYPE_MEAN
        options.n_ctx = UInt32(maxTokens)
        options.n_batch = UInt32(maxTokens)
        options.n_ubatch = UInt32(maxTokens)
        options.n_seq_max = UInt32(Self.inputsPerBatch)
        options.kv_unified = true   // any one input may take the whole context
        if device == .cpu {
            // The performance cores only: the efficiency ones hold a batch back.
            let threads = Int32(Self.performanceCores)
            options.n_threads = threads
            options.n_threads_batch = threads
            options.offload_kqv = false
        }
        guard let context = llama_init_from_model(model, options) else {
            llama_model_free(model)
            throw EmbedderError("can't make a llama.cpp context")
        }
        self.model = model
        self.context = context
        batch = llama_batch_ext_init(context)
        vocabulary = llama_model_get_vocab(model)
        outputWidth = Int(llama_model_n_embd_out(model))
        rowWidth = Int(llama_model_n_embd_inp(model))
        capacity = maxTokens
        // The GPU's pipelines are built by the first calls: now, rather than on the first query.
        do {
            _ = try embed([Prompts.query("warm up"), Prompts.document("warm up")])
            _ = try embed([Prompts.query("warm up")])
        } catch {
            close()
            throw error
        }
        loadSeconds = Date().timeIntervalSince(started)
    }

    deinit { close() }

    public func close() {
        closeImages()
        closeSound()
        if let batch { llama_batch_ext_free(batch) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        batch = nil
        context = nil
        model = nil
    }

    // MARK: Text

    /// One vector per text, in order. Texts share batches while they fit.
    public func embed(_ texts: [String]) throws -> [[Float]] {
        guard context != nil else { throw EmbedderError("the embedder is closed") }
        var vectors: [[Float]] = []
        var group: [[llama_token]] = []
        var groupTokens = 0
        func encodeGroup() throws {
            guard !group.isEmpty else { return }
            vectors += try encode { filler in
                for tokens in group {
                    filler.beginInput()
                    for token in tokens { try filler.append(token: token) }
                }
            }
            group = []
            groupTokens = 0
        }
        for text in texts {
            let tokens = tokens(of: text)
            if group.count == Self.inputsPerBatch || groupTokens + tokens.count > capacity { try encodeGroup() }
            group.append(tokens)
            groupTokens += tokens.count
        }
        try encodeGroup()
        return vectors
    }

    /// The text's tokens with the model's start and end ones, cut to `capacity` with the end one kept.
    private func tokens(of text: String) -> [llama_token] {
        let length = Int32(text.utf8.count)
        // Asked with no room, llama.cpp says how many there are (as a negative count).
        let count = -llama_tokenize(vocabulary, text, length, nil, 0, true, true)
        guard count > 0 else { return [] }
        var tokens = [llama_token](repeating: 0, count: Int(count))
        let made = llama_tokenize(vocabulary, text, length, &tokens, count, true, true)
        tokens.removeLast(tokens.count - Int(max(made, 0)))
        if tokens.count > capacity {
            tokens = Array(tokens.prefix(capacity - 1)) + [llama_vocab_eos(vocabulary)]
        }
        return tokens
    }

    // MARK: Pictures and sound

    /// The image encoder, from an mmproj with it (one with an audio encoder too loads without that one: our llama.cpp
    /// patch): about 200 MB more, until `closeImages()`.
    public func openImages(projector path: URL) throws {
        guard imageEncoder == nil else { return }
        let started = Date()
        imageEncoder = try loadEncoder(path, leavingOut: "MTMD_NO_AUDIO")
        imageLoadSeconds = Date().timeIntervalSince(started)
    }

    public func closeImages() {
        if let imageEncoder { mtmd_free(imageEncoder) }
        imageEncoder = nil
    }

    /// The audio encoder, likewise: about 330 MB more, until `closeSound()`.
    public func openSound(projector path: URL) throws {
        guard soundEncoder == nil else { return }
        let started = Date()
        soundEncoder = try loadEncoder(path, leavingOut: "MTMD_NO_VISION")
        soundLoadSeconds = Date().timeIntervalSince(started)
    }

    public func closeSound() {
        if let soundEncoder { mtmd_free(soundEncoder) }
        soundEncoder = nil
    }

    /// `variable` names the encoder not to load, for as long as mtmd reads the file.
    private func loadEncoder(_ path: URL, leavingOut variable: String) throws -> OpaquePointer {
        guard let model else { throw EmbedderError("the embedder is closed") }
        setenv(variable, "1", 1)
        defer { unsetenv(variable) }
        var options = mtmd_context_params_default()
        options.use_gpu = device == .gpu
        options.print_timings = false
        options.warmup = true
        // Pictures come sized for their budget (ImagePixels): mtmd takes them as they are.
        options.image_min_tokens = 1
        options.image_max_tokens = Int32(ImagePixels.budgets.max()!)
        if device == .cpu { options.n_threads = Int32(Self.performanceCores) }
        guard let encoder = mtmd_init_from_file(path.path, model, options) else {
            throw EmbedderError("can't load \(path.path)")
        }
        return encoder
    }

    /// A picture's vector; `prompt` holds it at `marker` (the marker alone: the picture alone).
    public func embed(image: ImagePixels, prompt: String = LlamaEmbedder.marker) throws -> [Float] {
        try embed([.picture(image)], prompt: prompt)
    }

    /// One vector for `prompt` with `media` at its markers, in order: any number of pictures, or one sound. It all has
    /// to fit `capacity` (a picture takes its budget in tokens, a second of sound 25).
    public func embed(_ media: [Media], prompt: String) throws -> [Float] {
        let hearing = media.contains(where: \.isSound)
        guard !hearing || media.count == 1 else { throw EmbedderError("a sound goes in alone") }
        guard let encoder = hearing ? soundEncoder : imageEncoder else {
            throw EmbedderError("the \(hearing ? "audio" : "image") encoder isn't open")
        }
        var bitmaps: [OpaquePointer?] = []
        defer { bitmaps.forEach { mtmd_bitmap_free($0) } }
        for item in media {
            let bitmap: OpaquePointer?
            switch item {
            case .picture(let picture):
                bitmap = picture.rgb.withUnsafeBufferPointer {
                    mtmd_bitmap_init(UInt32(picture.width), UInt32(picture.height), $0.baseAddress)
                }
            case .sound(let samples):
                bitmap = samples.withUnsafeBufferPointer { mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }
            }
            guard let bitmap else { throw EmbedderError("can't hand the encoder its input") }
            bitmaps.append(bitmap)
        }
        guard let chunks = mtmd_input_chunks_init() else { throw EmbedderError("mtmd has no room") }
        defer { mtmd_input_chunks_free(chunks) }
        let status = prompt.withCString { text -> Int32 in
            var input = mtmd_input_text(text: text, text_len: strlen(text), add_special: true, parse_special: true)
            return mtmd_tokenize(encoder, chunks, &input, bitmaps, bitmaps.count)
        }
        guard status == 0 else { throw EmbedderError("mtmd couldn't lay out the input (\(status))") }
        let vectors = try encode { filler in
            filler.beginInput()
            for index in 0..<mtmd_input_chunks_size(chunks) {
                let chunk = mtmd_input_chunks_get(chunks, index)
                if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                    var count = 0
                    guard let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                    for token in UnsafeBufferPointer(start: tokens, count: count) { try filler.append(token: token) }
                } else {
                    guard mtmd_encode_chunk(encoder, chunk) == 0, let rows = mtmd_get_output_embd(encoder) else {
                        throw EmbedderError("the \(hearing ? "audio" : "image") encoder failed")
                    }
                    for row in 0..<mtmd_input_chunk_get_n_tokens(chunk) {
                        try filler.append(row: UnsafePointer(rows + row * rowWidth), width: rowWidth)
                    }
                }
            }
        }
        return vectors[0]
    }

    // MARK: Encoding

    /// Lays inputs into the batch, an input at a time: each position gets its input's sequence, its place in it, and
    /// is pooled into the input's vector.
    private struct Filler {
        let batch: OpaquePointer
        private(set) var inputs: Int32 = 0
        private var position: llama_pos = 0

        init(_ batch: OpaquePointer) { self.batch = batch }

        mutating func beginInput() {
            inputs += 1
            position = 0
        }

        mutating func append(token: llama_token) throws {
            try place(llama_batch_ext_add_token(batch, inputs - 1, token))
        }

        /// One encoder row (`width` floats, copied by the batch).
        mutating func append(row: UnsafePointer<Float>, width: Int) throws {
            try place(llama_batch_ext_add_embd(batch, inputs - 1, llama_embd(data: row, n_rows: 1, n_embd: width)))
        }

        private mutating func place(_ index: Int32) throws {
            guard index >= 0 else { throw EmbedderError("the input doesn't fit the batch") }
            var at: [llama_pos] = [position, 0, 0, 0]
            guard llama_batch_ext_set_pos(batch, index, &at), llama_batch_ext_set_output_embd(batch, index, true) else {
                throw EmbedderError("llama.cpp didn't take position \(position)")
            }
            position += 1
        }
    }

    /// `fill` lays the inputs in; the text model encodes them, and each input's pooled vector comes back at unit
    /// length.
    private func encode(_ fill: (inout Filler) throws -> Void) throws -> [[Float]] {
        guard let batch, let context else { throw EmbedderError("the embedder is closed") }
        llama_batch_ext_clear(batch)
        defer { llama_batch_ext_clear(batch) }
        var filler = Filler(batch)
        try fill(&filler)
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else { throw EmbedderError("llama.cpp couldn't encode (\(status))") }
        return try (0..<filler.inputs).map { input in
            guard let pooled = llama_get_embeddings_seq(context, input) else {
                throw EmbedderError("no vector for input \(input)")
            }
            return Self.unitLength(UnsafeBufferPointer(start: pooled, count: outputWidth))
        }
    }

    private static func unitLength(_ values: UnsafeBufferPointer<Float>) -> [Float] {
        var vector = Array(values)
        var squares: Float = 0
        vDSP_svesq(vector, 1, &squares, vDSP_Length(vector.count))
        guard squares > 0 else { return vector }
        var scale = 1 / squares.squareRoot()
        vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(vector.count))
        return vector
    }

    // MARK: Setting up

    /// The GPU, or the CPU when the GPU won't take the model (or `PASTEMIND_CPU=1` says so). Every Apple Silicon Mac has
    /// a Metal GPU: a query takes ~10 ms on an M1 Pro's, ~40 on its CPU.
    public static func best(model path: URL, maxTokens: Int = 1024) throws -> LlamaEmbedder {
        if ProcessInfo.processInfo.environment["PASTEMIND_CPU"] != "1",
           let onGPU = try? LlamaEmbedder(model: path, device: .gpu, maxTokens: maxTokens) {
            return onGPU
        }
        return try LlamaEmbedder(model: path, device: .cpu, maxTokens: maxTokens)
    }

    /// The Mac's performance cores (4 on an M1 Air, 6 to 12 on a Pro), at least 2.
    private static let performanceCores: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return max(2, Int(cores)) }
        return max(2, min(ProcessInfo.processInfo.activeProcessorCount, 4))
    }()

    /// llama.cpp's process-wide setup, once: its log (and mtmd's) kept to warnings and errors, on stderr.
    private static let setUp: Void = {
        let warnings: ggml_log_callback = { level, text, _ in
            guard let text, level != GGML_LOG_LEVEL_CONT, level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        }
        llama_log_set(warnings, nil)
        mtmd_helper_log_set(warnings, nil)
        llama_backend_init()
    }()
}

public struct EmbedderError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
