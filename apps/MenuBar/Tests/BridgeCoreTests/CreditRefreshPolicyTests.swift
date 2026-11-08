import Foundation
import XCTest
@testable import BridgeCore

final class CreditRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func due(
        visible: Bool = true,
        ready: Bool = true,
        refreshing: Bool = false,
        attempt: Date? = nil,
        estimate: QuotaEstimate? = nil,
        at date: Date? = nil
    ) -> Bool {
        CreditRefreshPolicy.shouldRefresh(now: date ?? now, isVisible: visible,
            isReady: ready, isRefreshing: refreshing, lastAttemptAt: attempt, estimate: estimate)
    }

    func testNoExtraProbeWhileHiddenUnreadyOrAlreadyRefreshing() {
        XCTAssertFalse(due(visible: false))
        XCTAssertFalse(due(ready: false))
        XCTAssertFalse(due(refreshing: true))
        XCTAssertTrue(due())
    }

    func testFreshStartupFullReadPreventsDuplicateNarrowProbe() {
        let estimate = QuotaEstimate(agent: .codex, source: .live, fetchedAt: now)
        XCTAssertFalse(due(estimate: estimate))
        XCTAssertFalse(due(estimate: estimate, at: now.addingTimeInterval(119.999)))
        XCTAssertTrue(due(estimate: estimate, at: now.addingTimeInterval(120)))
    }

    func testRecentAttemptThrottlesFailuresWithoutNewProviderTimestamp() {
        let old = QuotaEstimate(agent: .codex, source: .live, fetchedAt: now.addingTimeInterval(-600))
        XCTAssertFalse(due(attempt: now.addingTimeInterval(-119), estimate: old))
        XCTAssertTrue(due(attempt: now.addingTimeInterval(-120), estimate: old))
    }

    func testRefreshFailureDateThrottlesPreservedOldBalance() {
        let failed = QuotaEstimate(agent: .codex, source: .live,
            fetchedAt: now.addingTimeInterval(-600), credits: QuotaCredits(balance: "12.30"),
            refreshFailedAt: now.addingTimeInterval(-30))
        XCTAssertFalse(due(estimate: failed))
        XCTAssertTrue(due(estimate: failed, at: now.addingTimeInterval(90)))
    }

    func testNewestFiniteObservationOrAttemptControlsCadence() {
        let estimate = QuotaEstimate(agent: .codex, source: .live,
            fetchedAt: now.addingTimeInterval(-120), refreshFailedAt: now.addingTimeInterval(-200))
        XCTAssertTrue(due(attempt: now.addingTimeInterval(-300), estimate: estimate))
        XCTAssertFalse(due(attempt: now.addingTimeInterval(-10), estimate: estimate))
    }

    func testFutureTimestampCannotTriggerTightRetryLoop() {
        let future = now.addingTimeInterval(60)
        XCTAssertFalse(due(attempt: future))
        XCTAssertFalse(due(attempt: future, at: now.addingTimeInterval(179)))
        XCTAssertTrue(due(attempt: future, at: now.addingTimeInterval(180)))
    }

    func testInvalidNowNeverLaunchesAndInvalidHistoryIsIgnored() {
        XCTAssertFalse(due(at: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertFalse(due(at: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertTrue(due(attempt: Date(timeIntervalSinceReferenceDate: .nan)))
        let estimate = QuotaEstimate(agent: .codex, fetchedAt: Date(timeIntervalSinceReferenceDate: .infinity))
        XCTAssertTrue(due(estimate: estimate))
    }

    func testRetainedRegistrationsCannotPollClosedWindows() {
        XCTAssertFalse(CreditRefreshPolicy.hasVisibleSurface(registered: ["accounts", "overview", "panel"],
            hubVisible: false, hubPage: .accounts, panelVisible: false, panelShowsCredits: true))
    }

    func testHubRequiresMatchingVisiblePageAndRegistration() {
        XCTAssertTrue(CreditRefreshPolicy.hasVisibleSurface(registered: ["accounts"],
            hubVisible: true, hubPage: .accounts, panelVisible: false, panelShowsCredits: false))
        XCTAssertTrue(CreditRefreshPolicy.hasVisibleSurface(registered: ["overview"],
            hubVisible: true, hubPage: .overview, panelVisible: false, panelShowsCredits: false))
        for page in [BridgePage.overview, .logs, .team] {
            XCTAssertFalse(CreditRefreshPolicy.hasVisibleSurface(registered: ["accounts"],
                hubVisible: true, hubPage: page, panelVisible: false, panelShowsCredits: false))
        }
        XCTAssertFalse(CreditRefreshPolicy.hasVisibleSurface(registered: [],
            hubVisible: true, hubPage: .accounts, panelVisible: false, panelShowsCredits: false))
    }

    func testActualCreditsPageUsesCatalogIdentityNotItsCapitalizedDisplayTitle() {
        XCTAssertEqual(BridgePage.credits.rawValue,"Credits")
        XCTAssertTrue(CreditRefreshPolicy.hasVisibleSurface(registered:["credits"],hubVisible:true,
            hubPage:.credits,panelVisible:false,panelShowsCredits:false))
        XCTAssertFalse(CreditRefreshPolicy.hasVisibleSurface(registered:["Credits"],hubVisible:true,
            hubPage:.credits,panelVisible:false,panelShowsCredits:false))
    }

    func testPanelRequiresActualVisibilityCreditTabAndRegistration() {
        XCTAssertTrue(CreditRefreshPolicy.hasVisibleSurface(registered: ["panel"],
            hubVisible: false, hubPage: nil, panelVisible: true, panelShowsCredits: true))
        XCTAssertFalse(CreditRefreshPolicy.hasVisibleSurface(registered: ["panel"],
            hubVisible: false, hubPage: nil, panelVisible: true, panelShowsCredits: false))
        XCTAssertFalse(CreditRefreshPolicy.hasVisibleSurface(registered: [],
            hubVisible: false, hubPage: nil, panelVisible: true, panelShowsCredits: true))
    }
}
