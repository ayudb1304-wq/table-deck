import XCTest
@testable import HoloCore

final class DetectorDozeTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func makeDetector(warmUp: Double = 0) -> StreamingTapDetector {
        StreamingTapDetector(
            sampleRate: sampleRate,
            channelCount: 1,
            warmUpDuration: warmUp
        )
    }

    private func quiet(_ count: Int = 512, level: Float = 0.0004) -> [Float] {
        Array(repeating: level, count: count)
    }

    private func tapBuffer(_ count: Int = 512, peak: Float = 0.3) -> [Float] {
        var chunk = quiet(count)
        chunk[count / 4] = peak
        chunk[count / 4 + 1] = -peak * 0.65
        return chunk
    }

    func testDozeEmitsNoTaps() {
        let detector = makeDetector()
        detector.setMode(.doze)

        var taps: [DetectedTap] = []
        for _ in 0..<40 {
            taps += detector.step(channels: [tapBuffer()]).taps
        }
        XCTAssertTrue(taps.isEmpty, "Doze must never produce a classifiable tap")
    }

    func testDozeReportsStrongTransientsAsWakeCandidates() {
        let detector = makeDetector()
        detector.setMode(.doze)

        for _ in 0..<20 { _ = detector.step(channels: [quiet()]) }
        let step = detector.step(channels: [tapBuffer()])
        XCTAssertEqual(step.wakeTransients, 1)
        XCTAssertTrue(step.taps.isEmpty)
    }

    func testDozeIgnoresRoomNoise() {
        let detector = makeDetector()
        detector.setMode(.doze)

        var transients = 0
        for _ in 0..<200 {
            transients += detector.step(channels: [quiet()]).wakeTransients
        }
        XCTAssertEqual(transients, 0, "A steady room must not look like a wake gesture")
    }

    /// The pairing that acceptance criterion 3 describes: a double tap in Doze
    /// completes the gesture, and the next tap after switching to Armed is
    /// emitted for classification.
    func testDoubleTapWakesAndTheNextTapClassifiesNormally() {
        let detector = makeDetector()
        detector.setMode(.doze)
        var gesture = WakeGestureDetector()

        for _ in 0..<20 { _ = detector.step(channels: [quiet()]) }

        var woke = false
        var now = 0.0
        let bufferSeconds = 512.0 / sampleRate
        for index in 0..<40 {
            // Two deliberate taps roughly 300 ms apart.
            let isTap = index == 0 || index == 28
            let step = detector.step(channels: [isTap ? tapBuffer() : quiet()])
            if step.wakeTransients > 0, gesture.noteTransient(at: now) { woke = true }
            now += bufferSeconds
        }
        XCTAssertTrue(woke, "Two strong transients inside one second must wake")

        detector.setMode(.armed)
        var taps: [DetectedTap] = []
        for _ in 0..<20 { taps += detector.step(channels: [quiet()]).taps }
        taps += detector.step(channels: [tapBuffer(peak: 0.45)]).taps
        for _ in 0..<12 { taps += detector.step(channels: [quiet()]).taps }
        XCTAssertEqual(taps.count, 1, "The first tap after waking must classify normally")
    }

    func testSwitchingModesKeepsTheLearnedNoiseFloor() {
        let detector = StreamingTapDetector(sampleRate: sampleRate, channelCount: 1)
        for _ in 0..<160 { _ = detector.step(channels: [quiet(512, level: 0.01)]) }
        let learned = detector.noiseFloorRMS
        XCTAssertGreaterThan(learned, 0.002)

        detector.setMode(.doze)
        XCTAssertEqual(detector.noiseFloorRMS, learned, accuracy: 1e-12)
        detector.setMode(.armed)
        XCTAssertEqual(detector.noiseFloorRMS, learned, accuracy: 1e-12)
    }

    func testArmedModeStillEmitsTheOnsetCandidateFlag() {
        let detector = makeDetector()
        for _ in 0..<20 { _ = detector.step(channels: [quiet()]) }
        let step = detector.step(channels: [tapBuffer()])
        XCTAssertTrue(step.onsetCandidate, "Hybrid confirmation chirps depend on this flag")
        XCTAssertEqual(step.wakeTransients, 0, "Wake transients are a Doze-only concept")
    }

    func testLongDozeBuffersAreHandledWithoutTruncation() {
        let detector = StreamingTapDetector(
            sampleRate: sampleRate,
            channelCount: 1,
            warmUpDuration: 0,
            maximumBufferFrames: 8_192
        )
        detector.setMode(.doze)
        for _ in 0..<10 { _ = detector.step(channels: [quiet(4_096)]) }
        let step = detector.step(channels: [tapBuffer(4_096)])
        XCTAssertEqual(step.wakeTransients, 1)
        XCTAssertEqual(detector.totalSamples, 4_096 * 11)
    }

    /// A long steady-state run. It does not prove the allocation count is zero
    /// (that needs Instruments, per acceptance criterion 7), but it does prove
    /// the reused buffers stay correct over many callbacks and that nothing
    /// drifts once the detector has settled.
    func testSteadyStateRemainsStableOverManyCallbacks() {
        let detector = makeDetector(warmUp: 0.75)
        for _ in 0..<5_000 { _ = detector.step(channels: [quiet()]) }
        XCTAssertTrue(detector.noiseFloorRMS.isFinite)
        XCTAssertEqual(detector.totalSamples, 512 * 5_000)

        let step = detector.step(channels: [tapBuffer(peak: 0.5)])
        XCTAssertTrue(step.onsetCandidate, "The detector must still trigger after a long quiet run")
    }
}
