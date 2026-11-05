import XCTest
@testable import ParakettoKit

@MainActor
final class TranscriptDeletionTests: XCTestCase {
    private func warning(for text: String) -> String {
        TranscriptsView.deletionWarning(for: HistoryEntry(id: UUID(), date: Date(), text: text, destination: "Notes", duration: 1,
                                                          inferenceMilliseconds: 1, delivery: .pasted))
    }

    func testAShortTranscriptIsQuotedWhole() {
        XCTAssertTrue(warning(for: "Call the dentist").hasPrefix("“Call the dentist”\n"))
    }

    func testAnExactFitIsNotMarkedAsCut() {
        let text = String(repeating: "a", count: 80)
        XCTAssertTrue(warning(for: text).hasPrefix("“\(text)”"))
    }

    func testALongTranscriptIsCutAndMarked() {
        let start = String(repeating: "a", count: 80)
        XCTAssertTrue(warning(for: start + "bbb").hasPrefix("“\(start)…”"))
    }

    func testTheWarningSaysItIsPermanent() {
        XCTAssertTrue(warning(for: "Call the dentist").hasSuffix("This can't be undone."))
    }
}
