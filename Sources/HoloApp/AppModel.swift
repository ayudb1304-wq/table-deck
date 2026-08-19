import AppKit
import Combine
import Foundation
import HoloCore

enum DiagnosticLabel: Hashable, Identifiable {
    case zone(DeskZone)
    case negative(String)

    var id: String {
        switch self {
        case .zone(let zone): return "zone-\(zone.rawValue)"
        case .negative(let label): return "negative-\(label)"
        }
    }

    var displayName: String {
        switch self {
        case .zone(let zone): return zone.displayName
        case .negative(let label): return label
        }
    }

    var zone: DeskZone? {
        if case .zone(let zone) = self { return zone }
        return nil
    }
}

/// A privileged action waiting for its one-time confirmation on this profile.
struct PendingPrivilegedConfirmation: Identifiable, Equatable {
    var id: String { "\(profileID.uuidString):\(kind.rawValue)" }
    var profileID: UUID
    var zone: DeskZone
    var kind: ZoneActionKind

    var prompt: String {
        "\(zone.displayName) is assigned \"\(kind.displayName)\". Actions like this reach outside Holo, so it needs confirming once before a tap can run it."
    }
}

enum HoloStorageError: Error, LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let area):
            return "\(area) storage is unavailable. Holo did not save this change."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .live
    @Published private(set) var profiles: [HoloProfile] = []
    @Published var selectedProfileID: UUID?
    @Published private(set) var activeZone: DeskZone?
    @Published private(set) var lastDecision: ClassificationDecision?
    @Published private(set) var statusMessage = "Ready to map your desk"
    @Published private(set) var calibrationSession: CalibrationSession?
    @Published private(set) var calibrationValidation: CrossValidationResult?
    @Published private(set) var evaluationSession: EvaluationSession?
    @Published private(set) var latestEvaluation: EvaluationReport?
    @Published private(set) var evaluationHistory: [EvaluationReport] = []
    @Published private(set) var latestEvaluationIsPersisted = false
    @Published private(set) var benchmarkSession: BenchmarkSession?
    @Published private(set) var approachComparison: ApproachComparison?
    @Published private(set) var diagnosticCaptures: [DiagnosticCaptureRecord] = []
    @Published var diagnosticLabel: DiagnosticLabel = .zone(.leftTop)
    @Published var diagnosticCaptureArmed = false
    @Published private(set) var guidedCaptureIssue: GuidedCaptureQualityIssue?
    @Published var debugRecordingEnabled = false
    @Published private(set) var hasDebugRecordings = false
    @Published var errorMessage: String?

    @Published private(set) var listeningTier: ListeningTier = .paused
    @Published private(set) var pauseReasons: [PauseReason] = []
    @Published private(set) var listeningSettings = ListeningTierSettings()
    @Published var pendingPrivilegedConfirmation: PendingPrivilegedConfirmation?

    let audio = AudioCaptureService()
    @Published var calibrationDraft = CalibrationDraft()

    private let profileStore: ProfileStore?
    private let evaluationStore: EvaluationStore?
    private let comparisonStore: ApproachComparisonStore?
    private let debugStore: DebugRecordingStore?
    private let listeningSettingsStore: ListeningSettingsStore?
    private let consentStore: PrivilegedActionConsentStore?
    private let actionDispatcher = LocalActionDispatcher()
    private let power = PowerStateObserver()
    private var tierMachine = ListeningTierMachine()
    private var privilegedConsent = PrivilegedActionConsent()
    private var privilegedRateLimiter = PrivilegedActionRateLimiter()
    private var tierTimer: Timer?
    private var recalibratingProfileID: UUID?
    private var calibrationAcceptAfter = Date.distantPast
    private var evaluationAcceptAfter = Date.distantPast
    private var benchmarkAcceptAfter = Date.distantPast
    private var calibrationArmTask: Task<Void, Never>?
    private var evaluationArmTask: Task<Void, Never>?
    private var benchmarkArmTask: Task<Void, Never>?
    private var activeZoneClearTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private var monotonicNow: Double { ProcessInfo.processInfo.systemUptime }

    init() {
        var startupErrors: [String] = []
        do { profileStore = try ProfileStore() }
        catch {
            profileStore = nil
            startupErrors.append("Profiles: \(error.localizedDescription)")
        }
        do { evaluationStore = try EvaluationStore() }
        catch {
            evaluationStore = nil
            startupErrors.append("Evaluations: \(error.localizedDescription)")
        }
        do { comparisonStore = try ApproachComparisonStore() }
        catch {
            comparisonStore = nil
            startupErrors.append("Sensing comparison: \(error.localizedDescription)")
        }
        do { debugStore = try DebugRecordingStore() }
        catch {
            debugStore = nil
            startupErrors.append("Debug recordings: \(error.localizedDescription)")
        }
        do { listeningSettingsStore = try ListeningSettingsStore() }
        catch {
            listeningSettingsStore = nil
            startupErrors.append("Listening settings: \(error.localizedDescription)")
        }
        do { consentStore = try PrivilegedActionConsentStore() }
        catch {
            consentStore = nil
            startupErrors.append("Action confirmations: \(error.localizedDescription)")
        }

        if let listeningSettingsStore {
            do { listeningSettings = try listeningSettingsStore.load() }
            catch { startupErrors.append("Listening settings: \(error.localizedDescription)") }
        }
        if let consentStore {
            do { privilegedConsent = try consentStore.load() }
            catch { startupErrors.append("Action confirmations: \(error.localizedDescription)") }
        }

        if let debugStore {
            do { hasDebugRecordings = try debugStore.containsRecordings() }
            catch { startupErrors.append("Debug recordings: \(error.localizedDescription)") }
        }
        if let profileStore {
            do { profiles = try profileStore.loadAll() }
            catch { startupErrors.append("Profiles: \(error.localizedDescription)") }
        }
        selectedProfileID = profiles.first?.id
        if let evaluationStore {
            do { evaluationHistory = try evaluationStore.loadAll() }
            catch { startupErrors.append("Evaluations: \(error.localizedDescription)") }
        }
        refreshLatestEvaluation()
        if let comparisonStore {
            do { approachComparison = try comparisonStore.load() }
            catch { startupErrors.append("Sensing comparison: \(error.localizedDescription)") }
        }
        if let profile = profiles.first {
            calibrationDraft = draft(for: profile)
        } else {
            calibrationDraft.strategy = applicableApproachComparison?.selectedStrategy ?? .passive
        }
        if !startupErrors.isEmpty {
            statusMessage = "Local storage needs attention"
            errorMessage = "Some local data could not be opened:\n\n" + startupErrors.joined(separator: "\n")
        }

        tierMachine = ListeningTierMachine(
            settings: listeningSettings,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        audio.setWakeGestureEnabled(listeningSettings.wakeGestureEnabled)

        audio.onObservation = { [weak self] observation in
            self?.handle(observation)
        }
        audio.onRouteInvalidated = { [weak self] message in
            self?.disarmAllCaptureIntents()
            self?.activeZone = nil
            self?.statusMessage = "Built-in audio route required"
            self?.errorMessage = message
        }
        audio.onWakeGesture = { [weak self] in
            self?.handleWakeGesture()
        }
        power.onChange = { [weak self] _ in
            self?.refreshTier()
        }
        actionDispatcher.onAsyncError = { [weak self] error in
            self?.errorMessage = "The assigned action failed. \(error.localizedDescription)"
        }
        audio.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    var selectedProfile: HoloProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID }
    }

    var guidedSection: AppSection? {
        GuidedNavigationGate.guidedSection(
            calibrationActive: calibrationSession != nil,
            evaluationActive: evaluationSession != nil,
            benchmarkActive: benchmarkSession != nil
        )
    }

    func canNavigate(to candidate: AppSection) -> Bool {
        GuidedNavigationGate.canNavigate(to: candidate, guidedSection: guidedSection)
    }

    var targetStrategy: SensingStrategy {
        SensingStrategyResolver.resolve(
            benchmark: benchmarkSession?.currentStrategy,
            calibration: calibrationSession?.draft.strategy,
            profile: selectedProfile?.sensingStrategy,
            comparison: applicableApproachComparison?.selectedStrategy
        )
    }

    var applicableApproachComparison: ApproachComparison? {
        guard let comparison = approachComparison else { return nil }
        return comparison.applies(to: selectedProfile?.id) ? comparison : nil
    }

    func activate() async {
        do {
            tierMachine.noteWake(at: monotonicNow)
            let decision = tierMachine.evaluate(power.conditions, at: monotonicNow)
            publish(decision)
            guard decision.tier != .paused else {
                statusMessage = decision.statusText
                return
            }
            try await audio.apply(tier: decision.tier, strategy: targetStrategy)
            power.setEngineRunning(audio.isListening)
            if let zone = calibrationSession?.currentZone {
                statusMessage = "Calibration ready • move to \(zone.displayName), then arm"
            } else if let zone = evaluationSession?.currentZone {
                statusMessage = "Accuracy test ready • move to \(zone.displayName), then arm"
            } else if let benchmark = benchmarkSession,
                      let strategy = benchmark.currentStrategy,
                      let zone = benchmark.currentZone {
                statusMessage = "Sensing comparison ready • \(strategy.displayName) • \(zone.displayName)"
            } else {
                statusMessage = selectedProfile == nil ? "Listening • calibration needed" : "Listening for desk taps"
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Microphone unavailable"
        }
    }

    func activateOnLaunch() async {
        startTierObservation()
        guard selectedProfile != nil else {
            section = .calibrate
            statusMessage = "Setup required • calibrate the four desk zones"
            return
        }

        switch audio.authorizationState {
        case .authorized:
            await activate()
        case .notDetermined:
            statusMessage = selectedProfile == nil
                ? "Microphone access will be requested when calibration begins"
                : "Press Resume to enable microphone access"
        case .unavailable:
            statusMessage = "Microphone access is off"
        }
    }

    func togglePause() {
        if audio.isListening {
            disarmAllCaptureIntents()
            activeZone = nil
            power.setManuallyPaused(true)
        } else if selectedProfile == nil && guidedSection == nil {
            openSetup()
        } else {
            resumeFromManualPause()
            Task { await activate() }
        }
    }

    // MARK: - Listening tier

    /// Starts the system observers and the coarse idle timer. Called once, from
    /// `activateOnLaunch`, so that unit-constructed models stay inert.
    func startTierObservation() {
        guard tierTimer == nil else { return }
        power.start()
        // The doze transition is the only tier change with no notification
        // behind it, so it needs a poll. Five seconds is far finer than the
        // three-minute default timeout and costs one comparison per tick.
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTier() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        tierTimer = timer
        refreshTier()
    }

    func updateListeningSettings(_ settings: ListeningTierSettings) {
        let sanitized = settings.sanitized()
        listeningSettings = sanitized
        tierMachine.settings = sanitized
        audio.setWakeGestureEnabled(sanitized.wakeGestureEnabled)
        do {
            guard let listeningSettingsStore else { throw HoloStorageError.unavailable("Listening settings") }
            try listeningSettingsStore.save(sanitized)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshTier()
    }

    private func resumeFromManualPause() {
        power.setManuallyPaused(false)
        tierMachine.noteWake(at: monotonicNow)
    }

    private func handleWakeGesture() {
        guard listeningSettings.wakeGestureEnabled else { return }
        tierMachine.noteWake(at: monotonicNow)
        refreshTier()
    }

    /// Recomputes the tier from current conditions and drives capture to match.
    /// Every path that can change a condition ends here.
    private func refreshTier() {
        var decision = tierMachine.evaluate(power.conditions, at: monotonicNow)
        // Guided capture never dozes. The user is standing at the desk waiting
        // to be told when to tap, and the idle countdown only counts taps that
        // reached the live pipeline.
        if guidedSection != nil, decision.tier == .doze {
            tierMachine.noteWake(at: monotonicNow)
            decision = tierMachine.evaluate(power.conditions, at: monotonicNow)
        }
        let changed = decision.tier != listeningTier
        publish(decision)

        if decision.tier == .paused {
            if changed {
                disarmAllCaptureIntents()
                activeZone = nil
                privilegedRateLimiter.reset()
            }
            if audio.isListening {
                audio.stop()
                power.setEngineRunning(false)
            }
            if changed, guidedSection == nil { statusMessage = decision.statusText }
            return
        }

        guard selectedProfile != nil || guidedSection != nil else { return }
        guard audio.authorizationState == .authorized || audio.isListening else { return }

        if changed, guidedSection == nil {
            statusMessage = decision.tier == .doze
                ? "Dozing, measuring loudness only"
                : "Listening for desk taps"
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audio.apply(tier: decision.tier, strategy: self.targetStrategy)
                self.power.setEngineRunning(self.audio.isListening)
            } catch is CancellationError {
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func publish(_ decision: ListeningTierDecision) {
        listeningTier = decision.tier
        pauseReasons = decision.pauseReasons
    }

    func openSetup() {
        guard guidedSection == nil else { return }
        section = .calibrate
        statusMessage = "Setup required • calibrate the four desk zones"
    }

    func selectProfile(_ id: UUID?) {
        guard guidedSection == nil else { return }
        selectedProfileID = id
        activeZoneClearTask?.cancel()
        activeZone = nil
        lastDecision = nil
        refreshLatestEvaluation()
        if let profile = selectedProfile {
            calibrationDraft = draft(for: profile)
        }
        Task {
            do { try await reconfigureListeningAudio(to: targetStrategy) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func beginCalibration(draft: CalibrationDraft, recalibrating: HoloProfile? = nil) {
        resumeFromManualPause()
        calibrationArmTask?.cancel()
        evaluationArmTask?.cancel()
        benchmarkArmTask?.cancel()
        calibrationDraft = draft
        recalibratingProfileID = recalibrating?.id
        calibrationSession = CalibrationSession(draft: draft)
        calibrationValidation = nil
        guidedCaptureIssue = nil
        calibrationAcceptAfter = Date().addingTimeInterval(0.5)
        evaluationSession = nil
        benchmarkSession = nil
        section = .calibrate
        statusMessage = "Calibration • \(DeskZone.leftTop.displayName)"
        Task {
            do {
                try await prepareGuidedAudio(to: draft.strategy)
                guard calibrationSession != nil,
                      audio.isListening,
                      audio.strategy == draft.strategy else { return }
                armCalibrationZone()
            }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func prepareRecalibration() {
        guard guidedSection == nil else { return }
        if let profile = selectedProfile {
            calibrationDraft = draft(for: profile)
        }
        section = .calibrate
    }

    func cancelCalibration() {
        calibrationArmTask?.cancel()
        calibrationSession = nil
        calibrationValidation = nil
        guidedCaptureIssue = nil
        recalibratingProfileID = nil
        statusMessage = "Calibration cancelled"
        Task {
            do { try await reconfigureListeningAudio(to: targetStrategy) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func armCalibrationZone() {
        guard var session = calibrationSession, let zone = session.currentZone else { return }
        calibrationArmTask?.cancel()
        session.isArmed = false
        session.isSettling = true
        guidedCaptureIssue = nil
        calibrationSession = session
        statusMessage = "Get ready • listening starts in one second"
        scheduleCalibrationArm(for: zone, delayNanoseconds: 1_000_000_000)
    }

    private func scheduleCalibrationArm(for zone: DeskZone, delayNanoseconds: UInt64) {
        calibrationArmTask?.cancel()
        calibrationArmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  var current = self.calibrationSession,
                  self.audio.isListening,
                  self.audio.strategy == current.draft.strategy,
                  current.currentZone == zone,
                  current.isSettling else { return }
            current.isSettling = false
            current.isArmed = true
            self.calibrationAcceptAfter = Date()
            self.calibrationSession = current
            self.statusMessage = "Calibration armed • \(zone.displayName) • tap 1 of \(current.targetPerZone)"
        }
    }

    func collectNegativeExamples(label: String?) {
        calibrationSession?.negativeLabel = label
        calibrationSession?.isArmed = label != nil
        calibrationSession?.isSettling = false
        guidedCaptureIssue = nil
        calibrationAcceptAfter = Date().addingTimeInterval(label == nil ? 0 : 0.8)
        if let label {
            statusMessage = "Rejection training • make a \(label.lowercased()) sound"
        } else {
            statusMessage = "Calibration zones complete"
        }
    }

    func clearNegativeExamples(label: String) {
        guard var session = calibrationSession else { return }
        session.negativeSamples.removeAll { $0.negativeLabel == label }
        if session.negativeLabel == label {
            session.negativeLabel = nil
            session.isArmed = false
            session.isSettling = false
        }
        guidedCaptureIssue = nil
        calibrationSession = session
        statusMessage = "Cleared \(label.lowercased()) examples"
    }

    func undoLastCalibrationTap() {
        calibrationArmTask?.cancel()
        guard var session = calibrationSession else { return }
        if session.negativeLabel != nil, !session.negativeSamples.isEmpty {
            session.negativeSamples.removeLast()
        } else if !session.positiveSamples.isEmpty {
            session.positiveSamples.removeLast()
        }
        session.isArmed = false
        session.isSettling = false
        calibrationValidation = nil
        guidedCaptureIssue = nil
        calibrationSession = session
        calibrationAcceptAfter = Date().addingTimeInterval(0.35)
        if let zone = session.currentZone {
            statusMessage = "\(zone.displayName) • tap \(session.count(for: zone) + 1) of \(session.targetPerZone)"
        }
    }

    func retryCalibrationZone(_ requestedZone: DeskZone? = nil) {
        calibrationArmTask?.cancel()
        guard var session = calibrationSession else { return }
        let zone: DeskZone?
        if let requestedZone {
            zone = requestedZone
        } else {
            let current = session.currentZone
            if let current, session.count(for: current) > 0 {
                zone = current
            } else if let current {
                zone = DeskZone.allCases.last {
                    $0.rawValue < current.rawValue && session.count(for: $0) > 0
                }
            } else {
                zone = DeskZone.allCases.last
            }
        }
        guard let zone else { return }
        session.positiveSamples.removeAll { $0.zone == zone }
        session.negativeLabel = nil
        session.isArmed = false
        session.isSettling = false
        calibrationValidation = nil
        guidedCaptureIssue = nil
        calibrationSession = session
        calibrationAcceptAfter = Date().addingTimeInterval(0.5)
        statusMessage = "Retry \(zone.displayName) • tap 1 of \(session.targetPerZone)"
    }

    func finishCalibration(openActions: Bool = false) {
        guard let session = calibrationSession, session.zonesComplete else { return }
        do {
            let classifier = try TrainedTapClassifier.train(
                positiveExamples: session.positiveSamples,
                negativeExamples: session.negativeSamples
            )
            let crossValidation = try calibrationValidation
                ?? ClassifierEvaluator.leaveOneOut(session.positiveSamples)
            let counts = DeskZone.allCases.map { session.count(for: $0) }
            let summary = CalibrationSummary(
                sampleCount: session.positiveSamples.count,
                samplesPerZone: counts,
                leaveOneOutAccuracy: crossValidation.accuracy
            )
            let oldProfile = profiles.first { $0.id == recalibratingProfileID }
            var profile = HoloProfile(
                id: oldProfile?.id ?? UUID(),
                name: session.draft.name,
                surfaceDescription: session.draft.surfaceDescription,
                laptopPositionNote: session.draft.laptopPositionNote,
                classifier: classifier,
                calibration: summary,
                zones: oldProfile?.zones ?? DeskZone.allCases.map { ZoneConfiguration(zone: $0) }
            )
            if let oldProfile { profile.createdAt = oldProfile.createdAt }
            guard let profileStore else { throw HoloStorageError.unavailable("Desk profile") }
            try profileStore.save(profile)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.insert(profile, at: 0)
            }
            selectedProfileID = profile.id
            calibrationArmTask?.cancel()
            calibrationSession = nil
            calibrationValidation = nil
            guidedCaptureIssue = nil
            recalibratingProfileID = nil
            section = openActions ? .actions : .live
            statusMessage = "Calibration saved • listening"
            Task {
                do { try await reconfigureListeningAudio(to: profile.sensingStrategy) }
                catch { errorMessage = error.localizedDescription }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginEvaluation() {
        guard selectedProfile != nil else {
            errorMessage = "Calibrate a desk profile before evaluating it."
            return
        }
        resumeFromManualPause()
        calibrationSession = nil
        benchmarkSession = nil
        calibrationArmTask?.cancel()
        benchmarkArmTask?.cancel()
        evaluationArmTask?.cancel()
        latestEvaluation = nil
        latestEvaluationIsPersisted = false
        activeZoneClearTask?.cancel()
        guidedCaptureIssue = nil
        activeZone = nil
        lastDecision = nil
        evaluationSession = EvaluationSession()
        section = .evaluate
        statusMessage = "Accuracy test ready • move to Left Top, then arm"
        Task {
            do { try await prepareGuidedAudio(to: targetStrategy) }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func armEvaluationZone() {
        guard var session = evaluationSession, let zone = session.currentZone else { return }
        evaluationArmTask?.cancel()
        session.isArmed = false
        session.isSettling = true
        evaluationSession = session
        statusMessage = "Get ready • accuracy test starts in one second"
        evaluationArmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  var current = self.evaluationSession,
                  self.audio.isListening,
                  self.audio.strategy == self.targetStrategy,
                  current.currentZone == zone,
                  current.isSettling else { return }
            current.isSettling = false
            current.isArmed = true
            self.evaluationAcceptAfter = Date()
            self.evaluationSession = current
            let count = current.records.filter { $0.expectedZone == zone }.count
            self.statusMessage = "Accuracy test armed • \(zone.displayName) • \(count + 1)/\(current.targetPerZone)"
        }
    }

    func cancelEvaluation() {
        evaluationArmTask?.cancel()
        evaluationSession = nil
        activeZone = nil
        refreshLatestEvaluation()
        statusMessage = "Accuracy test cancelled"
    }

    func beginApproachBenchmark() {
        resumeFromManualPause()
        calibrationArmTask?.cancel()
        evaluationArmTask?.cancel()
        benchmarkArmTask?.cancel()
        calibrationSession = nil
        evaluationSession = nil
        benchmarkSession = BenchmarkSession()
        guidedCaptureIssue = nil
        section = .diagnostics
        statusMessage = "Sensing comparison ready • move to Left Top, then arm"
        Task {
            do { try await prepareGuidedAudio(to: .passive) }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func armApproachBenchmarkZone() {
        guard var session = benchmarkSession,
              let strategy = session.currentStrategy,
              let zone = session.currentZone else { return }
        benchmarkArmTask?.cancel()
        session.isArmed = false
        session.isSettling = true
        guidedCaptureIssue = nil
        benchmarkSession = session
        statusMessage = "Get ready • \(strategy.displayName) • \(zone.displayName)"
        benchmarkArmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  var current = self.benchmarkSession,
                  self.audio.isListening,
                  self.audio.strategy == strategy,
                  current.currentStrategy == strategy,
                  current.currentZone == zone,
                  current.isSettling else { return }
            current.isSettling = false
            current.isArmed = true
            self.benchmarkAcceptAfter = Date()
            self.benchmarkSession = current
            self.statusMessage = "Sensing comparison armed • \(strategy.displayName) • \(zone.displayName)"
        }
    }

    func cancelApproachBenchmark() {
        benchmarkArmTask?.cancel()
        benchmarkSession = nil
        guidedCaptureIssue = nil
        statusMessage = "Sensing comparison cancelled"
        Task {
            do { try await reconfigureListeningAudio(to: targetStrategy) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func armDiagnosticCapture() {
        diagnosticCaptureArmed = true
        statusMessage = "Diagnostic armed • tap \(diagnosticLabel.displayName)"
    }

    func exportDiagnosticReport() {
        let report = DiagnosticSessionReport(
            microphone: audio.diagnostics,
            captures: diagnosticCaptures,
            approachComparison: approachComparison,
            recordingsRetained: debugRecordingEnabled
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "holo-diagnostic-\(Self.fileTimestamp()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.jsonData().write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }

    func setDebugRecordingEnabled(_ enabled: Bool) {
        guard enabled else {
            debugRecordingEnabled = false
            return
        }
        guard debugStore != nil else {
            debugRecordingEnabled = false
            errorMessage = HoloStorageError.unavailable("Debug recording").localizedDescription
            return
        }
        debugRecordingEnabled = true
    }

    func clearDebugRecordings() {
        do {
            guard let debugStore else { throw HoloStorageError.unavailable("Debug recording") }
            try debugStore.clear()
            hasDebugRecordings = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateAction(for zone: DeskZone, action: ZoneActionConfiguration) -> Bool {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }),
              let zoneIndex = profiles[profileIndex].zones.firstIndex(where: { $0.zone == zone }) else { return false }
        var updatedProfile = profiles[profileIndex]
        updatedProfile.zones[zoneIndex].action = action
        do {
            guard let profileStore else { throw HoloStorageError.unavailable("Desk profile") }
            try profileStore.save(updatedProfile)
            profiles[profileIndex] = updatedProfile
            // Ask at assignment time rather than at the moment a tap fires, so
            // the confirmation lands while the user is looking at the action
            // they just chose.
            if ActionAuthorization.isPrivileged(action.kind),
               !privilegedConsent.isGranted(profileID: updatedProfile.id, kind: action.kind) {
                requestPrivilegedConfirmation(
                    profileID: updatedProfile.id,
                    zone: zone,
                    kind: action.kind
                )
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func testAction(_ action: ZoneActionConfiguration) {
        do { try actionDispatcher.perform(action) }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteSelectedProfile() {
        guard let profile = selectedProfile else { return }
        do {
            guard let profileStore else { throw HoloStorageError.unavailable("Desk profile") }
            try profileStore.delete(profile)
            profiles.removeAll { $0.id == profile.id }
            // A future profile could reuse this UUID; it must not inherit the
            // deleted profile's confirmations.
            privilegedConsent.revokeAll(profileID: profile.id)
            persistPrivilegedConsent()
            selectedProfileID = profiles.first?.id
            refreshLatestEvaluation()
            if let nextProfile = selectedProfile {
                calibrationDraft = draft(for: nextProfile)
            }
            statusMessage = profiles.isEmpty ? "Calibration needed" : "Profile deleted"
            Task {
                do { try await reconfigureListeningAudio(to: targetStrategy) }
                catch { errorMessage = error.localizedDescription }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handle(_ observation: TapObservation) {
        // Defense in depth. Capture is already stopped when the session locks,
        // so reaching here with a non-Armed tier means an observation was in
        // flight across the transition. It is dropped whole: not recorded, not
        // classified, not counted toward a guided session.
        guard listeningTier == .armed, !power.conditions.isScreenLocked else { return }

        if debugRecordingEnabled {
            let label = currentCaptureLabel
            do {
                guard let debugStore else { throw HoloStorageError.unavailable("Debug recording") }
                try debugStore.save(
                   observation,
                   label: label,
                   sampleRate: audio.diagnostics.sampleRate
                )
                hasDebugRecordings = true
            } catch {
                debugRecordingEnabled = false
                errorMessage = "Debug recording stopped because the WAV could not be saved. \(error.localizedDescription)"
            }
        }

        if var benchmark = benchmarkSession {
            handleBenchmark(observation, session: &benchmark)
            benchmarkSession = benchmark.currentStrategy == nil ? nil : benchmark
            return
        }

        if var calibration = calibrationSession {
            handleCalibration(observation, session: &calibration)
            calibrationSession = calibration
            return
        }

        if var evaluation = evaluationSession, let profile = selectedProfile, let expected = evaluation.currentZone {
            guard evaluation.isArmed, Date() >= evaluationAcceptAfter else { return }
            var decision = profile.classifier.predict(observation.feature)
            decision.processingLatencyMilliseconds = observation.processingLatencyMilliseconds
            evaluation.records.append(EvaluationRecord(
                expectedZone: expected,
                decision: decision,
                responseLatencyMilliseconds: responseLatencyMilliseconds(for: observation),
                capturedAt: observation.feature.capturedAt,
                feature: observation.feature
            ))
            present(decision)
            evaluationAcceptAfter = Date().addingTimeInterval(0.40)
            let completedExpectedZone = evaluation.records.filter { $0.expectedZone == expected }.count == evaluation.targetPerZone
            if completedExpectedZone {
                evaluation.isArmed = false
                evaluation.isSettling = false
                activeZone = nil
            }
            evaluationSession = evaluation
            if let next = evaluation.currentZone {
                statusMessage = completedExpectedZone
                    ? "Zone complete • move to \(next.displayName), then arm"
                    : "Accuracy test • \(next.displayName) • \(evaluation.records.filter { $0.expectedZone == next }.count + 1)/\(evaluation.targetPerZone)"
            } else {
                finishEvaluation(evaluation)
            }
            return
        }

        if section == .diagnostics {
            if diagnosticCaptureArmed {
                let capture = DiagnosticCaptureRecord(
                    label: diagnosticLabel.displayName,
                    zone: diagnosticLabel.zone,
                    feature: observation.feature,
                    responseLatencyMilliseconds: responseLatencyMilliseconds(for: observation)
                )
                diagnosticCaptures.append(capture)
                diagnosticCaptureArmed = false
                statusMessage = "Diagnostic captured • \(observation.feature.quality.summary)"
            }
            return
        }

        guard let profile = selectedProfile else {
            statusMessage = "Tap detected • calibrate to identify its zone"
            return
        }
        var decision = profile.classifier.predict(observation.feature)
        decision.processingLatencyMilliseconds = observation.processingLatencyMilliseconds
        present(decision)
        guard let zone = decision.zone else {
            statusMessage = "Rejected • \(decision.rejectionReason?.displayName ?? "low confidence")"
            return
        }

        // An accepted tap is the clearest possible signal that the user is at
        // the desk, so it restarts the idle countdown even if the action is
        // then denied.
        tierMachine.noteAcceptedTap(at: monotonicNow)

        let action = profile.action(for: zone)
        let now = monotonicNow
        let dispatch = LocalActionDispatchPolicy.decide(
            for: decision,
            actionKind: action.kind,
            tier: listeningTier,
            isSessionUnlocked: !power.conditions.isScreenLocked,
            isDeskActive: section == .live,
            hasPrivilegedConfirmation: privilegedConsent.isGranted(profileID: profile.id, kind: action.kind),
            privilegedRateLimitAllows: privilegedRateLimiter.allows(at: now)
        )

        switch dispatch {
        case .allow:
            statusMessage = "\(zone.displayName) • \(Int(decision.confidence * 100))% confidence"
            do {
                try actionDispatcher.perform(action)
                if ActionAuthorization.isPrivileged(action.kind) {
                    privilegedRateLimiter.noteDispatch(at: now)
                }
            } catch {
                statusMessage = "\(zone.displayName) accepted • action failed"
                errorMessage = error.localizedDescription
            }
        case .deny(.awaitingConfirmation(let kind)):
            statusMessage = "\(zone.displayName) • confirmation needed"
            requestPrivilegedConfirmation(profileID: profile.id, zone: zone, kind: kind)
        case .deny(.deskInactive):
            statusMessage = "\(zone.displayName) detected • actions paused outside Desk"
        case .deny(let reason):
            statusMessage = "\(zone.displayName) detected • \(reason.explanation)"
        }
    }

    // MARK: - Privileged action confirmation

    private func requestPrivilegedConfirmation(profileID: UUID, zone: DeskZone, kind: ZoneActionKind) {
        guard pendingPrivilegedConfirmation == nil else { return }
        pendingPrivilegedConfirmation = PendingPrivilegedConfirmation(
            profileID: profileID,
            zone: zone,
            kind: kind
        )
    }

    func confirmPendingPrivilegedAction() {
        guard let pending = pendingPrivilegedConfirmation else { return }
        pendingPrivilegedConfirmation = nil
        privilegedConsent.grant(profileID: pending.profileID, kind: pending.kind)
        persistPrivilegedConsent()
    }

    func declinePendingPrivilegedAction() {
        pendingPrivilegedConfirmation = nil
    }

    private func persistPrivilegedConsent() {
        do {
            guard let consentStore else { throw HoloStorageError.unavailable("Action confirmations") }
            try consentStore.save(privilegedConsent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleCalibration(_ observation: TapObservation, session: inout CalibrationSession) {
        guard session.isArmed else { return }
        guard Date() >= calibrationAcceptAfter else { return }
        guard observation.feature.strategy == session.draft.strategy else { return }
        let quality = observation.feature.quality

        if let zone = session.currentZone {
            if let issue = GuidedCaptureQuality.issue(for: quality) {
                guidedCaptureIssue = issue
                statusMessage = issue.guidance
                return
            }
            guidedCaptureIssue = nil
            session.positiveSamples.append(LabeledTap(zone: zone, feature: observation.feature))
            let count = session.count(for: zone)
            calibrationAcceptAfter = Date().addingTimeInterval(0.40)
            if let next = session.currentZone {
                if count == session.targetPerZone {
                    session.isArmed = false
                    session.isSettling = true
                    statusMessage = "Zone saved • move to \(next.displayName) • listening starts automatically"
                    scheduleCalibrationArm(for: next, delayNanoseconds: 2_000_000_000)
                } else {
                    statusMessage = "\(zone.displayName) • tap \(count + 1) of \(session.targetPerZone)"
                }
            } else {
                session.isArmed = false
                session.isSettling = false
                do {
                    calibrationValidation = try ClassifierEvaluator.leaveOneOut(session.positiveSamples)
                    statusMessage = "All four zones captured • save or add rejection examples"
                } catch {
                    calibrationValidation = nil
                    statusMessage = "Calibration review unavailable"
                    errorMessage = "Holo could not review calibration consistency. \(error.localizedDescription)"
                }
            }
        } else if let label = session.negativeLabel {
            // Rejection examples are intentionally not required to resemble a
            // clean tap. Their job is to represent talking, typing, laptop
            // touches, and other sounds that should never run an action.
            guidedCaptureIssue = nil
            session.negativeSamples.append(LabeledTap(zone: nil, negativeLabel: label, feature: observation.feature))
            statusMessage = "\(label) examples • \(session.negativeCount(for: label)) captured"
        }
    }

    private func handleBenchmark(_ observation: TapObservation, session: inout BenchmarkSession) {
        guard session.isArmed,
              Date() >= benchmarkAcceptAfter,
              let strategy = session.currentStrategy,
              let zone = session.currentZone,
              observation.feature.strategy == strategy else { return }
        let quality = observation.feature.quality
        if let issue = GuidedCaptureQuality.issue(for: quality) {
            guidedCaptureIssue = issue
            statusMessage = "Sensing comparison • \(issue.guidance)"
            return
        }
        guidedCaptureIssue = nil
        let oldStrategy = strategy
        session.samples.append(BenchmarkSample(
            labeledTap: LabeledTap(zone: zone, feature: observation.feature),
            processingLatencyMilliseconds: observation.processingLatencyMilliseconds
        ))
        benchmarkAcceptAfter = Date().addingTimeInterval(0.40)

        guard let nextStrategy = session.currentStrategy, let nextZone = session.currentZone else {
            do {
                let comparison = try ApproachComparison.measure(
                    session.samples,
                    profileID: selectedProfile?.id
                )
                approachComparison = comparison
                guard let comparisonStore else { throw HoloStorageError.unavailable("Sensing comparison") }
                try comparisonStore.save(comparison)
                calibrationDraft.strategy = comparison.selectedStrategy
                benchmarkSession = nil
                statusMessage = "Comparison selected • \(comparison.selectedStrategy.displayName)"
                let resumeStrategy = selectedProfile?.sensingStrategy ?? comparison.selectedStrategy
                Task {
                    do { try await reconfigureListeningAudio(to: resumeStrategy) }
                    catch { errorMessage = error.localizedDescription }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        let completedZone = session.count(strategy: strategy, zone: zone) == session.targetPerZone
        if completedZone {
            session.isArmed = false
            session.isSettling = false
            statusMessage = "Set saved • move to \(nextZone.displayName), then arm \(nextStrategy.displayName)"
        } else {
            let nextTap = session.count(strategy: strategy, zone: zone) + 1
            statusMessage = "Sensing comparison • \(strategy.displayName) • \(zone.displayName) • \(nextTap)/\(session.targetPerZone)"
        }
        if nextStrategy != oldStrategy {
            Task {
                do { try await reconfigureListeningAudio(to: nextStrategy) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func finishEvaluation(_ session: EvaluationSession) {
        guard let profile = selectedProfile else { return }
        let report = EvaluationReport(
            profileID: profile.id,
            profileName: profile.name,
            strategy: profile.sensingStrategy,
            startedAt: session.startedAt,
            records: session.records,
            notes: "Guided held-out session; \(EvaluationAcceptance.tapsPerZone) taps per zone."
        )
        latestEvaluation = report
        latestEvaluationIsPersisted = false
        evaluationSession = nil
        do {
            guard let evaluationStore else { throw HoloStorageError.unavailable("Evaluation report") }
            try evaluationStore.save(report)
            evaluationHistory.removeAll {
                $0.profileID == report.profileID && $0.completedAt == report.completedAt
            }
            evaluationHistory.append(report)
            evaluationHistory.sort { $0.completedAt > $1.completedAt }
            latestEvaluationIsPersisted = true
            statusMessage = report.meetsAccuracyAndLatencyTargets
                ? "Accuracy test passed"
                : "Accuracy test complete • review results"
        } catch {
            statusMessage = "Accuracy test complete • report not saved"
            errorMessage = "The accuracy test completed, but its JSON/CSV report was not saved. \(error.localizedDescription)"
        }
    }

    private var currentCaptureLabel: String {
        if let session = calibrationSession {
            if let zone = session.currentZone { return "calibration-\(zone.shortName)" }
            if let label = session.negativeLabel { return "negative-\(label)" }
        }
        if let session = evaluationSession, let zone = session.currentZone { return "evaluation-\(zone.shortName)" }
        if let session = benchmarkSession, let strategy = session.currentStrategy, let zone = session.currentZone {
            return "benchmark-\(strategy.rawValue)-\(zone.shortName)"
        }
        return diagnosticLabel.displayName
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func responseLatencyMilliseconds(for observation: TapObservation) -> Double {
        AudioTimeline.elapsedMilliseconds(
            since: observation.eventHostTimeSeconds,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func refreshLatestEvaluation() {
        latestEvaluation = EvaluationHistory.latest(
            for: selectedProfile?.id,
            in: evaluationHistory
        )
        latestEvaluationIsPersisted = latestEvaluation != nil
    }

    private func disarmAllCaptureIntents() {
        calibrationArmTask?.cancel()
        evaluationArmTask?.cancel()
        benchmarkArmTask?.cancel()
        calibrationSession?.isArmed = false
        calibrationSession?.isSettling = false
        calibrationSession?.negativeLabel = nil
        evaluationSession?.isArmed = false
        evaluationSession?.isSettling = false
        benchmarkSession?.isArmed = false
        benchmarkSession?.isSettling = false
        diagnosticCaptureArmed = false
        guidedCaptureIssue = nil
    }

    private func present(_ decision: ClassificationDecision) {
        activeZoneClearTask?.cancel()
        lastDecision = decision
        activeZone = decision.zone
        guard let zone = decision.zone else { return }
        activeZoneClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.activeZone == zone else { return }
            self.activeZone = nil
        }
    }

    private func reconfigureListeningAudio(to strategy: SensingStrategy) async throws {
        guard audio.isListening else { return }
        try await audio.apply(tier: listeningTier, strategy: strategy)
        power.setEngineRunning(audio.isListening)
    }

    /// Guided capture always wants Armed: calibration and accuracy tests need
    /// the full pipeline, and the user is demonstrably at the machine. A system
    /// pause (locked, in a call, out of battery) still wins.
    private func prepareGuidedAudio(to strategy: SensingStrategy) async throws {
        tierMachine.noteWake(at: monotonicNow)
        let decision = tierMachine.evaluate(power.conditions, at: monotonicNow)
        publish(decision)
        guard decision.tier != .paused else {
            statusMessage = decision.statusText
            return
        }
        try await audio.apply(tier: .armed, strategy: strategy)
        power.setEngineRunning(audio.isListening)
    }

    private func draft(for profile: HoloProfile) -> CalibrationDraft {
        CalibrationDraft(
            name: profile.name,
            surfaceDescription: profile.surfaceDescription,
            laptopPositionNote: profile.laptopPositionNote,
            strategy: applicableApproachComparison?.selectedStrategy ?? profile.sensingStrategy
        )
    }
}
