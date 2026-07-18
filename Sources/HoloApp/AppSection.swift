import Foundation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case live
    case calibrate
    case actions
    case evaluate
    case diagnostics

    static let primary: [AppSection] = [.live, .calibrate, .actions, .evaluate]
    static let advanced: [AppSection] = [.diagnostics]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Desk"
        case .calibrate: return "Calibration"
        case .diagnostics: return "Diagnostics"
        case .evaluate: return "Accuracy Test"
        case .actions: return "Actions"
        }
    }

    var symbol: String {
        switch self {
        case .live: return "rectangle.split.2x1.fill"
        case .calibrate: return "scope"
        case .diagnostics: return "waveform.path.ecg"
        case .evaluate: return "checkmark.seal"
        case .actions: return "slider.horizontal.3"
        }
    }
}
