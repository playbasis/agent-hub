import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class ServicePresentationTests: XCTestCase {
    func testEmptyProofNeverClaimsVerificationEvenWhenCompatibilityFlagsAreTrue() {
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: []), .empty)
        XCTAssertEqual(ProviderProofPresentation.headline(.empty), "No requests recorded yet")
    }

    func testProofRequiresValidCompleteAndConsistentRecords() {
        let receipt = record()
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .threeProviders)
        XCTAssertEqual(ProviderProofPresentation.state(summary: nil, records: [receipt]), .unchecked)
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt], snapshotIsConsistent: false), .unchecked)
        var invalid = summary(); invalid.traceVerified = false
        XCTAssertEqual(ProviderProofPresentation.state(summary: invalid, records: [receipt]), .invalid)
        var partial = receipt; partial.completeness = .partial
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [partial]), .partial)
    }

    func testUnknownEffortIsPartialNotAnIdentityMismatch() {
        var receipt = record()
        receipt.identity.resolvedEffort = nil
        XCTAssertFalse(ProviderProofPresentation.hasEffortMismatch(receipt.identity))
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .partial)
        receipt.identity.resolvedEffort = "  "
        XCTAssertFalse(ProviderProofPresentation.hasEffortMismatch(receipt.identity))
        receipt.identity.resolvedEffort = "LOW"
        XCTAssertTrue(ProviderProofPresentation.hasEffortMismatch(receipt.identity))
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .identityMismatch)
        receipt.identity.resolvedEffort = " HIGH "
        XCTAssertFalse(ProviderProofPresentation.hasEffortMismatch(receipt.identity))
    }

    func testProofHighlightsModelMismatchAndDistinguishesPairParticipation() {
        var receipt = record()
        receipt.identity.resolvedModel = "unrequested-model"
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .identityMismatch)
        receipt.identity.resolvedModel = nil
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .partial)
        var pair = summary(); pair.threeProviderVerified = false
        XCTAssertEqual(ProviderProofPresentation.state(summary: pair, records: [record()]), .twoProviders)
        pair.dualProviderVerified = false
        XCTAssertEqual(ProviderProofPresentation.state(summary: pair, records: [record()]), .participationIncomplete)
    }

    func testMissingEstimatedOrInvalidTokenUsageCannotShowFullVerification() {
        var receipt = record()
        receipt.usage.total = nil
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .partial)
        receipt.usage.total = -1
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .partial)
        receipt.usage.total = 5; receipt.usage.provenance = .estimated
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .partial)
        receipt.usage.provenance = .providerReported
        XCTAssertEqual(ProviderProofPresentation.state(summary: summary(), records: [receipt]), .threeProviders)
    }

    func testTeamProgressUsesPlannedTasksAndDoesNotInflateDuplicateReceipts() {
        let plan = plan()
        let round = UUID()
        var completed = RoomWorkRecord(round: round, task: plan.tasks[0]); completed.state = "complete"
        var retry = completed; retry.id = UUID(); retry.state = "running"
        var room = TeamRoom(title: "Fixture")
        room.plan = plan; room.work = [completed, retry]
        let rows = TeamPlanPresentation.records(room: room, plan: plan)
        XCTAssertEqual(TeamPlanPresentation.tasks(plan).count, 2, "An unreported task stays in the denominator")
        XCTAssertEqual(rows.count, 1, "Repeated receipts must not count as more tasks")
        XCTAssertEqual(rows.first?.state, "running", "Latest matching receipt wins")
    }

    func testTeamLiveRoundCannotReuseOldCompletedWorkAndTaskOrderStaysStable() {
        let plan = plan()
        let oldRound = UUID(), currentRound = UUID()
        var old = RoomWorkRecord(round: oldRound, task: plan.tasks[0]); old.state = "complete"
        let second = RoomWorkRecord(round: currentRound, task: plan.tasks[1])
        let first = RoomWorkRecord(round: currentRound, task: plan.tasks[0])
        var room = TeamRoom(title: "Fixture")
        room.plan = plan; room.round = currentRound; room.work = [second, first, old]
        XCTAssertEqual(TeamPlanPresentation.records(room: room, plan: plan).map(\.task.id), ["first", "second"])
        XCTAssertEqual(TeamPlanPresentation.records(room: room, plan: plan).filter { $0.state == "complete" }.count, 0)
        room.work = [old]
        XCTAssertTrue(TeamPlanPresentation.records(room: room, plan: plan).isEmpty)
    }

    func testTeamConfiguredModelIsNotMisrepresentedAsProviderReported() {
        var settings = RoomSettings(); settings.claudeModel = "requested-claude"; settings.codexModel = "requested-codex"
        var receipt = RoomWorkRecord(round: UUID(), task: plan().tasks[0])
        XCTAssertEqual(TeamPlanPresentation.reportedModel(receipt, settings: settings), "Requested: requested-claude · provider model not reported")
        receipt.model = "actual-model"
        XCTAssertEqual(TeamPlanPresentation.reportedModel(receipt, settings: settings), "Provider reported: actual-model")
        receipt.model = " "
        XCTAssertEqual(TeamPlanPresentation.reportedModel(receipt, settings: nil), "Model not reported")
        receipt.task.owner = "Unknown provider"
        XCTAssertEqual(TeamPlanPresentation.reportedModel(receipt, settings: settings), "Model not reported")
    }

    private func plan() -> RoomPlan {
        RoomPlan(mode: .implement, message: "Plan", contract: "Deliver the requested work", tasks: [
            RoomWork(id: "first", owner: "Claude", kind: .implement, title: "First step", prompt: "Implement the UI", dependsOn: []),
            RoomWork(id: "second", owner: "Codex", kind: .verify, title: "Second step", prompt: "Verify the UI", dependsOn: ["first"]),
        ])
    }

    private func record() -> TraceRecord {
        TraceRecord(id: "receipt", sequence: 1, timestamp: Date(), bridgeSessionID: "fixture", turnID: "turn", eventID: nil, provider: .claude,
            nativeSessionID: "native", nativeTurnID: nil,
            identity: ProviderIdentity(requestedModel: "sonnet", resolvedModel: "claude-sonnet-5", requestedEffort: "high", resolvedEffort: "high"),
            usage: TokenUsage(input: 2, output: 3, total: 5, provenance: .providerReported), tools: [], durationMilliseconds: 1_000,
            timeToFirstTokenMilliseconds: nil, outcome: "success", exitCode: 0, completeness: .complete, warnings: [], budgetReserved: nil,
            budgetRemaining: nil, estimatedCostUSD: nil, costProvenance: .unavailable, adapterVersion: "fixture/1", previousHash: nil, recordHash: "fixture")
    }

    private func summary() -> TraceSummary {
        TraceSummary(bridgeSessionID: "fixture", records: 1, providers: ["claude": 1], successfulProviders: ["claude", "codex", "grok"],
            totalTokens: 5, toolCalls: 0, budgetRemaining: nil, threeProviderVerified: true, dualProviderVerified: true,
            traceVerified: true, completeness: .complete, updatedAt: Date())
    }
}
