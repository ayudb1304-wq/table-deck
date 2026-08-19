import Foundation

/// Recognizes the deliberate double tap that lifts Doze back to Armed.
///
/// Doze deliberately does not classify, so this works on nothing but transient
/// timestamps: two strong onsets inside one second, separated by enough time
/// that a single tap ringing across two buffers cannot satisfy it by itself.
///
/// Allocation-free after `init`: the timestamp ring is sized once.
public struct WakeGestureDetector: Equatable, Sendable {
    public static let defaultWindow: TimeInterval = 1.0
    public static let defaultMinimumSeparation: TimeInterval = 0.06

    public let requiredTransients: Int
    public let window: TimeInterval
    public let minimumSeparation: TimeInterval

    private var timestamps: [Double]
    private var count = 0
    private var writeIndex = 0

    public init(
        requiredTransients: Int = 2,
        window: TimeInterval = WakeGestureDetector.defaultWindow,
        minimumSeparation: TimeInterval = WakeGestureDetector.defaultMinimumSeparation
    ) {
        let required = max(requiredTransients, 2)
        self.requiredTransients = required
        self.window = max(window, 0.1)
        self.minimumSeparation = max(minimumSeparation, 0)
        self.timestamps = Array(repeating: -.greatestFiniteMagnitude, count: required)
    }

    public mutating func reset() {
        for index in timestamps.indices { timestamps[index] = -.greatestFiniteMagnitude }
        count = 0
        writeIndex = 0
    }

    /// Records one strong transient. Returns true when the gesture just
    /// completed, and clears itself so the next wake needs a fresh double tap.
    public mutating func noteTransient(at now: Double) -> Bool {
        guard now.isFinite else { return false }
        if let previous = mostRecent, now - previous < minimumSeparation {
            // Same impact still ringing. Slide the timestamp forward rather
            // than counting it twice.
            timestamps[(writeIndex + timestamps.count - 1) % timestamps.count] = now
            return false
        }

        timestamps[writeIndex] = now
        writeIndex = (writeIndex + 1) % timestamps.count
        count = min(count + 1, timestamps.count)

        guard count >= requiredTransients else { return false }
        let oldest = timestamps.min() ?? now
        guard now - oldest <= window else { return false }

        reset()
        return true
    }

    private var mostRecent: Double? {
        guard count > 0 else { return nil }
        return timestamps[(writeIndex + timestamps.count - 1) % timestamps.count]
    }
}
