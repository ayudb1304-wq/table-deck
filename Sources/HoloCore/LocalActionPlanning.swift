import Foundation

public enum LocalActionCommand: Equatable, Sendable {
    case playSound(name: String)
    case copyText(String)
    case speakText(String)
    case openURL(URL)
    case runShortcut(URL)
    case openApplication(bookmarkData: Data)
    case openItem(bookmarkData: Data)
    case runShellCommand(String)
    case takeScreenshot(interactive: Bool)
}

public enum LocalActionPlanner {
    /// Converts a saved zone action into a validated side-effect command. `nil`
    /// means visual feedback only or an action that is not fully configured.
    public static func command(for action: ZoneActionConfiguration) -> LocalActionCommand? {
        switch action.kind {
        case .none:
            return nil

        case .sound:
            let name = action.soundName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .playSound(name: name)

        case .copyText:
            return hasContent(action.text) ? .copyText(action.text) : nil

        case .speakText:
            return hasContent(action.text) ? .speakText(action.text) : nil

        case .openURL:
            var candidate = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return nil }
            if !candidate.contains("://") { candidate = "https://" + candidate }
            guard let url = URL(string: candidate),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false else { return nil }
            return .openURL(url)

        case .runShortcut:
            let name = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            return components.url.map(LocalActionCommand.runShortcut)

        case .openApplication:
            guard let bookmarkData = action.bookmarkData, !bookmarkData.isEmpty else { return nil }
            return .openApplication(bookmarkData: bookmarkData)

        case .openItem:
            guard let bookmarkData = action.bookmarkData, !bookmarkData.isEmpty else { return nil }
            return .openItem(bookmarkData: bookmarkData)

        case .runShellCommand:
            let command = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, !command.contains("\0") else { return nil }
            return .runShellCommand(command)

        case .screenshotClipboard:
            return .takeScreenshot(interactive: false)

        case .screenshotSelection:
            return .takeScreenshot(interactive: true)
        }
    }

    private static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Why an accepted classification did not run its action.
public enum LocalActionDenial: Equatable, Sendable {
    case sessionLocked
    case notArmed(ListeningTier)
    case deskInactive
    case notAccepted
    case awaitingConfirmation(ZoneActionKind)
    case rateLimited

    public var explanation: String {
        switch self {
        case .sessionLocked:
            return "Actions never run while the screen is locked."
        case .notArmed(let tier):
            return "Actions only run while listening (currently \(tier.displayName.lowercased()))."
        case .deskInactive:
            return "Actions are paused outside Desk."
        case .notAccepted:
            return "The tap was not accepted."
        case .awaitingConfirmation:
            return "Confirm this action once before it can run from a tap."
        case .rateLimited:
            return "This action ran a moment ago."
        }
    }
}

public enum LocalActionDispatchDecision: Equatable, Sendable {
    case allow
    case deny(LocalActionDenial)

    public var isAllowed: Bool { self == .allow }

    public var denial: LocalActionDenial? {
        if case .deny(let reason) = self { return reason }
        return nil
    }
}

public enum LocalActionDispatchPolicy {
    /// Automatic side effects are confined to the live Desk surface. Guided
    /// capture and configuration screens can still classify for feedback, but
    /// only an accepted Desk decision may run an assigned action.
    public static func allowsAutomaticDispatch(
        for decision: ClassificationDecision,
        isDeskActive: Bool
    ) -> Bool {
        isDeskActive && decision.wasAccepted
    }

    /// Full gate, spec 01. Checked in this order so the reported denial is the
    /// most fundamental one: a locked session is never reported as "rate
    /// limited", and a dozing engine is never reported as "not accepted".
    ///
    /// The session-lock and tier checks are a hard constraint, not a
    /// convenience. They are duplicated in `AppModel` on purpose (defense in
    /// depth): capture is already stopped when the session locks, so this gate
    /// is the backstop for an observation that was in flight at the moment the
    /// screen locked.
    public static func decide(
        for decision: ClassificationDecision,
        actionKind: ZoneActionKind,
        tier: ListeningTier,
        isSessionUnlocked: Bool,
        isDeskActive: Bool,
        hasPrivilegedConfirmation: Bool,
        privilegedRateLimitAllows: Bool
    ) -> LocalActionDispatchDecision {
        guard isSessionUnlocked else { return .deny(.sessionLocked) }
        guard tier.allowsActions else { return .deny(.notArmed(tier)) }
        guard isDeskActive else { return .deny(.deskInactive) }
        guard decision.wasAccepted else { return .deny(.notAccepted) }

        guard ActionAuthorization.isPrivileged(actionKind) else { return .allow }
        guard hasPrivilegedConfirmation else { return .deny(.awaitingConfirmation(actionKind)) }
        guard privilegedRateLimitAllows else { return .deny(.rateLimited) }
        return .allow
    }
}
