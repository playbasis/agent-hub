@testable import BridgeCore
import Foundation
import XCTest

final class CodexCreditEstimatesTests: XCTestCase {
    private let base = ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z")!
    private func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    private func usage(input: Int? = 1_000_000, cached: Int? = 200_000, output: Int? = 100_000,
                       total: Int? = 1_100_000, reasoning: Int? = 80_000, writes: Int? = nil,
                       provenance: MetricProvenance = .providerReported) -> TokenUsage {
        TokenUsage(input: input, output: output, cachedInput: cached, cacheWriteInput: writes,
                   reasoning: reasoning, total: total, provenance: provenance)
    }
    private func step(_ id: String, model: String? = "gpt-6.1-sol", at: Double = 100,
                      effort: String? = nil, usage: TokenUsage? = nil, partial: Bool = false) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: date(at), model: model, effort: effort, usage: usage ?? self.usage(), usageIsPartial: partial)
    }
    private func turn(_ id: String, steps: [ActivityModelStep]?, start: Double = 0, end: Double = 1_000,
                      usage: TokenUsage = TokenUsage(), model: String? = nil) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: date(start), completedAt: date(end), status: "completed",
                     promptCount: 9_999, humanPromptCount: 7_777, toolCount: 3_333, model: model, usage: usage,
                     modelSteps: steps, modelStepsComplete: steps == nil ? nil : true)
    }
    private func session(_ id: String, provider: AgentName = .codex, project: String? = "/repo", parent: String? = nil,
                         turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: id, title: "Do not export this private prompt title",
                        projectPath: project, createdAt: date(-86_400), updatedAt: date(3_600), observedAt: date(3_600),
                        parentSessionID: parent, turns: turns, historyComplete: true, source: "fixture")
    }
    private func report(_ sessions: [ActivitySession], from: Double? = 0, to: Double = 3_600) -> ActivityAccounting.Report {
        let overview = ActivityOverview(generatedAt: date(3_600), sessions: sessions,
            sources: [ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: date(3_600), message: "Fixture")],
            accountUsage: ActivityAccountUsage(lifetimeTokens: 9_999_999_999))
        return ActivityAccounting.build(overview: overview, from: from.map(date), to: date(to))
    }
    private func estimate(_ step: ActivityModelStep) -> CodexCreditEstimates.Result {
        CodexCreditEstimates.build(report: report([session("s", turns: [turn("t", steps: [step])])]))
    }
    private func reasons(_ summary: CodexCreditEstimates.Summary) -> Set<CodexCreditEstimates.Reason> {
        Set(summary.reasons.map(\.reason))
    }

    func testExactOfficialCreditRateSnapshotAndOneMillionTokenComponents() {
        let expected: [(String, String, String, String, Double)] = [
            ("gpt-6-astra", "250", "25", "1250", 1525),
            ("gpt-6.1-sol", "50", "2.5", "250", 302.5),
            ("gpt-6.1-terra", "25", "1.25", "125", 151.25),
            ("gpt-6-sol", "50", "5", "250", 305),
            ("gpt-6-luna", "2.5", "0.25", "12.5", 15.25),
            ("gpt-5.6-sol", "100", "10", "500", 610),
            ("gpt-5.6-terra", "50", "5", "300", 355),
            ("gpt-5.6-luna", "5", "0.5", "30", 35.5),
        ]
        XCTAssertEqual(CodexCreditEstimates.catalog.rates.count, expected.count)
        for (model, inputRate, cachedRate, outputRate, amount) in expected {
            let rate = CodexCreditEstimates.catalog.rates.first { $0.model == model }
            XCTAssertEqual(rate?.freshInput, inputRate)
            XCTAssertEqual(rate?.cachedInput, cachedRate)
            XCTAssertEqual(rate?.output, outputRate)
            let result = estimate(step(model, model: model,
                usage: usage(input: 2_000_000, cached: 1_000_000, output: 1_000_000, total: 3_000_000)))
            XCTAssertEqual(result.total.estimatedCredits, amount, model)
            XCTAssertFalse(result.total.isPartial, model)
            XCTAssertEqual(result.total.coverage.completeReceiptCount, 1)
        }
    }

    func testCachedInputAndReasoningAreSubsetsNotExtraCharges() {
        let result = estimate(step("s"))
        // (1,000,000 − 200,000) × 50 + 200,000 × 2.5 + 100,000 × 250, per million.
        XCTAssertEqual(result.total.estimatedCredits, 65.5)
        XCTAssertEqual(result.total.estimatedCreditsExact, "65.5")
        XCTAssertEqual(result.total.coverage.observedModelSteps, 1)
        XCTAssertEqual(result.total.coverage.unknownSpeedReceiptCount, 1)
        let noReasoning = estimate(step("s", usage: usage(reasoning: nil)))
        XCTAssertEqual(result.total.estimatedCreditsExact, noReasoning.total.estimatedCreditsExact)
        XCTAssertFalse(noReasoning.total.isPartial, "A missing reasoning subset is not a missing billed component")
    }

    func testCacheWritesHaveNoIndependentCodexCharge() {
        let base = estimate(step("s"))
        let writes = estimate(step("s", usage: usage(writes: 50_000)))
        XCTAssertEqual(writes.total.estimatedCreditsExact, base.total.estimatedCreditsExact)
        XCTAssertEqual(writes.total.estimatedCredits, 65.5)
        XCTAssertFalse(writes.total.isPartial)
    }

    func testUltraEffortIsNotUltrafastAndNoEffortInfersASpeedMultiplier() {
        let base = estimate(step("s"))
        for effort in ["low", "high", "ultra", "xhigh", "fast", "ultrafast"] {
            let result = estimate(step("s", effort: effort))
            XCTAssertEqual(result.total.estimatedCreditsExact, base.total.estimatedCreditsExact, effort)
            XCTAssertEqual(result.basis, "standard_rate_equivalent")
            XCTAssertTrue(result.warnings.contains { $0.contains("not applied or inferred") })
        }
    }

    func testMissingCacheNeverBecomesZeroOrFullPriceInput() {
        let result = estimate(step("s", usage: usage(cached: nil)))
        XCTAssertEqual(result.total.estimatedCredits, 25, "Only the measured output is priceable")
        XCTAssertTrue(result.total.isPartial)
        XCTAssertTrue(reasons(result.total).contains(.missingCachedInput))
        XCTAssertEqual(result.total.coverage.freshInputReceipts, 0)
        XCTAssertEqual(result.total.coverage.cachedInputReceipts, 0)
        XCTAssertEqual(result.total.coverage.outputReceipts, 1)
        XCTAssertEqual(result.total.coverage.partialReceiptCount, 1)
    }

    func testMissingInputAndOutputKeepOnlyIndependentlyKnownComponents() {
        let noInput = estimate(step("s", usage: usage(input: nil)))
        XCTAssertEqual(noInput.total.estimatedCredits, 25.5, "Known cached subset and output are a partial subtotal")
        XCTAssertTrue(reasons(noInput.total).contains(.missingInput))
        XCTAssertTrue(noInput.total.isPartial)
        let noOutput = estimate(step("s", usage: usage(output: nil)))
        XCTAssertEqual(noOutput.total.estimatedCredits, 40.5)
        XCTAssertTrue(reasons(noOutput.total).contains(.missingOutput))
        XCTAssertTrue(noOutput.total.isPartial)
    }

    func testMissingTotalCannotClaimFullyReconciledCoverage() {
        let result = estimate(step("s", usage: usage(total: nil)))
        XCTAssertEqual(result.total.estimatedCredits, 65.5)
        XCTAssertTrue(result.total.isPartial)
        XCTAssertTrue(reasons(result.total).contains(.missingTotal))
        XCTAssertEqual(result.total.coverage.completeReceiptCount, 0)
    }

    func testUnknownAndUnsupportedModelsNeverInheritRates() {
        let unknown = estimate(step("s", model: nil))
        XCTAssertNil(unknown.total.estimatedCredits)
        XCTAssertNil(unknown.modelRows.first?.model)
        XCTAssertTrue(reasons(unknown.total).contains(.unknownModel))
        for model in ["gpt-6", "gpt-6-astra-latest", "gpt-6.1-sol-2026-11-05", "GPT-6.1-SOL", "gpt-6-sol-fast"] {
            let result = estimate(step("s", model: model))
            XCTAssertNil(result.total.estimatedCredits, model)
            XCTAssertEqual(result.modelRows.first?.model, model)
            XCTAssertTrue(reasons(result.total).contains(.unsupportedModel), model)
            XCTAssertEqual(result.total.coverage.unpricedReceiptCount, 1)
        }
    }

    func testEstimatedUnavailableAndNegativeUsageAreNotMeasuredZeroes() {
        for provenance in [MetricProvenance.estimated, .unavailable] {
            let result = estimate(step("s", usage: usage(provenance: provenance)))
            XCTAssertNil(result.total.estimatedCredits)
            XCTAssertTrue(reasons(result.total).contains(.nonAuthoritativeUsage))
            XCTAssertTrue(result.total.isPartial)
        }
        let negative = estimate(step("s", usage: usage(cached: -1)))
        XCTAssertEqual(negative.total.estimatedCredits, 25)
        XCTAssertTrue(negative.total.isPartial)
        XCTAssertTrue(reasons(negative.total).contains(.missingCachedInput))
        let derived = estimate(step("s", usage: usage(provenance: .derived)))
        XCTAssertEqual(derived.total.estimatedCredits, 65.5)
    }

    func testInconsistentCachedSubsetAndTotalNeverPriceAnInventedInputSplit() {
        let cachedTooLarge = estimate(step("s", usage: usage(cached: 2_000_000)))
        XCTAssertEqual(cachedTooLarge.total.estimatedCredits, 25)
        XCTAssertEqual(cachedTooLarge.total.coverage.freshInputReceipts, 0)
        XCTAssertEqual(cachedTooLarge.total.coverage.cachedInputReceipts, 0)
        XCTAssertTrue(reasons(cachedTooLarge.total).contains(.inconsistentUsage))
        let wrongTotal = estimate(step("s", usage: usage(total: 2_000_000)))
        XCTAssertEqual(wrongTotal.total.estimatedCredits, 25)
        XCTAssertTrue(wrongTotal.total.isPartial)
        XCTAssertTrue(reasons(wrongTotal.total).contains(.inconsistentUsage))
    }

    func testExplicitZeroIsDistinctFromUnknownAndRoundTripsAsNull() throws {
        let zero = estimate(step("s", usage: usage(input: 0, cached: 0, output: 0, total: 0, reasoning: 0)))
        XCTAssertEqual(zero.total.estimatedCredits, 0)
        XCTAssertEqual(zero.total.estimatedCreditsExact, "0")
        XCTAssertFalse(zero.total.isPartial)
        let unknown = estimate(step("s", usage: TokenUsage()))
        XCTAssertNil(unknown.total.estimatedCredits)
        XCTAssertTrue(unknown.total.isPartial)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: BridgeJSON.compactEncoder.encode(unknown)) as? [String: Any])
        let total = try XCTUnwrap(object["total"] as? [String: Any])
        XCTAssertTrue(total["estimatedCredits"] is NSNull)
        XCTAssertTrue(total["estimatedCreditsExact"] is NSNull)
        let catalog = try XCTUnwrap(object["catalog"] as? [String: Any])
        XCTAssertTrue(catalog["effectiveFrom"] is NSNull)
        XCTAssertTrue(catalog["validUntil"] is NSNull)
        let decoded = try BridgeJSON.decoder.decode(CodexCreditEstimates.Result.self, from: BridgeJSON.compactEncoder.encode(unknown))
        XCTAssertEqual(decoded, unknown)
    }

    func testThreeDimensionsReconcileWithoutAddingTablesOrDuplicatedChildHistory() {
        let parentTurn = turn("parent-native", steps: [step("parent-step")])
        let childTurn = turn("child-native", steps: [step("child-step", model: "gpt-6-luna", at: 500)])
        let claudeTurn = turn("claude-native", steps: [step("claude-step", model: "gpt-6-astra")])
        let accounting = report([
            session("parent", project: "/parent", turns: [parentTurn]),
            session("child", project: "/child", parent: "parent", turns: [parentTurn, childTurn]),
            session("claude", provider: .claude, project: "/claude", turns: [claudeTurn]),
        ])
        let result = CodexCreditEstimates.build(report: accounting)
        XCTAssertEqual(result.total.coverage.receiptCount, 2)
        XCTAssertEqual(result.total.coverage.observedModelSteps, 2)
        XCTAssertEqual(result.total.estimatedCredits, 68.8)
        XCTAssertEqual(result.modelRows.count, 2)
        XCTAssertEqual(result.projectRows.count, 2)
        XCTAssertEqual(result.sessionRows.count, 2)
        for rows in [result.modelRows, result.projectRows, result.sessionRows] {
            XCTAssertEqual(rows.compactMap(\.estimatedCredits).reduce(0, +), 68.8, accuracy: 0.000_000_01)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.coverage.observedModelSteps }, 2)
        }
        XCTAssertEqual(result.sessionRows.first { $0.sessionID == "child" }?.estimatedCredits, 3.3)
        XCTAssertEqual(result.projectRows.first { $0.projectPath == "/parent" }?.sessionIDs, ["parent"])
    }

    func testNativeAggregateRemainderDoesNotBorrowLastModelOrBecomeRequests() {
        let native = turn("legacy", steps: nil, usage: usage(), model: "gpt-6-astra")
        let result = CodexCreditEstimates.build(report: report([session("s", turns: [native])]))
        XCTAssertNil(result.total.estimatedCredits)
        XCTAssertTrue(reasons(result.total).contains(.unknownModel))
        XCTAssertEqual(result.total.coverage.observedModelSteps, 0)
        XCTAssertEqual(result.total.coverage.usageReceiptCount, 1)
        XCTAssertEqual(result.total.coverage.unpricedReceiptCount, 1)
    }

    func testStepPoolAndNativeTotalAreNotPricedTwice() {
        let recorded = step("one")
        let native = turn("native", steps: [recorded], usage: usage(), model: "gpt-6-astra")
        let result = CodexCreditEstimates.build(report: report([session("s", turns: [native])]))
        XCTAssertEqual(result.total.estimatedCredits, 65.5)
        XCTAssertEqual(result.total.coverage.receiptCount, 1)
        XCTAssertEqual(result.total.coverage.observedModelSteps, 1)
    }

    func testOffWindowEventsAndCrossingNativePoolsAreNeverMovedIntoTheWindow() {
        let dated = turn("wide", steps: [step("before", at: -1), step("start", at: 0), step("end", at: 3_600)], start: -100, end: 4_000)
        let crossing = turn("crossing", steps: nil, start: -100, end: 1_000, usage: usage(), model: "gpt-6-astra")
        let result = CodexCreditEstimates.build(report: report([session("s", turns: [dated, crossing])]))
        XCTAssertEqual(result.total.estimatedCredits, 65.5)
        XCTAssertEqual(result.total.coverage.observedModelSteps, 1)
        XCTAssertTrue(reasons(result.total).contains(.unplacedUsage))
        XCTAssertEqual(result.total.coverage.unpricedReceiptCount, 1)
        XCTAssertTrue(result.total.isPartial)
    }

    func testUndatedAndMalformedDecodedReceiptsCannotUseObservedAtForPricing() {
        var undated = step("undated")
        undated.timestamp = nil
        let noDate = estimate(undated)
        XCTAssertNil(noDate.total.estimatedCredits)
        XCTAssertTrue(noDate.total.isPartial)
        var accounting = report([session("s", turns: [turn("t", steps: [step("s")])])])
        accounting.receipts[0].timestamp = date(3_600)
        let offWindow = CodexCreditEstimates.build(report: accounting)
        XCTAssertNil(offWindow.total.estimatedCredits)
        XCTAssertTrue(reasons(offWindow.total).contains(.outsideAccountingWindow))
        accounting.receipts[0].timestamp = nil
        XCTAssertNil(CodexCreditEstimates.build(report: accounting).total.estimatedCredits)
    }

    func testPartialAndUnknownModelRowsRemainVisibleWithoutPoisoningKnownSubtotals() {
        let native = turn("t", steps: [step("known"), step("unknown", model: "future-model", at: 200),
                                       step("partial", at: 300, partial: true)])
        let result = CodexCreditEstimates.build(report: report([session("s", turns: [native])]))
        XCTAssertEqual(result.total.estimatedCredits, 131)
        XCTAssertTrue(result.total.isPartial)
        XCTAssertEqual(result.total.coverage.receiptCount, 3)
        XCTAssertEqual(result.total.coverage.pricedReceiptCount, 2)
        XCTAssertEqual(result.total.coverage.completeReceiptCount, 1)
        XCTAssertEqual(result.total.coverage.partialReceiptCount, 2)
        XCTAssertTrue(result.modelRows.first { $0.model == "future-model" }?.isPartial == true)
        XCTAssertNil(result.modelRows.first { $0.model == "future-model" }?.estimatedCredits)
    }

    func testEmptyAndInvalidReportsNeverCreateAccountWideOrZeroCharges() {
        let empty = CodexCreditEstimates.build(report: report([]))
        XCTAssertNil(empty.total.estimatedCredits)
        XCTAssertEqual(empty.total.coverage.receiptCount, 0)
        XCTAssertTrue(empty.modelRows.isEmpty)
        let invalid = CodexCreditEstimates.build(report: report([session("s", turns: [turn("t", steps: [step("s")])])], from: 100, to: 0))
        XCTAssertFalse(invalid.isValid)
        XCTAssertNil(invalid.total.estimatedCredits)
        XCTAssertTrue(reasons(invalid.total).contains(.invalidAccountingReport))
        var unsupported = report([session("s", turns: [turn("t", steps: [step("s")])])])
        unsupported.scope.source = .providerAccount
        let excluded = CodexCreditEstimates.build(report: unsupported)
        XCTAssertFalse(excluded.isValid)
        XCTAssertNil(excluded.total.estimatedCredits)
        XCTAssertTrue(reasons(excluded.total).contains(.unsupportedAccountingScope))
    }

    func testMissingProjectRemainsUnknownAndPrivateTitlesAreNotExported() throws {
        let result = CodexCreditEstimates.build(report: report([session("s", project: nil, turns: [turn("t", steps: [step("s")])])]))
        XCTAssertEqual(result.projectRows.count, 1)
        XCTAssertNil(result.projectRows[0].projectPath)
        XCTAssertEqual(result.projectRows[0].id, "unknown-project")
        let text = try XCTUnwrap(String(data: BridgeJSON.compactEncoder.encode(result), encoding: .utf8))
        XCTAssertFalse(text.contains("private prompt title"))
        XCTAssertFalse(text.contains("Do not export"))
    }

    func testExactDecimalSmallAmountsDoNotAccumulateBinaryRounding() {
        let tiny = usage(input: 1, cached: 0, output: 0, total: 1, reasoning: 0)
        let steps = (0..<10).map { step("s\($0)", model: "gpt-6.1-terra", at: Double(100 + $0), usage: tiny) }
        let result = CodexCreditEstimates.build(report: report([session("s", turns: [turn("t", steps: steps)])]))
        XCTAssertEqual(result.total.estimatedCreditsExact, "0.00025")
        XCTAssertEqual(result.total.estimatedCredits, 0.00025)
        XCTAssertEqual(result.total.coverage.observedModelSteps, 10)
        XCTAssertFalse(result.total.isPartial)
    }

    func testCreditArithmeticDoesNotUseOverflowingIntTokenTotals() {
        let enormous = usage(input: Int.max, cached: 0, output: 0, total: Int.max, reasoning: 0)
        let steps = [step("a", usage: enormous), step("b", at: 200, usage: enormous)]
        let accounting = report([session("s", turns: [turn("t", steps: steps)])])
        XCTAssertTrue(accounting.totals.usage.tokenOverflow)
        let result = CodexCreditEstimates.build(report: accounting)
        XCTAssertNotNil(result.total.estimatedCreditsExact)
        XCTAssertTrue(result.total.estimatedCredits?.isFinite == true)
        XCTAssertEqual(result.total.coverage.pricedReceiptCount, 2)
        XCTAssertEqual(result.total.coverage.completeReceiptCount, 2)
    }

    func testBoundedProjectionAndDuplicateDefenseAreExplicit() {
        var accounting = report([session("s", turns: [turn("t", steps: [step("a"), step("b", at: 200), step("c", at: 300)])])])
        let bounded = CodexCreditEstimates.build(report: accounting, maximumReceiptCount: 2)
        XCTAssertEqual(bounded.total.estimatedCredits, 131)
        XCTAssertEqual(bounded.total.coverage.receiptCount, 2)
        XCTAssertEqual(bounded.total.coverage.omittedReceiptCount, 1)
        XCTAssertTrue(bounded.total.isPartial)
        XCTAssertTrue(bounded.modelRows[0].isPartial)
        XCTAssertTrue(reasons(bounded.total).contains(.receiptLimit))
        accounting.receipts.append(accounting.receipts[0])
        let duplicate = CodexCreditEstimates.build(report: accounting)
        XCTAssertEqual(duplicate.total.estimatedCredits, 196.5)
        XCTAssertEqual(duplicate.total.coverage.receiptCount, 3)
        XCTAssertEqual(duplicate.total.coverage.omittedReceiptCount, 1)
        XCTAssertTrue(reasons(duplicate.total).contains(.duplicateReceiptOmitted))
    }

    func testSnapshotMetadataAndPastUsageClearlyRemainCurrentRateEquivalents() throws {
        let result = CodexCreditEstimates.build(report: report([session("s", turns: [turn("t", steps: [step("s", at: -100)], start: -200, end: 0)])], from: -1_000))
        XCTAssertEqual(result.catalog.id, "openai-codex-credit-token-rates/2026-11-05")
        XCTAssertEqual(result.catalog.rateAsOf, "2026-11-05")
        XCTAssertEqual(result.catalog.sourceURL, "https://developers.openai.com/codex/pricing#token-rates")
        XCTAssertEqual(result.catalog.unit, "credits_per_million_tokens")
        XCTAssertNil(result.catalog.effectiveFrom)
        XCTAssertNil(result.catalog.validUntil)
        XCTAssertEqual(result.catalog.rates.first { $0.model == "gpt-5.6-sol" }?.promotionAtLeastThrough, "2026-11-21")
        XCTAssertEqual(result.total.estimatedCredits, 65.5)
        XCTAssertEqual(result.provenance, .estimated)
        XCTAssertEqual(result.basis, "standard_rate_equivalent")
        XCTAssertTrue(result.warnings.contains { $0.contains("not a claim about historical rates") })
        XCTAssertTrue(result.warnings.contains { $0.contains("never scaled to a credit-balance decline") })
        let decoded = try BridgeJSON.decoder.decode(CodexCreditEstimates.Result.self, from: BridgeJSON.compactEncoder.encode(result))
        XCTAssertEqual(decoded, result)
    }
}
