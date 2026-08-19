import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import HoloCore
import IOKit.ps

/// Samples every system condition the listening tier depends on and publishes
/// them as one value.
///
/// Nothing here decides anything. `ListeningTierMachine` in HoloCore owns the
/// policy; this type only reports what the machine is currently like. That split
/// is what lets the tier rules be unit tested without a running Mac.
@MainActor
final class PowerStateObserver: ObservableObject {
    @Published private(set) var conditions = ListeningConditions()

    /// Fires after any condition changes, including the first sample.
    var onChange: ((ListeningConditions) -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultCenterObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var slowPollTimer: Timer?
    private let slowPollInterval: TimeInterval
    private var isEngineRunning = false

    init(slowPollInterval: TimeInterval = 60) {
        self.slowPollInterval = slowPollInterval
    }

    func start() {
        guard workspaceObservers.isEmpty, distributedObservers.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        let sleepNotifications: [(Notification.Name, Bool)] = [
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false)
        ]
        for (name, asleep) in sleepNotifications {
            workspaceObservers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.update { $0.isSystemAsleep = asleep }
                }
            })
        }

        let distributed = DistributedNotificationCenter.default()
        let lockNotifications: [(String, Bool)] = [
            ("com.apple.screenIsLocked", true),
            ("com.apple.screenIsUnlocked", false)
        ]
        for (name, locked) in lockNotifications {
            distributedObservers.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.update { $0.isScreenLocked = locked }
                }
            })
        }

        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            defaultCenterObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sampleProcessInfo()
                }
            })
        }

        // Battery level and microphone contention have no notification worth
        // subscribing to, so they ride a deliberately slow timer. Spec 01 asks
        // for 60 s; noticing a low battery a minute late costs nothing.
        let timer = Timer.scheduledTimer(withTimeInterval: slowPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.samplePolled() }
        }
        timer.tolerance = slowPollInterval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        slowPollTimer = timer

        sampleAll()
    }

    func stop() {
        slowPollTimer?.invalidate()
        slowPollTimer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in defaultCenterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        workspaceObservers.removeAll()
        defaultCenterObservers.removeAll()
        distributedObservers.removeAll()
    }

    /// The capture service tells us whether it currently holds the input device.
    /// Without this we cannot read anything useful out of the Core Audio
    /// "running somewhere" flag, because we are one of the somewheres.
    func setEngineRunning(_ running: Bool) {
        guard isEngineRunning != running else { return }
        isEngineRunning = running
        samplePolled()
    }

    func setManuallyPaused(_ paused: Bool) {
        update { $0.manuallyPaused = paused }
    }

    // MARK: - Sampling

    func sampleAll() {
        update {
            if let locked = Self.readScreenLocked() { $0.isScreenLocked = locked }
            $0.thermalPressure = Self.thermalPressure(ProcessInfo.processInfo.thermalState)
            $0.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            Self.applyPowerSource(to: &$0)
            $0.isMicrophoneBusyElsewhere = self.microphoneBusyElsewhere()
        }
    }

    private func sampleProcessInfo() {
        update {
            $0.thermalPressure = Self.thermalPressure(ProcessInfo.processInfo.thermalState)
            $0.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func samplePolled() {
        update {
            Self.applyPowerSource(to: &$0)
            $0.isMicrophoneBusyElsewhere = self.microphoneBusyElsewhere()
        }
    }

    private func update(_ mutate: (inout ListeningConditions) -> Void) {
        var next = conditions
        mutate(&next)
        apply(next)
    }

    /// Test seam: injecting conditions exercises the same publish path the
    /// system notifications use.
    func apply(_ next: ListeningConditions) {
        guard next != conditions else { return }
        conditions = next
        onChange?(next)
    }

    static func thermalPressure(_ state: ProcessInfo.ThermalState) -> ThermalPressure {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    private static func readScreenLocked() -> Bool? {
        guard let raw = CGSessionCopyCurrentDictionary(),
              let session = (raw as NSDictionary) as? [String: Any] else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool
    }

    private static func applyPowerSource(to conditions: inout ListeningConditions) {
        conditions.batteryFraction = nil
        conditions.isRunningOnBattery = false

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }

        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue(),
                  let description = (raw as NSDictionary) as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                conditions.batteryFraction = min(max(Double(current) / Double(maximum), 0), 1)
            }
            conditions.isRunningOnBattery =
                (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return
        }
    }

    /// Best-effort microphone contention.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` cannot separate our own
    /// engine from anyone else's, so it is only meaningful while our engine is
    /// stopped. That is exactly the case that matters for resuming: once the
    /// call ends the flag drops and the tier machine lifts the pause. A call
    /// that starts while Holo is armed still surfaces through the existing
    /// `AVAudioEngineConfigurationChange` route check.
    private func microphoneBusyElsewhere() -> Bool {
        guard !isEngineRunning else { return conditions.isMicrophoneBusyElsewhere }
        guard let deviceID = SystemAudioRouteInspector.defaultInputDeviceID() else { return false }
        return SystemAudioRouteInspector.deviceIsRunningSomewhere(deviceID)
    }
}
