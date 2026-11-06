import Foundation

/// Every transcript is a plain text file in `transcripts/` under Application Support, named by the
/// date and time of its dictation or import. Paraketto writes each file once and never changes or removes it.
struct TranscriptFolder {
    let url: URL

    init(url: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = url ?? support.appendingPathComponent("Paraketto/transcripts", isDirectory: true)
    }

    /// A transcript from the same second as an existing file gets a numbered name instead of replacing it.
    @discardableResult
    func save(_ text: String, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let stamp = Self.filenameFormatter.string(from: date)
        let data = Data((text + "\n").utf8)
        var copy = 1
        while true {
            let name = copy == 1 ? stamp : "\(stamp) \(copy)"
            let file = url.appendingPathComponent("\(name).txt")
            do {
                try data.write(to: file, options: .withoutOverwriting)
                return file
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                copy += 1
            }
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

/// Earlier versions also kept each transcript's original text as JSON and its recording as WAV in
/// `history/`, for 7 days. Each of those transcripts first gets its text file if it never got one,
/// then its JSON joins the older ones in `history/archive`, which nothing reads, and its recording is
/// deleted. A transcript whose text file can't be written keeps both for a later launch to retry.
enum LegacyHistory {
    static let directory = TranscriptFolder().url.deletingLastPathComponent()
        .appendingPathComponent("history", isDirectory: true)

    private struct Entry: Decodable {
        let date: Date
        let text: String
        let textFilename: String?
    }

    @MainActor
    static func clear(_ directory: URL = LegacyHistory.directory, into transcripts: TranscriptFolder, dictionary: DictionaryStore) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let archive = directory.appendingPathComponent("archive", isDirectory: true)
        for json in files where json.pathExtension == "json" {
            do {
                try saveTextFile(of: json, into: transcripts, dictionary: dictionary)
                try manager.createDirectory(at: archive, withIntermediateDirectories: true)
                try manager.moveItem(at: json, to: archive.appendingPathComponent(json.lastPathComponent))
            } catch {
                Log.info("Could not clear an old transcript: \(error.localizedDescription)")
            }
        }
        // Also catches recordings whose transcripts were deleted in the app while their recordings couldn't be.
        for recording in files where recording.pathExtension == "wav"
            && !manager.fileExists(atPath: recording.deletingPathExtension().appendingPathExtension("json").path) {
            do { try manager.removeItem(at: recording) }
            catch { Log.info("Could not delete an old recording: \(error.localizedDescription)") }
        }
    }

    /// The file's name goes into the JSON straight away, so a launch after a failure further on doesn't write a second file.
    @MainActor
    private static func saveTextFile(of json: URL, into transcripts: TranscriptFolder, dictionary: DictionaryStore) throws {
        let data = try Data(contentsOf: json)
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        guard entry.textFilename == nil else { return }
        let file = try transcripts.save(dictionary.apply(to: entry.text), date: entry.date)
        do {
            guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            fields["textFilename"] = file.lastPathComponent
            try JSONSerialization.data(withJSONObject: fields).write(to: json, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
