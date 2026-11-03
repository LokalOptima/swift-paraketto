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
    /// Set once the transcript has its file in the transcripts folder, so one deleted there later isn't recreated.
    var textFilename: String? = nil

    // Derived only; deliberately excluded from JSON so the original stays immutable.
    var replacementResult: ReplacementResult? = nil
    var displayText: String { replacementResult?.text ?? text }
    var textFileContents: String { displayText + "\n" }
    var processed: ReplacementResult {
        replacementResult ?? ReplacementResult(original: text, text: text, replacements: [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, text, destination, duration, inferenceMilliseconds, delivery, sourceFilename, textFilename
    }

    var wordCount: Int {
        displayText.split { $0.isWhitespace || $0.isNewline }.count
    }
}

enum TextSearch {
    /// What to look for in what was typed, if anything. A single letter would match nearly everything.
    static func term(in typed: String) -> String {
        let term = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.count < 2 ? "" : term
    }

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

/// Persists the entries in the Transcripts view as `<id>.json` plus `<id>.wav` under Application Support.
/// Each transcript also gets a permanent text file in the `transcripts` folder next to them. Past the
/// retention period an entry leaves the view, its WAV is deleted and its JSON moves to `archive`, which
/// nothing reads, so loading and searching don't slow down as transcripts pile up.
@MainActor
final class HistoryStore: ObservableObject {
    static let retentionDays = 7

    @Published private(set) var entries: [HistoryEntry] = []

    private var matcher = DictionaryMatcher()
    private var dictionarySubscription: AnyCancellable?
    private var evictionSubscription: AnyCancellable?
    let directory: URL
    let transcriptsDirectory: URL

    init(directory: URL? = nil, dictionary: DictionaryStore? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("Paraketto/history", isDirectory: true)
        transcriptsDirectory = self.directory.deletingLastPathComponent().appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        entries = loadAll()
        dictionarySubscription = dictionary?.$rules.sink { [weak self] rules in
            guard let self else { return }
            matcher = DictionaryMatcher(rules: rules)
            entries = entries.map { entry in
                let updated = self.processed(entry)
                self.updateTextFile(of: entry, to: updated)
                return updated
            }
        }
        evictExpired()
        // A menu-bar app can stay open for weeks.
        evictionSubscription = Timer.publish(every: 3600, tolerance: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.evictExpired() }
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
        entries.insert(withTextFile(processed(entry)), at: 0)
    }

    /// Takes entries past the retention period out of the view, but only once their text is safe in its file.
    /// Saves any file that failed before, which is also how transcripts from before this folder existed get theirs.
    func evictExpired(now: Date = Date()) {
        entries = entries.map(withTextFile)
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60)
        entries.removeAll { $0.date < cutoff && $0.textFilename != nil && archive($0) }
    }

    /// Deletes the recording and files away the JSON. The recording goes first, so that if this
    /// stops halfway the JSON is still in place to try again from and no recording is left behind.
    private func archive(_ entry: HistoryEntry) -> Bool {
        let destination = directory.appendingPathComponent("archive", isDirectory: true)
        let audio = audioURL(for: entry), json = jsonURL(for: entry)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
            if FileManager.default.fileExists(atPath: json.path) {
                try FileManager.default.moveItem(at: json, to: destination.appendingPathComponent(json.lastPathComponent))
            }
            return true
        } catch {
            Log.info("Could not archive a transcript: \(error.localizedDescription)")
            return false
        }
    }

    /// The file and its name in the JSON are saved together or not at all, or every launch would add another file.
    private func withTextFile(_ entry: HistoryEntry) -> HistoryEntry {
        guard entry.textFilename == nil else { return entry }
        let url = newTextFileURL(for: entry)
        var result = entry
        result.textFilename = url.lastPathComponent
        do {
            try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
            try entry.textFileContents.write(to: url, atomically: true, encoding: .utf8)
            try JSONEncoder().encode(result).write(to: jsonURL(for: result), options: .atomic)
            return result
        } catch {
            try? FileManager.default.removeItem(at: url)
            Log.info("Could not save a transcript's text file: \(error.localizedDescription)")
            return entry
        }
    }

    /// A dictionary change reaches a text file only while it still holds what was last saved there,
    /// so a file that was edited, renamed or deleted in the meantime stays as it is.
    private func updateTextFile(of entry: HistoryEntry, to updated: HistoryEntry) {
        guard updated.displayText != entry.displayText, let url = textFileURL(for: entry),
              (try? String(contentsOf: url, encoding: .utf8)) == entry.textFileContents else { return }
        try? updated.textFileContents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private func newTextFileURL(for entry: HistoryEntry) -> URL {
        let stamp = Self.filenameFormatter.string(from: entry.date)
        var url = transcriptsDirectory.appendingPathComponent("\(stamp).txt")
        var copy = 1
        while FileManager.default.fileExists(atPath: url.path) {
            copy += 1
            url = transcriptsDirectory.appendingPathComponent("\(stamp) \(copy).txt")
        }
        return url
    }

    private func textFileURL(for entry: HistoryEntry) -> URL? {
        entry.textFilename.map { transcriptsDirectory.appendingPathComponent($0) }
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
        if let url = textFileURL(for: entry) { try? FileManager.default.removeItem(at: url) }
        entries.removeAll { $0.id == entry.id }
    }

    func audioURL(for entry: HistoryEntry) -> URL {
        directory.appendingPathComponent("\(entry.id.uuidString).wav")
    }

    /// Named like the transcript's text file, so the two sort together.
    func recordingFilename(for entry: HistoryEntry) -> String {
        "\(Self.filenameFormatter.string(from: entry.date)).wav"
    }

    /// Off the main thread, as an imported recording can run to hundreds of MB. The write
    /// is atomic and the recording is read first, so a failure leaves a file being replaced as it was.
    func saveRecording(of entry: HistoryEntry, to destination: URL) async throws {
        let recording = audioURL(for: entry)
        try await Task.detached {
            try Data(contentsOf: recording, options: .mappedIfSafe).write(to: destination, options: .atomic)
        }.value
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
