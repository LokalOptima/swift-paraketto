import XCTest
@testable import ParakettoKit

@MainActor
final class RecordingDownloadTests: XCTestCase {
    private var root: URL!
    private var history: URL { root.appendingPathComponent("history") }
    private var destination: URL { root.appendingPathComponent("downloaded.wav") }
    private let week: TimeInterval = 7 * 24 * 60 * 60

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func add(date: Date = Date(), to store: HistoryStore) throws -> HistoryEntry {
        let entry = HistoryEntry(id: UUID(), date: date, text: "hello", destination: "Notes", duration: 1,
                                 inferenceMilliseconds: 1, delivery: .pasted)
        let recording = try RecordingFile()
        try recording.append([0.1, 0.2, 0.3])
        try store.add(entry, recording: recording)
        return try XCTUnwrap(store.entries.first { $0.id == entry.id })
    }

    func testDownloadingCopiesTheRecordingAndLeavesItInPlace() async throws {
        let store = HistoryStore(directory: history)
        let saved = try add(to: store)
        let original = try Data(contentsOf: store.audioURL(for: saved))

        try await store.saveRecording(of: saved, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: saved)), original)
        XCTAssertEqual(store.entries.map(\.id), [saved.id])
    }

    func testDownloadingReplacesAFileAlreadyThere() async throws {
        let store = HistoryStore(directory: history)
        let saved = try add(to: store)
        try Data("old".utf8).write(to: destination)

        try await store.saveRecording(of: saved, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: store.audioURL(for: saved)))
    }

    func testAMissingRecordingFailsAndLeavesAFileAlreadyThereAlone() async throws {
        let store = HistoryStore(directory: history)
        let saved = try add(to: store)
        try FileManager.default.removeItem(at: store.audioURL(for: saved))
        try Data("old".utf8).write(to: destination)

        do {
            try await store.saveRecording(of: saved, to: destination)
            XCTFail("Expected the download to fail")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testAFailedDownloadLeavesNoFileBehind() async throws {
        let store = HistoryStore(directory: history)
        let saved = try add(to: store)
        let folder = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: store.audioURL(for: saved))

        do {
            try await store.saveRecording(of: saved, to: folder.appendingPathComponent("gone.wav"))
            XCTFail("Expected the download to fail")
        } catch {}

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testTheSuggestedNameMatchesTheTranscriptsTextFile() throws {
        let store = HistoryStore(directory: history)
        let saved = try add(to: store)

        let name = store.recordingFilename(for: saved)

        XCTAssertEqual(name.replacingOccurrences(of: ".wav", with: ".txt"), saved.textFilename)
    }

    func testADownloadedCopyOutlivesTheRecordingsDeletionAfterAWeek() async throws {
        let store = HistoryStore(directory: history)
        let saved = try add(to: store)
        let recording = store.audioURL(for: saved)
        try await store.saveRecording(of: saved, to: destination)

        store.evictExpired(now: saved.date.addingTimeInterval(week + 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(store.entries.isEmpty)
    }
}
