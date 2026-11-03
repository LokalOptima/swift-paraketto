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

enum TextSearch {
    /// Every occurrence of `query`, ignoring case and accents. UTF-16 ranges, matching AppKit's text system.
    static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let text = foldingStrokes(text)
        let query = foldingStrokes(query) as String
        var matches: [NSRange] = []
        var start = 0
        while start < text.length {
            let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: start, length: text.length - start))
            // Besides not found, some marks such as U+0900 match nothing at all, which would never advance.
            guard match.length > 0 else { break }
            matches.append(match)
            start = NSMaxRange(match)
        }
        return matches
    }

    private static let strokedLetters = Dictionary(uniqueKeysWithValues: zip("ŁłØøĐđÐðĦħıŦŧ".utf16, "LlOoDdDdHhiTt".utf16))

    /// Stroked letters don't decompose, so `.diacriticInsensitive` leaves them alone. Each folds
    /// to a single UTF-16 unit, which keeps ranges valid for the original text.
    private static func foldingStrokes(_ text: String) -> NSString {
        guard !text.utf8.allSatisfy({ $0 < 0x80 }) else { return text as NSString }
        return String(decoding: text.utf16.map { $0 < 0xD0 ? $0 : strokedLetters[$0] ?? $0 }, as: UTF16.self) as NSString
    }

    /// Stretches of `text` around `matches` for when only about `capacity` UTF-16 units fit. When more
    /// matches exist than fit, they are sampled evenly so the stretches span the whole transcript.
    /// Stretches stop at word boundaries, and stretches with only whitespace between them join.
    static func excerpt(of text: String, around matches: [NSRange], capacity: Int, context: Int = 30) -> [NSRange] {
        guard let first = matches.first else { return [] }
        let text = text as NSString
        let separatorLength = 3
        let fitting = max(1, capacity / (2 * context + first.length + separatorLength))
        let chosen = matches.count <= fitting ? matches
            : (0..<fitting).map { matches[$0 * (matches.count - 1) / max(1, fitting - 1)] }
        var stretches: [NSRange] = []
        for match in chosen {
            let next = stretch(around: match, in: text, context: context)
            if let last = stretches.last, onlyWhitespaceSeparates(last, next, in: text) {
                stretches[stretches.count - 1] = NSUnionRange(last, next)
            } else {
                stretches.append(next)
            }
        }
        return stretches
    }

    private static func onlyWhitespaceSeparates(_ first: NSRange, _ second: NSRange, in text: NSString) -> Bool {
        let end = NSMaxRange(first)
        guard second.location > end else { return true }
        let gap = NSRange(location: end, length: second.location - end)
        return text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, range: gap).location == NSNotFound
    }

    private static func stretch(around match: NSRange, in text: NSString, context: Int) -> NSRange {
        let matchEnd = NSMaxRange(match)
        var start = 0
        if match.location > context {
            let earliest = text.rangeOfComposedCharacterSequence(at: match.location - context).location
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines,
                                              range: NSRange(location: earliest, length: match.location - earliest))
            start = space.location == NSNotFound ? earliest : NSMaxRange(space)
        }
        var end = text.length
        if text.length - matchEnd > context {
            let latest = NSMaxRange(text.rangeOfComposedCharacterSequence(at: matchEnd + context - 1))
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                              range: NSRange(location: matchEnd, length: latest - matchEnd))
            end = space.location == NSNotFound ? latest : space.location
        }
        return NSRange(location: start, length: end - start)
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
