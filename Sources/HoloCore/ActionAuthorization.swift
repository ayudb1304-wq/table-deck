import Foundation

/// How much damage an action can do if it fires when the user did not mean it.
public enum ActionRisk: String, Codable, Sendable {
    /// Feedback the user can ignore: visual only, a sound, clipboard text, speech.
    case safe
    /// Reaches outside Holo: launches, opens, runs, or captures the screen.
    case privileged
}

public enum ActionAuthorization {
    public static func risk(of kind: ZoneActionKind) -> ActionRisk {
        switch kind {
        case .none, .sound, .copyText, .speakText:
            return .safe
        case .openURL, .runShortcut, .openApplication, .openItem,
             .runShellCommand, .screenshotClipboard, .screenshotSelection:
            return .privileged
        }
    }

    public static func isPrivileged(_ kind: ZoneActionKind) -> Bool {
        risk(of: kind) == .privileged
    }

    /// Minimum gap between two privileged dispatches, spec 01.
    public static let privilegedMinimumInterval: TimeInterval = 2.0
}

/// Enforces "at most one privileged action every two seconds" across all zones.
/// Deliberately global rather than per-zone: the risk being limited is a burst
/// of unintended side effects, not repetition of one particular action.
public struct PrivilegedActionRateLimiter: Equatable, Sendable {
    public let minimumInterval: TimeInterval
    private var lastDispatchAt: Double?

    public init(minimumInterval: TimeInterval = ActionAuthorization.privilegedMinimumInterval) {
        self.minimumInterval = max(minimumInterval, 0)
    }

    public func allows(at now: Double) -> Bool {
        guard let lastDispatchAt else { return true }
        return now - lastDispatchAt >= minimumInterval
    }

    /// Records a dispatch. Call only after the action actually ran.
    public mutating func noteDispatch(at now: Double) {
        lastDispatchAt = now
    }

    public mutating func reset() {
        lastDispatchAt = nil
    }
}

/// Remembers which privileged actions the user has already confirmed, per
/// profile. Spec 01 asks for one confirmation the first time each privileged
/// kind is armed on a profile, not one per firing.
public struct PrivilegedActionConsent: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// "<profile uuid>:<action kind raw value>" entries.
    public private(set) var grants: Set<String>

    public init(grants: Set<String> = []) {
        self.version = Self.currentVersion
        self.grants = grants
    }

    public static func key(profileID: UUID, kind: ZoneActionKind) -> String {
        "\(profileID.uuidString):\(kind.rawValue)"
    }

    public func isGranted(profileID: UUID, kind: ZoneActionKind) -> Bool {
        guard ActionAuthorization.isPrivileged(kind) else { return true }
        return grants.contains(Self.key(profileID: profileID, kind: kind))
    }

    public mutating func grant(profileID: UUID, kind: ZoneActionKind) {
        guard ActionAuthorization.isPrivileged(kind) else { return }
        grants.insert(Self.key(profileID: profileID, kind: kind))
    }

    public mutating func revoke(profileID: UUID, kind: ZoneActionKind) {
        grants.remove(Self.key(profileID: profileID, kind: kind))
    }

    /// Called when a profile is deleted so a recycled UUID cannot inherit consent.
    public mutating func revokeAll(profileID: UUID) {
        let prefix = "\(profileID.uuidString):"
        grants = grants.filter { !$0.hasPrefix(prefix) }
    }
}
