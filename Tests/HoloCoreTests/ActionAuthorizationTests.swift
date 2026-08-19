import XCTest
@testable import HoloCore

final class ActionAuthorizationTests: XCTestCase {
    private let accepted = ClassificationDecision(
        zone: .leftTop,
        confidence: 0.9,
        signalStrength: 0.8,
        zoneDistances: [0.1, 0.9, 0.9, 0.9],
        rejectionReason: nil
    )

    private let rejected = ClassificationDecision(
        zone: nil,
        confidence: 0.2,
        signalStrength: 0.3,
        zoneDistances: [],
        rejectionReason: .ambiguousZone
    )

    private func decide(
        _ decision: ClassificationDecision? = nil,
        kind: ZoneActionKind = .sound,
        tier: ListeningTier = .armed,
        unlocked: Bool = true,
        deskActive: Bool = true,
        confirmed: Bool = true,
        rateLimitAllows: Bool = true
    ) -> LocalActionDispatchDecision {
        LocalActionDispatchPolicy.decide(
            for: decision ?? accepted,
            actionKind: kind,
            tier: tier,
            isSessionUnlocked: unlocked,
            isDeskActive: deskActive,
            hasPrivilegedConfirmation: confirmed,
            privilegedRateLimitAllows: rateLimitAllows
        )
    }

    func testSafeAndPrivilegedClassification() {
        for kind in [ZoneActionKind.none, .sound, .copyText, .speakText] {
            XCTAssertEqual(ActionAuthorization.risk(of: kind), .safe, "\(kind) should be safe")
        }
        for kind in [ZoneActionKind.openURL, .runShortcut, .openApplication, .openItem,
                     .runShellCommand, .screenshotClipboard, .screenshotSelection] {
            XCTAssertEqual(ActionAuthorization.risk(of: kind), .privileged, "\(kind) should be privileged")
        }
        // Every kind is classified; a new action kind must not default to safe
        // by omission.
        XCTAssertEqual(ZoneActionKind.allCases.count, 11)
    }

    func testALockedSessionBlocksEvenASafeAction() {
        XCTAssertEqual(decide(kind: .sound, unlocked: false), .deny(.sessionLocked))
        XCTAssertEqual(decide(kind: .none, unlocked: false), .deny(.sessionLocked))
    }

    func testOnlyArmedRunsActions() {
        XCTAssertEqual(decide(tier: .doze), .deny(.notArmed(.doze)))
        XCTAssertEqual(decide(tier: .paused), .deny(.notArmed(.paused)))
        XCTAssertTrue(decide(tier: .armed).isAllowed)
    }

    func testLockOutranksTier() {
        XCTAssertEqual(decide(tier: .paused, unlocked: false), .deny(.sessionLocked))
    }

    func testActionsStayConfinedToTheDeskSurface() {
        XCTAssertEqual(decide(deskActive: false), .deny(.deskInactive))
    }

    func testRejectedDecisionsNeverDispatch() {
        XCTAssertEqual(decide(rejected), .deny(.notAccepted))
    }

    func testPrivilegedActionsNeedConfirmationOnce() {
        XCTAssertEqual(
            decide(kind: .runShellCommand, confirmed: false),
            .deny(.awaitingConfirmation(.runShellCommand))
        )
        XCTAssertTrue(decide(kind: .runShellCommand, confirmed: true).isAllowed)
    }

    func testSafeActionsSkipConfirmationAndRateLimiting() {
        XCTAssertTrue(decide(kind: .copyText, confirmed: false, rateLimitAllows: false).isAllowed)
    }

    func testPrivilegedActionsAreRateLimited() {
        XCTAssertEqual(decide(kind: .openURL, rateLimitAllows: false), .deny(.rateLimited))
    }

    func testRateLimiterAllowsOnePrivilegedActionEveryTwoSeconds() {
        var limiter = PrivilegedActionRateLimiter()
        XCTAssertTrue(limiter.allows(at: 100))
        limiter.noteDispatch(at: 100)
        XCTAssertFalse(limiter.allows(at: 101))
        XCTAssertFalse(limiter.allows(at: 101.99))
        XCTAssertTrue(limiter.allows(at: 102))

        limiter.reset()
        XCTAssertTrue(limiter.allows(at: 100.1))
    }

    func testConsentIsPerProfileAndPerKind() {
        let deskA = UUID()
        let deskB = UUID()
        var consent = PrivilegedActionConsent()

        XCTAssertFalse(consent.isGranted(profileID: deskA, kind: .runShellCommand))
        XCTAssertTrue(consent.isGranted(profileID: deskA, kind: .sound), "Safe kinds never need consent")

        consent.grant(profileID: deskA, kind: .runShellCommand)
        XCTAssertTrue(consent.isGranted(profileID: deskA, kind: .runShellCommand))
        XCTAssertFalse(consent.isGranted(profileID: deskA, kind: .openURL))
        XCTAssertFalse(consent.isGranted(profileID: deskB, kind: .runShellCommand))
    }

    func testDeletingAProfileRevokesItsConsentOnly() {
        let deskA = UUID()
        let deskB = UUID()
        var consent = PrivilegedActionConsent()
        consent.grant(profileID: deskA, kind: .runShellCommand)
        consent.grant(profileID: deskA, kind: .openURL)
        consent.grant(profileID: deskB, kind: .openURL)

        consent.revokeAll(profileID: deskA)
        XCTAssertFalse(consent.isGranted(profileID: deskA, kind: .runShellCommand))
        XCTAssertFalse(consent.isGranted(profileID: deskA, kind: .openURL))
        XCTAssertTrue(consent.isGranted(profileID: deskB, kind: .openURL))
    }

    func testConsentSurvivesARoundTripThroughJSON() throws {
        let desk = UUID()
        var consent = PrivilegedActionConsent()
        consent.grant(profileID: desk, kind: .runShortcut)

        let data = try JSONEncoder().encode(consent)
        let restored = try JSONDecoder().decode(PrivilegedActionConsent.self, from: data)
        XCTAssertEqual(restored.version, PrivilegedActionConsent.currentVersion)
        XCTAssertTrue(restored.isGranted(profileID: desk, kind: .runShortcut))
    }
}
