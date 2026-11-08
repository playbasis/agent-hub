@testable import BridgeCore
import Foundation
import XCTest

final class ModelWorkProfileTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    private func usage(_ total: Int?, output: Int?) -> TokenUsage {
        TokenUsage(input: total.map { $0 - (output ?? 0) }, output: output, cachedInput: 0, cacheWriteInput: 0, reasoning: 0, total: total,
                   provenance: total == nil ? .unavailable : .providerReported)
    }
    private func step(_ id: String, at seconds: Double, model: String, total: Int?, output: Int?) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: date(seconds), model: model, usage: usage(total, output: output), usageIsPartial: false)
    }
    private func rows(_ steps: [ActivityModelStep]) -> [ActivityModelAccounting.Row] {
        let turn = ActivityTurn(id: "t", startedAt: date(0), completedAt: date(3_000), status: "completed",
                                usage: TokenUsage(input: nil, output: nil, cachedInput: nil, cacheWriteInput: nil, reasoning: nil, total: nil, provenance: .unavailable),
                                modelSteps: steps, modelStepsComplete: true)
        let session = ActivitySession(id: "s", provider: .codex, nativeID: "s", title: "s", projectPath: "/repo",
                                      createdAt: date(-100), updatedAt: date(3_000), observedAt: date(3_000),
                                      parentSessionID: nil, turns: [turn], historyComplete: true, source: "fixture")
        let overview = ActivityOverview(generatedAt: date(3_600), sessions: [session],
                                        sources: [ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: date(3_600), message: "Fixture")])
        return ActivityAccounting.build(overview: overview, from: date(0), to: date(3_600)).modelRows
    }

    func testAveragesDivideEachSubtotalByTheRecordsThatReportedIt() throws {
        let rows = rows([step("a", at: 10, model: "gpt-6.1-terra", total: 1_000, output: 100),
                         step("b", at: 20, model: "gpt-6.1-terra", total: 3_000, output: 300),
                         step("c", at: 30, model: "gpt-6.1-terra", total: nil, output: nil)])
        let row = try XCTUnwrap(rows.first { $0.name == "gpt-6.1-terra" })
        let profile = ModelWorkProfile(row)
        XCTAssertEqual(try XCTUnwrap(profile.contextPerStep), 2_000, accuracy: 0.001, "a step without usage is unknown, not a zero that dilutes the average")
        XCTAssertEqual(try XCTUnwrap(profile.writtenPerStep), 200, accuracy: 0.001)
        XCTAssertFalse(profile.approximate)
    }

    func testRowsWithoutReportedUsageHaveNoAverage() throws {
        let rows = rows([step("a", at: 10, model: "claude-opus-5-5", total: nil, output: nil)])
        let profile = ModelWorkProfile(try XCTUnwrap(rows.first))
        XCTAssertNil(profile.contextPerStep)
        XCTAssertNil(profile.writtenPerStep)
    }
}
