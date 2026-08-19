import XCTest
@testable import HoloCore

final class ActiveProbeDutyCycleTests: XCTestCase {
    func testHybridEmitsNothingWithoutAnOnsetCandidate() {
        XCTAssertEqual(
            ActiveProbeDutyCycle.steadyState(strategy: .hybrid, tier: .armed),
            .silent,
            "Hybrid must not chirp continuously"
        )
    }

    func testHybridEmitsOneConfirmationChirpPerOnsetCandidate() {
        var duty = ActiveProbeDutyCycle()
        XCTAssertEqual(duty.onOnsetCandidate(strategy: .hybrid, tier: .armed, at: 1.0), .confirmation)
    }

    func testHybridDoesNotStackChirpsInsideTheConfirmationWindow() {
        var duty = ActiveProbeDutyCycle()
        XCTAssertEqual(duty.onOnsetCandidate(strategy: .hybrid, tier: .armed, at: 1.0), .confirmation)
        XCTAssertEqual(duty.onOnsetCandidate(strategy: .hybrid, tier: .armed, at: 1.05), .silent)
        XCTAssertEqual(duty.onOnsetCandidate(strategy: .hybrid, tier: .armed, at: 1.20), .confirmation)
    }

    func testActiveKeepsItsContinuousLoopWhileArmed() {
        XCTAssertEqual(ActiveProbeDutyCycle.steadyState(strategy: .active, tier: .armed), .continuous)
    }

    func testTheProbeIsSilentInDozeAndPaused() {
        for strategy in SensingStrategy.allCases {
            for tier in [ListeningTier.doze, .paused] {
                XCTAssertEqual(
                    ActiveProbeDutyCycle.steadyState(strategy: strategy, tier: tier),
                    .silent,
                    "\(strategy) must be silent while \(tier)"
                )
            }
        }
    }

    func testDozeSwallowsOnsetDrivenChirpsToo() {
        var duty = ActiveProbeDutyCycle()
        XCTAssertEqual(duty.onOnsetCandidate(strategy: .hybrid, tier: .doze, at: 1.0), .silent)
    }

    func testPassiveNeverChirps() {
        var duty = ActiveProbeDutyCycle()
        XCTAssertEqual(ActiveProbeDutyCycle.steadyState(strategy: .passive, tier: .armed), .silent)
        XCTAssertEqual(duty.onOnsetCandidate(strategy: .passive, tier: .armed, at: 1.0), .silent)
    }
}
