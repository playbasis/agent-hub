import BridgeCore
import Foundation
import XCTest

/// Exercises the exported consumer surface without @testable access. Every
/// identifier, date and quantity is synthetic; no account or native file is read.
final class ActivityAccountingPublicContractTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 978_307_200)

    func testPublicReportMatchesRequiredWireFieldsAndRoundTripsDeterministically() throws {
        let snapshot = fixture(measured: true)
        let report = ActivityAccounting.build(overview: snapshot, from: nil, to: snapshot.generatedAt)
        let encoded = try BridgeJSON.compactEncoder.encode(report)
        let decoded = try BridgeJSON.decoder.decode(ActivityAccounting.Report.self, from: encoded)
        XCTAssertEqual(try BridgeJSON.compactEncoder.encode(decoded), encoded)
        XCTAssertEqual(report.schemaVersion, "accounting/1")
        XCTAssertEqual(report.metricDefinitionsVersion, "activity-metrics/1")
        XCTAssertEqual(report.totals.tokensKnown, 7, "Cached input and reasoning subsets must not be added again")
        XCTAssertEqual(report.totals.outputKnown, 2)
        XCTAssertEqual(report.modelRows.first?.observedModelSteps, 1)
        XCTAssertEqual(report.modelRows.first?.observedStepCount, 1)
        XCTAssertEqual(report.modelRows.first?.key.model, "example-model")
        XCTAssertEqual(report.scope.source, .localNativeHistory)
        XCTAssertEqual(report.bySession()["example-session"]?.totals.tokensKnown, 7)
        XCTAssertEqual(report.projected(sessionIDs: ["example-session"]).summary, report.summary)

        let object = try json(encoded)
        let schema = try schemaDefinitions()
        try required(object, in: schema, named: "report")
        let scope = try XCTUnwrap(object["scope"] as? [String: Any]); try required(scope, in: schema, named: "scope")
        let totals = try XCTUnwrap(object["totals"] as? [String: Any]); try required(totals, in: schema, named: "totals")
        let usage = try XCTUnwrap(totals["usage"] as? [String: Any]); try required(usage, in: schema, named: "usageTotals")
        let summary = try XCTUnwrap(object["summary"] as? [String: Any]); try required(summary, in: schema, named: "summary")
        let row = try XCTUnwrap((object["modelRows"] as? [[String: Any]])?.first); try required(row, in: schema, named: "modelRow")
        let receipt = try XCTUnwrap((object["receipts"] as? [[String: Any]])?.first); try required(receipt, in: schema, named: "receipt")
        let native = try XCTUnwrap((object["nativeObservations"] as? [[String: Any]])?.first); try required(native, in: schema, named: "nativeObservation")
        let rawUsage = try XCTUnwrap(receipt["usage"] as? [String: Any]); try required(rawUsage, in: schema, named: "providerUsage")
        XCTAssertTrue(scope["from"] is NSNull)
        XCTAssertTrue(receipt["projectPath"] is NSNull)
        XCTAssertTrue(receipt["effort"] is NSNull)
        XCTAssertTrue(summary["unallocatedTokens"] is NSNull)
        XCTAssertEqual(usage["weightingVersion"] as? String, "fresh-input-equivalent/1")
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("Synthetic private title"))
        XCTAssertFalse(text.contains("Synthetic goal objective"))
    }

    func testUnknownMeasurementsAndCountsAreNullNotZeroInPublicDTOs() throws {
        let snapshot = fixture(measured: false)
        let report = ActivityAccounting.build(overview: snapshot, from: nil, to: snapshot.generatedAt)
        let object = try json(BridgeJSON.compactEncoder.encode(report))
        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        let usage = try XCTUnwrap(totals["usage"] as? [String: Any])
        let row = try XCTUnwrap((object["modelRows"] as? [[String: Any]])?.first)
        let key = try XCTUnwrap(row["key"] as? [String: Any])
        let receipt = try XCTUnwrap((object["receipts"] as? [[String: Any]])?.first)
        let native = try XCTUnwrap((object["nativeObservations"] as? [[String: Any]])?.first)
        let providerUsage = try XCTUnwrap(receipt["usage"] as? [String: Any])
        XCTAssertTrue(usage["tokensKnown"] is NSNull)
        XCTAssertTrue(usage["outputKnown"] is NSNull)
        XCTAssertTrue(usage["weightedEquivalent"] is NSNull)
        XCTAssertTrue(row["observedStepCount"] is NSNull)
        XCTAssertTrue(row["requestCount"] is NSNull, "Compatibility alias must preserve unknown semantics")
        XCTAssertTrue(row["shareOfObservedSteps"] is NSNull)
        XCTAssertTrue(row["tokens"] is NSNull)
        XCTAssertTrue(key["model"] is NSNull)
        XCTAssertTrue(receipt["model"] is NSNull)
        XCTAssertTrue(receipt["timestamp"] is NSNull, "Native interval usage cannot invent a provider-event date")
        for field in ["input", "output", "cached_input", "cache_write_input", "reasoning", "total"] {
            XCTAssertTrue(providerUsage[field] is NSNull, field)
        }
        for field in ["submittedPrompts", "confirmedHumanPrompts", "toolCalls"] {
            XCTAssertTrue(totals[field] is NSNull, field)
            XCTAssertTrue(native[field] is NSNull, field)
        }
        XCTAssertNil(report.modelRows.first?.observedStepCount)
        XCTAssertEqual(report.modelRows.first?.observedModelSteps, 0, "Only an observed coordinate, never an implied count of API attempts")
        XCTAssertTrue(report.modelRows.first?.stepsArePartial == true)
    }

    func testMalformedNegativeUsageBecomesPartialNullWithoutChangingNativeEvidence() throws {
        var snapshot = fixture(measured: true)
        let invalid = TokenUsage(input: -1, output: -2, cachedInput: -3, cacheWriteInput: -4,
            reasoning: -5, total: -6, provenance: .providerReported)
        snapshot.sessions[0].turns[0].usage = invalid
        snapshot.sessions[0].turns[0].modelSteps?[0].usage = invalid
        let report = ActivityAccounting.build(overview: snapshot, from: nil, to: snapshot.generatedAt)
        let receipt = try XCTUnwrap(report.receipts.first { $0.kind == .modelStep })
        XCTAssertTrue(receipt.usageIsPartial == true)
        XCTAssertNil(report.totals.tokensKnown)
        XCTAssertTrue(report.totals.tokensArePartial)
        let object = try json(BridgeJSON.compactEncoder.encode(receipt))
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        for field in ["input", "output", "cached_input", "cache_write_input", "reasoning", "total"] {
            XCTAssertTrue(usage[field] is NSNull, field)
        }
        XCTAssertEqual(snapshot.sessions[0].turns[0].usage.total, -6, "Normalization never rewrites native evidence")
        XCTAssertEqual(snapshot.sessions[0].turns[0].modelSteps?[0].usage.output, -2)
    }

    func testMetricDefinitionsKeepAccountPlanGoalAndDirectScopesDistinct() throws {
        XCTAssertEqual(ActivityMetricDefinitions.version, "activity-metrics/1")
        XCTAssertEqual(ActivityMetricDefinitions.definition("local.tokens")?.scope, .localNativeHistory)
        XCTAssertEqual(ActivityMetricDefinitions.definition("provider.account_tokens")?.scope, .providerAccount)
        XCTAssertEqual(ActivityMetricDefinitions.definition("provider.goal_tokens")?.scope, .nativeGoal)
        XCTAssertEqual(ActivityMetricDefinitions.definition("provider.plan_usage")?.scope, .providerPlanWindow)
        XCTAssertEqual(ActivityMetricScope.directProviderResponse.rawValue, "direct_provider_response")
        var snapshot = fixture(measured: true)
        snapshot.accountUsage = ActivityAccountUsage(lifetimeTokens: 900)
        snapshot.sessions[0].goal?.tokensUsed = 800
        let report = ActivityAccounting.build(overview: snapshot, from: nil, to: snapshot.generatedAt)
        XCTAssertEqual(report.totals.tokensKnown, 7, "Separate provider counters must never be inferred into the local ledger")
        let definitions = try schemaDefinitions()
        let scope = try XCTUnwrap(definitions["metricScope"] as? [String: Any])
        let cases = try XCTUnwrap(scope["enum"] as? [String])
        XCTAssertTrue(cases.contains("direct_provider_response"))
        XCTAssertTrue(cases.contains("provider_account"))
        XCTAssertTrue(cases.contains("provider_plan_window"))
        XCTAssertTrue(cases.contains("native_goal"))
    }

    func testPublicModelAccountingUsesWireMillisecondPrecisionBeforeBoundaryDecisions() throws {
        var snapshot = fixture(measured: true)
        let raw = base.addingTimeInterval(10.0004)
        snapshot.sessions[0].turns[0].modelSteps?[0].timestamp = raw
        let boundary = try XCTUnwrap(ActivityAccountingPrecision.date(raw))
        let direct = ActivityModelAccounting.inspect(sessions: snapshot.sessions, from: boundary.addingTimeInterval(-1), to: boundary)
        let exported = try BridgeJSON.compactEncoder.encode(snapshot.sessions)
        let imported = try BridgeJSON.decoder.decode([ActivitySession].self, from: exported)
        let replay = ActivityModelAccounting.inspect(sessions: imported, from: boundary.addingTimeInterval(-1), to: boundary)
        XCTAssertEqual(direct, replay)
        XCTAssertEqual(direct.summary.totalObservedSteps, 0, "A checkpoint on the serialized exclusive end stays outside both app and API decisions")
        XCTAssertEqual(ActivityAccountingPrecision.timestampPrecision, "millisecond")
        let invalid = ActivityModelAccounting.inspect(sessions: snapshot.sessions,
            from: Date(timeIntervalSinceReferenceDate: .nan), to: base.addingTimeInterval(30))
        XCTAssertTrue(invalid.receipts.isEmpty, "An invalid lower bound cannot silently become an all-history request")
    }

    private func fixture(measured: Bool) -> ActivityOverview {
        let usage = measured ? TokenUsage(input: 5, output: 2, cachedInput: 3, cacheWriteInput: 0, reasoning: 1, total: 7, provenance: .providerReported) : TokenUsage()
        let steps: [ActivityModelStep]? = measured ? [ActivityModelStep(id: "example-step", timestamp: base.addingTimeInterval(10), model: "example-model", usage: usage, evidence: "synthetic-contract-example/1", usageIsPartial: false)] : nil
        let native = ActivityTurn(id: "example-native-record", startedAt: base, completedAt: base.addingTimeInterval(20), status: "completed",
            model: "example-configured-model", usage: usage, usageIsPartial: measured ? false : nil, modelSteps: steps, modelStepsComplete: measured ? true : nil)
        let session = ActivitySession(id: "example-session", provider: .codex, nativeID: "example-session", title: "Synthetic private title",
            createdAt: base, updatedAt: base.addingTimeInterval(30), observedAt: base.addingTimeInterval(30),
            goal: ActivityGoal(id: "example-goal", sessionID: "example-session", objective: "Synthetic goal objective", status: "active", createdAt: base, updatedAt: base),
            turns: [native], historyComplete: true, source: "synthetic-contract-fixture")
        return ActivityOverview(generatedAt: base.addingTimeInterval(30), sessions: [session], sources: [ActivitySourceHealth(id: "example-source", status: "ready", checkedAt: base.addingTimeInterval(30), message: "Synthetic contract fixture")])
    }
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func schemaDefinitions() throws -> [String: Any] {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
        let source = try Data(contentsOf: root.appendingPathComponent("schemas/accounting-v1.schema.json"))
        return try XCTUnwrap(try json(source)["$defs"] as? [String: Any])
    }
    private func required(_ object: [String: Any], in definitions: [String: Any], named name: String) throws {
        let definition = try XCTUnwrap(definitions[name] as? [String: Any])
        let required = try XCTUnwrap(definition["required"] as? [String])
        for field in required { XCTAssertNotNil(object[field], "\(name).\(field) missing from public encoder") }
    }
}
