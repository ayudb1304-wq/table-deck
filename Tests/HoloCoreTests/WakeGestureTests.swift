import XCTest
@testable import HoloCore

final class WakeGestureTests: XCTestCase {
    func testTwoTransientsInsideTheWindowCompleteTheGesture() {
        var detector = WakeGestureDetector()
        XCTAssertFalse(detector.noteTransient(at: 10.0))
        XCTAssertTrue(detector.noteTransient(at: 10.4))
    }

    func testTransientsSpreadWiderThanTheWindowDoNotWake() {
        var detector = WakeGestureDetector()
        XCTAssertFalse(detector.noteTransient(at: 10.0))
        XCTAssertFalse(detector.noteTransient(at: 11.5))
        // The stale first transient must not keep counting: a third tap close
        // to the second one is what finally wakes.
        XCTAssertTrue(detector.noteTransient(at: 11.9))
    }

    func testOneImpactRingingAcrossBuffersIsNotADoubleTap() {
        var detector = WakeGestureDetector()
        XCTAssertFalse(detector.noteTransient(at: 5.00))
        XCTAssertFalse(detector.noteTransient(at: 5.01), "10 ms apart is one impact, not two taps")
        XCTAssertFalse(detector.noteTransient(at: 5.02))
        XCTAssertTrue(detector.noteTransient(at: 5.30))
    }

    func testCompletingTheGestureClearsIt() {
        var detector = WakeGestureDetector()
        XCTAssertFalse(detector.noteTransient(at: 1.0))
        XCTAssertTrue(detector.noteTransient(at: 1.2))
        XCTAssertFalse(detector.noteTransient(at: 1.4), "A fresh double tap is required for the next wake")
        XCTAssertTrue(detector.noteTransient(at: 1.6))
    }

    func testResetDropsPartialProgress() {
        var detector = WakeGestureDetector()
        XCTAssertFalse(detector.noteTransient(at: 1.0))
        detector.reset()
        XCTAssertFalse(detector.noteTransient(at: 1.2))
    }

    func testNonFiniteTimestampsAreIgnored() {
        var detector = WakeGestureDetector()
        XCTAssertFalse(detector.noteTransient(at: .nan))
        XCTAssertFalse(detector.noteTransient(at: 1.0))
        XCTAssertTrue(detector.noteTransient(at: 1.3))
    }
}
