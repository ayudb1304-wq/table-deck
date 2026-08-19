import Foundation

/// How much of the pipeline is running right now.
///
/// The tier is derived state: `ListeningTierMachine` recomputes it from the
/// current system conditions plus how long it has been since the last accepted
/// tap. Nothing else may assign a tier directly.
public enum ListeningTier: String, Codable, Sendable, CaseIterable {
    /// Full detect → classify → act pipeline on short buffers.
    case armed
    /// Engine running on long buffers, loudness gate and noise-floor tracking
    /// only. No feature extraction, no classification, no actions.
    case doze
    /// Engine stopped and the microphone released.
    case paused

    public var displayName: String {
        switch self {
        case .armed: return "Listening"
        case .doze: return "Dozing"
        case .paused: return "Paused"
        }
    }

    /// Only Armed may run an assigned action.
    public var allowsActions: Bool { self == .armed }
}

/// Why capture is stopped. Ordered by how strongly it overrides the others:
/// the first reason in `ListeningTierDecision.pauseReasons` is the one shown.
public enum PauseReason: String, Codable, Sendable, CaseIterable, Comparable {
    case manual
    case screenLocked
    case systemAsleep
    case microphoneInUse
    case thermalPressure
    case lowPowerMode
    case lowBattery

    /// Lower is more important.
    private var priority: Int {
        switch self {
        case .manual: return 0
        case .screenLocked: return 1
        case .systemAsleep: return 2
        case .microphoneInUse: return 3
        case .thermalPressure: return 4
        case .lowPowerMode: return 5
        case .lowBattery: return 6
        }
    }

    public static func < (lhs: PauseReason, rhs: PauseReason) -> Bool {
        lhs.priority < rhs.priority
    }

    /// Short phrase for the status line, e.g. "Paused (locked)".
    public var statusDetail: String {
        switch self {
        case .manual: return "manual"
        case .screenLocked: return "locked"
        case .systemAsleep: return "asleep"
        case .microphoneInUse: return "call"
        case .thermalPressure: return "heat"
        case .lowPowerMode: return "low power"
        case .lowBattery: return "battery"
        }
    }

    public var explanation: String {
        switch self {
        case .manual: return "You paused listening."
        case .screenLocked: return "The screen is locked."
        case .systemAsleep: return "The Mac is asleep."
        case .microphoneInUse: return "Another app is using the microphone."
        case .thermalPressure: return "The Mac is running hot."
        case .lowPowerMode: return "Low Power Mode is on."
        case .lowBattery: return "The battery is below your threshold."
        }
    }
}

/// Mirror of `ProcessInfo.ThermalState`, kept separate so the state machine
/// stays free of platform types and testable without a live `ProcessInfo`.
public enum ThermalPressure: Int, Codable, Sendable, Comparable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Everything the tier decision depends on, sampled from the system.
public struct ListeningConditions: Equatable, Sendable {
    public var manuallyPaused: Bool
    public var isScreenLocked: Bool
    public var isSystemAsleep: Bool
    public var isMicrophoneBusyElsewhere: Bool
    public var thermalPressure: ThermalPressure
    public var isLowPowerModeEnabled: Bool
    /// 0...1, or nil when there is no battery (desktop, or IOKit gave nothing).
    public var batteryFraction: Double?
    public var isRunningOnBattery: Bool

    public init(
        manuallyPaused: Bool = false,
        isScreenLocked: Bool = false,
        isSystemAsleep: Bool = false,
        isMicrophoneBusyElsewhere: Bool = false,
        thermalPressure: ThermalPressure = .nominal,
        isLowPowerModeEnabled: Bool = false,
        batteryFraction: Double? = nil,
        isRunningOnBattery: Bool = false
    ) {
        self.manuallyPaused = manuallyPaused
        self.isScreenLocked = isScreenLocked
        self.isSystemAsleep = isSystemAsleep
        self.isMicrophoneBusyElsewhere = isMicrophoneBusyElsewhere
        self.thermalPressure = thermalPressure
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.batteryFraction = batteryFraction
        self.isRunningOnBattery = isRunningOnBattery
    }
}

/// User-tunable parts of the tier policy. Versioned and stored on its own,
/// deliberately outside `HoloProfile`: these are machine preferences, not desk
/// calibration, and they must not force a profile schema bump.
public struct ListeningTierSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let minimumIdleDozeTimeout: TimeInterval = 30
    public static let maximumIdleDozeTimeout: TimeInterval = 3_600
    public static let defaultIdleDozeTimeout: TimeInterval = 180

    public var version: Int
    /// Seconds without an accepted tap before dropping to Doze.
    public var idleDozeTimeout: TimeInterval
    /// Whether a double tap can lift Doze back to Armed.
    public var wakeGestureEnabled: Bool
    /// 0...1 battery level at or below which Holo pauses. `nil` disables it.
    public var batteryPauseFraction: Double?

    public init(
        idleDozeTimeout: TimeInterval = ListeningTierSettings.defaultIdleDozeTimeout,
        wakeGestureEnabled: Bool = true,
        batteryPauseFraction: Double? = nil
    ) {
        self.version = Self.currentVersion
        self.idleDozeTimeout = idleDozeTimeout
        self.wakeGestureEnabled = wakeGestureEnabled
        self.batteryPauseFraction = batteryPauseFraction
    }

    /// Clamps values that arrived from disk or a stale build into the range the
    /// state machine is willing to act on.
    public func sanitized() -> ListeningTierSettings {
        var result = self
        result.version = Self.currentVersion
        if !result.idleDozeTimeout.isFinite {
            result.idleDozeTimeout = Self.defaultIdleDozeTimeout
        }
        result.idleDozeTimeout = min(
            max(result.idleDozeTimeout, Self.minimumIdleDozeTimeout),
            Self.maximumIdleDozeTimeout
        )
        if let fraction = result.batteryPauseFraction {
            result.batteryPauseFraction = fraction.isFinite ? min(max(fraction, 0.05), 0.90) : nil
        }
        return result
    }
}

public struct ListeningTierDecision: Equatable, Sendable {
    public var tier: ListeningTier
    /// Empty unless `tier == .paused`. Sorted, most important first.
    public var pauseReasons: [PauseReason]

    public init(tier: ListeningTier, pauseReasons: [PauseReason] = []) {
        self.tier = tier
        self.pauseReasons = pauseReasons
    }

    public var primaryPauseReason: PauseReason? { pauseReasons.first }

    /// The status-line string described by spec 01.
    public var statusText: String {
        switch tier {
        case .armed:
            return "Listening"
        case .doze:
            return "Dozing, measuring loudness only"
        case .paused:
            guard let reason = primaryPauseReason else { return "Paused" }
            return "Paused (\(reason.statusDetail))"
        }
    }
}

/// Pure, clock-injected tier policy.
///
/// `now` is monotonic seconds (`ProcessInfo.systemUptime` in the app, an
/// arbitrary counter in tests). The machine never reads a clock itself so its
/// behavior is fully reproducible.
public struct ListeningTierMachine: Equatable, Sendable {
    public var settings: ListeningTierSettings {
        didSet { settings = settings.sanitized() }
    }

    public private(set) var tier: ListeningTier = .armed
    public private(set) var pauseReasons: [PauseReason] = []

    /// Last moment the user demonstrably interacted: an accepted tap, a wake
    /// gesture, or a manual resume. Doze is measured from here.
    private var lastActivityAt: Double

    public init(
        settings: ListeningTierSettings = ListeningTierSettings(),
        startedAt: Double = 0
    ) {
        self.settings = settings.sanitized()
        self.lastActivityAt = startedAt
    }

    /// An accepted tap resets the idle countdown.
    public mutating func noteAcceptedTap(at now: Double) {
        lastActivityAt = now
    }

    /// A wake gesture or an explicit Resume lifts Doze immediately.
    public mutating func noteWake(at now: Double) {
        lastActivityAt = now
    }

    @discardableResult
    public mutating func evaluate(_ conditions: ListeningConditions, at now: Double) -> ListeningTierDecision {
        let reasons = Self.pauseReasons(for: conditions, settings: settings)
        let wasPaused = tier == .paused

        guard reasons.isEmpty else {
            tier = .paused
            pauseReasons = reasons
            return ListeningTierDecision(tier: .paused, pauseReasons: reasons)
        }

        // Coming back from Paused always lands in Armed with a fresh countdown.
        // The user just unlocked, hung up, or plugged in; making them tap twice
        // to get out of Doze would read as the app being broken.
        if wasPaused {
            lastActivityAt = now
        }

        pauseReasons = []
        let idleFor = now - lastActivityAt
        tier = idleFor >= settings.idleDozeTimeout ? .doze : .armed
        return ListeningTierDecision(tier: tier, pauseReasons: [])
    }

    /// Seconds until Doze, or nil when not applicable.
    public func secondsUntilDoze(at now: Double) -> TimeInterval? {
        guard tier == .armed else { return nil }
        return max(0, settings.idleDozeTimeout - (now - lastActivityAt))
    }

    static func pauseReasons(
        for conditions: ListeningConditions,
        settings: ListeningTierSettings
    ) -> [PauseReason] {
        var reasons: [PauseReason] = []
        if conditions.manuallyPaused { reasons.append(.manual) }
        if conditions.isScreenLocked { reasons.append(.screenLocked) }
        if conditions.isSystemAsleep { reasons.append(.systemAsleep) }
        if conditions.isMicrophoneBusyElsewhere { reasons.append(.microphoneInUse) }
        if conditions.thermalPressure >= .serious { reasons.append(.thermalPressure) }
        if conditions.isLowPowerModeEnabled { reasons.append(.lowPowerMode) }
        if let threshold = settings.batteryPauseFraction,
           conditions.isRunningOnBattery,
           let level = conditions.batteryFraction,
           level.isFinite,
           level <= threshold {
            reasons.append(.lowBattery)
        }
        return reasons.sorted()
    }
}
