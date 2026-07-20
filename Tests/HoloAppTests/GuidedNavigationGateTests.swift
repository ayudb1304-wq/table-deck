import XCTest

final class GuidedNavigationGateTests: XCTestCase {
    func testNoActiveSessionAllowsAllNavigation() {
        XCTAssertNil(GuidedNavigationGate.guidedSection(
            calibrationActive: false,
            evaluationActive: false,
            benchmarkActive: false
        ))
        for section in AppSection.allCases {
            XCTAssertTrue(GuidedNavigationGate.canNavigate(to: section, guidedSection: nil))
        }
    }

    func testActiveSessionsMapToTheirSections() {
        XCTAssertEqual(
            GuidedNavigationGate.guidedSection(
                calibrationActive: true, evaluationActive: false, benchmarkActive: false
            ),
            .calibrate
        )
        XCTAssertEqual(
            GuidedNavigationGate.guidedSection(
                calibrationActive: false, evaluationActive: true, benchmarkActive: false
            ),
            .evaluate
        )
        XCTAssertEqual(
            GuidedNavigationGate.guidedSection(
                calibrationActive: false, evaluationActive: false, benchmarkActive: true
            ),
            .diagnostics
        )
    }

    func testCalibrationTakesPrecedenceOverOtherActiveSessions() {
        XCTAssertEqual(
            GuidedNavigationGate.guidedSection(
                calibrationActive: true, evaluationActive: true, benchmarkActive: true
            ),
            .calibrate
        )
        XCTAssertEqual(
            GuidedNavigationGate.guidedSection(
                calibrationActive: false, evaluationActive: true, benchmarkActive: true
            ),
            .evaluate
        )
    }

    func testGuidedSessionOnlyAllowsItsOwnSection() {
        for section in AppSection.allCases {
            XCTAssertEqual(
                GuidedNavigationGate.canNavigate(to: section, guidedSection: .calibrate),
                section == .calibrate
            )
        }
    }
}
