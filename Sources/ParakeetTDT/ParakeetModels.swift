import CoreML
import Foundation

public enum ParakeetError: LocalizedError {
    case missingFile(String)
    case missingOutput(String)
    case unexpectedShape(String, [Int])
    case download(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "Model file missing: \(name)"
        case .missingOutput(let name): return "Model output missing: \(name)"
        case .unexpectedShape(let name, let shape): return "Unexpected shape for \(name): \(shape)"
        case .download(let message): return "Model download failed: \(message)"
        }
    }
}

/// Tensor dimensions of the Ultra Core ML export.
public enum ParakeetConstants {
    public static let sampleRate = 16_000
    /// The exported preprocessor and encoder take exactly this many samples (15 s).
    public static let windowSamples = 240_000
    /// Audio samples per encoder frame: 10 ms mel hop times 8x subsampling.
    public static let samplesPerFrame = 1280
    public static let encoderHiddenSize = 1024
    public static let decoderHiddenSize = 640
    public static let decoderLayers = 2
    public static let blankToken = 8192
    public static let durationBins = [0, 1, 2, 3, 4]
    /// Ultra often emits two tokens on one frame; longer runs on a single frame are mostly invented phrases.
    public static let maxSymbolsPerFrame = 3
    /// Shorter recordings are rejected: the model has nothing to decode and FluidAudio uses the same floor.
    public static let minimumSamples = sampleRate * 3 / 10

    static func frames(covering samples: Int) -> Int {
        (samples + samplesPerFrame - 1) / samplesPerFrame
    }
}

/// The four Core ML models of FluidAudio's export plus our VAD head and the vocabulary.
public final class ParakeetModels {
    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let joint: MLModel
    let vad: MLModel?
    let vocabulary: Vocabulary

    /// The preprocessor runs on the CPU; everything else prefers the Neural Engine, as FluidAudio does.
    public init(directory: URL, vadModel: URL?) throws {
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let ane = MLModelConfiguration()
        ane.computeUnits = .cpuAndNeuralEngine
        preprocessor = try Self.load(directory.appendingPathComponent("Preprocessor.mlmodelc"), cpu)
        encoder = try Self.load(directory.appendingPathComponent("Encoder.mlmodelc"), ane)
        decoder = try Self.load(directory.appendingPathComponent("Decoder.mlmodelc"), ane)
        joint = try Self.load(directory.appendingPathComponent(ModelStore.jointFilename), ane)
        vad = try vadModel.map { try Self.load($0, ane) }
        vocabulary = try Vocabulary(url: directory.appendingPathComponent("parakeet_v3_vocab.json"))
    }

    private static func load(_ url: URL, _ configuration: MLModelConfiguration) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParakeetError.missingFile(url.lastPathComponent)
        }
        return try MLModel(contentsOf: url, configuration: configuration)
    }
}

/// SentencePiece vocabulary: token id to piece, with "▁" marking a word start.
struct Vocabulary {
    private let pieces: [String]

    init(url: URL) throws {
        let table = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        var pieces = Array(repeating: "", count: table.count)
        for (id, piece) in table {
            guard let index = Int(id), pieces.indices.contains(index) else { continue }
            pieces[index] = piece
        }
        self.pieces = pieces
    }

    func text(for tokens: [Int]) -> String {
        var text = ""
        for token in tokens where token >= 0 && token < pieces.count {
            let piece = pieces[token]
            if piece.hasPrefix("▁") {
                if !text.isEmpty { text += " " }
                text += piece.dropFirst()
            } else {
                text += piece
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
