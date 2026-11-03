import Foundation
import ParakeetTDT

/// Parakeet Ultra on the Apple Neural Engine through the ParakeetTDT library.
actor Transcriber {
    enum LoadPhase: Equatable {
        /// Fetching model files from Hugging Face; `fraction` is 0...1 of the download.
        case downloading(fraction: Double)
        /// First preparation of these model files on this macOS version.
        case optimizing
        /// Loading a model that has already been prepared successfully.
        case loading
    }

    /// Recordings shorter than this have nothing to decode, so callers skip them up front.
    static let minimumSamples = ParakeetConstants.minimumSamples

    private var transcriber: ParakeetTranscriber?
    private var session: ParakeetTranscriber.Session?
    private var sessionError: Error?
    private let vadModelURL: URL?

    init(vadModelURL: URL? = Bundle.main.url(forResource: "VadHead", withExtension: "mlmodelc")) {
        self.vadModelURL = vadModelURL
    }

    /// Download, prepare, and load the Ultra recognizer.
    func load(progress: @escaping @Sendable (LoadPhase) -> Void) async throws {
        let store = ModelStore()
        let directory = try await store.locate { fraction in progress(.downloading(fraction: fraction)) }
        // Keep the existing Ultra receipt so upgrades reuse its preparation history.
        let preparation = ModelPreparationRecord(
            directory: directory,
            additionalModels: [store.ownEncoderURL, store.ownFusedDecoderURL].compactMap { $0 },
            recordURL: store.ownDirectory.deletingLastPathComponent()
                .appendingPathComponent(".multi-preparation.json"))
        progress(preparation.isPrepared ? .loading : .optimizing)
        if vadModelURL == nil { Log.info("VadHead.mlmodelc not bundled; long recordings fall back to fixed windows") }
        // VadHead includes its own trained subsampler and detects pauses independently.
        let models = try ParakeetModels(directory: directory, vadModel: vadModelURL, encoderModel: store.ownEncoderURL, fusedDecoder: store.ownFusedDecoderURL)
        Log.info("encoder windows (mel frames): \(models.encoder.variants.map(\.melFrames))")
        let transcriber = try ParakeetTranscriber(models: models)
        try transcriber.warmUp()
        do { try preparation.markPrepared() }
        catch { Log.info("Could not save model preparation record: \(error.localizedDescription)") }
        session = nil
        sessionError = nil
        self.transcriber = transcriber
    }

    /// Opens a recording. Audio is fed with `append` while it is captured; segments are transcribed
    /// as soon as their cut is known, so `finish` only has the tail left to do.
    func startSession() throws {
        guard let transcriber else { throw TranscriberError.notLoaded }
        session = transcriber.startSession()
        sessionError = nil
    }

    func append(_ samples: [Float]) {
        guard let session, sessionError == nil else { return }
        do { try session.append(samples) } catch { sessionError = error }
    }

    func fail(_ error: Error) {
        if sessionError == nil { sessionError = error }
    }

    func finish() throws -> String {
        guard let session else { throw TranscriberError.notLoaded }
        defer { self.session = nil }
        if let sessionError { throw sessionError }
        return try session.finish().text
    }

    func discard() {
        session = nil
    }

    struct FileResult {
        let text: String
        let recording: RecordingFile
        let inferenceMilliseconds: Int
    }

    /// Runs on this actor, away from the UI; cancellation is checked between small batches.
    /// Uses a local session so a failed import cannot leave live dictation half initialized.
    func transcribeFile(_ url: URL, progress: @escaping @Sendable (Double) -> Void) throws -> FileResult {
        guard let transcriber else { throw TranscriberError.notLoaded }
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let reader = try AudioFileReader(url: url)
        let recording = try RecordingFile()
        let session = transcriber.startSession()
        let started = Date()
        var reported = -1.0
        while let samples = try reader.next() {
            try Task.checkCancellation()
            try recording.append(samples)
            try session.append(samples)
            let fraction = min(reader.progress, 0.99)
            if fraction - reported >= 0.01 {
                progress(fraction)
                reported = fraction
            }
        }
        try Task.checkCancellation()
        let text = try session.finish().text
        try recording.finish()
        try Task.checkCancellation()
        return FileResult(text: text, recording: recording,
                          inferenceMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    enum TranscriberError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The speech model has not finished loading." }
    }
}
