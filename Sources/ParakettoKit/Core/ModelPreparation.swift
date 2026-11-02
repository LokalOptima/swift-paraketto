import Foundation
import ParakeetTDT

/// Run through the signed app executable so Core ML prepares the same models, URLs,
/// configuration and application context used by interactive dictation.
enum ModelPreparation {
    static func run(cachedOnly: Bool) async throws {
        if cachedOnly, ModelStore().cachedDirectory == nil {
            report("Skipping preparation: model not downloaded yet; the app downloads it on first launch.")
            return
        }
        let start = Date()
        let recognizer = Transcriber()
        try await recognizer.load { phase in
            switch phase {
            case .downloading(let fraction):
                report(String(format: "Downloading %.0f%%", fraction * 100))
            case .optimizing: report("Optimizing…")
            case .loading: report("Loading…")
            }
        }
        report(String(format: "Parakeet Ultra prepared in %.2f s", Date().timeIntervalSince(start)))
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
