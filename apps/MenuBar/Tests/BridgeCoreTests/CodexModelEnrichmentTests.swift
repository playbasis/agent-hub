import Foundation
import XCTest
@testable import BridgeCore

final class CodexModelEnrichmentTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private func step(_ id: String, model: String = "gpt-6-astra", seconds: Double = 1) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: at.addingTimeInterval(seconds), model: model, effort: "ultra",
                          usage: TokenUsage(input: 8, output: 2, cachedInput: 4, total: 10, provenance: .providerReported), usageIsPartial: false)
    }
    private func session(_ turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: "codex:thread", provider: .codex, nativeID: "thread", title: "Fixture", createdAt: at,
                        updatedAt: at.addingTimeInterval(20), turns: turns, historyComplete: true, source: "fixture")
    }

    func testCheckpointsRecoverModelsButKeepAuthoritativeAPITimingAndTools() {
        let original = ActivityTurn(id: "codex:turn:one", startedAt: at, completedAt: at.addingTimeInterval(10), durationSeconds: 10,
            status: "completed", promptCount: 1, toolCount: 4, categories: ["tests": 4])
        var metadata = CodexModelStepReader.Turn()
        metadata.model = "gpt-6.1-sol"; metadata.effort = "ultra"
        metadata.startedAt = at.addingTimeInterval(1); metadata.completedAt = at.addingTimeInterval(11)
        metadata.modelSteps = [step("a"), step("b", model: "gpt-6.1-sol")]
        metadata.modelStepsComplete = true; metadata.status = "completed"
        var result = CodexModelStepReader.Result(); result.finished = true; result.turns["one"] = metadata
        let enriched = CodexActivityParser.enrichModelSteps(session([original]), telemetry: result)
        XCTAssertEqual(enriched.turns.count, 1)
        XCTAssertEqual(enriched.turns[0].modelSteps?.count, 2)
        XCTAssertEqual(enriched.turns[0].startedAt, at)
        XCTAssertEqual(enriched.turns[0].completedAt, original.completedAt)
        XCTAssertEqual(enriched.turns[0].toolCount, 4)
        XCTAssertEqual(enriched.turns[0].usage.total, 20)
        XCTAssertEqual(enriched.turns[0].usage.input, 16)
        XCTAssertEqual(enriched.turns[0].usage.cachedInput, 8)
        XCTAssertEqual(enriched.turns[0].usage.output, 4)
        XCTAssertEqual(enriched.models, ["gpt-6-astra", "gpt-6.1-sol"])
    }

    func testOlderReceiptBearingTurnCanBeImportedWithoutInventingToolsOrPrompts() {
        var metadata = CodexModelStepReader.Turn()
        metadata.modelSteps = [step("old")]; metadata.model = "gpt-6-astra"
        metadata.startedAt = at; metadata.completedAt = at.addingTimeInterval(2); metadata.status = "completed"
        metadata.modelStepsComplete = true
        var result = CodexModelStepReader.Result(); result.finished = true
        result.turns["historical"] = metadata
        result.turns["bare-context"] = CodexModelStepReader.Turn()
        let enriched = CodexActivityParser.enrichModelSteps(session([]), telemetry: result)
        XCTAssertEqual(enriched.turns.map(\.id), ["codex:turn:historical"])
        XCTAssertNil(enriched.turns[0].promptCount)
        XCTAssertNil(enriched.turns[0].toolCount)
        XCTAssertEqual(enriched.turns[0].durationSeconds, 2)
    }

    func testBudgetStopPreservesPriorCheckpointAndCompleteUsage() {
        let original = ActivityTurn(id: "codex:turn:one", status: "completed",
            usage: TokenUsage(total: 20, provenance: .providerReported), usageIsPartial: false,
            modelSteps: [step("a"), step("b")], modelStepsComplete: true)
        var metadata = CodexModelStepReader.Turn(); metadata.modelSteps = [step("b")]
        var result = CodexModelStepReader.Result(); result.hitBudget = true; result.turns["one"] = metadata
        let enriched = CodexActivityParser.enrichModelSteps(session([original]), telemetry: result)
        XCTAssertEqual(enriched.turns[0].modelSteps?.count, 2)
        XCTAssertEqual(enriched.turns[0].usage.total, 20)
        XCTAssertFalse(enriched.historyComplete)
        XCTAssertTrue(enriched.warnings.contains { $0.contains("bounded passes") })
    }

    func testDatabaseRetainsStepEvidenceAndSearchIdentitiesAcrossRestartAndPartialReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-step-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.sqlite")
        let database = try ActivityDatabase(url: url)
        let turn = ActivityTurn(id: "codex:turn:one", completedAt: at, status: "completed",
            modelSteps: [step("a"), step("b", model: "gpt-6.1-sol")], modelStepsComplete: true)
        let health = ActivitySourceHealth(id: "fixture", status: "partial", checkedAt: at, message: "Fixture")
        try database.merge([ActivityCollection(sessions: [session([turn])], health: health)], now: at)
        let reopened = try ActivityDatabase(url: url)
        var partial = session([ActivityTurn(id: turn.id)]); partial.historyComplete = false
        try reopened.merge([ActivityCollection(sessions: [partial], health: health)], now: at)
        let snapshot = try reopened.overview()
        XCTAssertEqual(snapshot.sessions[0].turns[0].modelSteps?.count, 2)
        XCTAssertEqual(Set(snapshot.sessions[0].models), ["gpt-6-astra", "gpt-6.1-sol"])
        XCTAssertEqual(snapshot.sessions[0].efforts, ["ultra"])
    }
}
