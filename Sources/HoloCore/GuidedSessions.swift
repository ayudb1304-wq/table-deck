import Foundation

public enum CalibrationGuidance {
    public static let targetTapsPerZone = 10
    /// Quick calibration: four accepted taps per zone, sixteen in one pass.
    public static let quickTapsPerZone = 4
    /// A top-up adds enough to clear the precise bar from a quick profile.
    public static let topUpTapsPerZone = 6
    /// At or above this many examples per zone, a profile counts as precise.
    public static let preciseMinimumPerZone = 10

    /// Below this leave-one-out agreement, the UI recommends recapturing the weakest zone.
    public static let minimumCleanAgreement = 0.80
}

/// How much evidence a profile was trained on. Stored on `CalibrationSummary`
/// and used to pick the classifier's rejection thresholds.
public enum CalibrationQuality: String, Codable, Sendable, CaseIterable, Equatable {
    case quick
    case precise

    public var displayName: String {
        switch self {
        case .quick: return "Quick"
        case .precise: return "Precise"
        }
    }

    public var tapsPerZone: Int {
        switch self {
        case .quick: return CalibrationGuidance.quickTapsPerZone
        case .precise: return CalibrationGuidance.targetTapsPerZone
        }
    }

    /// Derives quality from what the profile actually holds, which is the only
    /// trustworthy source once top-ups can add examples after the fact.
    public static func resolved(samplesPerZone counts: [Int]) -> CalibrationQuality {
        guard counts.count == DeskZone.allCases.count else { return .quick }
        return counts.allSatisfy { $0 >= CalibrationGuidance.preciseMinimumPerZone } ? .precise : .quick
    }

    public static func resolved(samples: [LabeledTap]) -> CalibrationQuality {
        resolved(samplesPerZone: DeskZone.allCases.map { zone in
            samples.filter { $0.zone == zone }.count
        })
    }
}

/// What a guided calibration pass is for.
public enum CalibrationMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// Four taps per zone, new profile. The default first-run path.
    case quick
    /// Ten taps per zone, new profile. Better model, longer setup.
    case precise
    /// Six more taps per zone, appended to an existing profile and retrained.
    case topUp

    public var tapsPerZone: Int {
        switch self {
        case .quick: return CalibrationGuidance.quickTapsPerZone
        case .precise: return CalibrationGuidance.targetTapsPerZone
        case .topUp: return CalibrationGuidance.topUpTapsPerZone
        }
    }

    public var isTopUp: Bool { self == .topUp }

    public var displayName: String {
        switch self {
        case .quick: return "Quick"
        case .precise: return "Precise"
        case .topUp: return "Top up"
        }
    }
}

public struct CalibrationDraft: Sendable, Equatable {
    public var name: String
    public var surfaceDescription: String
    public var laptopPositionNote: String
    public var strategy: SensingStrategy

    public init(
        name: String = "My Desk",
        surfaceDescription: String = "Rigid desk",
        laptopPositionNote: String = "Laptop centered; position unchanged",
        strategy: SensingStrategy = .passive
    ) {
        self.name = name
        self.surfaceDescription = surfaceDescription
        self.laptopPositionNote = laptopPositionNote
        self.strategy = strategy
    }
}

public struct CalibrationSession: Sendable {
    public let mode: CalibrationMode
    public let targetPerZone: Int
    public var draft: CalibrationDraft
    public var positiveSamples: [LabeledTap]
    public var negativeSamples: [LabeledTap]
    public var negativeLabel: String?
    public var isArmed: Bool
    public var isSettling: Bool
    /// Examples already on the profile being topped up. They count toward the
    /// resulting model but not toward this pass's per-zone target.
    public let carriedSamples: [LabeledTap]

    public init(
        draft: CalibrationDraft,
        mode: CalibrationMode = .precise,
        carriedSamples: [LabeledTap] = []
    ) {
        self.draft = draft
        self.mode = mode
        self.targetPerZone = mode.tapsPerZone
        self.positiveSamples = []
        self.negativeSamples = []
        self.negativeLabel = nil
        self.isArmed = false
        self.isSettling = false
        self.carriedSamples = mode.isTopUp ? carriedSamples.filter { $0.zone != nil } : []
    }

    /// Everything the retrained classifier will see: what was carried in plus
    /// what this pass captured.
    public var trainingSamples: [LabeledTap] { carriedSamples + positiveSamples }

    public var resultingQuality: CalibrationQuality {
        CalibrationQuality.resolved(samples: trainingSamples)
    }

    public var currentZone: DeskZone? {
        DeskZone.allCases.first { zone in count(for: zone) < targetPerZone }
    }

    public var zonesComplete: Bool { currentZone == nil }
    public var totalRequired: Int { targetPerZone * DeskZone.allCases.count }
    public var progress: Double { Double(positiveSamples.count) / Double(totalRequired) }

    public func count(for zone: DeskZone) -> Int {
        positiveSamples.filter { $0.zone == zone }.count
    }

    public func negativeCount(for label: String) -> Int {
        negativeSamples.filter { $0.negativeLabel == label }.count
    }
}

public struct EvaluationSession: Sendable {
    public let startedAt: Date
    public let targetPerZone: Int
    public var records: [EvaluationRecord]
    public var isArmed: Bool
    public var isSettling: Bool

    public init(
        startedAt: Date = Date(),
        targetPerZone: Int = EvaluationAcceptance.tapsPerZone
    ) {
        self.startedAt = startedAt
        self.targetPerZone = targetPerZone
        self.records = []
        self.isArmed = false
        self.isSettling = false
    }

    public var currentZone: DeskZone? {
        DeskZone.allCases.first { zone in
            records.filter { $0.expectedZone == zone }.count < targetPerZone
        }
    }

    public var progress: Double {
        Double(records.count) / Double(targetPerZone * DeskZone.allCases.count)
    }
}

public struct BenchmarkSession: Sendable {
    public let targetPerZone: Int
    public var samples: [BenchmarkSample]
    public var isArmed: Bool
    public var isSettling: Bool

    public init(targetPerZone: Int = 3) {
        self.targetPerZone = targetPerZone
        self.samples = []
        self.isArmed = false
        self.isSettling = false
    }

    public var currentStrategy: SensingStrategy? {
        SensingStrategy.allCases.first { strategy in
            DeskZone.allCases.contains { zone in
                count(strategy: strategy, zone: zone) < targetPerZone
            }
        }
    }

    public var currentZone: DeskZone? {
        guard let strategy = currentStrategy else { return nil }
        return DeskZone.allCases.first {
            count(strategy: strategy, zone: $0) < targetPerZone
        }
    }

    public var progress: Double {
        Double(samples.count)
            / Double(targetPerZone * DeskZone.allCases.count * SensingStrategy.allCases.count)
    }

    public func count(strategy: SensingStrategy, zone: DeskZone) -> Int {
        samples.filter {
            $0.labeledTap.feature.strategy == strategy && $0.labeledTap.zone == zone
        }.count
    }
}
