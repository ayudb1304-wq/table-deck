import Foundation

/// Sidebar gating for guided captures: while a calibration, accuracy test, or
/// approach benchmark is running, only that session's section is reachable.
enum GuidedNavigationGate {
    static func guidedSection(
        calibrationActive: Bool,
        evaluationActive: Bool,
        benchmarkActive: Bool
    ) -> AppSection? {
        if calibrationActive { return .calibrate }
        if evaluationActive { return .evaluate }
        if benchmarkActive { return .diagnostics }
        return nil
    }

    static func canNavigate(to candidate: AppSection, guidedSection: AppSection?) -> Bool {
        guidedSection == nil || guidedSection == candidate
    }
}
