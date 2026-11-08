import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class OverviewToolCallKPITests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, counts: [Int?], prompt: Int? = 1, start: TimeInterval = -80) -> ActivitySession {
        let turns = counts.enumerated().map { index, count in
            ActivityTurn(id: "\(id)-turn-\(index)", startedAt: now.addingTimeInterval(start + Double(index)),
                         completedAt: now.addingTimeInterval(-10 + Double(index)), status: "completed",
                         promptCount: prompt, humanPromptCount: 1, toolCount: count)
        }
        return ActivitySession(id: id, provider: .codex, nativeID: id, title: id, projectPath: nil,
            createdAt: now.addingTimeInterval(-1_000), updatedAt: now.addingTimeInterval(-1), observedAt: now,
            turns: turns, historyComplete: true, source: "fixture")
    }

    private func report(_ sessions: [ActivitySession], selected: Set<String>? = nil, sourceReady: Bool = true) -> ActivityAccounting.Report {
        let sources = sourceReady ? [ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: now, message: "Fixture")] : []
        return ActivityAccounting.build(overview: ActivityOverview(generatedAt: now, sessions: sessions, sources: sources),
                                        sessionIDs: selected, from: now.addingTimeInterval(-100), to: now)
    }

    func testKnownCountUsesCanonicalScopedSubtotal() {
        let a = session("a", counts: [2, 3]), b = session("b", counts: [99])
        let scoped = report([a, a, b], selected: ["a"])
        XCTAssertEqual(scoped.totals.toolCalls, 5)
        XCTAssertEqual(OverviewToolCallKPI.make(scoped), .init(value: "5", detail: "Recorded locally"))
    }

    func testMissingAndKnownZeroRemainDifferent() {
        let missing = report([session("a", counts: [nil])])
        XCTAssertNil(missing.totals.toolCalls)
        XCTAssertEqual(OverviewToolCallKPI.make(missing).value, "—")
        let zero = report([session("a", counts: [0])])
        XCTAssertEqual(zero.totals.toolCalls, 0)
        XCTAssertEqual(OverviewToolCallKPI.make(zero).value, "0")
    }

    func testIncompleteNativeCountersAndSourcesAreMarkedConservatively() {
        let missingTool = report([session("a", counts: [3, nil])])
        XCTAssertEqual(OverviewToolCallKPI.make(missingTool), .init(value: "≥3", detail: "Coverage may be partial"))
        let missingPrompt = report([session("a", counts: [3], prompt: nil)])
        XCTAssertEqual(OverviewToolCallKPI.make(missingPrompt).value, "≥3")
        let missingSource = report([session("a", counts: [0])], sourceReady: false)
        XCTAssertEqual(OverviewToolCallKPI.make(missingSource).value, "≥0")
    }

    func testWholeTurnCrossingWindowDoesNotInventDatedToolCalls() {
        let scoped = report([session("a", counts: [7], start: -200)])
        XCTAssertNil(scoped.totals.toolCalls)
        XCTAssertEqual(scoped.totals.unallocatedNativeCounters.toolCalls, 7)
        XCTAssertEqual(OverviewToolCallKPI.make(scoped).value, "—")
    }

    func testInvalidScopeDoesNotShowAValue() {
        let overview = ActivityOverview(generatedAt: now, sessions: [session("a", counts: [1])])
        let invalid = ActivityAccounting.build(overview: overview, from: now, to: now)
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(OverviewToolCallKPI.make(invalid), .init(value: "—", detail: "Count unavailable"))
    }
}
