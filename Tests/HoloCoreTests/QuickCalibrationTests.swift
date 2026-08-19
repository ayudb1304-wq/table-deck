import XCTest
@testable import HoloCore

final class QuickCalibrationTests: XCTestCase {

    // MARK: - Session shape

    func testQuickSessionAsksForFourTapsPerZone() {
        var session = CalibrationSession(draft: CalibrationDraft(), mode: .quick)
        XCTAssertEqual(session.targetPerZone, 4)
        XCTAssertEqual(session.totalRequired, 16)
        XCTAssertEqual(session.currentZone, .leftTop)

        for zone in DeskZone.allCases {
            for _ in 0..<4 {
                XCTAssertEqual(session.currentZone, zone)
                session.positiveSamples.append(sample(zone: zone))
            }
        }
        XCTAssertTrue(session.zonesComplete)
        XCTAssertEqual(session.resultingQuality, .quick)
    }

    func testPreciseRemainsTheDefaultSessionShape() {
        let session = CalibrationSession(draft: CalibrationDraft())
        XCTAssertEqual(session.mode, .precise)
        XCTAssertEqual(session.targetPerZone, CalibrationGuidance.targetTapsPerZone)
        XCTAssertEqual(session.totalRequired, 40)
    }

    func testQualityFollowsTheExamplesNotTheMode() {
        XCTAssertEqual(CalibrationQuality.resolved(samplesPerZone: [4, 4, 4, 4]), .quick)
        XCTAssertEqual(CalibrationQuality.resolved(samplesPerZone: [10, 10, 10, 10]), .precise)
        XCTAssertEqual(
            CalibrationQuality.resolved(samplesPerZone: [10, 10, 10, 9]),
            .quick,
            "One short zone keeps the whole profile quick"
        )
        XCTAssertEqual(CalibrationQuality.resolved(samplesPerZone: [10, 10]), .quick, "Wrong shape is never precise")
    }

    // MARK: - Top up

    func testTopUpCarriesExistingExamplesAndTargetsSixMore() {
        let existing = DeskZone.allCases.flatMap { zone in
            (0..<4).map { _ in sample(zone: zone) }
        }
        var session = CalibrationSession(
            draft: CalibrationDraft(),
            mode: .topUp,
            carriedSamples: existing
        )

        XCTAssertEqual(session.targetPerZone, 6)
        XCTAssertEqual(session.trainingSamples.count, 16)
        XCTAssertEqual(session.resultingQuality, .quick)
        XCTAssertEqual(session.currentZone, .leftTop, "The pass counts only new taps")

        for zone in DeskZone.allCases {
            for _ in 0..<6 { session.positiveSamples.append(sample(zone: zone)) }
        }

        XCTAssertTrue(session.zonesComplete)
        XCTAssertEqual(session.trainingSamples.count, 40)
        XCTAssertEqual(
            session.resultingQuality,
            .precise,
            "Ten examples per zone must flip the profile to precise"
        )
    }

    func testFreshSessionsIgnoreCarriedSamples() {
        let session = CalibrationSession(
            draft: CalibrationDraft(),
            mode: .quick,
            carriedSamples: [sample(zone: .leftTop)]
        )
        XCTAssertTrue(session.carriedSamples.isEmpty)
        XCTAssertTrue(session.trainingSamples.isEmpty)
    }

    func testTopUpDropsNegativeExamplesFromTheCarriedSet() {
        let negative = LabeledTap(zone: nil, negativeLabel: "Talking", feature: feature(zone: .leftTop))
        let session = CalibrationSession(
            draft: CalibrationDraft(),
            mode: .topUp,
            carriedSamples: [sample(zone: .leftTop), negative]
        )
        XCTAssertEqual(session.carriedSamples.count, 1)
    }

    // MARK: - Thresholds

    func testQuickThresholdsAreStrictlyStricterThanStandard() {
        XCTAssertGreaterThan(
            ClassifierThresholds.quick.minimumConfidence,
            ClassifierThresholds.standard.minimumConfidence
        )
        XCTAssertGreaterThan(
            ClassifierThresholds.quick.minimumRelativeSeparation,
            ClassifierThresholds.standard.minimumRelativeSeparation
        )
        XCTAssertGreaterThan(
            ClassifierThresholds.quick.minimumLinearScoreMargin,
            ClassifierThresholds.standard.minimumLinearScoreMargin
        )
        XCTAssertEqual(ClassifierThresholds.forQuality(.quick), .quick)
        XCTAssertEqual(ClassifierThresholds.forQuality(.precise), .standard)
        XCTAssertTrue(ClassifierThresholds.quick.isFinite)
    }

    func testThresholdsAreCarriedOnTheTrainedModel() throws {
        let classifier = try TrainedTapClassifier.train(
            positiveExamples: quickTrainingSamples(),
            thresholds: .quick
        )
        XCTAssertEqual(classifier.thresholds, .quick)
        XCTAssertEqual(classifier.minimumConfidence, ClassifierDefaults.quickMinimumConfidence)
    }

    /// Acceptance criterion 3: with the same four-examples-per-zone training
    /// set, the stricter thresholds must reject at least as much, and strictly
    /// more somewhere along the ambiguous band. Relative ordering only; the
    /// absolute rate is not asserted.
    func testQuickThresholdsRejectAmbiguousTapsMoreOften() throws {
        let training = quickTrainingSamples()
        let standard = try TrainedTapClassifier.train(positiveExamples: training, thresholds: .standard)
        let quick = try TrainedTapClassifier.train(positiveExamples: training, thresholds: .quick)

        let probes = ambiguousProbes()
        let standardAccepted = Set(
            probes.indices.filter { standard.predict(probes[$0]).wasAccepted }
        )
        let quickAccepted = Set(
            probes.indices.filter { quick.predict(probes[$0]).wasAccepted }
        )

        XCTAssertTrue(
            standardAccepted.isSuperset(of: quickAccepted),
            "Stricter thresholds can only remove acceptances, never add them"
        )
        XCTAssertGreaterThan(
            probes.count - quickAccepted.count,
            probes.count - standardAccepted.count,
            "Quick thresholds must reject strictly more of the ambiguous sweep"
        )
    }

    func testQuickThresholdsStillAcceptTapsAtTheZoneCentres() throws {
        let quick = try TrainedTapClassifier.train(
            positiveExamples: quickTrainingSamples(),
            thresholds: .quick
        )
        for zone in DeskZone.allCases {
            let decision = quick.predict(feature(zone: zone))
            XCTAssertEqual(decision.zone, zone, "A clean \(zone.displayName) tap must still classify")
        }
    }

    // MARK: - Fixtures

    /// Four examples per zone, the quick-calibration budget.
    private func quickTrainingSamples() -> [LabeledTap] {
        DeskZone.allCases.flatMap { zone in
            (0..<4).map { index in
                LabeledTap(zone: zone, feature: feature(zone: zone, jitter: Double(index - 2) * 0.014))
            }
        }
    }

    /// A fine sweep along the line between two adjacent zone centres. Points
    /// near the middle are genuinely ambiguous; points near the ends are not.
    /// The sweep is dense so it covers the whole confidence range rather than
    /// hoping a single hand-picked point lands in the interesting band.
    private func ambiguousProbes() -> [TapFeatureVector] {
        let steps = 201
        return (0..<steps).map { step in
            let t = Double(step) / Double(steps - 1)
            return interpolatedFeature(from: .leftTop, to: .rightTop, t: t)
        }
    }

    private func interpolatedFeature(from: DeskZone, to: DeskZone, t: Double) -> TapFeatureVector {
        let start = rawValues(for: from)
        let end = rawValues(for: to)
        let values = zip(start, end).map { $0 + ($1 - $0) * t }
        return TapFeatureVector(
            strategy: .passive,
            names: featureNames,
            values: values,
            quality: cleanQuality
        )
    }

    private func sample(zone: DeskZone) -> LabeledTap {
        LabeledTap(zone: zone, feature: feature(zone: zone))
    }

    private let featureNames = ["row", "column", "diagonal", "texture"]

    private var cleanQuality: SignalQuality {
        SignalQuality(
            signalToNoiseDB: 28,
            peakAmplitude: 0.12,
            rmsAmplitude: 0.025,
            clippingFraction: 0,
            noiseFloorRMS: 0.0004,
            durationMilliseconds: 90
        )
    }

    private func rawValues(for zone: DeskZone, jitter: Double = 0) -> [Double] {
        [
            Double(zone.row) * 2.2 + jitter,
            Double(zone.column) * 2.0 - jitter,
            Double(zone.row + zone.column) * 0.8 + jitter * 0.5,
            Double(zone.rawValue) * 0.35 - jitter * 0.2
        ]
    }

    private func feature(zone: DeskZone, jitter: Double = 0) -> TapFeatureVector {
        TapFeatureVector(
            strategy: .passive,
            names: featureNames,
            values: rawValues(for: zone, jitter: jitter),
            quality: cleanQuality
        )
    }
}
