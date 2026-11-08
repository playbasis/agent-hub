import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class TokenChartAccountingTests: XCTestCase {
    @MainActor
    func testChartUsesReportedTotalsEvenWhenBreakdownIsUnavailable() async throws {
        let asOf = Date(timeIntervalSince1970: 1_793_686_620)
        let usage = TokenUsage(output: 20, total: 100, provenance: .providerReported)
        let step = ActivityModelStep(id: "fixture-step", timestamp: asOf.addingTimeInterval(-1), model: "gpt-6.1-sol", usage: usage, usageIsPartial: false)
        let turn = ActivityTurn(id: "fixture-turn", startedAt: asOf.addingTimeInterval(-2), completedAt: asOf.addingTimeInterval(-1),
                                status: "completed", usage: usage, usageIsPartial: false, modelSteps: [step], modelStepsComplete: true)
        let session = ActivitySession(id: "codex:fixture", provider: .codex, nativeID: "fixture", title: "Fixture",
                                      createdAt: asOf.addingTimeInterval(-10), updatedAt: asOf, observedAt: asOf, turns: [turn], source: "fixture")
        let source = ActivitySourceHealth(id: "codex-activity", status: "partial", checkedAt: asOf, message: "Fixture collection coverage")
        let snapshot = TokenAccountingSeriesAdapter.build(overview: ActivityOverview(generatedAt: asOf, sessions: [session], sources: [source]))
        let point = try XCTUnwrap(snapshot.hourly.points.last)
        let measured = try XCTUnwrap(point.authoritativeByAgent?["codex"])
        XCTAssertEqual(TokenActivityChart.Metric.total.value(measured), 100)
        XCTAssertEqual(TokenActivityChart.Metric.output.value(measured), 20)
        XCTAssertNil(TokenActivityChart.Metric.weighted.value(measured))
        XCTAssertEqual(snapshot.historyIsPartial, true)
        XCTAssertFalse(TokenActivityChart.Metric.total.isPartial(measured), "Collection coverage must not change the canonical measurement confidence flag")
        XCTAssertNil(point.byAgent["codex"], "The chart must not depend on manufactured zero components")
    }

    @MainActor
    func testLegacyChartValuesRejectMalformedOrOverflowingComponents() async {
        XCTAssertNil(TokenActivityChart.Metric.total.legacyValue(TokenComponents(freshInput: Int.max, cacheRead: 1)))
        XCTAssertNil(TokenActivityChart.Metric.output.legacyValue(TokenComponents(output: -1)))
        XCTAssertEqual(TokenActivityChart.compact(Double.infinity), "Unavailable")
        XCTAssertFalse(TokenActivityChart.compact(Int.min).isEmpty, "Formatting must not call abs(Int.min)")
        let point = TokenSeriesPoint(start: Date(timeIntervalSince1970: 0), byAgent: ["codex": TokenComponents(freshInput: 100)])
        XCTAssertNil(TokenActivityChart.Metric.total.value(in: point, agent: "codex", canonical: true), "A missing canonical measurement cannot fall back to legacy components")
        XCTAssertEqual(TokenActivityChart.Metric.total.value(in: point, agent: "codex", canonical: false), 100)
    }
}
