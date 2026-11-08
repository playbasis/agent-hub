import Foundation
import XCTest
@testable import BridgeCore

final class ActivityModelAccountingSchemaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCanonicalRowsAndReceiptsConserveContainedUsageWithoutInventingSteps() throws {
        let result = inspect(native(total: 100, steps: [step("one", model: "gpt-6-astra", total: 20)], complete: false))
        XCTAssertEqual(result.summary.totalObservedSteps, 1)
        XCTAssertEqual(result.summary.nativeTurns, 1)
        XCTAssertEqual(result.rows.compactMap(\.tokens).reduce(0, +), 100)
        XCTAssertEqual(result.receipts.filter(\.includedInTotals).compactMap { $0.usage.total }.reduce(0, +), 100)
        XCTAssertEqual(result.receipts.filter(\.countsAsModelStep).count, 1)
        let remainder = try XCTUnwrap(result.receipts.first { $0.kind == .nativeUsageRemainder })
        XCTAssertEqual(remainder.usage.total, 80)
        XCTAssertEqual(remainder.usage.provenance, .derived)
        XCTAssertEqual(result.receipts.first { $0.kind == .modelStep }?.usage.provenance, .providerReported)
        XCTAssertNil(remainder.model)
        XCTAssertNil(remainder.timestamp, "A turn interval must never masquerade as a model-step timestamp")
        XCTAssertEqual(remainder.intervalStart, now.addingTimeInterval(-50))
        XCTAssertEqual(remainder.intervalEnd, now.addingTimeInterval(-5))
        XCTAssertEqual(remainder.timeBasis, .nativeInterval)
        XCTAssertFalse(remainder.countsAsModelStep)
        XCTAssertTrue(remainder.includedInTotals)
        XCTAssertEqual(remainder.projectPath, "/fixture/project")
    }

    func testCrossBoundaryRemainderHasMetadataButNoPeriodContribution() throws {
        let value = native(total: 100, steps: [step("one", model: "gpt-6-astra", total: 20)], complete: false, start: -120)
        let result = inspect(value)
        XCTAssertEqual(result.summary.unallocatedTokens, 80)
        XCTAssertEqual(result.summary.unallocatedTurns, 1)
        XCTAssertEqual(result.rows.compactMap(\.tokens).reduce(0, +), 20)
        XCTAssertEqual(result.receipts.filter(\.includedInTotals).compactMap { $0.usage.total }.reduce(0, +), 20)
        let unplaced = try XCTUnwrap(result.receipts.first { $0.kind == .unplacedNativeUsage })
        XCTAssertEqual(unplaced.usage.total, 80)
        XCTAssertNil(unplaced.timestamp)
        XCTAssertFalse(unplaced.includedInTotals)
        XCTAssertEqual(unplaced.timeBasis, .unplaced)
    }

    func testOpenAllHistoryRemainderRemainsUndatedRatherThanUsingObservationAsAnEvent() throws {
        var value = native(total: 100, steps: nil, complete: nil, start: -86_400)
        value.completedAt = nil; value.status = "inProgress"
        let result = ActivityModelAccounting.inspect(sessions: [session("one", turns: [value])], from: nil, to: now)
        let receipt = try XCTUnwrap(result.receipts.first)
        XCTAssertEqual(receipt.kind, .nativeUsageRemainder)
        XCTAssertTrue(receipt.includedInTotals)
        XCTAssertNil(receipt.timestamp)
        XCTAssertNil(receipt.intervalEnd)
        XCTAssertEqual(receipt.observedAt, now)
        XCTAssertEqual(result.rows.first?.tokens, 100)
        XCTAssertNil(result.rows.first?.requestCount)
    }

    func testProviderEventsKeepTheirOwnDateAndMetadataOnlyTraceability() throws {
        let value = native(total: 30, steps: [step("a", model: "gpt-6-astra", total: 10, seconds: -30),
                                            step("b", model: "gpt-6.1-sol", total: 20, seconds: -10)], complete: true, end: 300)
        let result = inspect(value)
        XCTAssertEqual(result.receipts.count, 2)
        XCTAssertTrue(result.receipts.allSatisfy { $0.kind == .modelStep && $0.timeBasis == .providerEvent && $0.includedInTotals })
        XCTAssertEqual(Set(result.receipts.compactMap(\.timestamp)), [now.addingTimeInterval(-30), now.addingTimeInterval(-10)])
        XCTAssertEqual(result.receipts.first?.sessionID, "one")
        XCTAssertEqual(result.receipts.first?.nativeTurnID, "codex:turn:native")
        XCTAssertEqual(result.receipts.first?.evidence, "fixture-provider-checkpoint/1")
        let exported = String(decoding: try BridgeJSON.compactEncoder.encode(result), as: UTF8.self)
        XCTAssertFalse(exported.contains("PRIVATE_SESSION_TITLE"))
        XCTAssertFalse(exported.contains("PRIVATE_GOAL_OBJECTIVE"))
    }

    func testOwnershipPrecedesFiltersForBothRowsAndReceiptProjectAttribution() {
        let inherited = step("copied", model: "gpt-6-astra", total: 50)
        let parent = session("parent", turns: [native(total: 50, steps: [inherited], complete: true)])
        var childTurn = native(total: 57, steps: [inherited, step("own", model: "gpt-6.1-sol", total: 7)], complete: true)
        childTurn.id = "codex:turn:child"
        var child = session("child", turns: [childTurn]); child.parentSessionID = parent.id; child.projectPath = "/fixture/child"
        let result = ActivityModelAccounting.inspect(sessions: [child], ownershipContext: [child, parent], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(result.summary.totalObservedSteps, 1)
        XCTAssertEqual(result.rows.first?.tokens, 7)
        XCTAssertEqual(result.receipts.count, 1)
        XCTAssertEqual(result.receipts.first?.model, "gpt-6.1-sol")
        XCTAssertEqual(result.receipts.first?.projectPath, "/fixture/child")
        XCTAssertEqual(result.receipts.first?.sessionID, "child")
    }

    func testRowsRoundTripWithDeterministicIdentityArraysAndExplicitUnknownCount() throws {
        var first = native(total: 100, steps: nil, complete: nil, start: -120)
        first.id = "codex:turn:z"
        var second = native(total: 40, steps: nil, complete: nil, start: -120)
        second.id = "codex:turn:a"
        let a = session("z", turns: [first]), b = session("a", turns: [second])
        let result = ActivityModelAccounting.inspect(sessions: [a, b], from: now.addingTimeInterval(-60), to: now)
        let reordered = ActivityModelAccounting.inspect(sessions: [b, a], from: now.addingTimeInterval(-60), to: now)
        let encoded = try BridgeJSON.compactEncoder.encode(result)
        XCTAssertEqual(encoded, try BridgeJSON.compactEncoder.encode(reordered))
        let decoded = try BridgeJSON.decoder.decode(ActivityModelAccounting.Result.self, from: encoded)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(ActivityModelAccounting.summary(decoded.rows), result.summary)
        XCTAssertEqual(decoded.summary.unallocatedTokens, 140)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let row = try XCTUnwrap((object["rows"] as? [[String: Any]])?.first)
        XCTAssertTrue(row["requestCount"] is NSNull)
        XCTAssertTrue(row["tokens"] is NSNull)
        let identities = try XCTUnwrap(row["nativeIDs"] as? [[String: Any]])
        XCTAssertEqual(identities.compactMap { $0["id"] as? String }, ["codex:turn:a", "codex:turn:z"])
    }

    func testSharesAreCanonicalAcrossKnownAndUnknownModelsButLegacyCountHasNoShare() throws {
        let measured = native(total: 30, steps: [step("known", model: "gpt-6-astra", total: 10),
                                               step("unknown", model: nil, total: 20)], complete: true)
        var legacy = native(total: 50, steps: nil, complete: nil); legacy.id = "codex:turn:legacy"
        let result = inspect(measured, additional: [legacy])
        XCTAssertEqual(result.rows.compactMap(\.shareOfObservedSteps).reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertEqual(result.summary.totalObservedSteps, 2)
        XCTAssertEqual(result.rows.first { $0.name == "gpt-6-astra" }?.shareOfObservedSteps, 0.5)
        XCTAssertEqual(result.rows.first { $0.name == nil }?.shareOfObservedSteps, 0.5)
        let onlyLegacy = inspect(legacy)
        XCTAssertNil(onlyLegacy.rows.first?.shareOfObservedSteps)
        let data = try BridgeJSON.compactEncoder.encode(result.rows)
        let decoded = try BridgeJSON.decoder.decode([ActivityModelAccounting.Row].self, from: data)
        XCTAssertEqual(decoded, result.rows)
    }

    func testEffortCountsArePublicCodableObjectsAndBuildIsTheSameInspection() throws {
        let value = native(total: 10, steps: [step("a", model: "gpt-6-astra", total: 10)], complete: true)
        let result = inspect(value)
        XCTAssertEqual(result.rows, ActivityModelAccounting.build(sessions: [session("one", turns: [value])], from: now.addingTimeInterval(-60), to: now))
        let effort = try XCTUnwrap(result.rows.first?.efforts.first)
        XCTAssertEqual(effort, ActivityModelAccounting.EffortCount(name: "high", count: 1))
        let encoded = try BridgeJSON.compactEncoder.encode(effort)
        XCTAssertEqual(try BridgeJSON.decoder.decode(ActivityModelAccounting.EffortCount.self, from: encoded), effort)
    }

    func testReceiptIDsAreProviderScopedStableAndDeterministicallyOrdered() {
        let value = native(total: 10, steps: [step("same", model: "shared", total: 10)], complete: true)
        let claude = session("claude", provider: .claude, turns: [value])
        let codex = session("codex", turns: [value])
        let first = ActivityModelAccounting.inspect(sessions: [codex, claude], from: nil, to: now)
        let second = ActivityModelAccounting.inspect(sessions: [claude, codex], from: nil, to: now)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.receipts.count, 2)
        XCTAssertEqual(Set(first.receipts.map(\.id)).count, 2)
        XCTAssertEqual(first.receipts.map(\.provider), [.claude, .codex])
    }

    func testProjectedNormalizedFactsMatchFilteredBuildWithoutReattributingParentCopies() {
        let inherited = step("copied", model: "gpt-6-astra", total: 50)
        let parent = session("parent", turns: [native(total: 50, steps: [inherited], complete: true)])
        var value = native(total: 57, steps: [inherited, step("own", model: "gpt-6.1-sol", total: 7)], complete: true)
        value.id = "codex:turn:child"
        var child = session("child", turns: [value]); child.parentSessionID = parent.id; child.projectPath = "/fixture/child"
        let full = ActivityModelAccounting.inspect(sessions: [parent, child], from: now.addingTimeInterval(-60), to: now)
        let projected = ActivityModelAccounting.summarize(receipts: full.receipts.filter { $0.sessionID == child.id })
        let direct = ActivityModelAccounting.inspect(sessions: [child], ownershipContext: [parent, child], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(projected, direct)
        XCTAssertEqual(projected.rows.first?.shareOfObservedSteps, 1)
        XCTAssertEqual(projected.rows.first?.tokens, 7)
        XCTAssertEqual(ActivityModelAccounting.summarize(receipts: projected.receipts + projected.receipts), projected, "Replaying identical normalized facts is idempotent")
    }

    func testSingleReducerPreservesKnownZeroAndUnplacedUnknownMetadata() {
        var empty = native(total: 0, steps: [], complete: true)
        empty.usage = TokenUsage(total: 0, provenance: .providerReported)
        let knownZero = inspect(empty)
        XCTAssertEqual(ActivityModelAccounting.summarize(receipts: knownZero.receipts), knownZero)
        XCTAssertEqual(knownZero.rows.first?.requestCount, 0)
        XCTAssertEqual(knownZero.summary.unmeasuredTurns, 0)
        let unplaced = inspect(native(total: 100, steps: [step("one", model: "gpt-6-astra", total: 20)], complete: false, start: -120))
        XCTAssertEqual(ActivityModelAccounting.summarize(receipts: unplaced.receipts), unplaced)
        XCTAssertEqual(unplaced.summary.unallocatedTokens, 80)
        XCTAssertEqual(unplaced.summary.unallocatedTurns, 1)
    }

    func testEstimatedUsageRetainsObservedStepsButCannotEnterKnownTokensOrOutput() throws {
        var measured = step("reported", model: "reported-model", total: 20)
        measured.usage = TokenUsage(input: 17, output: 3, cachedInput: 0, cacheWriteInput: 0, reasoning: 0, total: 20, provenance: .providerReported)
        var estimated = step("estimated", model: "estimated-model", total: 10)
        estimated.usage = TokenUsage(input: 6, output: 4, cachedInput: 0, cacheWriteInput: 0, reasoning: 0, total: 10, provenance: .estimated)
        let result = inspect(native(total: nil, steps: [measured, estimated], complete: true))
        XCTAssertEqual(result.summary.totalObservedSteps, 2)
        XCTAssertEqual(result.rows.compactMap(\.tokens).reduce(0, +), 20)
        XCTAssertEqual(result.rows.compactMap(\.output).reduce(0, +), 3)
        XCTAssertEqual(result.rows.reduce(0) { $0 + $1.tokenReceipts }, 1)
        XCTAssertEqual(result.rows.reduce(0) { $0 + $1.usageRecords }, 2)
        let estimateRow = try XCTUnwrap(result.rows.first { $0.name == "estimated-model" })
        XCTAssertEqual(estimateRow.observedStepCount, 1)
        XCTAssertNil(estimateRow.tokens)
        XCTAssertNil(estimateRow.output)
        XCTAssertEqual(estimateRow.tokenReceipts, 0)
        XCTAssertEqual(estimateRow.partialReceipts, 1)
        XCTAssertTrue(estimateRow.tokensArePartial)
        let retained = try XCTUnwrap(result.receipts.first { $0.usage.provenance == .estimated })
        XCTAssertEqual(retained.usage.total, 10)
        XCTAssertTrue(retained.usageIsPartial == true)
    }

    func testEstimatedPoolCannotLaunderRemainderIntoAuthoritativeDerivedUsage() throws {
        var value = native(total: 100, steps: [step("reported", model: "gpt-6-astra", total: 20)], complete: false)
        value.usage.provenance = .estimated
        let result = inspect(value)
        XCTAssertEqual(result.rows.compactMap(\.tokens).reduce(0, +), 20)
        let remainder = try XCTUnwrap(result.receipts.first { $0.kind == .nativeUsageRemainder })
        XCTAssertEqual(remainder.usage.total, 80)
        XCTAssertEqual(remainder.usage.provenance, .estimated)
        XCTAssertTrue(remainder.usageIsPartial == true)
        XCTAssertNil(result.rows.first { $0.name == nil }?.tokens)
    }

    func testUnplacedEstimatedAmountRemainsMetadataNotKnownSummaryTokens() throws {
        var value = native(total: 100, steps: nil, complete: nil, start: -120)
        value.usage.provenance = .estimated
        let result = inspect(value)
        XCTAssertNil(result.rows.first?.tokens)
        XCTAssertEqual(result.summary.unallocatedTurns, 1)
        XCTAssertNil(result.summary.unallocatedTokens)
        let retained = try XCTUnwrap(result.receipts.first { $0.kind == .unplacedNativeUsage })
        XCTAssertEqual(retained.usage.total, 100)
        XCTAssertEqual(retained.usage.provenance, .estimated)
    }

    func testEstimatedStepDoesNotSubtractFromAnAuthoritativeNativePool() throws {
        let measured = step("reported", model: "gpt-6-astra", total: 20)
        var estimated = step("estimated", model: "estimated-model", total: 10); estimated.usage.provenance = .estimated
        let result = inspect(native(total: 100, steps: [measured, estimated], complete: false))
        XCTAssertEqual(result.summary.totalObservedSteps, 2)
        XCTAssertEqual(result.rows.compactMap(\.tokens).reduce(0, +), 100)
        let remainder = try XCTUnwrap(result.receipts.first { $0.kind == .nativeUsageRemainder })
        XCTAssertEqual(remainder.usage.total, 80, "An estimate cannot consume authoritative native usage allocation")
        XCTAssertEqual(remainder.usage.provenance, .derived)
        XCTAssertNil(result.rows.first { $0.name == "estimated-model" }?.tokens)
    }

    func testUnavailableProvenanceWithNumericPayloadDoesNotBecomeKnownUsage() {
        var unknown = step("unknown", model: "example-model", total: 10); unknown.usage.provenance = .unavailable
        let result = inspect(native(total: nil, steps: [unknown], complete: true))
        XCTAssertEqual(result.summary.totalObservedSteps, 1)
        XCTAssertNil(result.rows.first?.tokens)
        XCTAssertEqual(result.rows.first?.tokenReceipts, 0)
        XCTAssertEqual(result.receipts.first?.usage.total, 10)
        XCTAssertTrue(result.receipts.first?.usageIsPartial == true)
    }

    private func inspect(_ value: ActivityTurn, additional: [ActivityTurn] = []) -> ActivityModelAccounting.Result {
        ActivityModelAccounting.inspect(sessions: [session("one", turns: [value] + additional)], from: now.addingTimeInterval(-60), to: now)
    }
    private func native(total: Int?, steps: [ActivityModelStep]?, complete: Bool?, start: Double = -50, end: Double = -5) -> ActivityTurn {
        ActivityTurn(id: "codex:turn:native", startedAt: now.addingTimeInterval(start), completedAt: now.addingTimeInterval(end),
            status: "completed", model: "last-context-model", usage: TokenUsage(total: total, provenance: .providerReported),
            usageIsPartial: false, modelSteps: steps, modelStepsComplete: complete)
    }
    private func step(_ id: String, model: String?, total: Int, seconds: Double = -10) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: now.addingTimeInterval(seconds), model: model, effort: "high",
            usage: TokenUsage(total: total, provenance: .providerReported), evidence: "fixture-provider-checkpoint/1", usageIsPartial: false)
    }
    private func session(_ id: String, provider: AgentName = .codex, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: id, title: "PRIVATE_SESSION_TITLE", projectPath: "/fixture/project",
            createdAt: now.addingTimeInterval(-3_600), updatedAt: now, observedAt: now,
            goal: ActivityGoal(id: "goal-\(id)", sessionID: id, objective: "PRIVATE_GOAL_OBJECTIVE", status: "active", createdAt: now, updatedAt: now),
            turns: turns, historyComplete: true, source: "fixture")
    }
}
