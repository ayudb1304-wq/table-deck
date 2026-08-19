import AVFoundation
import Combine
import Foundation
import HoloCore

struct TapObservation {
    var feature: TapFeatureVector
    var spectrum: [SpectrumBand]
    var rawChannels: [[Float]]
    var onsetOffset: Int
    var eventHostTimeSeconds: Double
    var processingLatencyMilliseconds: Double
}

enum AudioCaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case noInputChannels
    case invalidAudioFormat
    case audioRouteUnavailable(String)
    case builtInInputRequired(String)
    case builtInOutputRequired(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Enable Holo in System Settings › Privacy & Security › Microphone."
        case .noInputChannels:
            return "The selected audio input exposes no microphone channels."
        case .invalidAudioFormat:
            return "The default microphone format could not be configured."
        case .audioRouteUnavailable(let detail):
            return detail
        case .builtInInputRequired(let selected):
            return "Holo requires the MacBook's built-in microphone. The current input is \(selected). Select MacBook Microphone in System Settings › Sound › Input, then press Resume."
        case .builtInOutputRequired(let selected):
            return "Active and Hybrid sensing require the MacBook's built-in speakers. The current output is \(selected). Select MacBook Speakers in System Settings › Sound › Output, or use Passive sensing."
        }
    }
}

enum MicrophoneAuthorizationState {
    case notDetermined
    case authorized
    case unavailable
}

@MainActor
final class AudioCaptureService: ObservableObject {
    /// Buffer sizes per tier. Armed keeps the original 512 frames (~10.7 ms at
    /// 48 kHz, ~94 callbacks/s). Doze uses 4096 (~85 ms, ~11.7 callbacks/s),
    /// which is what drives acceptance criterion 1.
    static let armedBufferFrames: AVAudioFrameCount = 512
    static let dozeBufferFrames: AVAudioFrameCount = 4_096

    private struct PendingStart {
        var id: UUID
        var tier: ListeningTier
        var strategy: SensingStrategy
        var task: Task<Void, Error>
    }

    @Published private(set) var isListening = false
    @Published private(set) var tier: ListeningTier = .paused
    @Published private(set) var permissionGranted = false
    @Published private(set) var liveLevel: Double = 0
    @Published private(set) var diagnostics = MicrophoneDiagnostics()
    @Published private(set) var strategy: SensingStrategy = .passive
    @Published var lastError: String?

    var onObservation: ((TapObservation) -> Void)?
    var onRouteInvalidated: ((String) -> Void)?
    /// A deliberate double tap arrived while dozing.
    var onWakeGesture: (() -> Void)?

    private var engine: AVAudioEngine?
    private var probePlayer: AVAudioPlayerNode?
    private var probeLoopBuffer: AVAudioPCMBuffer?
    private var probeConfirmationBuffer: AVAudioPCMBuffer?
    private var configurationObserver: NSObjectProtocol?
    // One queue per QoS. A DispatchQueue's QoS is fixed at creation, so dozing
    // at `.utility` means dispatching to a different queue, not mutating this
    // one. The tap closure captures whichever queue was current when it was
    // installed, so a tier switch can never hand a buffer to a drained queue.
    nonisolated private let armedQueue = DispatchQueue(label: "com.holo.audio-analysis", qos: .userInteractive)
    nonisolated private let dozeQueue = DispatchQueue(label: "com.holo.audio-analysis.doze", qos: .utility)
    nonisolated(unsafe) private var detector: StreamingTapDetector?
    nonisolated(unsafe) private var extractor: TapFeatureExtractor?
    nonisolated(unsafe) private var wakeGesture = WakeGestureDetector()
    nonisolated(unsafe) private var probeDutyCycle = ActiveProbeDutyCycle()
    nonisolated(unsafe) private var timing = CallbackTimingAccumulator()
    nonisolated(unsafe) private var sampleRate = 48_000.0
    nonisolated(unsafe) private var inputLatencySeconds = 0.0
    nonisolated(unsafe) private var callbackCounter = 0
    nonisolated(unsafe) private var activeTier: ListeningTier = .paused
    /// Audio-queue mirror of `strategy`. The published property is MainActor
    /// state and must not be read from the analysis queue.
    nonisolated(unsafe) private var activeStrategy: SensingStrategy = .passive
    nonisolated(unsafe) private var wakeGestureEnabled = true
    private var captureGeneration: UInt64 = 0
    // Authorization is process-wide, not tied to one capture-service object.
    // Keeping both the in-flight request and its decision static guarantees
    // that even an unexpected second model/service in the same app process
    // cannot enqueue another macOS permission prompt.
    private static let permissionRequestGate = AsyncBooleanRequestGate()
    private static var permissionDecisionThisLaunch: Bool?
    private var pendingStart: PendingStart?

    var authorizationState: MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied, .restricted: return .unavailable
        @unknown default: return .unavailable
        }
    }

    private static func bufferFrames(for tier: ListeningTier) -> AVAudioFrameCount {
        tier == .doze ? dozeBufferFrames : armedBufferFrames
    }

    private func queue(for tier: ListeningTier) -> DispatchQueue {
        tier == .doze ? dozeQueue : armedQueue
    }

    func setWakeGestureEnabled(_ enabled: Bool) {
        wakeGestureEnabled = enabled
    }

    /// The single entry point for tier changes. Everything else in the app asks
    /// for a tier and a strategy and lets this decide whether that means
    /// starting, stopping, or just reinstalling the tap.
    func apply(tier requestedTier: ListeningTier, strategy requestedStrategy: SensingStrategy) async throws {
        guard requestedTier != .paused else {
            stop()
            return
        }

        if isListening, self.strategy == requestedStrategy {
            // Same engine, same route, different cadence. Reinstalling the tap
            // keeps the learned noise floor, which is worth far more than the
            // simplicity of a full restart: a restart would re-enter the 0.75 s
            // warm-up every time the desk goes quiet and wakes again.
            if activeTier != requestedTier {
                reinstallTap(for: requestedTier)
            }
            return
        }

        try await start(tier: requestedTier, strategy: requestedStrategy)
    }

    private func start(tier requestedTier: ListeningTier, strategy requestedStrategy: SensingStrategy) async throws {
        if isListening && self.strategy == requestedStrategy && activeTier == requestedTier { return }

        if let pendingStart, pendingStart.strategy == requestedStrategy, pendingStart.tier == requestedTier {
            try await pendingStart.task.value
            return
        }

        pendingStart?.task.cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.startNow(tier: requestedTier, strategy: requestedStrategy)
        }
        pendingStart = PendingStart(id: id, tier: requestedTier, strategy: requestedStrategy, task: task)

        do {
            try await task.value
            if pendingStart?.id == id { pendingStart = nil }
        } catch {
            if pendingStart?.id == id { pendingStart = nil }
            throw error
        }
    }

    private func startNow(tier requestedTier: ListeningTier, strategy: SensingStrategy) async throws {
        try Task.checkCancellation()
        stopCapture()

        let route: AudioRouteInfo
        do {
            route = try SystemAudioRouteInspector.currentRoute()
        } catch {
            let captureError = AudioCaptureError.audioRouteUnavailable(error.localizedDescription)
            lastError = captureError.localizedDescription
            throw captureError
        }
        diagnostics.deviceName = route.input?.name ?? "No input"
        diagnostics.audioRoute = route
        if let issue = AudioHardwarePolicy.issue(for: route, strategy: strategy) {
            let captureError = Self.captureError(for: issue)
            lastError = captureError.localizedDescription
            throw captureError
        }

        guard await requestMicrophonePermission() else {
            lastError = AudioCaptureError.microphonePermissionDenied.localizedDescription
            throw AudioCaptureError.microphonePermissionDenied
        }
        try Task.checkCancellation()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw AudioCaptureError.noInputChannels }
        guard format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw AudioCaptureError.invalidAudioFormat
        }

        self.strategy = strategy
        sampleRate = format.sampleRate
        inputLatencySeconds = input.presentationLatency
        let channelCount = Int(format.channelCount)
        armedQueue.sync {
            // Sized for twice the largest tier buffer: `installTap` treats its
            // size as a hint, and a device that hands over more than requested
            // must not force a reallocation on the audio path.
            detector = StreamingTapDetector(
                sampleRate: format.sampleRate,
                channelCount: channelCount,
                maximumBufferFrames: Int(Self.dozeBufferFrames) * 2
            )
            detector?.setMode(requestedTier == .doze ? .doze : .armed)
            extractor = TapFeatureExtractor(sampleRate: format.sampleRate, strategy: strategy)
            timing = CallbackTimingAccumulator()
            wakeGesture.reset()
            probeDutyCycle.reset()
            callbackCounter = 0
            activeTier = requestedTier
            activeStrategy = strategy
        }

        if strategy != .passive {
            configureProbe(on: engine, sampleRate: format.sampleRate)
        }

        installTap(on: input, format: format, tier: requestedTier)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lastError = error.localizedDescription
            throw error
        }
        self.engine = engine
        applyProbeSteadyState(for: requestedTier)
        diagnostics = MicrophoneDiagnostics(
            deviceName: route.input?.name ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default system input",
            audioRoute: route,
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            channelNames: (1...channelCount).map { "Input \($0)" },
            bufferFrameCount: Int(Self.bufferFrames(for: requestedTier)),
            timing: TimingDiagnostics(
                expectedCallbackMilliseconds: Double(Self.bufferFrames(for: requestedTier)) / format.sampleRate * 1_000,
                estimatedInputLatencyMilliseconds: inputLatencySeconds * 1_000
            ),
            microphonePermissionGranted: true
        )
        lastError = nil
        isListening = true
        tier = requestedTier
        observeConfigurationChanges(for: engine)
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat, tier installedTier: ListeningTier) {
        let fallbackInputLatency = inputLatencySeconds
        let generation = captureGeneration
        let sampleRateForTap = format.sampleRate
        let targetQueue = queue(for: installedTier)
        input.installTap(
            onBus: 0,
            bufferSize: Self.bufferFrames(for: installedTier),
            format: nil
        ) { [weak self] buffer, when in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }
            let channels = (0..<channelCount).map { channel in
                Array(UnsafeBufferPointer(start: channelData[channel], count: frameCount))
            }
            let callbackUptime = ProcessInfo.processInfo.systemUptime
            let reportedHostTime = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : .nan
            let fallbackHostTime = callbackUptime - Double(frameCount) / sampleRateForTap - fallbackInputLatency
            let bufferStartHostTimeSeconds = reportedHostTime.isFinite && abs(reportedHostTime - callbackUptime) < 10
                ? reportedHostTime
                : fallbackHostTime
            targetQueue.async { [weak self] in
                self?.process(
                    channels: channels,
                    callbackUptime: callbackUptime,
                    bufferStartHostTimeSeconds: bufferStartHostTimeSeconds,
                    generation: generation
                )
            }
        }
    }

    /// Swaps buffer size and processing QoS without touching the engine.
    private func reinstallTap(for requestedTier: ListeningTier) {
        guard let engine, isListening else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)

        // Drain the queue the old tap was feeding so no in-flight buffer is
        // still inside the detector while its mode changes.
        queue(for: activeTier).sync {
            detector?.setMode(requestedTier == .doze ? .doze : .armed)
            wakeGesture.reset()
            probeDutyCycle.reset()
            activeTier = requestedTier
        }

        installTap(on: input, format: format, tier: requestedTier)
        applyProbeSteadyState(for: requestedTier)
        tier = requestedTier
        diagnostics.bufferFrameCount = Int(Self.bufferFrames(for: requestedTier))
        diagnostics.timing = TimingDiagnostics(
            expectedCallbackMilliseconds: Double(Self.bufferFrames(for: requestedTier)) / sampleRate * 1_000,
            estimatedInputLatencyMilliseconds: inputLatencySeconds * 1_000
        )
    }

    func stop() {
        pendingStart?.task.cancel()
        pendingStart = nil
        stopCapture()
    }

    private func stopCapture() {
        captureGeneration &+= 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        probePlayer?.stop()
        probePlayer = nil
        probeLoopBuffer = nil
        probeConfirmationBuffer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
        // Both queues, because a tier switch may have left work on either.
        for queue in [armedQueue, dozeQueue] {
            queue.sync {
                detector = nil
                extractor = nil
            }
        }
        activeTier = .paused
        isListening = false
        tier = .paused
        liveLevel = 0
    }

    /// Exposed so diagnostics (and acceptance criterion 1) can confirm the
    /// analysis queue actually dropped to `.utility` while dozing.
    var processingQoSClass: DispatchQoS.QoSClass {
        queue(for: activeTier).qos.qosClass
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
            return true
        case .denied, .restricted:
            permissionGranted = false
            return false
        case .notDetermined:
            if let permissionDecisionThisLaunch = Self.permissionDecisionThisLaunch {
                permissionGranted = permissionDecisionThisLaunch
                return permissionDecisionThisLaunch
            }
            let granted = await Self.permissionRequestGate.run {
                await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) {
                        continuation.resume(returning: $0)
                    }
                }
            }
            Self.permissionDecisionThisLaunch = granted
            permissionGranted = granted
            return granted
        @unknown default:
            permissionGranted = false
            return false
        }
    }

    private static func captureError(for issue: AudioHardwarePolicyIssue) -> AudioCaptureError {
        switch issue {
        case .inputUnavailable:
            return .audioRouteUnavailable("No default microphone is available. Select MacBook Microphone in System Settings › Sound › Input.")
        case .builtInInputRequired(let selected):
            return .builtInInputRequired(selected)
        case .outputUnavailable:
            return .audioRouteUnavailable("No default speaker output is available. Select MacBook Speakers in System Settings › Sound › Output.")
        case .builtInOutputRequired(let selected):
            return .builtInOutputRequired(selected)
        }
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard isListening else { return }
        do {
            let route = try SystemAudioRouteInspector.currentRoute()
            diagnostics.audioRoute = route
            diagnostics.deviceName = route.input?.name ?? "No input"
            if let issue = AudioHardwarePolicy.issue(for: route, strategy: strategy) {
                invalidateRoute(with: Self.captureError(for: issue))
            } else if engine?.isRunning != true {
                invalidateRoute(with: .audioRouteUnavailable(
                    "The audio device changed and capture stopped. Confirm the built-in routes, then press Resume."
                ))
            }
        } catch {
            invalidateRoute(with: .audioRouteUnavailable(error.localizedDescription))
        }
    }

    private func invalidateRoute(with error: AudioCaptureError) {
        let message = error.localizedDescription
        stop()
        lastError = message
        onRouteInvalidated?(message)
    }

    // MARK: - Probe

    private func configureProbe(on engine: AVAudioEngine, sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let chirp = ActiveProbe.chirp(sampleRate: sampleRate)
        let periodFrames = max(Int(sampleRate * 0.120), 1)
        guard let loopBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(periodFrames)
        ), let loopSamples = loopBuffer.floatChannelData?[0] else { return }
        loopBuffer.frameLength = AVAudioFrameCount(periodFrames)
        for index in 0..<periodFrames {
            loopSamples[index] = index < chirp.count ? chirp[index] : 0
        }

        guard let confirmationBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(chirp.count, 1))
        ), let confirmationSamples = confirmationBuffer.floatChannelData?[0] else { return }
        confirmationBuffer.frameLength = AVAudioFrameCount(chirp.count)
        for index in 0..<chirp.count { confirmationSamples[index] = chirp[index] }

        player.volume = 0.55
        probePlayer = player
        probeLoopBuffer = loopBuffer
        probeConfirmationBuffer = confirmationBuffer
    }

    /// Starts or silences the probe for a tier. Hybrid deliberately leaves the
    /// player running with nothing scheduled: it renders silence until an onset
    /// candidate schedules one chirp.
    private func applyProbeSteadyState(for requestedTier: ListeningTier) {
        guard let player = probePlayer else { return }
        switch ActiveProbeDutyCycle.steadyState(strategy: strategy, tier: requestedTier) {
        case .continuous:
            guard let probeLoopBuffer else { return }
            player.stop()
            player.scheduleBuffer(probeLoopBuffer, at: nil, options: .loops)
            player.play()
        case .silent:
            if strategy == .hybrid && requestedTier == .armed {
                // Running but empty: scheduling later is what makes a sound.
                if !player.isPlaying { player.play() }
            } else {
                player.stop()
            }
        case .confirmation:
            break
        }
    }

    /// Called from the analysis queue when the detector flags an onset.
    nonisolated private func scheduleConfirmationChirp() {
        Task { @MainActor [weak self] in
            guard let self,
                  let player = self.probePlayer,
                  let buffer = self.probeConfirmationBuffer,
                  self.isListening else { return }
            if !player.isPlaying { player.play() }
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }
    }

    // MARK: - Analysis

    nonisolated private func process(
        channels: [[Float]],
        callbackUptime: Double,
        bufferStartHostTimeSeconds: Double,
        generation: UInt64
    ) {
        guard let detector, let frameCount = channels.first?.count else { return }
        callbackCounter += 1
        timing.record(timestamp: callbackUptime)
        let bufferStartSampleIndex = detector.totalSamples
        let dozing = activeTier == .doze

        let step = detector.step(channels: channels)

        if dozing {
            // Doze reports level for the UI and nothing else: no mixdown for
            // metering, no feature extraction, no classification.
            if step.wakeTransients > 0, wakeGestureEnabled, wakeGesture.noteTransient(at: callbackUptime) {
                Task { @MainActor [weak self] in
                    guard let self, self.captureGeneration == generation, self.isListening else { return }
                    self.onWakeGesture?()
                }
            }
            if callbackCounter.isMultiple(of: 2) {
                publishTiming(frameCount: frameCount, level: nil, generation: generation)
            }
            return
        }

        if step.onsetCandidate,
           probeDutyCycle.onOnsetCandidate(
               strategy: activeStrategy,
               tier: .armed,
               at: callbackUptime
           ) == .confirmation {
            scheduleConfirmationChirp()
        }

        let mono = channels.count == 1 ? channels[0] : (0..<frameCount).map { index in
            channels.reduce(Float.zero) { $0 + $1[index] / Float(channels.count) }
        }
        let rms = sqrt(mono.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(mono.count, 1)))

        if callbackCounter.isMultiple(of: 8) {
            publishTiming(frameCount: frameCount, level: rms, generation: generation)
        }

        guard let extractor else { return }
        for event in step.taps {
            let processingStart = ProcessInfo.processInfo.systemUptime
            let analysis = extractor.analyze(from: event)
            let processingEnd = ProcessInfo.processInfo.systemUptime
            let eventUptime = AudioTimeline.eventHostTimeSeconds(
                bufferStartHostTimeSeconds: bufferStartHostTimeSeconds,
                bufferStartSampleIndex: bufferStartSampleIndex,
                eventSampleIndex: event.streamSampleIndex,
                sampleRate: sampleRate
            )
            let observation = TapObservation(
                feature: analysis.feature,
                spectrum: analysis.spectrum,
                rawChannels: event.channels,
                onsetOffset: event.onsetOffset,
                eventHostTimeSeconds: eventUptime,
                processingLatencyMilliseconds: (processingEnd - processingStart) * 1_000
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.captureGeneration == generation,
                      self.isListening else { return }
                self.diagnostics.latestSignalQuality = analysis.feature.quality
                self.diagnostics.latestFrequencyResponse = analysis.spectrum
                self.diagnostics.capturedAt = Date()
                self.onObservation?(observation)
            }
        }
    }

    nonisolated private func publishTiming(frameCount: Int, level rms: Double?, generation: UInt64) {
        let expected = Double(frameCount) / sampleRate * 1_000
        let timingSnapshot = timing.diagnostics(
            expectedMilliseconds: expected,
            inputLatencyMilliseconds: inputLatencySeconds * 1_000
        )
        Task { @MainActor [weak self] in
            guard let self,
                  self.captureGeneration == generation,
                  self.isListening else { return }
            if let rms {
                self.liveLevel = min(max((20 * log10(max(rms, 1e-8)) + 70) / 70, 0), 1)
            }
            self.diagnostics.timing = timingSnapshot
        }
    }
}
