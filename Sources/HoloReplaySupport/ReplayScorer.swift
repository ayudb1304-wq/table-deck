import Foundation
import HoloCore

public enum ReplayMode: String, Codable {
    case vectors
    case wav
}

struct ReplayCoverage: Codable, Equatable {
    let withVectors: Int
    let total: Int
    let fraction: Double
}

struct ReplayZoneAccuracy: Codable, Equatable {
    let zone: String
    let correct: Int
    let total: Int
    let accuracy: Double
}

struct ReplayOutcomeCounts: Codable, Equatable {
    let rejections: Int
    let wrongZone: Int
    let missingVector: Int
}

public struct ReplayResult: Codable, Equatable {
    let mode: ReplayMode
    let zones: [String]
    let coverage: ReplayCoverage
    let overallAccuracy: Double
    let recordedAccuracy: Double
    let accuracyDelta: Double
    let perZoneAccuracy: [ReplayZoneAccuracy]
    let confusionMatrix: [[Int]]
    let outcomes: ReplayOutcomeCounts

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func humanReadable() -> String {
        var lines = [
            "HoloReplay (\(mode.rawValue))",
            "Attempts: \(coverage.total)",
            "Coverage: \(coverage.withVectors)/\(coverage.total) (\(Self.percent(coverage.fraction)))",
            "Overall accuracy: \(Self.percent(overallAccuracy))",
            "Recorded accuracy: \(Self.percent(recordedAccuracy))",
            "Delta: \(Self.signedPercentagePoints(accuracyDelta))",
            "Outcomes: \(outcomes.rejections) rejected, \(outcomes.wrongZone) wrong-zone, \(outcomes.missingVector) missing-vector",
            "",
            "Per-zone accuracy:"
        ]
        for item in perZoneAccuracy {
            lines.append("  \(item.zone): \(item.correct)/\(item.total) (\(Self.percent(item.accuracy)))")
        }

        lines.append("")
        lines.append("Confusion matrix (expected rows, predicted columns):")
        lines.append("       " + zones.map { Self.padded($0, width: 4) }.joined())
        for (index, row) in confusionMatrix.enumerated() {
            lines.append("  \(Self.padded(zones[index], width: 5))" + row.map { Self.padded(String($0), width: 4) }.joined())
        }
        lines.append("  Rejections and missing vectors are excluded from matrix cells.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static let outputLocale = Locale(identifier: "en_US_POSIX")

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", locale: outputLocale, value * 100)
    }

    private static func signedPercentagePoints(_ value: Double) -> String {
        String(format: "%+.2f pp", locale: outputLocale, value * 100)
    }

    private static func padded(_ value: String, width: Int) -> String {
        String(repeating: " ", count: max(width - value.count, 0)) + value
    }
}

public enum ReplayError: Error, LocalizedError, Equatable {
    case unsupportedProfileVersion(Int)
    case invalidProfileTopology
    case invalidEvaluationTopology(Int?)
    case profileMismatch(expected: UUID, actual: UUID)
    case strategyMismatch(profile: SensingStrategy, evaluation: SensingStrategy)
    case wavModeUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfileVersion(let version):
            return "profile version \(version) is unsupported; expected \(HoloProfile.currentVersion)"
        case .invalidProfileTopology:
            return "profile does not contain exactly the four supported zones"
        case .invalidEvaluationTopology(let count):
            return "evaluation topology is \(count.map(String.init) ?? "missing"); expected \(DeskZone.allCases.count) zones"
        case .profileMismatch(let expected, let actual):
            return "evaluation belongs to profile \(actual.uuidString), not \(expected.uuidString)"
        case .strategyMismatch(let profile, let evaluation):
            return "profile uses \(profile.rawValue) sensing but evaluation uses \(evaluation.rawValue)"
        case .wavModeUnavailable:
            return "WAV replay is unavailable because debug WAVs do not retain the EvaluationRecord UUID, exact detector onsetOffset, or detector noise floor, and timestamp/label filenames also include unarmed events. Feature-vector fingerprinting cannot safely recover that metadata while the extractor itself may be changing. Use --mode vectors; trustworthy WAV replay requires those fields in per-record WAV metadata."
        }
    }
}

public enum ReplayInput {
    static func decodeProfile(_ data: Data) throws -> HoloProfile {
        try decoder().decode(HoloProfile.self, from: data)
    }

    static func decodeEvaluation(_ data: Data) throws -> EvaluationReport {
        try decoder().decode(EvaluationReport.self, from: data)
    }

    public static func loadProfile(at url: URL) throws -> HoloProfile {
        try decodeProfile(Data(contentsOf: url))
    }

    public static func loadEvaluation(at url: URL) throws -> EvaluationReport {
        try decodeEvaluation(Data(contentsOf: url))
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum ReplayScorer {
    public static func score(
        profile: HoloProfile,
        evaluation: EvaluationReport
    ) throws -> ReplayResult {
        try validate(profile: profile, evaluation: evaluation)
        let classifier = try TrainedTapClassifier.train(
            positiveExamples: profile.classifier.positiveExamples,
            negativeExamples: profile.classifier.negativeExamples
        )

        let zones = DeskZone.allCases
        var correct = 0
        var covered = 0
        var rejections = 0
        var wrongZone = 0
        var missingVector = 0
        var confusion = Array(
            repeating: Array(repeating: 0, count: zones.count),
            count: zones.count
        )
        var zoneCorrect = Array(repeating: 0, count: zones.count)
        var zoneTotal = Array(repeating: 0, count: zones.count)

        for record in evaluation.records {
            let expectedIndex = record.expectedZone.rawValue
            zoneTotal[expectedIndex] += 1
            guard let feature = record.feature else {
                missingVector += 1
                continue
            }

            covered += 1
            let decision = classifier.predict(feature)
            guard let predicted = decision.zone else {
                rejections += 1
                continue
            }
            confusion[expectedIndex][predicted.rawValue] += 1
            if predicted == record.expectedZone {
                correct += 1
                zoneCorrect[expectedIndex] += 1
            } else {
                wrongZone += 1
            }
        }

        let total = evaluation.records.count
        let overallAccuracy = Self.ratio(correct, total)
        let recordedAccuracy = evaluation.overallAccuracy
        return ReplayResult(
            mode: .vectors,
            zones: zones.map(\.shortName),
            coverage: ReplayCoverage(
                withVectors: covered,
                total: total,
                fraction: Self.ratio(covered, total)
            ),
            overallAccuracy: overallAccuracy,
            recordedAccuracy: recordedAccuracy,
            accuracyDelta: overallAccuracy - recordedAccuracy,
            perZoneAccuracy: zones.map { zone in
                let index = zone.rawValue
                return ReplayZoneAccuracy(
                    zone: zone.shortName,
                    correct: zoneCorrect[index],
                    total: zoneTotal[index],
                    accuracy: Self.ratio(zoneCorrect[index], zoneTotal[index])
                )
            },
            confusionMatrix: confusion,
            outcomes: ReplayOutcomeCounts(
                rejections: rejections,
                wrongZone: wrongZone,
                missingVector: missingVector
            )
        )
    }

    private static func validate(profile: HoloProfile, evaluation: EvaluationReport) throws {
        guard profile.version == HoloProfile.currentVersion else {
            throw ReplayError.unsupportedProfileVersion(profile.version)
        }
        guard profile.zones.count == DeskZone.allCases.count,
              Set(profile.zones.map(\.zone)) == Set(DeskZone.allCases) else {
            throw ReplayError.invalidProfileTopology
        }
        guard evaluation.topologyZoneCount == DeskZone.allCases.count else {
            throw ReplayError.invalidEvaluationTopology(evaluation.topologyZoneCount)
        }
        if let evaluationProfileID = evaluation.profileID,
           evaluationProfileID != profile.id {
            throw ReplayError.profileMismatch(expected: profile.id, actual: evaluationProfileID)
        }
        guard evaluation.strategy == profile.sensingStrategy else {
            throw ReplayError.strategyMismatch(
                profile: profile.sensingStrategy,
                evaluation: evaluation.strategy
            )
        }
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}
