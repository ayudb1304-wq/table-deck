import Foundation
import HoloCore
@testable import HoloReplaySupport
import XCTest

final class ReplayScorerTests: XCTestCase {
    func testRescoringInMemoryJSONFixtureReproducesRecordedOutcome() throws {
        let fixture = try makeFixture()
        let encodedProfile = try encode(fixture.profile)
        let encodedEvaluation = try encode(fixture.evaluation)

        let profile = try ReplayInput.decodeProfile(encodedProfile)
        let evaluation = try ReplayInput.decodeEvaluation(encodedEvaluation)
        let result = try ReplayScorer.score(profile: profile, evaluation: evaluation)

        XCTAssertEqual(result.coverage.withVectors, 4)
        XCTAssertEqual(result.coverage.total, 4)
        XCTAssertEqual(result.overallAccuracy, evaluation.overallAccuracy, accuracy: 1e-12)
        XCTAssertEqual(result.accuracyDelta, 0, accuracy: 1e-12)
        XCTAssertEqual(result.confusionMatrix, [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ])
    }

    func testPerturbedClassifierChangesReplayScore() throws {
        let fixture = try makeFixture()
        let baseline = try ReplayScorer.score(
            profile: fixture.profile,
            evaluation: fixture.evaluation
        )
        var perturbed = fixture.profile
        perturbed.classifier.positiveExamples = perturbed.classifier.positiveExamples.map { sample in
            var changed = sample
            if let zone = sample.zone {
                changed.zone = DeskZone(rawValue: (zone.rawValue + 1) % DeskZone.allCases.count)
            }
            return changed
        }

        let changed = try ReplayScorer.score(
            profile: perturbed,
            evaluation: fixture.evaluation
        )

        XCTAssertEqual(baseline.overallAccuracy, 1, accuracy: 1e-12)
        XCTAssertNotEqual(changed.overallAccuracy, baseline.overallAccuracy)
    }

    func testMissingVectorStaysIncorrectAndInDenominator() throws {
        let fixture = try makeFixture()
        let classifier = fixture.profile.classifier
        let retainedFeature = feature(zone: .leftTop, jitter: 0.01)
        let records = [
            EvaluationRecord(
                expectedZone: .leftTop,
                decision: classifier.predict(retainedFeature),
                responseLatencyMilliseconds: 10,
                feature: retainedFeature
            ),
            EvaluationRecord(
                expectedZone: .leftBottom,
                decision: classifier.predict(feature(zone: .leftBottom, jitter: 0.01)),
                responseLatencyMilliseconds: 10
            )
        ]
        let evaluation = EvaluationReport(
            profileID: fixture.profile.id,
            profileName: fixture.profile.name,
            strategy: .passive,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            records: records
        )

        let result = try ReplayScorer.score(profile: fixture.profile, evaluation: evaluation)

        XCTAssertEqual(result.coverage.withVectors, 1)
        XCTAssertEqual(result.coverage.total, 2)
        XCTAssertEqual(result.overallAccuracy, 0.5, accuracy: 1e-12)
        XCTAssertEqual(result.recordedAccuracy, 1, accuracy: 1e-12)
        XCTAssertEqual(result.accuracyDelta, -0.5, accuracy: 1e-12)
        XCTAssertEqual(result.outcomes.missingVector, 1)
        XCTAssertEqual(result.perZoneAccuracy.first { $0.zone == "LF" }?.total, 1)
    }

    private func makeFixture() throws -> (profile: HoloProfile, evaluation: EvaluationReport) {
        let classifier = try TrainedTapClassifier.train(positiveExamples: trainingSamples())
        let profileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let profile = HoloProfile(
            id: profileID,
            name: "Replay fixture",
            surfaceDescription: "Synthetic",
            laptopPositionNote: "Centered",
            classifier: classifier,
            calibration: CalibrationSummary(
                sampleCount: classifier.positiveExamples.count,
                samplesPerZone: DeskZone.allCases.map { zone in
                    classifier.positiveExamples.filter { $0.zone == zone }.count
                },
                leaveOneOutAccuracy: nil
            )
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let records = DeskZone.allCases.map { zone -> EvaluationRecord in
            let heldOut = feature(zone: zone, jitter: 0.012, capturedAt: capturedAt)
            return EvaluationRecord(
                expectedZone: zone,
                decision: classifier.predict(heldOut),
                responseLatencyMilliseconds: 25,
                capturedAt: capturedAt,
                feature: heldOut
            )
        }
        return (
            profile,
            EvaluationReport(
                profileID: profileID,
                profileName: profile.name,
                strategy: .passive,
                startedAt: capturedAt,
                completedAt: capturedAt.addingTimeInterval(1),
                records: records
            )
        )
    }

    private func trainingSamples() -> [LabeledTap] {
        DeskZone.allCases.flatMap { zone in
            (0..<4).map { index in
                LabeledTap(
                    zone: zone,
                    feature: feature(zone: zone, jitter: Double(index - 2) * 0.01)
                )
            }
        }
    }

    private func feature(
        zone: DeskZone,
        jitter: Double,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TapFeatureVector {
        TapFeatureVector(
            strategy: .passive,
            names: ["row", "column", "diagonal", "spread"],
            values: [
                Double(zone.row) + jitter,
                Double(zone.column) - jitter,
                Double(zone.row + zone.column) + jitter * 0.5,
                Double(zone.rawValue) * 0.4 - jitter
            ],
            quality: SignalQuality(
                signalToNoiseDB: 24,
                peakAmplitude: 0.12,
                rmsAmplitude: 0.025,
                clippingFraction: 0,
                noiseFloorRMS: 0.001,
                durationMilliseconds: 90
            ),
            capturedAt: capturedAt
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
