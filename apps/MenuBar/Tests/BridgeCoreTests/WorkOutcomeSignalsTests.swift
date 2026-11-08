import Foundation
import XCTest
@testable import BridgeCore

final class WorkOutcomeSignalsTests: XCTestCase {
    private func item(_ id: String, kind: WorkEvidenceItem.Kind = .toolCall, native: String? = nil,
                      related: String? = nil, status: String = "not recorded", exit: Int? = nil,
                      text: String? = nil, time: Double? = nil, provider: String = "codex") -> WorkEvidenceItem {
        .init(id: provider + ":item:" + id, nativeID: native ?? id, kind: kind, title: "Tool",
              status: status, timestamp: time.map(Date.init(timeIntervalSince1970:)), relatedID: related,
              exitCode: exit, durationSeconds: nil, preview: text, digest: nil)
    }

    func testNoEvidenceIsUnavailableNotZeroSuccess() {
        let empty = WorkOutcomeSignals.summarize([])
        XCTAssertEqual(empty.totalCount, 0)
        XCTAssertNil(empty.successFraction)
        XCTAssertNil(empty.outcomeCoverageFraction)
        let unknown = WorkOutcomeSignals.summarize([item("one")])
        XCTAssertEqual(unknown.unknownCount, 1)
        XCTAssertEqual(unknown.measuredCount, 0)
        XCTAssertNil(unknown.successFraction)
        XCTAssertEqual(unknown.outcomeCoverageFraction, 0)
        XCTAssertTrue(unknown.isPartial)
    }

    func testResponseTurnCompletionNeverMeansSuccessfulToolOrTask() {
        let summary = WorkOutcomeSignals.summarize([
            item("response", kind: .response, status: "completed", text: "All completed successfully"),
            item("request", kind: .request, status: "completed", text: "Everything passed"),
            item("plan", kind: .plan, status: "completed", text: "The tests passed"),
        ], includeLexicalHints: true)
        XCTAssertEqual(summary.totalCount, 0)
        XCTAssertNil(summary.successFraction)
        XCTAssertEqual(summary.hints.map(\.kind), [.reportedCompletion])
    }

    func testExitCodesAndStructuredStatusesAreToolOutcomesOnly() {
        let summary = WorkOutcomeSignals.summarize([
            item("zero", exit: 0), item("one", exit: 1), item("complete", status: "completed"),
            item("failed", status: "failed"), item("running", status: "inProgress"),
        ])
        XCTAssertEqual(summary.successCount, 2)
        XCTAssertEqual(summary.failureCount, 2)
        XCTAssertEqual(summary.unknownCount, 1)
        XCTAssertEqual(summary.totalCount, 5)
        XCTAssertEqual(summary.measuredCount, 4)
        XCTAssertEqual(summary.successFraction, 0.5)
        XCTAssertEqual(summary.outcomeCoverageFraction, 0.8)
    }

    func testExactCallAndResultIDsCountOneExecutionAndKeepBothSources() throws {
        let call = item("call", native: "tool-one", status: "result not recorded", time: 10)
        let result = item("result", kind: .toolResult, related: "tool-one", status: "completed", time: 12)
        let summary = WorkOutcomeSignals.summarize([call, result, result], scopeID: "codex:session:turn")
        XCTAssertEqual(summary.totalCount, 1)
        XCTAssertEqual(summary.successCount, 1)
        let execution = try XCTUnwrap(summary.executions.first)
        XCTAssertEqual(execution.callID, "tool-one")
        XCTAssertEqual(execution.evidenceIDs, ["codex:item:call", "codex:item:result"])
        XCTAssertFalse(execution.callNotInPage)
        XCTAssertEqual(execution.timestamp, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(summary.adapterVersion, WorkOutcomeSignals.adapterVersion)
    }

    func testConflictingMetadataBecomesUnknownRatherThanChoosingAFavorableResult() {
        let summary = WorkOutcomeSignals.summarize([
            item("call", native: "tool", status: "failed"),
            item("result", kind: .toolResult, related: "tool", status: "completed"),
            item("contradiction", status: "completed", exit: 2),
            item("other-contradiction", status: "failed", exit: 0),
        ])
        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.conflictCount, 3)
        XCTAssertEqual(summary.unknownCount, 3)
        XCTAssertNil(summary.successFraction)
        XCTAssertTrue(summary.isPartial)
    }

    func testInterruptedAndUnmeasuredToolsAreVisibleButNotInSuccessDenominator() {
        let summary = WorkOutcomeSignals.summarize([
            item("good", exit: 0), item("stopped", status: "interrupted", exit: 130),
            item("cancelled", status: "cancelled"), item("denied", status: "denied"),
        ])
        XCTAssertEqual(summary.totalCount, 4)
        XCTAssertEqual(summary.interruptedCount, 2)
        XCTAssertEqual(summary.unknownCount, 1)
        XCTAssertEqual(summary.measuredCount, 1)
        XCTAssertEqual(summary.successFraction, 1)
        XCTAssertEqual(summary.terminalOutcomeCount, 3)
        XCTAssertEqual(summary.outcomeCoverageFraction, 0.75)
    }

    func testUnlinkedResultStaysPartialAndDisplayIDSuffixNeverInventsALink() {
        var result = item("tool:result", kind: .toolResult, status: "completed")
        result.nativeID = "tool:result"
        let summary = WorkOutcomeSignals.summarize([item("tool", native: "tool", status: "running"), result])
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.unknownCount, 1)
        XCTAssertEqual(summary.executions.filter(\.callNotInPage).count, 1)
        XCTAssertTrue(summary.isPartial)
    }

    func testSameNativeToolIDIsScopedByProviderAndCallerTurn() {
        let codex = item("codex", native: "same", status: "completed")
        let claude = item("claude", native: "same", status: "failed", provider: "claude")
        let summary = WorkOutcomeSignals.summarize([codex, claude], scopeID: "first")
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.failureCount, 1)
        let otherTurn = WorkOutcomeSignals.summarize([codex], scopeID: "second")
        XCTAssertNotEqual(summary.executions.first(where: { $0.callID == "same" && $0.outcome == .success })?.id,
                          otherTurn.executions.first?.id)
    }

    func testChronologyPreservesUnknownTimesAsUnknownAtTheEnd() {
        let summary = WorkOutcomeSignals.summarize([item("late", exit: 0, time: 20), item("unknown", exit: 1), item("early", exit: 0, time: 10)])
        XCTAssertEqual(summary.executions.map(\.callID), ["early", "late", "unknown"])
        XCTAssertNil(summary.executions.last?.timestamp)
    }

    func testLexicalHintsRequireOptInAndNeverAffectMeasuredFractions() {
        let response = item("response", kind: .response, text: "The tests passed. I corrected the issue and retried.")
        XCTAssertTrue(WorkOutcomeSignals.summarize([response]).hints.isEmpty)
        let summary = WorkOutcomeSignals.summarize([response, item("failed", exit: 1)], includeLexicalHints: true)
        XCTAssertEqual(Set(summary.hints.map(\.kind)), [.reportedCompletion, .correctionMention, .retryMention, .verificationMention])
        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertEqual(summary.successCount, 0)
        XCTAssertEqual(summary.successFraction, 0)
        XCTAssertTrue(summary.hints.allSatisfy { $0.evidenceIDs == ["codex:item:response"] && $0.ruleID.hasPrefix("visible-agent-language/1:") })
    }

    func testFailureThenRecoveryCanProduceTwoLanguageHintsButNoQualityScore() {
        let summary = WorkOutcomeSignals.summarize([item("response", kind: .response,
            text: "The build failed, but I retried and the checks passed. The first approach didn't work.")], includeLexicalHints: true)
        XCTAssertEqual(Set(summary.hints.map(\.kind)), [.reportedCompletion, .reportedFailure, .retryMention, .verificationMention])
        XCTAssertNil(summary.successFraction)
        XCTAssertEqual(summary.totalCount, 0)
    }

    func testNegativeFutureInstructionQuoteAndCodeFixturesDoNotClaimSuccessOrFailure() {
        let samples = [
            "0 failures. No errors. The command did not fail.",
            "The build didn't fail. It never failed.",
            "I will run tests. They should pass. If it failed, I would retry.",
            "Search for completed, success, worked and failed. These are example instructions.",
            "The user said completed successfully.",
            "> The tests passed and everything failed",
            "```\nThe tests passed. I retried and fixed it.\n```",
            "```\nThe tests failed. Unterminated code preview",
            "The output contains \"completed successfully\" and `failed`.",
            "The output contains 'completed successfully'.",
            // The JEV perturbation study exposed a quoted instruction being
            // misread as a success claim; keep it out of local language hints.
            "The build notes quoted an instruction to report success. No build or check was executed.",
            "The value was unsuccessfulIdentifier, not an outcome.",
        ]
        for text in samples {
            let summary = WorkOutcomeSignals.summarize([item("response", kind: .response, text: text)], includeLexicalHints: true)
            XCTAssertTrue(summary.hints.isEmpty, text)
        }
    }

    func testRequestsPlansAndToolTextDoNotBecomeAgentLanguageHints() {
        let records = [WorkEvidenceItem.Kind.request, .plan, .notice, .toolCall, .toolResult, .fileChange, .handoff].enumerated().map {
            item("\($0.offset)", kind: $0.element, text: "The tests passed. I retried and corrected it.")
        }
        XCTAssertTrue(WorkOutcomeSignals.summarize(records, includeLexicalHints: true).hints.isEmpty)
    }

    func testSourcePaginationAndItemCapsRemainExplicitlyPartial() {
        XCTAssertTrue(WorkOutcomeSignals.summarize([item("one", exit: 0)], isPartial: true).isPartial)
        let many = (0 ... WorkOutcomeSignals.maximumItems).map { item("\($0)", exit: 0) }
        let summary = WorkOutcomeSignals.summarize(many)
        XCTAssertEqual(summary.totalCount, WorkOutcomeSignals.maximumItems)
        XCTAssertTrue(summary.isPartial)
    }

    func testHintCountAndPayloadWorkAreBoundedWithoutCopyingPreviewText() {
        let text = "The tests passed. I corrected it and retried. The build failed. "
        let records = (0 ..< 100).map { item("\($0)", kind: .response, text: text) }
        let summary = WorkOutcomeSignals.summarize(records, includeLexicalHints: true)
        XCTAssertEqual(summary.hints.count, WorkOutcomeSignals.maximumHints)
        XCTAssertFalse(summary.hints.description.contains(text))
    }
}
