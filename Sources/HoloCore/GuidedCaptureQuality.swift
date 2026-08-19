import Foundation

public enum GuidedCaptureQualityIssue: String, Codable, Equatable, Sendable {
    case clipped
    case weak
    case noisy

    /// The same vocabulary the live surface uses for a rejected tap, so quick
    /// calibration can label a retry with a phrase the user will see again.
    public var rejection: RejectionReason {
        switch self {
        case .clipped: return .clippedSignal
        case .weak: return .weakSignal
        case .noisy: return .lowSignalToNoise
        }
    }

    public var guidance: String {
        switch self {
        case .clipped:
            return "That tap clipped. Use a lighter, more natural tap."
        case .weak:
            return "That tap was too soft. Try a slightly firmer tap."
        case .noisy:
            return "Background noise masked that tap. Wait for quiet, then try again."
        }
    }
}

public enum GuidedCaptureQuality {
    public static let minimumSignalToNoiseDB = 7.0
    public static let minimumPeakAmplitude = SignalQuality.minimumReliablePeakAmplitude
    public static let maximumClippingFraction = SignalQuality.maximumReliableClippingFraction

    /// Returns the most actionable reason a guided sample should be retried.
    /// Evaluation intentionally does not use this gate: every armed held-out tap
    /// must be counted, including classifier rejections.
    public static func issue(for quality: SignalQuality) -> GuidedCaptureQualityIssue? {
        if quality.clippingFraction > maximumClippingFraction { return .clipped }
        if quality.peakAmplitude < minimumPeakAmplitude { return .weak }
        if quality.signalToNoiseDB < minimumSignalToNoiseDB { return .noisy }
        return nil
    }
}
