import XCTest
@testable import ParakettoKit

@MainActor
final class TranscriptFolderTests: XCTestCase {
    private var root: URL!
    private var history: URL { root.appendingPathComponent("history") }
    private var folder: URL { root.appendingPathComponent("transcripts") }
    private var archive: URL { history.appendingPathComponent("archive") }
    private let week: TimeInterval = 7 * 24 * 60 * 60

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ text: String = "hello", date: Date = Date()) -> HistoryEntry {
        HistoryEntry(id: UUID(), date: date, text: text, destination: "Notes", duration: 1,
                     inferenceMilliseconds: 1, delivery: .pasted)
    }

    @discardableResult
    private func add(_ entry: HistoryEntry, to store: HistoryStore) throws -> HistoryEntry {
        let recording = try RecordingFile()
        try recording.append([0.1])
        try store.add(entry, recording: recording)
        return try XCTUnwrap(store.entries.first { $0.id == entry.id })
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func text(of name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// An entry as saved by a version of the app that had no transcripts folder.
    private func writeLegacy(_ entry: HistoryEntry) throws {
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        fields.removeValue(forKey: "textFilename")
        try JSONSerialization.data(withJSONObject: fields).write(to: history.appendingPathComponent("\(entry.id.uuidString).json"))
        try Data([1, 2, 3]).write(to: history.appendingPathComponent("\(entry.id.uuidString).wav"))
    }

    // MARK: Saving

    func testADictationSavesTheTextAsShownNamedByItsLocalDate() throws {
        let dictionary = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        try dictionary.save(DictionaryRule(target: "GitHub", aliases: ["gee tub"]))
        let store = HistoryStore(directory: history, dictionary: dictionary)
        let date = Date()
        let saved = try add(entry("pushed to gee tub", date: date), to: store)

        let name = "\(stamp(date)).txt"
        XCTAssertEqual(files(in: folder), [name])
        XCTAssertEqual(saved.textFilename, name)
        XCTAssertEqual(try text(of: name), "pushed to GitHub\n")
    }

    func testTheNameOfTheFileSurvivesARelaunchAndNothingIsWrittenTwice() throws {
        let store = HistoryStore(directory: history)
        let saved = try add(entry(), to: store)
        let reloaded = HistoryStore(directory: history)
        XCTAssertEqual(reloaded.entries, store.entries)
        XCTAssertEqual(reloaded.entries.first?.textFilename, saved.textFilename)
        XCTAssertEqual(files(in: folder).count, 1)
    }

    func testDeliveryUpdatesKeepTheNameOfTheFile() throws {
        let store = HistoryStore(directory: history)
        let saved = try add(entry(), to: store)
        try store.updateDelivery(id: saved.id, to: .copied)
        let reloaded = HistoryStore(directory: history).entries.first
        XCTAssertEqual(reloaded?.delivery, .copied)
        XCTAssertEqual(reloaded?.textFilename, saved.textFilename)
    }

    func testTranscriptsFromTheSameSecondGetSeparateFiles() throws {
        let store = HistoryStore(directory: history)
        let date = Date()
        try add(entry("first", date: date), to: store)
        try add(entry("second", date: date), to: store)
        try add(entry("third", date: date), to: store)
        XCTAssertEqual(try text(of: "\(stamp(date)).txt"), "first\n")
        XCTAssertEqual(try text(of: "\(stamp(date)) 2.txt"), "second\n")
        XCTAssertEqual(try text(of: "\(stamp(date)) 3.txt"), "third\n")
    }

    func testAccentsAndNewlinesAreWrittenAsUTF8() throws {
        let store = HistoryStore(directory: history)
        let saved = try add(entry("Wrocław ☕️\nsecond line"), to: store)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(saved.textFilename!)),
                       Data("Wrocław ☕️\nsecond line\n".utf8))
    }

    func testDeletingATranscriptDeletesItsFile() throws {
        let store = HistoryStore(directory: history)
        let saved = try add(entry(), to: store)
        try add(entry("the other one", date: Date().addingTimeInterval(5)), to: store)
        store.remove(saved)
        XCTAssertEqual(files(in: folder).count, 1)
        XCTAssertEqual(try text(of: files(in: folder)[0]), "the other one\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: saved).path))
    }

    // MARK: Leaving the view

    func testAfterAWeekTheFileStaysTheRecordingGoesAndTheJSONIsArchived() throws {
        let store = HistoryStore(directory: history)
        let date = Date()
        let saved = try add(entry("old news", date: date), to: store)
        let name = try XCTUnwrap(saved.textFilename)

        store.evictExpired(now: date.addingTimeInterval(week - 1))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: saved).path))

        store.evictExpired(now: date.addingTimeInterval(week + 1))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try text(of: name), "old news\n")
        XCTAssertEqual(files(in: archive), ["\(saved.id.uuidString).json"])
        XCTAssertEqual(files(in: history), ["archive"])
        XCTAssertTrue(HistoryStore(directory: history).entries.isEmpty)
    }

    func testOnlyEntriesPastTheWeekLeaveAndTheirOrderIsKept() throws {
        let store = HistoryStore(directory: history)
        let now = Date()
        let old = try add(entry("old", date: now.addingTimeInterval(-week - 60)), to: store)
        let recent = try add(entry("recent", date: now.addingTimeInterval(-week + 60)), to: store)
        let newest = try add(entry("newest", date: now), to: store)
        store.evictExpired(now: now)
        XCTAssertEqual(store.entries.map(\.id), [newest.id, recent.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: old).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: recent).path))
        XCTAssertEqual(files(in: folder).count, 3)
    }

    func testOpeningTheAppAlsoEvicts() throws {
        let old = entry("old", date: Date().addingTimeInterval(-week - 60))
        let store = HistoryStore(directory: history)
        try add(old, to: store)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(HistoryStore(directory: history).entries.isEmpty)
        XCTAssertEqual(files(in: folder).count, 1)
    }

    func testEvictingNothingChangesNothing() throws {
        let store = HistoryStore(directory: history)
        let saved = try add(entry(), to: store)
        let json = history.appendingPathComponent("\(saved.id.uuidString).json")
        let before = try Data(contentsOf: json)
        store.evictExpired()
        XCTAssertEqual(store.entries.map(\.id), [saved.id])
        XCTAssertEqual(try Data(contentsOf: json), before)
        XCTAssertEqual(files(in: folder).count, 1)
    }

    // MARK: Transcripts from before the folder existed

    func testOldTranscriptsGetFilesOnTheFirstLaunchAndOnlyOnce() throws {
        let dictionary = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        try dictionary.save(DictionaryRule(target: "GitHub", aliases: ["gee tub"]))
        let oldDate = Date().addingTimeInterval(-week * 3)
        let recentDate = Date().addingTimeInterval(-60)
        let old = entry("gee tub old", date: oldDate)
        let recent = entry("gee tub recent", date: recentDate)
        try writeLegacy(old)
        try writeLegacy(recent)

        let store = HistoryStore(directory: history, dictionary: dictionary)

        XCTAssertEqual(store.entries.map(\.id), [recent.id])
        XCTAssertEqual(try text(of: "\(stamp(oldDate)).txt"), "GitHub old\n")
        XCTAssertEqual(try text(of: "\(stamp(recentDate)).txt"), "GitHub recent\n")
        XCTAssertEqual(files(in: archive), [old.id.uuidString + ".json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent(old.id.uuidString + ".wav").path))
        XCTAssertEqual(try Data(contentsOf: history.appendingPathComponent(recent.id.uuidString + ".wav")), Data([1, 2, 3]))

        let archived = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: archive.appendingPathComponent(old.id.uuidString + ".json")))
        XCTAssertEqual(archived.text, "gee tub old")
        XCTAssertEqual(archived.textFilename, "\(stamp(oldDate)).txt")

        let reloaded = HistoryStore(directory: history, dictionary: dictionary)
        XCTAssertEqual(reloaded.entries.first?.textFilename, "\(stamp(recentDate)).txt")
        XCTAssertEqual(files(in: folder).count, 2)
    }

    // MARK: Nothing is lost when something fails

    func testAnEntryStaysUntilItsFileIsSaved() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: folder)  // A plain file where the folder belongs.
        let store = HistoryStore(directory: history)
        let date = Date()
        let saved = try add(entry("keep me", date: date), to: store)
        XCTAssertNil(saved.textFilename)

        let later = date.addingTimeInterval(week + 1)
        store.evictExpired(now: later)
        XCTAssertEqual(store.entries.map(\.id), [saved.id])
        XCTAssertEqual(files(in: history).sorted(), ["\(saved.id.uuidString).json", "\(saved.id.uuidString).wav"])

        try FileManager.default.removeItem(at: folder)
        store.evictExpired(now: later)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try text(of: "\(stamp(date)).txt"), "keep me\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: saved).path))
    }

    func testAFileWhoseNameCannotBeRecordedIsNotLeftBehind() throws {
        let old = entry("stuck")
        try writeLegacy(old)
        // A read-only folder stops the atomic write that records the name in the JSON.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: history.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: history.path) }
        let store = HistoryStore(directory: history)
        XCTAssertEqual(store.entries.map(\.id), [old.id])
        XCTAssertNil(store.entries.first?.textFilename)
        XCTAssertEqual(files(in: folder), [], "Every launch would otherwise add another file")
    }

    func testAnEntryThatCannotBeArchivedStaysInTheView() throws {
        let store = HistoryStore(directory: history)
        let date = Date()
        let saved = try add(entry(date: date), to: store)
        try Data().write(to: archive)  // A plain file where the folder belongs.
        store.evictExpired(now: date.addingTimeInterval(week + 1))
        XCTAssertEqual(store.entries.map(\.id), [saved.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: saved).path))
    }

    func testAnEntryWhoseJSONCannotMoveStaysAndIsTriedAgain() throws {
        let store = HistoryStore(directory: history)
        let date = Date()
        let saved = try add(entry(date: date), to: store)
        let name = "\(saved.id.uuidString).json"
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data().write(to: archive.appendingPathComponent(name))  // Moving onto an existing file fails.
        let later = date.addingTimeInterval(week + 1)

        store.evictExpired(now: later)
        XCTAssertEqual(store.entries.map(\.id), [saved.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent(name).path))

        try FileManager.default.removeItem(at: archive.appendingPathComponent(name))
        store.evictExpired(now: later)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(files(in: archive), [name])
    }

    func testAnArchiveInterruptedByACrashIsFinishedOnTheNextLaunch() throws {
        let store = HistoryStore(directory: history)
        let saved = try add(entry(date: Date().addingTimeInterval(-week - 60)), to: store)
        try FileManager.default.removeItem(at: store.audioURL(for: saved))

        XCTAssertTrue(HistoryStore(directory: history).entries.isEmpty)
        XCTAssertEqual(files(in: archive), ["\(saved.id.uuidString).json"])
        XCTAssertEqual(files(in: history), ["archive"])
    }

    // MARK: The folder belongs to the user

    func testAFileDeletedInTheFolderIsNotRecreated() throws {
        let store = HistoryStore(directory: history)
        let date = Date()
        let saved = try add(entry(date: date), to: store)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(saved.textFilename!))

        XCTAssertEqual(HistoryStore(directory: history).entries.count, 1)
        XCTAssertEqual(files(in: folder), [])
        store.evictExpired(now: date.addingTimeInterval(week + 1))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(files(in: folder), [])
    }

    func testADictionaryChangeReachesOnlyFilesLeftAlone() throws {
        let dictionary = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        let store = HistoryStore(directory: history, dictionary: dictionary)
        let now = Date()
        let untouched = try add(entry("gee tub a", date: now), to: store)
        let edited = try add(entry("gee tub b", date: now.addingTimeInterval(1)), to: store)
        let deleted = try add(entry("gee tub c", date: now.addingTimeInterval(2)), to: store)
        let renamed = try add(entry("gee tub d", date: now.addingTimeInterval(3)), to: store)
        let unrelated = try add(entry("no match", date: now.addingTimeInterval(4)), to: store)
        try "my own notes\n".write(to: folder.appendingPathComponent(edited.textFilename!), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(deleted.textFilename!))
        try FileManager.default.moveItem(at: folder.appendingPathComponent(renamed.textFilename!),
                                         to: folder.appendingPathComponent("mine.txt"))
        let before = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(unrelated.textFilename!).path)[.modificationDate] as? Date

        try dictionary.save(DictionaryRule(target: "GitHub", aliases: ["gee tub"]))

        XCTAssertEqual(try text(of: untouched.textFilename!), "GitHub a\n")
        XCTAssertEqual(try text(of: edited.textFilename!), "my own notes\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(deleted.textFilename!).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(renamed.textFilename!).path))
        XCTAssertEqual(try text(of: "mine.txt"), "gee tub d\n")
        let after = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(unrelated.textFilename!).path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)

        // Removing the rule brings the untouched file back, as each change follows the last one saved.
        let rule = try XCTUnwrap(dictionary.rules.first)
        try dictionary.remove(id: rule.id)
        XCTAssertEqual(try text(of: untouched.textFilename!), "gee tub a\n")
    }

    func testFilesOfTranscriptsThatLeftTheViewStayAsTheyAre() throws {
        let dictionary = DictionaryStore(url: root.appendingPathComponent("dictionary.json"))
        let store = HistoryStore(directory: history, dictionary: dictionary)
        let date = Date()
        let saved = try add(entry("gee tub", date: date), to: store)
        store.evictExpired(now: date.addingTimeInterval(week + 1))
        try dictionary.save(DictionaryRule(target: "GitHub", aliases: ["gee tub"]))
        XCTAssertEqual(try text(of: saved.textFilename!), "gee tub\n")
    }

    // MARK: Previews

    func testPreviewsKeepTheirFilesInTheirDisposableFolder() throws {
        var fixtures: PreviewFixtures? = PreviewFixtures()
        let directory = try XCTUnwrap(fixtures?.controller.history.transcriptsDirectory)
        XCTAssertTrue(directory.path.contains("ParakettoPreviews/"))
        XCTAssertEqual(files(in: directory).count, 4)
        fixtures = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
