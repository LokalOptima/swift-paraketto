import Combine
import Foundation

/// One dictation: transcript, where it went, and the recording that produced it.
struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Delivery: String, Codable {
        case pasted
        case copied
        case keptInHistory
        case imported
    }

    let id: UUID
    let date: Date
    /// Persisted verbatim recognition output. Never rewritten by dictionary changes.
    let text: String
    let destination: String
    let duration: TimeInterval
    var inferenceMilliseconds: Int
    var delivery: Delivery
    var sourceFilename: String? = nil

    // Derived only; deliberately excluded from JSON so the original stays immutable.
    var replacementResult: ReplacementResult? = nil
    var displayText: String { replacementResult?.text ?? text }
    var processed: ReplacementResult {
        replacementResult ?? ReplacementResult(original: text, text: text, replacements: [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, text, destination, duration, inferenceMilliseconds, delivery, sourceFilename
    }

    var wordCount: Int {
        displayText.split { $0.isWhitespace || $0.isNewline }.count
    }
}

/// Persists entries as `<id>.json` plus `<id>.wav` under Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private var matcher = DictionaryMatcher()
    private var dictionarySubscription: AnyCancellable?
    let directory: URL

    init(directory: URL? = nil, dictionary: DictionaryStore? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("Paraketto/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        entries = loadAll()
        dictionarySubscription = dictionary?.$rules.sink { [weak self] rules in
            guard let self else { return }
            matcher = DictionaryMatcher(rules: rules)
            entries = entries.map { self.processed($0) }
        }
    }

    func add(_ entry: HistoryEntry, recording: RecordingFile) throws {
        let metadata = try JSONEncoder().encode(entry)
        try recording.move(to: audioURL(for: entry))
        do {
            try metadata.write(to: jsonURL(for: entry), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: audioURL(for: entry))
            throw error
        }
        entries.insert(processed(entry), at: 0)
    }

    func process(_ text: String) -> ReplacementResult { matcher.apply(to: text) }

    private func processed(_ entry: HistoryEntry) -> HistoryEntry {
        var result = entry
        let replacement = process(entry.text)
        result.replacementResult = replacement.replacements.isEmpty ? nil : replacement
        return result
    }

    /// Delivery metadata may change; the saved transcript remains the original.
    func updateDelivery(id: UUID, to delivery: HistoryEntry.Delivery) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        entry.delivery = delivery
        try JSONEncoder().encode(entry).write(to: jsonURL(for: entry), options: .atomic)
        entries[index] = entry
    }

    func remove(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: jsonURL(for: entry))
        try? FileManager.default.removeItem(at: audioURL(for: entry))
        entries.removeAll { $0.id == entry.id }
    }

    func audioURL(for entry: HistoryEntry) -> URL {
        directory.appendingPathComponent("\(entry.id.uuidString).wav")
    }

    private func jsonURL(for entry: HistoryEntry) -> URL {
        directory.appendingPathComponent("\(entry.id.uuidString).json")
    }

    private func loadAll() -> [HistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(HistoryEntry.self, from: $0) } }
            .sorted { $0.date > $1.date }
    }

    // MARK: Stats

    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }
}
