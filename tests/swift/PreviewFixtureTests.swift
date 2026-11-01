#if DEBUG
import Foundation
import XCTest
@testable import ParakettoKit

final class PreviewFixtureTests: XCTestCase {
    @MainActor
    func testPreviewsUseDisposableDataAndIndependentStores() throws {
        var fixture: PreviewFixtures? = PreviewFixtures()
        let root = fixture!.controller.history.directory.deletingLastPathComponent()
        XCTAssertTrue(root.path.contains("ParakettoPreviews/"))
        XCTAssertEqual(fixture!.controller.dictionary.rules.count, 3)
        XCTAssertEqual(fixture!.controller.history.entries.count, 4)
        XCTAssertTrue(fixture!.controller.history.entries[0].displayText.contains("GitHub"))
        XCTAssertTrue(fixture!.controller.history.entries[0].text.contains("gee tub"))
        XCTAssertEqual(fixture!.controller.state, .loadingModel)
        let empty = PreviewFixtures(empty: true)
        XCTAssertNotEqual(empty.controller.dictionary.url, fixture!.controller.dictionary.url)
        XCTAssertTrue(empty.controller.dictionary.rules.isEmpty)
        XCTAssertTrue(empty.controller.history.entries.isEmpty)
        fixture = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// Every previewed state must leave the real import path closed, so a file dropped on the
    /// canvas cannot reach the recognizer.
    @MainActor
    func testPreviewStatesShowWithoutEnablingImports() {
        let controller = PreviewFixtures(empty: true).controller
        let states: [DictationController.State] = [
            .downloadingModel(0.5), .optimizingModel, .loadingModel, .idle, .recording,
            .transcribing, .notice("Copied"), .failed("No mic access"),
        ]
        for state in states {
            controller.showPreview(state)
            XCTAssertEqual(controller.state, state)
            XCTAssertFalse(controller.canImportFiles, state.label)
            XCTAssertFalse(controller.importFiles([URL(fileURLWithPath: "/tmp/preview.wav")]), state.label)
        }
    }

    /// Retry is clickable in the canvas's Model failed preview and must stay inert there.
    @MainActor
    func testRetryInPreviewDoesNotLoadModels() {
        let controller = PreviewFixtures(empty: true).controller
        controller.showPreview(.failed("Offline"), modelError: "Could not load model: Offline")
        controller.retryModelLoad()
        XCTAssertEqual(controller.state, .failed("Offline"))
        XCTAssertFalse(controller.isLoadingModel)
    }

    @MainActor
    func testPreviewShowsBannersAndModelErrors() {
        let controller = PreviewFixtures(empty: true).controller
        controller.showPreview(.failed("Offline"), modelError: "Could not load model: Offline",
                               fileImport: .init(filename: "a.wav", progress: 0.5), importErrors: ["b.wav: bad"])
        XCTAssertEqual(controller.modelError, "Could not load model: Offline")
        XCTAssertEqual(controller.fileImport?.progress, 0.5)
        XCTAssertEqual(controller.importErrors, ["b.wav: bad"])
        XCTAssertFalse(controller.isLoadingModel)
        controller.showPreview(.loadingModel)
        XCTAssertTrue(controller.isLoadingModel)
        XCTAssertNil(controller.modelError)
        XCTAssertNil(controller.fileImport)
        XCTAssertTrue(controller.importErrors.isEmpty)
    }
}
#endif
