import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// What the detector is allowed to spend per callback.
public enum DetectorMode: String, Sendable, CaseIterable {
    /// Full onset detection with pre-roll and analysis-window capture.
    case armed
    /// Loudness gate and noise-floor adaptation only. No pre-roll, no capture,
    /// no emitted taps. Reports strong transients so the app can recognize a
    /// wake gesture without classifying anything.
    case doze
}

/// One callback's worth of detector output.
public struct DetectorStep: Sendable {
    public var taps: [DetectedTap]
    /// Strong transients seen while dozing. Always 0 in Armed.
    public var wakeTransients: Int
    /// True on the callback where an onset armed a capture. Hybrid sensing uses
    /// this, and only this, to decide when to emit a confirmation chirp.
    public var onsetCandidate: Bool

    public init(taps: [DetectedTap] = [], wakeTransients: Int = 0, onsetCandidate: Bool = false) {
        self.taps = taps
        self.wakeTransients = wakeTransients
        self.onsetCandidate = onsetCandidate
    }
}

/// A low-allocation streaming onset detector. It adapts to the local noise floor,
/// retains a short pre-roll, and emits a fixed-length analysis window.
///
/// Every working buffer is allocated once in `init` and reused. In steady state
/// `step(channels:)` performs no heap allocation at all; the only allocation on
/// the audio path is the `DetectedTap` that escapes when a tap is actually
/// emitted, which cannot be avoided because the event outlives the callback.
public final class StreamingTapDetector {
    public let sampleRate: Double
    public let channelCount: Int
    public let analysisWindowSamples: Int
    public let preRollSamples: Int
    public let warmUpSamples: Int

    public private(set) var noiseFloorRMS: Double
    public private(set) var totalSamples: Int64 = 0
    public private(set) var mode: DetectorMode = .armed

    private let initialNoiseFloorRMS: Double
    private let wakePeakMultiplier: Double
    private let wakeMinimumPeak: Double

    // Flat, channel-major scratch. Channel `c` sample `i` lives at
    // `c * maximumBufferFrames + i`. Flat storage keeps the hot path free of
    // nested-array subscripts and of any chance of a copy-on-write allocation.
    private var maximumBufferFrames: Int
    private var channelScratch: [Float]
    private var monoScratch: [Float]
    private var onsetScratch: [Float]

    // Pre-roll ring, `channelCount * preRollSamples`.
    private var preRoll: [Float]
    private var preRollHead = 0
    private var preRollCount = 0

    // Capture buffer, `channelCount * captureCapacity`.
    private var captureCapacity: Int
    private var captureBuffer: [Float]
    private var captureLength = 0
    private var isCapturing = false
    private var captureOnsetOffset = 0
    private var captureStreamIndex: Int64 = 0
    private var captureNoiseFloor: Double = 0

    private var refractorySamplesRemaining = 0
    private var adaptNoiseDuringRefractory = false
    private var warmUpSamplesRemaining: Int
    private var onsetFilterState = Array(repeating: Float.zero, count: 4)

    public init(
        sampleRate: Double,
        channelCount: Int,
        analysisDuration: Double = 0.090,
        preRollDuration: Double = 0.012,
        warmUpDuration: Double = 0.75,
        initialNoiseFloorRMS: Double = 0.0005,
        maximumBufferFrames: Int = 8_192,
        wakePeakMultiplier: Double = 6.0,
        wakeMinimumPeak: Double = 0.012
    ) {
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        self.analysisWindowSamples = max(Int(sampleRate * analysisDuration), 1_024)
        self.preRollSamples = max(Int(sampleRate * preRollDuration), 128)
        self.warmUpSamples = max(Int(sampleRate * warmUpDuration), 0)
        self.initialNoiseFloorRMS = max(initialNoiseFloorRMS, 0.000_01)
        self.noiseFloorRMS = max(initialNoiseFloorRMS, 0.000_01)
        self.warmUpSamplesRemaining = max(Int(sampleRate * warmUpDuration), 0)
        self.wakePeakMultiplier = max(wakePeakMultiplier, 1)
        self.wakeMinimumPeak = max(wakeMinimumPeak, 0)

        let frames = max(maximumBufferFrames, 512)
        self.maximumBufferFrames = frames
        let channels = max(channelCount, 1)
        self.channelScratch = Array(repeating: 0, count: channels * frames)
        self.monoScratch = Array(repeating: 0, count: frames)
        self.onsetScratch = Array(repeating: 0, count: frames)
        self.preRoll = Array(repeating: 0, count: channels * self.preRollSamples)
        self.captureCapacity = self.preRollSamples + self.analysisWindowSamples + frames
        self.captureBuffer = Array(repeating: 0, count: channels * self.captureCapacity)
    }

    /// Switching tiers keeps the learned noise floor (that is the expensive
    /// thing to relearn) but drops any half-finished capture and stale pre-roll.
    public func setMode(_ newMode: DetectorMode) {
        guard newMode != mode else { return }
        mode = newMode
        isCapturing = false
        captureLength = 0
        preRollHead = 0
        preRollCount = 0
        refractorySamplesRemaining = 0
        adaptNoiseDuringRefractory = false
    }

    public func reset() {
        totalSamples = 0
        noiseFloorRMS = initialNoiseFloorRMS
        preRollHead = 0
        preRollCount = 0
        isCapturing = false
        captureLength = 0
        refractorySamplesRemaining = 0
        adaptNoiseDuringRefractory = false
        warmUpSamplesRemaining = warmUpSamples
        for index in onsetFilterState.indices { onsetFilterState[index] = 0 }
    }

    public func process(channels incoming: [[Float]]) -> [DetectedTap] {
        step(channels: incoming).taps
    }

    public func step(channels incoming: [[Float]]) -> DetectorStep {
        guard !incoming.isEmpty else { return DetectorStep() }
        let frameCount = incoming.map(\.count).min() ?? 0
        guard frameCount > 0 else { return DetectorStep() }

        growBuffersIfNeeded(frameCount: frameCount)
        loadScratch(from: incoming, frameCount: frameCount)
        mixDown(frameCount: frameCount)
        lowPassForOnset(frameCount: frameCount)
        defer { totalSamples += Int64(frameCount) }

        let rms = rootMeanSquare(count: frameCount)
        let peak = peakMagnitude(count: frameCount)

        // The initial fixed floor is only a safe bootstrap value. A MacBook mic
        // in a real room can sit well above it; trying to detect before learning
        // that floor creates a loop where every buffer looks like an impulse and
        // the floor never gets a chance to rise.
        if warmUpSamplesRemaining > 0 {
            adaptNoiseFloor(to: rms, isWarmUp: true)
            warmUpSamplesRemaining = max(0, warmUpSamplesRemaining - frameCount)
            if mode == .armed { appendToPreRoll(frameCount: frameCount) }
            return DetectorStep()
        }

        if mode == .doze {
            // Everything below this point (pre-roll, capture, feature-grade
            // thresholds) is skipped on purpose. Doze exists to cost nothing.
            adaptNoiseFloor(to: rms, isWarmUp: false)
            return DetectorStep(wakeTransients: wakeTransient(rms: rms, peak: peak) ? 1 : 0)
        }

        if refractorySamplesRemaining > 0 {
            if adaptNoiseDuringRefractory {
                adaptNoiseFloor(to: rms, isWarmUp: false)
            }
            refractorySamplesRemaining = max(0, refractorySamplesRemaining - frameCount)
            if refractorySamplesRemaining == 0 {
                adaptNoiseDuringRefractory = false
            }
            appendToPreRoll(frameCount: frameCount)
            return DetectorStep()
        }

        if isCapturing {
            appendToCapture(frameCount: frameCount)
            if let event = completeCaptureIfReady() {
                return DetectorStep(taps: [event])
            }
            return DetectorStep()
        }

        // Detect on a low-pass signal so the optional 15.5–21 kHz probe
        // cannot arm its own capture. The emitted event still contains the
        // untouched full-band channels used by the feature extractor.
        let rmsThreshold = max(noiseFloorRMS * 1.18, 0.0008)
        let peakThreshold = max(noiseFloorRMS * 4.0, 0.007)
        let crest = peak / max(rms, 0.000_001)
        let strongSampleThreshold = max(peakThreshold, peak * 0.55)
        var strongSampleCount = 0
        for index in 0..<frameCount where abs(Double(onsetScratch[index])) >= strongSampleThreshold {
            strongSampleCount += 1
        }
        let strongSampleFraction = Double(strongSampleCount) / Double(max(frameCount, 1))
        let isImpulse = rms > rmsThreshold
            && peak > peakThreshold
            && crest > 2.0
            && strongSampleFraction < 0.20

        if isImpulse {
            var crossing = 0
            for index in 0..<frameCount where abs(Double(onsetScratch[index])) >= peakThreshold {
                crossing = index
                break
            }
            beginCapture(crossing: crossing)
            appendToCapture(frameCount: frameCount)
            if let event = completeCaptureIfReady() {
                return DetectorStep(taps: [event], onsetCandidate: true)
            }
            return DetectorStep(onsetCandidate: true)
        } else {
            adaptNoiseFloor(to: rms, isWarmUp: false)
            appendToPreRoll(frameCount: frameCount)
        }

        return DetectorStep()
    }

    // MARK: - Buffer management

    private func growBuffersIfNeeded(frameCount: Int) {
        guard frameCount > maximumBufferFrames else { return }
        // Only reachable if the audio device hands over a buffer larger than
        // any tier requests. Reallocating is far better than truncating audio,
        // and it happens at most once per buffer-size increase, never per
        // callback. A capture in flight is dropped rather than spliced.
        maximumBufferFrames = frameCount
        channelScratch = Array(repeating: 0, count: channelCount * frameCount)
        monoScratch = Array(repeating: 0, count: frameCount)
        onsetScratch = Array(repeating: 0, count: frameCount)
        captureCapacity = preRollSamples + analysisWindowSamples + frameCount
        captureBuffer = Array(repeating: 0, count: channelCount * captureCapacity)
        isCapturing = false
        captureLength = 0
    }

    private func loadScratch(from incoming: [[Float]], frameCount: Int) {
        for channel in 0..<channelCount {
            let source = incoming[min(channel, incoming.count - 1)]
            let base = channel * maximumBufferFrames
            for index in 0..<frameCount {
                channelScratch[base + index] = source[index]
            }
        }
    }

    private func mixDown(frameCount: Int) {
        guard channelCount > 1 else {
            for index in 0..<frameCount { monoScratch[index] = channelScratch[index] }
            return
        }
        let scale = 1 / Float(channelCount)
        for index in 0..<frameCount { monoScratch[index] = 0 }
        for channel in 0..<channelCount {
            let base = channel * maximumBufferFrames
            for index in 0..<frameCount {
                monoScratch[index] += channelScratch[base + index] * scale
            }
        }
    }

    private func lowPassForOnset(frameCount: Int) {
        let cutoff = min(6_000.0, sampleRate * 0.20)
        let alpha = Float(1 - exp(-2 * Double.pi * cutoff / sampleRate))
        for index in 0..<frameCount {
            var filtered = monoScratch[index]
            for stage in onsetFilterState.indices {
                onsetFilterState[stage] += alpha * (filtered - onsetFilterState[stage])
                filtered = onsetFilterState[stage]
            }
            onsetScratch[index] = filtered
        }
    }

    /// Double accumulation, deliberately. `vDSP_rmsqv` accumulates in Float and
    /// would shift the detection thresholds by a hair, which the replay suite is
    /// entitled to notice. Peak has no such problem (see `peakMagnitude`).
    private func rootMeanSquare(count: Int) -> Double {
        guard count > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<count {
            let value = Double(onsetScratch[index])
            sum += value * value
        }
        return sqrt(sum / Double(count))
    }

    /// `vDSP_maxmgv` is a pure comparison reduction, so it returns exactly the
    /// same value as the scalar loop it replaces.
    private func peakMagnitude(count: Int) -> Double {
        guard count > 0 else { return 0 }
        #if canImport(Accelerate)
        var result: Float = 0
        onsetScratch.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxmgv(base, 1, &result, vDSP_Length(count))
        }
        return Double(result)
        #else
        var result = 0.0
        for index in 0..<count {
            result = max(result, abs(Double(onsetScratch[index])))
        }
        return result
        #endif
    }

    private func wakeTransient(rms: Double, peak: Double) -> Bool {
        let threshold = max(noiseFloorRMS * wakePeakMultiplier, wakeMinimumPeak)
        let crest = peak / max(rms, 0.000_001)
        return peak > threshold && crest > 2.0
    }

    private func adaptNoiseFloor(to measuredRMS: Double, isWarmUp: Bool) {
        guard measuredRMS.isFinite else { return }
        let measured = max(measuredRMS, 0.000_01)
        if isWarmUp {
            let alpha = 0.14
            noiseFloorRMS = (1 - alpha) * noiseFloorRMS + alpha * measured
            return
        }

        // Track sustained room changes quickly enough to avoid a false-trigger
        // cascade, but cap one-step growth so a real tap does not become the new
        // baseline. Downward movement is deliberately slower and steadier.
        let capped = min(measured, max(noiseFloorRMS * 3.5, 0.020))
        let alpha = capped > noiseFloorRMS ? 0.06 : 0.025
        noiseFloorRMS = (1 - alpha) * noiseFloorRMS + alpha * capped
    }

    private func appendToPreRoll(frameCount: Int) {
        let capacity = preRollSamples
        for index in 0..<frameCount {
            let position = (preRollHead + preRollCount) % capacity
            for channel in 0..<channelCount {
                preRoll[channel * capacity + position] = channelScratch[channel * maximumBufferFrames + index]
            }
            if preRollCount < capacity {
                preRollCount += 1
            } else {
                preRollHead = (preRollHead + 1) % capacity
            }
        }
    }

    private func beginCapture(crossing: Int) {
        isCapturing = true
        captureLength = preRollCount
        for channel in 0..<channelCount {
            let captureBase = channel * captureCapacity
            let preRollBase = channel * preRollSamples
            for index in 0..<preRollCount {
                let source = (preRollHead + index) % preRollSamples
                captureBuffer[captureBase + index] = preRoll[preRollBase + source]
            }
        }
        captureOnsetOffset = preRollCount + crossing
        captureStreamIndex = totalSamples + Int64(crossing)
        captureNoiseFloor = noiseFloorRMS
    }

    private func appendToCapture(frameCount: Int) {
        guard isCapturing else { return }
        let copyCount = min(frameCount, captureCapacity - captureLength)
        guard copyCount > 0 else { return }
        for channel in 0..<channelCount {
            let captureBase = channel * captureCapacity + captureLength
            let scratchBase = channel * maximumBufferFrames
            for index in 0..<copyCount {
                captureBuffer[captureBase + index] = channelScratch[scratchBase + index]
            }
        }
        captureLength += copyCount
    }

    private func completeCaptureIfReady() -> DetectedTap? {
        guard isCapturing, captureLength >= analysisWindowSamples else { return nil }
        var trimmed = [[Float]]()
        trimmed.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let base = channel * captureCapacity
            trimmed.append(Array(captureBuffer[base..<(base + analysisWindowSamples)]))
        }
        let event = DetectedTap(
            channels: trimmed,
            onsetOffset: min(captureOnsetOffset, analysisWindowSamples - 1),
            streamSampleIndex: captureStreamIndex,
            noiseFloorRMS: captureNoiseFloor
        )
        let accepted = ImpactEventGate.accepts(event, sampleRate: sampleRate)
        isCapturing = false
        captureLength = 0
        preRollHead = 0
        preRollCount = 0
        refractorySamplesRemaining = Int(sampleRate * 0.14)
        // A rejected sustained event is likely speech or a changed background.
        // Let the floor follow it during the refractory period so conversation
        // cannot repeatedly re-arm the detector every 140 ms.
        adaptNoiseDuringRefractory = !accepted
        return accepted ? event : nil
    }
}
