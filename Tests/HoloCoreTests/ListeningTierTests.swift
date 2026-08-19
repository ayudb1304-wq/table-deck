import XCTest
@testable import HoloCore

final class ListeningTierTests: XCTestCase {
    private func makeMachine(
        timeout: TimeInterval = 180,
        battery: Double? = nil
    ) -> ListeningTierMachine {
        ListeningTierMachine(
            settings: ListeningTierSettings(
                idleDozeTimeout: timeout,
                wakeGestureEnabled: true,
                batteryPauseFraction: battery
            ),
            startedAt: 0
        )
    }

    func testStaysArmedUntilTheIdleTimeoutElapses() {
        var machine = makeMachine(timeout: 180)
        let quiet = ListeningConditions()

        XCTAssertEqual(machine.evaluate(quiet, at: 10).tier, .armed)
        XCTAssertEqual(machine.evaluate(quiet, at: 179.9).tier, .armed)
        XCTAssertEqual(machine.evaluate(quiet, at: 180).tier, .doze)
    }

    func testAnAcceptedTapRestartsTheIdleCountdown() {
        var machine = makeMachine(timeout: 60)
        let quiet = ListeningConditions()

        XCTAssertEqual(machine.evaluate(quiet, at: 59).tier, .armed)
        machine.noteAcceptedTap(at: 59)
        XCTAssertEqual(machine.evaluate(quiet, at: 118).tier, .armed)
        XCTAssertEqual(machine.evaluate(quiet, at: 119).tier, .doze)
    }

    func testAWakeGestureLiftsDoze() {
        var machine = makeMachine(timeout: 60)
        let quiet = ListeningConditions()

        XCTAssertEqual(machine.evaluate(quiet, at: 61).tier, .doze)
        machine.noteWake(at: 61)
        XCTAssertEqual(machine.evaluate(quiet, at: 61).tier, .armed)
    }

    func testScreenLockPausesAndUnlockReturnsToArmed() {
        var machine = makeMachine(timeout: 60)
        var conditions = ListeningConditions()

        // Long enough that an unlock landing in Doze would be the naive result.
        XCTAssertEqual(machine.evaluate(conditions, at: 61).tier, .doze)

        conditions.isScreenLocked = true
        let locked = machine.evaluate(conditions, at: 62)
        XCTAssertEqual(locked.tier, .paused)
        XCTAssertEqual(locked.primaryPauseReason, .screenLocked)
        XCTAssertFalse(locked.tier.allowsActions)

        conditions.isScreenLocked = false
        let unlocked = machine.evaluate(conditions, at: 900)
        XCTAssertEqual(unlocked.tier, .armed, "Coming back from a pause must start a fresh countdown")
        XCTAssertTrue(unlocked.pauseReasons.isEmpty)
    }

    func testMicrophoneContentionPausesAndClearingReturnsToListening() {
        var machine = makeMachine(timeout: 600)
        var conditions = ListeningConditions()
        XCTAssertEqual(machine.evaluate(conditions, at: 1).tier, .armed)

        conditions.isMicrophoneBusyElsewhere = true
        let inCall = machine.evaluate(conditions, at: 2)
        XCTAssertEqual(inCall.tier, .paused)
        XCTAssertEqual(inCall.primaryPauseReason, .microphoneInUse)

        conditions.isMicrophoneBusyElsewhere = false
        XCTAssertEqual(machine.evaluate(conditions, at: 3).tier, .armed)
    }

    func testThermalPressurePausesOnlyAtSeriousOrWorse() {
        var machine = makeMachine()
        var conditions = ListeningConditions()

        conditions.thermalPressure = .fair
        XCTAssertEqual(machine.evaluate(conditions, at: 1).tier, .armed)

        conditions.thermalPressure = .serious
        XCTAssertEqual(machine.evaluate(conditions, at: 2).primaryPauseReason, .thermalPressure)

        conditions.thermalPressure = .critical
        XCTAssertEqual(machine.evaluate(conditions, at: 3).primaryPauseReason, .thermalPressure)
    }

    func testLowPowerModePauses() {
        var machine = makeMachine()
        var conditions = ListeningConditions()
        conditions.isLowPowerModeEnabled = true
        XCTAssertEqual(machine.evaluate(conditions, at: 1).primaryPauseReason, .lowPowerMode)
    }

    func testBatteryThresholdIsOffByDefaultAndOnlyAppliesOnBattery() {
        var withoutThreshold = makeMachine(battery: nil)
        var conditions = ListeningConditions(batteryFraction: 0.05, isRunningOnBattery: true)
        XCTAssertEqual(withoutThreshold.evaluate(conditions, at: 1).tier, .armed)

        var withThreshold = makeMachine(battery: 0.20)
        XCTAssertEqual(withThreshold.evaluate(conditions, at: 1).primaryPauseReason, .lowBattery)

        conditions.isRunningOnBattery = false
        XCTAssertEqual(withThreshold.evaluate(conditions, at: 2).tier, .armed, "Plugged in is never a low-battery pause")

        conditions.isRunningOnBattery = true
        conditions.batteryFraction = 0.5
        XCTAssertEqual(withThreshold.evaluate(conditions, at: 3).tier, .armed)
    }

    func testManualPauseOutranksEveryOtherReason() {
        var machine = makeMachine()
        let conditions = ListeningConditions(
            manuallyPaused: true,
            isScreenLocked: true,
            isLowPowerModeEnabled: true
        )
        let decision = machine.evaluate(conditions, at: 1)
        XCTAssertEqual(decision.primaryPauseReason, .manual)
        XCTAssertEqual(decision.pauseReasons.count, 3)
        XCTAssertEqual(decision.statusText, "Paused (manual)")
    }

    func testStatusTextPerTier() {
        XCTAssertEqual(ListeningTierDecision(tier: .armed).statusText, "Listening")
        XCTAssertEqual(
            ListeningTierDecision(tier: .doze).statusText,
            "Dozing, measuring loudness only"
        )
        XCTAssertEqual(
            ListeningTierDecision(tier: .paused, pauseReasons: [.microphoneInUse]).statusText,
            "Paused (call)"
        )
    }

    func testSettingsAreClampedIntoTheSupportedRange() {
        let tooShort = ListeningTierSettings(idleDozeTimeout: 1).sanitized()
        XCTAssertEqual(tooShort.idleDozeTimeout, ListeningTierSettings.minimumIdleDozeTimeout)

        let tooLong = ListeningTierSettings(idleDozeTimeout: 99_999).sanitized()
        XCTAssertEqual(tooLong.idleDozeTimeout, ListeningTierSettings.maximumIdleDozeTimeout)

        let notANumber = ListeningTierSettings(idleDozeTimeout: .nan).sanitized()
        XCTAssertEqual(notANumber.idleDozeTimeout, ListeningTierSettings.defaultIdleDozeTimeout)

        let absurdBattery = ListeningTierSettings(batteryPauseFraction: 4).sanitized()
        XCTAssertEqual(absurdBattery.batteryPauseFraction, 0.90)
    }

    func testSecondsUntilDozeOnlyAppliesWhileArmed() {
        var machine = makeMachine(timeout: 100)
        _ = machine.evaluate(ListeningConditions(), at: 40)
        XCTAssertEqual(machine.secondsUntilDoze(at: 40) ?? -1, 60, accuracy: 0.001)

        _ = machine.evaluate(ListeningConditions(), at: 200)
        XCTAssertNil(machine.secondsUntilDoze(at: 200))
    }
}
