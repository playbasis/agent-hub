import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class ModelStepReportRegressionTests: XCTestCase {
    func testReplayTimestampCannotMoveTheSameResponseIntoTheCurrentWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = TokenUsage(input: 8, output: 2, total: 10, provenance: .providerReported)
        let earlier = ActivityModelStep(id: "stable", timestamp: now.addingTimeInterval(-100), model: "gpt-6-astra", usage: usage, usageIsPartial: false)
        var replay = earlier; replay.timestamp = now.addingTimeInterval(-10)
        let old = ActivityTurn(id: "native", completedAt: now.addingTimeInterval(-10), modelSteps: [earlier], modelStepsComplete: true)
        var newer = old; newer.modelSteps = [replay]
        let parent = ActivitySession(id: "p", provider: .codex, nativeID: "p", title: "p", createdAt: now.addingTimeInterval(-1_000),
            updatedAt: now, observedAt: now.addingTimeInterval(-2), turns: [old], source: "fixture")
        let copy = ActivitySession(id: "c", provider: .codex, nativeID: "c", title: "c", createdAt: now.addingTimeInterval(-500),
            updatedAt: now, observedAt: now, parentSessionID: "p", turns: [newer], source: "fixture")
        let rows = ModelUsageReport.build(sessions: [parent, copy], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(ModelUsageReport.summary(rows).totalObservedSteps, 0)
    }

    func testLongUnfinishedTurnWithRecentStepsRemainsInScope() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let step = ActivityModelStep(id: "recent", timestamp: now.addingTimeInterval(-5), model: "gpt-6.1-sol")
        let turn = ActivityTurn(id: "open", startedAt: now.addingTimeInterval(-200_000), status: "inProgress", modelSteps: [step], modelStepsComplete: false)
        let session = ActivitySession(id: "s", provider: .codex, nativeID: "s", title: "s", createdAt: now.addingTimeInterval(-200_000),
            updatedAt: now.addingTimeInterval(-200_000), turns: [turn], source: "fixture")
        let overview = ActivityOverview(generatedAt: now, sessions: [session])
        let scope = ReportScope.build(overview: overview, key: .init(generatedAt: now, sessionCount: 1, provider: "all", project: "all", query: "",
            cutoff: now.addingTimeInterval(-86_400), now: now))
        XCTAssertEqual(scope.sessions.map(\.id), ["s"])
        let rows = ModelUsageReport.build(sessions: scope.matchingSessions, ownershipContext: overview.sessions, from: now.addingTimeInterval(-86_400), to: now)
        XCTAssertEqual(rows.first?.requestCount, 1)
        XCTAssertTrue(rows.first?.requestsArePartial == true)
    }
}
