import Foundation

public enum ActiveProbe {
    public static func chirp(
        sampleRate: Double,
        duration: Double = 0.024,
        startFrequency: Double = 15_500,
        endFrequency: Double = 21_000,
        amplitude: Double = 0.035
    ) -> [Float] {
        let count = max(Int(sampleRate * duration), 32)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let slope = (endFrequency - startFrequency) / duration
            let phase = 2 * Double.pi * (startFrequency * time + 0.5 * slope * time * time)
            let edge = min(Double(index) / Double(max(count / 8, 1)), Double(count - 1 - index) / Double(max(count / 8, 1)))
            let envelope = min(max(edge, 0), 1)
            return Float(sin(phase) * amplitude * envelope)
        }
    }

    static func responseFeatures(
        signal: [Double],
        sampleRate: Double,
        spectrum: [Double]? = nil
    ) -> (names: [String], values: [Double]) {
        let probe = chirp(sampleRate: sampleRate).map(Double.init)
        guard signal.count >= probe.count else {
            return (activeFeatureNames, Array(repeating: 0, count: activeFeatureNames.count))
        }

        let stride = max(probe.count / 4, 1)
        var correlations: [Double] = []
        var index = 0
        let probeEnergy = sqrt(probe.reduce(0) { $0 + $1 * $1 }) + 1e-12
        while index + probe.count <= signal.count {
            var dot = 0.0
            var energy = 0.0
            for probeIndex in probe.indices {
                let sample = signal[index + probeIndex]
                dot += sample * probe[probeIndex]
                energy += sample * sample
            }
            correlations.append(dot / (probeEnergy * sqrt(energy) + 1e-12))
            index += stride
        }

        let peak = correlations.map(abs).max() ?? 0
        let peakIndex = correlations.enumerated().max(by: { abs($0.element) < abs($1.element) })?.offset ?? 0
        let mean = correlations.isEmpty ? 0 : correlations.reduce(0, +) / Double(correlations.count)
        let variance = correlations.isEmpty ? 0 : correlations.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(correlations.count)
        let responseSpectrum = spectrum ?? Radix2FFT.powerSpectrum(
            signal,
            size: min(Radix2FFT.nextPowerOfTwo(signal.count), 4096)
        )
        let responseBands = normalizedLogBands(spectrum: responseSpectrum, sampleRate: sampleRate, count: 8)
        let values = [peak, Double(peakIndex) / Double(max(correlations.count - 1, 1)), mean, sqrt(variance)] + responseBands
        return (activeFeatureNames, values)
    }

    /// Longest gap between a passive onset candidate and its confirmation
    /// chirp, spec 01.
    public static let confirmationWindow: TimeInterval = 0.150

    static let activeFeatureNames = [
        "probe_correlation_peak", "probe_correlation_lag", "probe_correlation_mean", "probe_correlation_spread"
    ] + (0..<8).map { "probe_band_\($0)" }

    private static func normalizedLogBands(spectrum: [Double], sampleRate: Double, count: Int) -> [Double] {
        let minimum = 8_000.0
        let maximum = min(sampleRate * 0.48, 22_000)
        let total = spectrum.reduce(0, +) + 1e-15
        return (0..<count).map { band in
            let lowRatio = Double(band) / Double(count)
            let highRatio = Double(band + 1) / Double(count)
            let low = minimum * pow(maximum / minimum, lowRatio)
            let high = minimum * pow(maximum / minimum, highRatio)
            let start = max(Int(low / sampleRate * Double((spectrum.count - 1) * 2)), 0)
            let end = min(Int(high / sampleRate * Double((spectrum.count - 1) * 2)), spectrum.count - 1)
            guard end >= start else { return -30 }
            let energy = spectrum[start...end].reduce(0, +) / total
            return log10(energy + 1e-12)
        }
    }
}

/// When the speaker is allowed to emit a chirp.
///
/// Continuous chirping is what made Hybrid feel like the Mac was permanently
/// making a noise at the edge of hearing, and it is the single largest idle
/// power cost of the sensing pipeline. Hybrid now emits one confirmation chirp
/// only in response to a passive onset candidate; Active keeps its continuous
/// loop because it has no passive candidate to react to.
public struct ActiveProbeDutyCycle: Equatable, Sendable {
    public enum Emission: Equatable, Sendable {
        /// Speaker stays silent.
        case silent
        /// The looping period buffer plays for as long as the tier lasts.
        case continuous
        /// One chirp, scheduled now.
        case confirmation
    }

    public let minimumInterval: TimeInterval
    private var lastConfirmationAt: Double?

    public init(minimumInterval: TimeInterval = ActiveProbe.confirmationWindow) {
        self.minimumInterval = max(minimumInterval, 0)
    }

    /// What the speaker should do while the tier is simply running, with no
    /// onset candidate in hand.
    public static func steadyState(strategy: SensingStrategy, tier: ListeningTier) -> Emission {
        guard tier == .armed else { return .silent }
        return strategy == .active ? .continuous : .silent
    }

    /// What the speaker should do now that the detector flagged a candidate.
    public mutating func onOnsetCandidate(
        strategy: SensingStrategy,
        tier: ListeningTier,
        at now: Double
    ) -> Emission {
        guard strategy == .hybrid, tier == .armed else { return .silent }
        if let lastConfirmationAt, now - lastConfirmationAt < minimumInterval { return .silent }
        lastConfirmationAt = now
        return .confirmation
    }

    public mutating func reset() {
        lastConfirmationAt = nil
    }
}
