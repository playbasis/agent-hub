import XCTest
@testable import BridgeCore

final class BridgeNavigationTests: XCTestCase {
    func testSidebarCatalogIncludesEachPageExactlyOnce() {
        let pages = BridgePageGroup.allCases.flatMap(\.pages)
        XCTAssertEqual(Set(pages), Set(BridgePage.allCases))
        XCTAssertEqual(pages.count, BridgePage.allCases.count)
        XCTAssertEqual(Set(pages.map(\.id)).count, pages.count)
        XCTAssertTrue([BridgePage.teamChat, .logs, .settings, .accounts].allSatisfy { pages.contains($0) })
    }
    func testShortcutNumbersFollowSidebarOrderAndStopAtNine() {
        let pages = BridgePageGroup.allCases.flatMap(\.pages)
        XCTAssertEqual(pages.compactMap(\.shortcutNumber), Array(1...9))
        XCTAssertEqual(BridgePage.overview.shortcutNumber, 1)
        XCTAssertEqual(pages.prefix(9).map(\.shortcutNumber), (1...9).map(Optional.some))
        XCTAssertTrue(pages.dropFirst(9).allSatisfy { $0.shortcutNumber == nil })
    }
    func testRestoresLegacyAndCurrentNamesWithSafeFallback() {
        XCTAssertEqual(BridgePage.restored("Team"), .team)
        XCTAssertEqual(BridgePage.restored("Agents"), .team)
        XCTAssertEqual(BridgePage.restored("team-chat"), .teamChat)
        XCTAssertEqual(BridgePage.restored("unknown-future-page"), .overview)
        XCTAssertEqual(BridgePage.restored(nil), .overview)
    }
    func testHistoryIgnoresReselectionAndBranchesAfterBack() {
        var state = BridgeNavigationState()
        state.navigate(to: .logs); state.navigate(to: .logs); state.navigate(to: .settings)
        XCTAssertEqual(state.backHistory, [.overview, .logs])
        state.goBack(); XCTAssertEqual(state.page, .logs)
        state.goForward(); XCTAssertEqual(state.page, .settings)
        state.goBack(); state.navigate(to: .teamChat)
        XCTAssertFalse(state.canGoForward)
        state.goBack(); state.goBack(); state.goBack()
        XCTAssertEqual(state.page, .overview)
    }
    func testSessionSelectionSurvivesPageNavigationWithoutLeakingInspector() {
        var state = BridgeNavigationState()
        state.openSession("codex:native-id")
        XCTAssertEqual(state.page, .goals)
        for page in [BridgePage.teamChat, .settings, .logs, .accounts, .glmChat, .providerProof, .journal] {
            state.navigate(to: page)
            XCTAssertFalse(page.supportsSessionInspector)
            XCTAssertEqual(state.selectedSessionID, "codex:native-id")
        }
        state.goBack(); state.selectSession(nil)
        XCTAssertNil(state.selectedSessionID)
    }
    func testOnlyActivityPagesRequestNativeHistoryCollection() {
        XCTAssertTrue(BridgePage.journal.needsActivityCollection)
        XCTAssertFalse(BridgePage.journal.showsActivityFilters)
        for page in [BridgePage.teamChat, .glmChat, .logs, .settings, .accounts, .providerProof] {
            XCTAssertFalse(page.needsActivityCollection)
            XCTAssertFalse(page.showsActivityFilters)
        }
        XCTAssertEqual(BridgeEntryPoint.settings.destination, .settings)
        XCTAssertEqual(BridgeEntryPoint.logs.destination, .logs)
        XCTAssertEqual(BridgeEntryPoint.teamChat.destination, .teamChat)
    }
    func testHistoryIsBoundedWithoutLosingCurrentPage() {
        var state = BridgeNavigationState()
        for index in 0..<120 { state.navigate(to: index.isMultiple(of: 2) ? .logs : .settings) }
        XCTAssertEqual(state.backHistory.count, 50)
        XCTAssertEqual(state.page, .settings)
    }

    func testCreditReportsShareFrameWithoutRenumberingExistingActivityShortcuts() {
        XCTAssertEqual(BridgePage.restored("credits"),.credits)
        XCTAssertEqual(BridgePage.credits.group,.app)
        XCTAssertTrue(BridgePage.credits.needsActivityCollection)
        XCTAssertTrue(BridgePage.credits.showsActivityFilters)
        XCTAssertFalse(BridgePage.credits.supportsSessionInspector)
        XCTAssertNil(BridgePage.credits.shortcutNumber)
    }

    func testSkillsIsAReportingPageBesideModels() {
        let activity = BridgePageGroup.activity.pages
        XCTAssertEqual(activity.firstIndex(of: .skills), activity.firstIndex(of: .models).map { $0 + 1 })
        XCTAssertEqual(BridgePage.restored("skills"), .skills)
        XCTAssertTrue(BridgePage.skills.showsActivityFilters)
        XCTAssertTrue(BridgePage.skills.supportsSessionInspector)
        XCTAssertEqual(BridgePage.skills.shortcutNumber, 7)
        // Reporting pages keep ⌘1–⌘9; Team Chat is reached from the sidebar.
        XCTAssertEqual(BridgePage.providerProof.shortcutNumber, 9)
        XCTAssertNil(BridgePage.teamChat.shortcutNumber)
    }
}
