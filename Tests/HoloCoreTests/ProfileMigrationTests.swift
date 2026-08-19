import XCTest
@testable import HoloCore

/// Acceptance criterion 2: a profile written by the pre-quick-calibration build
/// must still load, and must report `.precise`.
final class ProfileMigrationTests: XCTestCase {
    func testCalibrationSummaryWithoutQualityDecodesAsPrecise() throws {
        let legacy = """
        {
          "sampleCount": 40,
          "samplesPerZone": [10, 10, 10, 10],
          "leaveOneOutAccuracy": 0.95,
          "capturedAt": "2026-01-05T10:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(CalibrationSummary.self, from: Data(legacy.utf8))

        XCTAssertEqual(summary.quality, .precise)
        XCTAssertEqual(summary.sampleCount, 40)
        XCTAssertEqual(summary.samplesPerZone, [10, 10, 10, 10])
    }

    func testCalibrationSummaryRoundTripsQuality() throws {
        let summary = CalibrationSummary(
            sampleCount: 16,
            samplesPerZone: [4, 4, 4, 4],
            leaveOneOutAccuracy: 0.8,
            quality: .quick
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(
            CalibrationSummary.self,
            from: try encoder.encode(summary)
        )
        XCTAssertEqual(restored.quality, .quick)
    }

    func testVersionThreeProfileLoadsAndReportsPrecise() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try ProfileStore(directory: temporary)

        var profile = try makeProfile()
        profile.version = 3
        try store.save(profile)
        // A real v3 file has no `quality` key at all, so strip it rather than
        // testing a v4 payload wearing a v3 version number.
        try stripCalibrationQuality(
            at: temporary.appendingPathComponent(profile.id.uuidString).appendingPathExtension("json")
        )

        let loaded = try XCTUnwrap(try store.loadAll().first)
        XCTAssertEqual(loaded.version, HoloProfile.currentVersion)
        XCTAssertEqual(loaded.calibrationQuality, .precise)
        XCTAssertEqual(loaded.id, profile.id)
        XCTAssertEqual(loaded.name, profile.name)
    }

    private func stripCalibrationQuality(at url: URL) throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var calibration = try XCTUnwrap(root["calibration"] as? [String: Any])
        calibration.removeValue(forKey: "quality")
        root["calibration"] = calibration
        try JSONSerialization.data(withJSONObject: root).write(to: url, options: .atomic)
    }

    func testMigrationDoesNotRewriteTheFile() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try ProfileStore(directory: temporary)

        var profile = try makeProfile()
        profile.version = 3
        try store.save(profile)

        let url = temporary.appendingPathComponent(profile.id.uuidString).appendingPathExtension("json")
        let before = try Data(contentsOf: url)
        _ = try store.loadAll()
        XCTAssertEqual(try Data(contentsOf: url), before, "Loading must not silently rewrite a profile")
    }

    func testVersionsOlderThanThreeAreSkipped() throws {
        XCTAssertFalse(ProfileMigration.canMigrate(version: 2))
        XCTAssertFalse(ProfileMigration.canMigrate(version: 1))
        XCTAssertTrue(ProfileMigration.canMigrate(version: 3))
        XCTAssertTrue(ProfileMigration.canMigrate(version: HoloProfile.currentVersion))
    }

    func testAQuickProfileSurvivesAStoreRoundTrip() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try ProfileStore(directory: temporary)

        let profile = try makeProfile(quality: .quick, thresholds: .quick)
        try store.save(profile)

        let loaded = try XCTUnwrap(try store.loadAll().first)
        XCTAssertEqual(loaded.calibrationQuality, .quick)
        XCTAssertEqual(loaded.classifier.thresholds, .quick)
    }

    func testTopUpDeficitReportsWhatIsStillMissing() throws {
        let quick = try makeProfile(perZone: 4, quality: .quick, thresholds: .quick)
        XCTAssertEqual(quick.topUpTapsNeededPerZone, 6)

        let precise = try makeProfile(perZone: 10)
        XCTAssertEqual(precise.topUpTapsNeededPerZone, 0)
    }

    // MARK: - Fixtures

    private func makeProfile(
        perZone: Int = 10,
        quality: CalibrationQuality = .precise,
        thresholds: ClassifierThresholds = .standard
    ) throws -> HoloProfile {
        let samples = DeskZone.allCases.flatMap { zone in
            (0..<perZone).map { index in
                LabeledTap(zone: zone, feature: feature(zone: zone, jitter: Double(index) * 0.01))
            }
        }
        let classifier = try TrainedTapClassifier.train(
            positiveExamples: samples,
            thresholds: thresholds
        )
        return HoloProfile(
            name: "Migration desk",
            surfaceDescription: "Oak",
            laptopPositionNote: "Centered",
            classifier: classifier,
            calibration: CalibrationSummary(
                sampleCount: samples.count,
                samplesPerZone: Array(repeating: perZone, count: DeskZone.allCases.count),
                leaveOneOutAccuracy: 0.95,
                quality: quality
            )
        )
    }

    private func feature(zone: DeskZone, jitter: Double) -> TapFeatureVector {
        TapFeatureVector(
            strategy: .passive,
            names: ["row", "column", "diagonal", "texture"],
            values: [
                Double(zone.row) * 2.2 + jitter,
                Double(zone.column) * 2.0 - jitter,
                Double(zone.row + zone.column) * 0.8 + jitter * 0.5,
                Double(zone.rawValue) * 0.35 - jitter * 0.2
            ],
            quality: SignalQuality(
                signalToNoiseDB: 28,
                peakAmplitude: 0.12,
                rmsAmplitude: 0.025,
                clippingFraction: 0,
                noiseFloorRMS: 0.0004,
                durationMilliseconds: 90
            )
        )
    }
}
