import HoloCore
import XCTest

final class SensingStrategyResolverTests: XCTestCase {
    func testBenchmarkStrategyWinsOverEverything() {
        XCTAssertEqual(
            SensingStrategyResolver.resolve(
                benchmark: .active, calibration: .hybrid, profile: .passive, comparison: .hybrid
            ),
            .active
        )
    }

    func testCalibrationDraftWinsOverProfileAndComparison() {
        XCTAssertEqual(
            SensingStrategyResolver.resolve(
                benchmark: nil, calibration: .hybrid, profile: .passive, comparison: .active
            ),
            .hybrid
        )
    }

    func testProfileWinsOverComparison() {
        XCTAssertEqual(
            SensingStrategyResolver.resolve(
                benchmark: nil, calibration: nil, profile: .hybrid, comparison: .active
            ),
            .hybrid
        )
    }

    func testComparisonAppliesWhenNothingElseIsSet() {
        XCTAssertEqual(
            SensingStrategyResolver.resolve(
                benchmark: nil, calibration: nil, profile: nil, comparison: .active
            ),
            .active
        )
    }

    func testDefaultsToPassive() {
        XCTAssertEqual(
            SensingStrategyResolver.resolve(
                benchmark: nil, calibration: nil, profile: nil, comparison: nil
            ),
            .passive
        )
    }
}
