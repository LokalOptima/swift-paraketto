import AppKit
import Combine
import XCTest
@testable import ParakettoKit

@MainActor
final class ScrollActivityTests: XCTestCase {
    private let activity = ScrollActivity.shared

    override func setUp() async throws {
        activity.scrolled(phase: .ended, momentumPhase: [])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(activity.isScrolling)
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func fingers(_ phase: NSEvent.Phase) {
        activity.scrolled(phase: phase, momentumPhase: [])
    }

    private func glide(_ phase: NSEvent.Phase) {
        activity.scrolled(phase: [], momentumPhase: phase)
    }

    func testMovingFingersCountAsScrolling() {
        fingers(.began)
        XCTAssertTrue(activity.isScrolling)
    }

    func testRestingFingersDoNotCount() {
        fingers(.mayBegin)
        XCTAssertFalse(activity.isScrolling)
        fingers(.cancelled)
        wait(0.05)
        XCTAssertFalse(activity.isScrolling)
    }

    func testHoverReturnsShortlyAfterTheFingersLift() {
        fingers(.began)
        fingers(.changed)
        fingers(.ended)
        wait(0.1)
        XCTAssertTrue(activity.isScrolling, "still inside the wait")
        wait(0.2)
        XCTAssertFalse(activity.isScrolling)
    }

    func testFingersHeldStillKeepHoverOff() {
        fingers(.began)
        wait(0.5)
        XCTAssertTrue(activity.isScrolling)
    }

    func testTheGlideNeitherDelaysHoverNorHidesItAgain() {
        fingers(.began)
        fingers(.ended)
        glide(.began)
        for _ in 0..<30 {
            glide(.changed)
            wait(0.01)
        }
        XCTAssertFalse(activity.isScrolling, "the glide must not extend the wait")
        glide(.changed)
        glide(.ended)
        XCTAssertFalse(activity.isScrolling, "the rest of the glide must not hide the actions again")
    }

    func testANewGestureCancelsTheWait() {
        fingers(.began)
        fingers(.ended)
        wait(0.1)
        fingers(.began)
        wait(0.2)
        XCTAssertTrue(activity.isScrolling)
    }

    func testALiftThatNeverArrivesDoesNotHideTheActionsForever() {
        fingers(.began)
        wait(1.5)
        XCTAssertTrue(activity.isScrolling, "the timeout is far longer than the wait after a lift")
        // The system may run a sleep this long up to 10% late.
        wait(0.9)
        XCTAssertFalse(activity.isScrolling)
    }

    func testMouseWheelEndsShortlyAfterItsLastNotch() {
        for _ in 0..<4 {
            activity.scrolled(phase: [], momentumPhase: [])
            XCTAssertTrue(activity.isScrolling)
            wait(0.1)
        }
        XCTAssertTrue(activity.isScrolling, "still inside the wait")
        wait(0.2)
        XCTAssertFalse(activity.isScrolling)
    }

    func testEventsInTheSameStateDoNotRepublish() {
        var changes = 0
        let subscription = activity.objectWillChange.sink { changes += 1 }
        fingers(.began)
        for _ in 0..<50 { fingers(.changed) }
        XCTAssertEqual(changes, 1, "each publish re-renders every visible row")
        subscription.cancel()
    }

    func testRealScrollEventsReachIt() throws {
        _ = NSApplication.shared
        func send(_ scroll: CGScrollPhase?, momentum: CGMomentumScrollPhase = .none) throws {
            let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scroll?.rawValue ?? 0))
            cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            NSApp.sendEvent(try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        }
        try send(.began)
        XCTAssertTrue(activity.isScrolling)
        try send(.ended)
        try send(nil, momentum: .begin)
        wait(0.3)
        XCTAssertFalse(activity.isScrolling)
        try send(nil, momentum: .continuous)
        XCTAssertFalse(activity.isScrolling, "a real momentum event must not count as a wheel notch")
    }
}
