import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class ModelUsageReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUICompatibilityNameUsesCanonicalCoreRowsAndShares() {
        let sessions = [session("one", turns: [turn("one", model: "gpt-6-astra"), turn("two", model: nil)])]
        let canonical = ActivityModelAccounting.inspect(sessions: sessions, from: nil, to: now)
        XCTAssertEqual(ModelUsageReport.build(sessions: sessions, from: nil, to: now), canonical.rows)
        XCTAssertEqual(ModelUsageReport.summary(canonical.rows), canonical.summary)
        XCTAssertEqual(canonical.rows.compactMap(\.shareOfObservedSteps).reduce(0, +), 1, accuracy: 0.000_001)
    }

    private func turn(_ id: String, model: String?, seconds: Double = -10, total: Int? = 10, output: Int? = 2,
                      partial: Bool = false) -> ActivityTurn {
        let usage = TokenUsage(input: total, output: output, total: total, provenance: .providerReported)
        return ActivityTurn(id: id, completedAt: now.addingTimeInterval(seconds), status: "completed", model: model,
                     usage: usage, usageIsPartial: partial,
                     modelSteps: [ActivityModelStep(id: "step:\(id)", timestamp: now.addingTimeInterval(seconds), model: model, usage: usage, usageIsPartial: partial)],
                     modelStepsComplete: !partial)
    }

    private func session(_ id: String, provider: AgentName = .codex, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: id, title: id, createdAt: now.addingTimeInterval(-1_000),
                        updatedAt: now, observedAt: now, turns: turns, source: "fixture")
    }

    func testSameModelAcrossProvidersRetainsSeparateIdentities() {
        let rows = ModelUsageReport.build(sessions: [session("one", provider: .claude, turns: [turn("a", model: "shared")]),
                                                     session("two", turns: [turn("b", model: "shared")])], from: nil, to: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(Set(rows.map(\.provider)), [.claude, .codex])
        XCTAssertEqual(rows.map(\.sessions), [1, 1])
    }

    func testBlankModelsStayUnrecordedAndWhitespaceDoesNotCreateDuplicateRows() {
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [turn("a", model: " "), turn("b", model: nil),
                                                                           turn("c", model: " model "), turn("d", model: "model")])], from: nil, to: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.name == "model" }?.requests, 2)
        XCTAssertEqual(rows.first { $0.name == nil }?.requests, 2)
    }

    func testSessionCountUsesTheSamePeriodAsRowUsage() {
        let rows = ModelUsageReport.build(sessions: [session("old", turns: [turn("old", model: "model", seconds: -500)]),
                                                     session("current", turns: [turn("new", model: "model")])],
                                          from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].requests, 1)
        XCTAssertEqual(rows[0].sessions, 1)
    }

    func testMissingAndPartialUsageRemainExplicitWithoutInventingTotals() {
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [turn("a", model: "model", total: 0, output: 0),
                                                                           turn("b", model: "model", total: nil, output: nil),
                                                                           turn("c", model: "model", total: 10, partial: true)])], from: nil, to: now)
        XCTAssertEqual(rows[0].tokens, 10)
        XCTAssertEqual(rows[0].tokenReceipts, 2)
        XCTAssertEqual(rows[0].outputReceipts, 2)
        XCTAssertTrue(rows[0].tokensArePartial)
        XCTAssertTrue(rows[0].outputIsPartial)
        XCTAssertTrue(rows[0].tokenCoverage.contains("2 of 3"))
        XCTAssertTrue(rows[0].tokenCoverage.contains("partial"))
        XCTAssertTrue(rows[0].accessibilitySummary.contains("2 of 3"))
        XCTAssertTrue(rows[0].accessibilitySummary.contains("Known tokens"))
        let unknown = ModelUsageReport.build(sessions: [session("one", turns: [turn("x", model: "model", total: nil, output: nil)])], from: nil, to: now)
        XCTAssertNil(unknown[0].tokens)
        XCTAssertNil(unknown[0].output)
    }

    func testOverflowIsUnavailableAndSharedForkReceiptsAreNotSummedTwice() {
        let shared = turn("shared", model: "model", total: Int.max)
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [shared]), session("two", turns: [shared, turn("b", model: "model", total: 1)])], from: nil, to: now)
        XCTAssertEqual(rows[0].requests, 2)
        XCTAssertNil(rows[0].tokens)
        XCTAssertEqual(rows[0].tokenReceipts, 2)
    }

    func testSegmentsFitExactlyWithoutInflatingTinyShares() {
        let widths = ModelUsageReport.segmentWidths(counts: [99_998, 1, 1], width: 100)
        XCTAssertEqual(widths.reduce(0, +), 100, accuracy: 0.000_001)
        XCTAssertEqual(widths[1], 0.001, accuracy: 0.000_001)
        XCTAssertEqual(ModelUsageReport.segmentWidths(counts: [1, 0], width: 100), [100, 0])
        XCTAssertEqual(ModelUsageReport.segmentWidths(counts: [0, 0], width: 100), [0, 0])
        XCTAssertEqual(ModelUsageReport.segmentWidths(counts: [1], width: .infinity), [0])
    }

    func testProjectFilteredChildDoesNotInheritModelCreditFromKnownParent() {
        let inherited = turn("parent-work", model: "parent-model", total: 50)
        let own = turn("child-work", model: "child-model", total: 7)
        let parent = session("parent", turns: [inherited])
        var child = session("child", turns: [inherited, own])
        child.parentSessionID = parent.id
        child.projectPath = "/tmp/child-worktree"
        let rows = ModelUsageReport.build(sessions: [child], ownershipContext: [parent, child], from: nil, to: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "child-model")
        XCTAssertEqual(rows.first?.requests, 1)
        XCTAssertEqual(rows.first?.tokens, 7)
        XCTAssertEqual(rows.first?.sessions, 1)
    }

    func testLegacyCodexTurnsKeepUsageButNeverBecomeOneImpliedModelStep() throws {
        var legacy = turn("legacy", model: "gpt-6-astra", total: 100)
        legacy.modelSteps = nil; legacy.modelStepsComplete = nil
        let row = try XCTUnwrap(ModelUsageReport.build(sessions: [session("one", turns: [legacy])], from: nil, to: now).first)
        XCTAssertEqual(row.requests, 0)
        XCTAssertNil(row.requestCount)
        XCTAssertEqual(row.unmeasuredTurns, 1)
        XCTAssertEqual(row.nativeTurns, 1)
        XCTAssertTrue(row.requestsArePartial)
        XCTAssertNil(row.name, "Legacy pooled usage must not be assigned to the turn's last model")
        XCTAssertEqual(row.tokens, 100)
        XCTAssertEqual(row.usageRecords, 1)
        XCTAssertTrue(row.tokensArePartial)
        XCTAssertTrue(row.tokenCoverage.contains("1 of 1 usage records"))
        XCTAssertTrue(row.tokenCoverage.contains("incomplete model-step attribution"))
    }

    func testClaudeLegacyRequestsCountOnceButSyntheticPendingPromptsDoNot() {
        var response = turn("claude-request:response", model: "sonnet")
        response.modelSteps = nil; response.modelStepsComplete = nil
        let pending = ActivityTurn(id: "claude:session:pending-prompts", startedAt: now.addingTimeInterval(-5),
            status: "submission_observed", promptCount: 3, usage: TokenUsage())
        let rows = ModelUsageReport.build(sessions: [session("one", provider: .claude, turns: [response, response, pending])], from: nil, to: now)
        XCTAssertEqual(rows.first { $0.name == "sonnet" }?.requestCount, 1)
        XCTAssertNil(rows.first { $0.name == nil }?.requestCount)
        let summary = ModelUsageReport.summary(rows)
        XCTAssertEqual(summary.totalObservedSteps, 1)
        XCTAssertEqual(summary.unmeasuredTurns, 1)
        XCTAssertEqual(summary.nativeTurns, 2)
    }

    func testThreeStepsInOneTurnKeepAstraAndSolUsageSeparateAndIgnorePooledTotal() {
        var native = turn("native", model: "gpt-6.1-sol", seconds: 300, total: 60)
        native.usage = TokenUsage(total: 60, provenance: .providerReported)
        native.modelSteps = [
            step("one", model: "gpt-6-astra", total: 10),
            step("two", model: "gpt-6.1-sol", total: 20),
            step("three", model: "gpt-6.1-sol", total: 30),
        ]
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(rows.first { $0.name == "gpt-6-astra" }?.requests, 1)
        XCTAssertEqual(rows.first { $0.name == "gpt-6-astra" }?.tokens, 10)
        XCTAssertEqual(rows.first { $0.name == "gpt-6.1-sol" }?.requests, 2)
        XCTAssertEqual(rows.first { $0.name == "gpt-6.1-sol" }?.tokens, 50)
        XCTAssertEqual(rows.compactMap(\.tokens).reduce(0, +), 60)
        let summary = ModelUsageReport.summary(rows)
        XCTAssertEqual(summary.totalObservedSteps, 3)
        XCTAssertEqual(summary.nativeTurns, 1, "A multi-model native turn is not counted once per model in the summary")
        XCTAssertEqual(summary.unmeasuredTurns, 0)
    }

    func testStepTimestampsUseHalfOpenWindowAndDoNotBorrowNativeCompletion() {
        var native = turn("native", model: "last-model", seconds: 30, total: 999)
        native.modelSteps = [
            step("before", model: "outside", total: 100, seconds: -61),
            step("at-start", model: "gpt-6-astra", total: 5, seconds: -60),
            step("inside", model: "gpt-6.1-sol", total: 7, seconds: -1),
            step("at-end", model: "outside", total: 200, seconds: 0),
        ]
        native.usage = TokenUsage(total: 312, provenance: .providerReported)
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(Set(rows.compactMap(\.name)), ["gpt-6-astra", "gpt-6.1-sol"])
        XCTAssertEqual(ModelUsageReport.summary(rows).totalObservedSteps, 2)
        XCTAssertEqual(rows.compactMap(\.tokens).reduce(0, +), 12)
    }

    func testUndatedStepRemainsUnmeasuredInsteadOfUsingTurnDate() {
        var native = turn("native", model: "gpt-6-astra", total: 99)
        var undated = step("undated", model: "gpt-6.1-sol", total: 20); undated.timestamp = nil
        native.modelSteps = [undated]
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].name)
        XCTAssertNil(rows[0].requestCount)
        XCTAssertNil(rows[0].tokens, "Pooled native usage must not be added when step telemetry exists")
        XCTAssertEqual(ModelUsageReport.summary(rows).unmeasuredTurns, 1)
        let unbounded = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: nil, to: nil)
        XCTAssertEqual(unbounded.first?.name, "gpt-6.1-sol")
        XCTAssertEqual(unbounded.first?.requests, 1)
    }

    func testReplayedStepIDIsCountedOnceAndNewestExplicitZeroCorrectionWins() {
        var native = turn("native", model: "model")
        native.modelSteps = [step("same", model: "model", total: 10), step("same", model: "model", total: 0)]
        native.usage = TokenUsage(total: 0, provenance: .providerReported)
        let row = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: nil, to: now).first
        XCTAssertEqual(row?.requests, 1)
        XCTAssertEqual(row?.tokens, 0)
        XCTAssertFalse(row?.tokensArePartial ?? true)
    }

    func testStepOwnershipIsResolvedBeforeProjectFilteringEvenAcrossCopiedTurnIDs() {
        var parentTurn = turn("parent-native", model: "gpt-6-astra")
        parentTurn.modelSteps = [step("copied", model: "gpt-6-astra", total: 50)]
        var childTurn = turn("child-native", model: "gpt-6-astra")
        childTurn.modelSteps = [step("copied", model: "gpt-6-astra", total: 50), step("own", model: "gpt-6.1-sol", total: 7)]
        let parent = session("parent", turns: [parentTurn])
        var child = session("child", turns: [childTurn]); child.parentSessionID = parent.id
        let rows = ModelUsageReport.build(sessions: [child], ownershipContext: [child, parent], from: nil, to: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "gpt-6.1-sol")
        XCTAssertEqual(rows[0].requests, 1)
        XCTAssertEqual(rows[0].tokens, 7)
    }

    func testPartialReceiptsAndLegacyRecordsUseUsageRecordDenominatorNotStepCount() throws {
        var measured = turn("measured", model: "gpt-6-astra")
        measured.modelSteps = [step("one", model: "gpt-6-astra", total: 10), step("two", model: "gpt-6-astra", total: 20)]
        measured.modelStepsComplete = false
        var legacy = turn("legacy", model: "gpt-6-astra", total: 100)
        legacy.modelSteps = nil
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [measured, legacy])], from: nil, to: now)
        let row = try XCTUnwrap(rows.first { $0.name == "gpt-6-astra" })
        XCTAssertEqual(row.requests, 2)
        XCTAssertEqual(row.requestCount, 2)
        XCTAssertTrue(row.requestsArePartial)
        XCTAssertEqual(row.unmeasuredTurns, 0)
        XCTAssertEqual(row.nativeTurns, 1)
        XCTAssertEqual(row.usageRecords, 2)
        XCTAssertEqual(row.tokenReceipts, 2)
        XCTAssertEqual(row.tokens, 30)
        let unknown = try XCTUnwrap(rows.first { $0.name == nil })
        XCTAssertNil(unknown.requestCount)
        XCTAssertEqual(unknown.unmeasuredTurns, 1)
        XCTAssertEqual(unknown.tokens, 100)
        XCTAssertTrue(unknown.tokenCoverage.contains("1 of 1 usage records"))
        XCTAssertEqual(rows.compactMap(\.tokens).reduce(0, +), 130)
        XCTAssertEqual(ModelUsageReport.summary(rows).nativeTurns, 2)
    }

    func testConfirmedEmptyTelemetryIsMeasuredZeroButNilTelemetryIsUnknown() throws {
        var empty = turn("empty", model: "model", total: 0, output: 0)
        empty.modelSteps = []; empty.modelStepsComplete = true
        let row = try XCTUnwrap(ModelUsageReport.build(sessions: [session("one", turns: [empty])], from: nil, to: now).first)
        XCTAssertEqual(row.requestCount, 0)
        XCTAssertEqual(row.nativeTurns, 1)
        XCTAssertEqual(row.unmeasuredTurns, 0)
        XCTAssertNil(row.tokens)
        empty.modelStepsComplete = false
        let partial = try XCTUnwrap(ModelUsageReport.build(sessions: [session("one", turns: [empty])], from: nil, to: now).first)
        XCTAssertNil(partial.requestCount)
        XCTAssertEqual(partial.unmeasuredTurns, 1)
    }

    func testStepIdentityIsProviderScopedAndDoesNotGuessMissingModelFromTurnOrSession() {
        let shared = step("same-provider-local-id", model: "shared", total: 5)
        var claude = turn("claude-native", model: "shared"); claude.modelSteps = [shared]
        var codex = turn("codex-native", model: "shared"); codex.modelSteps = [shared]
        claude.usage = shared.usage; codex.usage = shared.usage
        let rows = ModelUsageReport.build(sessions: [session("claude", provider: .claude, turns: [claude]), session("codex", turns: [codex])], from: nil, to: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.requests), [1, 1])
        XCTAssertEqual(ModelUsageReport.summary(rows).totalObservedSteps, 2)
        var unknown = turn("unknown-native", model: "gpt-6-astra")
        unknown.modelSteps = [step("unknown-model", model: " ", total: 5)]
        var observed = session("unknown", turns: [unknown]); observed.models = ["gpt-6-astra", "gpt-6.1-sol"]
        let unattributed = ModelUsageReport.build(sessions: [observed], from: nil, to: now)
        XCTAssertNil(unattributed.first?.name, "A turn/session model list cannot identify an unnamed model-step receipt")
        XCTAssertEqual(unattributed.first?.requests, 1)
    }

    func testIndividualStepPartialUsageStillSurfacesWhenTurnIsComplete() throws {
        var native = turn("native", model: "gpt-6-astra")
        var partial = step("partial", model: "gpt-6-astra", total: 10); partial.usageIsPartial = true
        native.modelSteps = [partial]; native.modelStepsComplete = true
        let row = try XCTUnwrap(ModelUsageReport.build(sessions: [session("one", turns: [native])], from: nil, to: now).first)
        XCTAssertEqual(row.requestCount, 1)
        XCTAssertTrue(row.requestsArePartial)
        XCTAssertTrue(row.tokensArePartial)
        XCTAssertEqual(row.partialReceipts, 1)
    }

    func testManyObservedStepsRemainDistinctWithinOneNativeTurn() throws {
        var native = turn("long-native", model: "gpt-6-astra", total: 1_000)
        native.usage = TokenUsage(total: 1_000, provenance: .providerReported)
        native.modelSteps = (0..<1_000).map { step("step-\($0)", model: "gpt-6-astra", total: 1) }
        let row = try XCTUnwrap(ModelUsageReport.build(sessions: [session("one", turns: [native])], from: nil, to: now).first)
        XCTAssertEqual(row.requestCount, 1_000)
        XCTAssertEqual(row.tokens, 1_000)
        XCTAssertEqual(row.nativeTurns, 1)
        XCTAssertEqual(row.usageRecords, 1_000)
    }

    func testContainedPartialStepsConserveKnownNativeUsageInUnknownAllocationWithoutInventingCalls() throws {
        var native = turn("native", model: "last-context-model", total: 100)
        native.startedAt = now.addingTimeInterval(-50); native.completedAt = now.addingTimeInterval(-5)
        native.modelSteps = [step("known", model: "gpt-6-astra", total: 20)]
        native.modelStepsComplete = false; native.usageIsPartial = false
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        let known = try XCTUnwrap(rows.first { $0.name == "gpt-6-astra" })
        let unknown = try XCTUnwrap(rows.first { $0.name == nil })
        XCTAssertEqual(known.tokens, 20)
        XCTAssertEqual(unknown.tokens, 80)
        XCTAssertEqual(unknown.requests, 0)
        XCTAssertNil(unknown.requestCount)
        XCTAssertEqual(unknown.unmeasuredTurns, 1)
        XCTAssertEqual(rows.compactMap(\.tokens).reduce(0, +), 100)
        let summary = ModelUsageReport.summary(rows)
        XCTAssertEqual(summary.totalObservedSteps, 1)
        XCTAssertEqual(summary.nativeTurns, 1)
        XCTAssertEqual(summary.unallocatedTurns, 0)
    }

    func testCrossBoundaryRemainderIsMetadataNotADatedWindowTotal() throws {
        var native = turn("native", model: "gpt-6-astra", total: 100)
        native.startedAt = now.addingTimeInterval(-120); native.completedAt = now.addingTimeInterval(-5)
        native.modelSteps = [step("known", model: "gpt-6-astra", total: 20)]
        native.modelStepsComplete = false
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(rows.compactMap(\.tokens).reduce(0, +), 20)
        let unknown = try XCTUnwrap(rows.first { $0.name == nil })
        XCTAssertNil(unknown.tokens)
        XCTAssertNil(unknown.requestCount)
        let summary = ModelUsageReport.summary(rows)
        XCTAssertEqual(summary.unallocatedTokens, 80)
        XCTAssertEqual(summary.unallocatedTurns, 1)
        XCTAssertEqual(summary.unmeasuredTurns, 1)
        let all = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: nil, to: now)
        XCTAssertEqual(all.compactMap(\.tokens).reduce(0, +), 100)
        XCTAssertEqual(ModelUsageReport.summary(all).unallocatedTurns, 0)
    }

    func testOldOngoingLegacyTurnRemainsUnmeasuredWithoutDatingLifetimeUsageToday() throws {
        var native = turn("ongoing", model: "gpt-6-astra", total: 100)
        native.startedAt = now.addingTimeInterval(-86_400); native.completedAt = nil; native.status = "inProgress"
        native.modelSteps = nil; native.modelStepsComplete = nil
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        let unknown = try XCTUnwrap(rows.first)
        XCTAssertNil(unknown.name)
        XCTAssertNil(unknown.requestCount)
        XCTAssertNil(unknown.tokens)
        XCTAssertEqual(unknown.nativeTurns, 1)
        let summary = ModelUsageReport.summary(rows)
        XCTAssertEqual(summary.totalObservedSteps, 0)
        XCTAssertEqual(summary.unmeasuredTurns, 1)
        XCTAssertEqual(summary.unallocatedTokens, 100)
        XCTAssertEqual(summary.unallocatedTurns, 1)
    }

    func testFullyReconciledStepsDoNotAddNativePooledUsageAgain() {
        var native = turn("native", model: "last-context-model", total: 100)
        native.usage = TokenUsage(total: 100, provenance: .providerReported)
        native.startedAt = now.addingTimeInterval(-50); native.completedAt = now.addingTimeInterval(-5)
        native.modelSteps = [step("a", model: "gpt-6-astra", total: 20), step("b", model: "gpt-6.1-sol", total: 80)]
        native.modelStepsComplete = true
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap(\.tokens).reduce(0, +), 100)
        XCTAssertEqual(ModelUsageReport.summary(rows).totalObservedSteps, 2)
        XCTAssertEqual(ModelUsageReport.summary(rows).unallocatedTurns, 0)
    }

    func testRemainderSubtractsKnownStepsOutsideWindowInsteadOfAllocatingThemAgain() {
        var native = turn("native", model: "last-context-model", total: 100)
        native.usage = TokenUsage(total: 100, provenance: .providerReported)
        native.startedAt = now.addingTimeInterval(-120); native.completedAt = now.addingTimeInterval(-5)
        native.modelSteps = [step("outside", model: "gpt-6-astra", total: 80, seconds: -100),
                             step("inside", model: "gpt-6.1-sol", total: 20)]
        native.modelStepsComplete = false
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.tokens, 20)
        XCTAssertEqual(ModelUsageReport.summary(rows).unallocatedTurns, 0)
    }

    func testTailLimitedClaudeFallbackCountIsPartialButIndividualUsageIsNotChanged() throws {
        var native = turn("claude-request:one", model: "sonnet")
        native.modelSteps = nil; native.modelStepsComplete = nil; native.usageIsPartial = false
        var observed = session("one", provider: .claude, turns: [native]); observed.historyComplete = false
        let row = try XCTUnwrap(ModelUsageReport.build(sessions: [observed], from: nil, to: now).first)
        XCTAssertEqual(row.requestCount, 1)
        XCTAssertTrue(row.requestsArePartial)
        XCTAssertEqual(row.partialReceipts, 0, "A partial session history must not rewrite a complete per-request usage receipt")
        XCTAssertEqual(row.tokens, 10)
    }

    func testUnknownModelReceiptAndRemainderShareUsageButNotAnInventedStepCount() throws {
        var native = turn("native", model: "last-context-model", total: 100)
        native.startedAt = now.addingTimeInterval(-50); native.completedAt = now.addingTimeInterval(-5)
        native.modelSteps = [step("unnamed", model: nil, total: 20)]; native.modelStepsComplete = false
        let row = try XCTUnwrap(ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now).first)
        XCTAssertNil(row.name)
        XCTAssertEqual(row.requests, 1)
        XCTAssertEqual(row.tokens, 100)
        XCTAssertEqual(row.nativeTurns, 1)
    }

    func testUnknownUnplaceableNativeUsageStaysNilNotZero() throws {
        var native = ActivityTurn(id: "ongoing", startedAt: now.addingTimeInterval(-3_600), status: "inProgress")
        native.modelSteps = nil
        let rows = ModelUsageReport.build(sessions: [session("one", turns: [native])], from: now.addingTimeInterval(-60), to: now)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.tokens)
        XCTAssertNil(row.requestCount)
        XCTAssertNil(ModelUsageReport.summary(rows).unallocatedTokens)
        XCTAssertEqual(ModelUsageReport.summary(rows).unallocatedTurns, 1)
    }

    private func step(_ id: String, model: String?, total: Int?, seconds: Double = -10) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: now.addingTimeInterval(seconds), model: model, effort: "high",
            usage: TokenUsage(total: total, provenance: total == nil ? .unavailable : .providerReported), usageIsPartial: false)
    }
}
