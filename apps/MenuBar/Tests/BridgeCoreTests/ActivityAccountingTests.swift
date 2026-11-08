@testable import BridgeCore
import Foundation
import XCTest

final class ActivityAccountingTests: XCTestCase {
    private let base = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    private func usage(_ total: Int?, output: Int? = 0, cached: Int? = 0, input: Int? = nil) -> TokenUsage {
        TokenUsage(input: input ?? total, output: output, cachedInput: cached, cacheWriteInput: 0, reasoning: 0, total: total,
                   provenance: total == nil ? .unavailable : .providerReported)
    }
    private func step(_ id: String, at seconds: Double, model: String = "gpt-6-astra", total: Int? = 10) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: date(seconds), model: model, usage: usage(total), usageIsPartial: false)
    }
    private func turn(_ id: String, start: Double, end: Double?, steps: [ActivityModelStep]?, total: Int? = nil) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: date(start), completedAt: end.map(date), status: end == nil ? "running" : "completed",
                     promptCount: 2, humanPromptCount: 1, toolCount: 3, usage: usage(total), categories: ["tests": 3],
                     artifacts: [ActivityArtifact(id: id + ":file", path: "/repo/result.swift")],
                     modelSteps: steps, modelStepsComplete: steps == nil ? nil : true)
    }
    private func session(_ id: String, provider: AgentName = .codex, project: String? = "/repo", parent: String? = nil, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: id, title: id, projectPath: project,
                        createdAt: date(-86_400), updatedAt: date(10_000), observedAt: date(10_000),
                        parentSessionID: parent, turns: turns, historyComplete: true, source: "fixture")
    }
    private func overview(_ sessions: [ActivitySession]) -> ActivityOverview {
        ActivityOverview(generatedAt: date(14_400), sessions: sessions,
                         sources: [ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: date(14_400), message: "Fixture")])
    }

    func testOneReceiptLedgerReconcilesModelsTotalsAndExactHourlyBins() throws {
        let a = step("a", at: 60, total: 10), b = step("b", at: 3_660, model: "gpt-6.1-sol", total: 20)
        let native = turn("native", start: -3_600, end: 14_400, steps: [a, b], total: 30)
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(10_800))
        XCTAssertEqual(report.schemaVersion, "accounting/1")
        XCTAssertEqual(report.totals.observedModelSteps, 2)
        XCTAssertEqual(report.totals.nativeRecords, 1)
        XCTAssertEqual(report.totals.tokensKnown, 30)
        XCTAssertEqual(ActivityMetrics.knownTotal(report.modelRows.map(\.tokens)), report.totals.tokensKnown)
        let series = report.series(granularity: .hour, timeZone: utc)
        XCTAssertEqual(series.points.count, 3)
        XCTAssertEqual(series.points.map(\.modelStepCount), [1, 1, 0])
        XCTAssertEqual(series.points.map(\.tokensKnown), [10, 20, nil])
        XCTAssertEqual(ActivityMetrics.knownTotal(series.points.map(\.tokensKnown) + [series.unallocated.tokensKnown]), report.totals.tokensKnown)
        XCTAssertEqual(series.points.reduce(0) { $0 + $1.modelStepCount } + series.unallocated.modelStepCount, report.totals.observedModelSteps)
        XCTAssertEqual(Set(series.points.flatMap(\.nativeRecordIDs)).count, report.totals.nativeRecords)
        XCTAssertGreaterThan(series.points.reduce(0) { $0 + $1.nativeRecords }, report.totals.nativeRecords, "native participation is a union, not an additive request count")
    }

    func testPartialEdgeWindowsAreHalfOpenAndDoNotAllocateEventsAtTheEnd() {
        let native = turn("n", start: 0, end: 100_000, steps: [step("before", at: 1_799), step("start", at: 1_800),
            step("last", at: 88_199), step("end", at: 88_200)], total: 40)
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(1_800), to: date(88_200))
        let series = report.series(granularity: .hour, timeZone: utc)
        XCTAssertEqual(report.totals.observedModelSteps, 2)
        XCTAssertEqual(report.totals.tokensKnown, 20)
        XCTAssertEqual(series.points.count, 25)
        XCTAssertEqual(series.points.first?.windowStart, date(1_800))
        XCTAssertEqual(series.points.last?.end, date(88_200))
        XCTAssertEqual(ActivityMetrics.knownTotal(series.points.map(\.tokensKnown)), 20)
    }

    func testWholeWindowNativeRemainderStaysUnallocatedAcrossSmallerBuckets() throws {
        let native = turn("legacy", start: 4_200, end: 10_200, steps: nil, total: 50)
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(14_400))
        XCTAssertEqual(report.totals.observedModelSteps, 0)
        XCTAssertEqual(report.totals.tokensKnown, 50)
        let hourly = report.series(granularity: .hour, timeZone: utc)
        XCTAssertTrue(hourly.points.allSatisfy { $0.tokensKnown == nil })
        XCTAssertEqual(hourly.unallocated.tokensKnown, 50)
        XCTAssertEqual(hourly.unallocatedByProvider["codex"]?.tokensKnown, 50)
        let daily = report.series(granularity: .day, timeZone: utc)
        XCTAssertEqual(daily.points.first?.tokensKnown, 50)
        XCTAssertNil(daily.unallocated.tokensKnown)
        let decoded = try BridgeJSON.decoder.decode(ActivityAccounting.Report.self, from: BridgeJSON.compactEncoder.encode(report))
        XCTAssertEqual(decoded.series(granularity: .hour, timeZone: utc).unallocated.tokensKnown, 50)
    }

    func testCrossingLegacyPoolIsNotDatedByItsCompletionAndRetainsItsEvidence() {
        let native = turn("legacy", start: -86_400, end: 3_600, steps: nil, total: 100)
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(7_200))
        XCTAssertNil(report.totals.tokensKnown)
        XCTAssertEqual(report.summary.unallocatedTokens, 100)
        XCTAssertEqual(report.totals.nativeRecords, 1)
        XCTAssertEqual(report.totals.activeSeconds, 3_600)
        XCTAssertTrue(report.receipts.contains { $0.kind == .unplacedNativeUsage && $0.usage.total == 100 && !$0.includedInTotals })
        XCTAssertTrue(report.series(granularity: .hour, timeZone: utc).points.allSatisfy { $0.tokensKnown == nil })
    }

    func testNativeCountersAndArtifactsRequireWholeNativeIntervalsNotJustAFinishDate() {
        let native = turn("wide", start: -3_600, end: 1_800, steps: [step("one", at: 600)], total: 10)
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(3_600))
        XCTAssertNil(report.totals.submittedPrompts)
        XCTAssertNil(report.totals.toolCalls)
        XCTAssertEqual(report.totals.unallocatedNativeCounters.submittedPrompts, 2)
        XCTAssertEqual(report.totals.unallocatedNativeCounters.toolCalls, 3)
        XCTAssertTrue(report.totals.nativeCountersArePartial)
        XCTAssertTrue(report.categoryMix.isEmpty)
        XCTAssertTrue(report.artifacts.isEmpty)
        XCTAssertFalse(report.nativeObservations[0].countersIncludedInWindow)
        let atEnd = turn("boundary", start: 0, end: 3_600, steps: [step("one", at: 600)], total: 10)
        let boundary = ActivityAccounting.build(overview: overview([session("s", turns: [atEnd])]), from: date(0), to: date(3_600))
        XCTAssertNil(boundary.totals.toolCalls, "a whole-record counter may contain an event at the exclusive ending boundary")
        XCTAssertEqual(boundary.totals.unallocatedNativeCounters.toolCalls, 3)
    }

    func testAgentTimeUnionsRequestsWithinOneSessionAndThenSumsDistinctSessions() {
        let a = turn("a", start: 0, end: 3_600, steps: [step("a-step", at: 100)], total: 10)
        let b = turn("b", start: 0, end: 3_600, steps: [step("b-step", at: 200)], total: 10)
        let one = ActivityAccounting.build(overview: overview([session("one", turns: [a, b])]), from: date(0), to: date(4_000))
        XCTAssertEqual(one.totals.activeSeconds, 3_600)
        XCTAssertEqual(one.totals.agentSeconds, 3_600)
        XCTAssertEqual(one.sessionWorkSeconds["one"], 3_600)
        let two = ActivityAccounting.build(overview: overview([session("one", turns: [a, b]), session("two", turns: [turn("c", start: 0, end: 3_600, steps: [step("c-step", at: 300)], total: 10)])]), from: date(0), to: date(4_000))
        XCTAssertEqual(two.totals.activeSeconds, 3_600)
        XCTAssertEqual(two.totals.agentSeconds, 7_200)
        XCTAssertEqual(two.totals.timedSessions, 2)
        XCTAssertEqual(two.totals.medianSessionSeconds, 3_600)
        XCTAssertEqual(two.series(granularity: .hour, timeZone: utc).points.first?.averageAgents, 2)
    }

    func testModelProviderAndProjectSubtotalsReconcileWithoutCreditingCopiedChildHistory() {
        let shared = turn("parent-native", start: 0, end: 600, steps: [step("shared", at: 100, total: 20)], total: 20)
        let childOwn = turn("child-native", start: 600, end: 1_200, steps: [step("child", at: 700, model: "gpt-6.1-sol", total: 5)], total: 5)
        let claude = turn("claude-native", start: 1_200, end: 1_800, steps: [step("claude", at: 1_300, model: "claude-sonnet-5", total: 7)], total: 7)
        let snapshot = overview([session("parent", project: "/p", turns: [shared]),
                                 session("child", project: "/c", parent: "parent", turns: [shared, childOwn]),
                                 session("claude", provider: .claude, project: "/other", turns: [claude])])
        let all = ActivityAccounting.build(overview: snapshot, from: date(0), to: date(3_600))
        let child = ActivityAccounting.build(overview: snapshot, sessionIDs: ["child"], from: date(0), to: date(3_600))
        XCTAssertEqual(child.totals.tokensKnown, 5)
        XCTAssertEqual(child.totals.observedModelSteps, 1)
        let sums = snapshot.sessions.map { ActivityAccounting.build(overview: snapshot, sessionIDs: [$0.id], from: date(0), to: date(3_600)).totals.tokensKnown }
        XCTAssertEqual(ActivityMetrics.knownTotal(sums), all.totals.tokensKnown)
        XCTAssertEqual(all.totals.tokensKnown, 32)
        XCTAssertEqual(ActivityMetrics.knownTotal(all.modelRows.map(\.tokens)), 32)
        let provider = Dictionary(grouping: all.receipts.filter(\.includedInTotals), by: \.provider).mapValues { ActivityMetrics.knownTotal($0.map(\.usage.total)) }
        XCTAssertEqual(provider[.codex]!, 25)
        XCTAssertEqual(provider[.claude]!, 7)
    }

    func testReportedZeroUnknownAndOverflowAreNotConfusedAndJSONUsesNull() throws {
        let zero = turn("zero", start: 0, end: 100, steps: [step("zero-step", at: 50, total: 0)], total: 0)
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [zero])]), from: date(0), to: date(7_200))
        XCTAssertEqual(report.totals.tokensKnown, 0)
        XCTAssertEqual(report.series(granularity: .hour, timeZone: utc).points.map(\.tokensKnown), [0, nil])
        let missing = turn("missing", start: 0, end: 100, steps: [step("unknown", at: 50, total: nil)])
        let unknown = ActivityAccounting.build(overview: overview([session("s", turns: [missing])]), from: date(0), to: date(3_600))
        XCTAssertNil(unknown.totals.tokensKnown)
        let encoded = try BridgeJSON.compactEncoder.encode(unknown.totals.usage)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(object["tokensKnown"] is NSNull)
        XCTAssertTrue(object["weightedEquivalent"] is NSNull)
        let enormous = turn("huge", start: 0, end: 100, steps: [step("max", at: 50, total: Int.max), step("extra", at: 60, total: 1)])
        let overflow = ActivityAccounting.build(overview: overview([session("s", turns: [enormous])]), from: date(0), to: date(3_600))
        XCTAssertNil(overflow.totals.tokensKnown)
        XCTAssertTrue(overflow.totals.usage.tokenOverflow)
        XCTAssertNil(overflow.totals.weightedEquivalent)
    }

    func testCachedAndReasoningSubsetsAreNeverAddedAgainAndWeightsRequireAReconciledSplit() {
        let measured = TokenUsage(input: 100, output: 5, cachedInput: 80, cacheWriteInput: 0, reasoning: 3, total: 105, provenance: .providerReported)
        let observed = ActivityModelStep(id: "cached", timestamp: date(100), model: "gpt-6-astra", usage: measured, usageIsPartial: false)
        let native = turn("n", start: 0, end: 200, steps: [observed], total: 105)
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(3_600))
        XCTAssertEqual(report.totals.tokensKnown, 105)
        XCTAssertEqual(report.totals.outputKnown, 5)
        XCTAssertEqual(report.totals.composition?.freshInput, 20)
        XCTAssertEqual(report.totals.composition?.rereadContext, 80)
        XCTAssertEqual(report.totals.weightedEquivalent, 53)
        var invalid = observed
        invalid.usage.cachedInput = 1_000
        let corrupt = ActivityAccounting.build(overview: overview([session("s", turns: [turn("n", start: 0, end: 200, steps: [invalid], total: 105)])]), from: date(0), to: date(3_600))
        XCTAssertEqual(corrupt.totals.tokensKnown, 105)
        XCTAssertNil(corrupt.totals.weightedEquivalent)
    }

    func testDecodedInvalidBreakdownCannotOverflowComputedTotalsOrWeights() throws {
        let breakdown = ActivityAccounting.Breakdown(freshInput: Int.max, rereadContext: 1, cacheWrites: 0, output: 0, receipts: 1, isComplete: true)
        XCTAssertNil(breakdown.total)
        let report = ActivityAccounting.build(overview: overview([]), from: date(0), to: date(3_600))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BridgeJSON.compactEncoder.encode(report.totals.usage)) as? [String: Any])
        object["composition"] = try JSONSerialization.jsonObject(with: BridgeJSON.compactEncoder.encode(breakdown))
        object["weightedEquivalent"] = Double.greatestFiniteMagnitude
        let decoded = try BridgeJSON.decoder.decode(ActivityAccounting.UsageTotals.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.weightedEquivalent)
    }

    func testAccountGoalAndQuotaCountersAreNotAddedAndInvalidWindowIsExplicit() {
        var onlyGoal = session("goal", turns: [])
        onlyGoal.goal = ActivityGoal(id: "goal", sessionID: "goal", objective: "Continue", status: "active", createdAt: date(-100), updatedAt: date(0), tokensUsed: 999_999)
        var snapshot = overview([onlyGoal])
        snapshot.accountUsage = ActivityAccountUsage(lifetimeTokens: 9_999_999, daily: [.init(date: "2026-11-03", tokens: 9_999_999)])
        let report = ActivityAccounting.build(overview: snapshot, from: date(0), to: date(3_600))
        XCTAssertNil(report.totals.tokensKnown)
        XCTAssertEqual(report.totals.observedModelSteps, 0)
        XCTAssertEqual(report.totals.sessions, 1)
        let invalid = ActivityAccounting.build(overview: snapshot, from: date(3_600), to: date(0))
        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(invalid.warnings.isEmpty)
        XCTAssertTrue(invalid.series(granularity: .hour).points.isEmpty)
    }

    func testDailyBriefUsesCanonicalStepDatesAndKnownTotalsInsteadOfTurnCompletionPool() throws {
        let native = turn("wide", start: -3_600, end: 14_400, steps: [step("in-day", at: 100, model: "gpt-6.1-sol", total: 20)], total: 20)
        let snapshot = overview([session("s", turns: [native])])
        let report = ActivityAccounting.build(overview: snapshot, from: date(0), to: date(7_200))
        let brief = try ActivityJournalBuilder.build(snapshot: snapshot, now: date(7_200), timezone: utc)
        XCTAssertEqual(report.totals.tokensKnown, 20)
        XCTAssertTrue(brief.markdown.contains("Recorded tokens"))
        XCTAssertTrue(brief.markdown.contains("20; 1 of 1 normalized usage records"))
        XCTAssertTrue(brief.markdown.contains("Observed model steps: 1"))
        XCTAssertTrue(brief.markdown.contains("gpt\\-6\\.1\\-sol"))
        XCTAssertEqual(ActivityJournalBuilder.formatVersion, "daily-brief/3")
    }

    func testAlreadyCanonicalSessionAndProjectProjectionsReconcileWithoutRenormalizingOwnership() {
        let parentWork = turn("p", start: 0, end: 100, steps: [step("p-step", at: 50, total: 10)], total: 10)
        let childWork = turn("c", start: 100, end: 200, steps: [step("c-step", at: 150, total: 20)], total: 20)
        let snapshot = overview([session("parent", project: "/p", turns: [parentWork]),
                                 session("child", project: "/c", parent: "parent", turns: [parentWork, childWork])])
        let report = ActivityAccounting.build(overview: snapshot, from: date(0), to: date(3_600))
        let child = report.projected(sessionIDs: ["child"])
        let bySession = report.bySession()
        let byProject = report.byProject()
        XCTAssertEqual(child.totals.tokensKnown, 20)
        XCTAssertEqual(child.totals.tokensKnown, bySession["child"]?.totals.tokensKnown)
        XCTAssertEqual(child.receipts, bySession["child"]?.receipts)
        XCTAssertEqual(child.totals.tokensKnown, byProject["/c"]?.totals.tokensKnown)
        XCTAssertEqual(ActivityMetrics.knownTotal(bySession.values.map { $0.totals.tokensKnown }), report.totals.tokensKnown)
        XCTAssertEqual(ActivityMetrics.knownTotal(byProject.values.map { $0.totals.tokensKnown }), report.totals.tokensKnown)
        XCTAssertEqual(child.scope.asOf, report.scope.asOf)
    }

    func testOpenGoalWithoutDatedWorkIsPreservedAsUnallocatedSessionNotFakeActivity() {
        var goal = session("goal", project: "/p", turns: [])
        goal.goal = ActivityGoal(id: "g", sessionID: goal.id, objective: "Continue", status: "active", createdAt: date(-100), updatedAt: date(0))
        let report = ActivityAccounting.build(overview: overview([goal]), from: date(0), to: date(3_600))
        XCTAssertEqual(report.openGoalSessionIDs, [goal.id])
        XCTAssertEqual(report.participatingSessionIDs, [goal.id])
        let series = report.series(granularity: .hour, timeZone: utc)
        XCTAssertTrue(series.points[0].sessionIDs.isEmpty)
        XCTAssertEqual(series.unallocatedSessionIDs, [goal.id])
        XCTAssertEqual(report.bySession()[goal.id]?.totals.sessions, 1)
        XCTAssertNil(report.totals.activeSeconds)
    }

    func testKnownSubtotalWeightsCanBeAvailableWhileCountCoverageRemainsPartial() {
        var native = turn("open", start: 0, end: nil, steps: [step("known", at: 100, total: 10)], total: 10)
        native.modelStepsComplete = false
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(3_600))
        XCTAssertTrue(report.totals.tokensArePartial)
        XCTAssertEqual(report.totals.composition?.isComplete, true)
        XCTAssertEqual(report.totals.weightedEquivalent, 10, "weights describe the reconciled known subtotal, not missing usage")

        var pooled = native
        pooled.completedAt = date(1_000)
        pooled.usage = TokenUsage(total: 100, provenance: .providerReported)
        let remainder = ActivityAccounting.build(overview: overview([session("s", turns: [pooled])]), from: date(0), to: date(3_600))
        XCTAssertEqual(remainder.totals.tokensKnown, 100)
        XCTAssertEqual(remainder.totals.composition?.isComplete, false)
        XCTAssertNil(remainder.totals.weightedEquivalent, "an unknown split for pooled tokens cannot be invented")
    }

    func testMillisecondWireBoundariesProduceTheSameFactsBeforeAndAfterRoundtrip() throws {
        let first = step("first", at: 0.0002, total: 10)
        let ending = step("ending", at: 0.0008, total: 20)
        let snapshot = overview([session("s", turns: [turn("n", start: 0, end: 0.001, steps: [first, ending], total: 30)])])
        let from = date(0.0004), to = date(0.0009)
        let report = ActivityAccounting.build(overview: snapshot, from: from, to: to)
        let decoded = try BridgeJSON.decoder.decode(ActivityOverview.self, from: BridgeJSON.compactEncoder.encode(snapshot))
        let decodedFrom = try BridgeJSON.decoder.decode(Date.self, from: BridgeJSON.compactEncoder.encode(from))
        let decodedTo = try BridgeJSON.decoder.decode(Date.self, from: BridgeJSON.compactEncoder.encode(to))
        let rebuilt = ActivityAccounting.build(overview: decoded, from: decodedFrom, to: decodedTo)
        XCTAssertEqual(report.scope.from, ActivityAccountingPrecision.date(decodedFrom))
        XCTAssertEqual(report.scope.to, ActivityAccountingPrecision.date(decodedTo))
        XCTAssertEqual(report.totals.observedModelSteps, rebuilt.totals.observedModelSteps)
        XCTAssertEqual(report.totals.tokensKnown, rebuilt.totals.tokensKnown)
        XCTAssertEqual(report.receipts, rebuilt.receipts)
        XCTAssertEqual(report.evidenceDigest, rebuilt.evidenceDigest)
        XCTAssertEqual(report.totals.tokensKnown, 10, "the rounded ending event is exactly on the exclusive wire boundary")
    }

    func testEvidenceDigestIdentifiesTheScopedFactsAndNotLocalizedSourceText() {
        let a = session("a", project: "/a", turns: [turn("a-native", start: 0, end: 100, steps: [step("a-step", at: 50)], total: 10)])
        let b = session("b", project: "/b", turns: [turn("b-native", start: 100, end: 200, steps: [step("b-step", at: 150, total: 20)], total: 20)])
        let snapshot = overview([a, b])
        let report = ActivityAccounting.build(overview: snapshot, from: date(0), to: date(3_600))
        var reordered = snapshot
        reordered.sessions.reverse()
        reordered.sources[0].message = "Different localized display text"
        let same = ActivityAccounting.build(overview: reordered, from: date(0), to: date(3_600))
        XCTAssertEqual(report.evidenceDigest.count, 64)
        XCTAssertEqual(report.evidenceDigest, same.evidenceDigest)
        let projected = report.projected(sessionIDs: ["a"])
        let direct = ActivityAccounting.build(overview: snapshot, sessionIDs: ["a"], from: date(0), to: date(3_600))
        XCTAssertEqual(projected.evidenceDigest, direct.evidenceDigest)
        XCTAssertNotEqual(projected.evidenceDigest, report.evidenceDigest)
    }

    func testNullableNativeMeasurementsAndDatesUseExplicitJSONNull() throws {
        var native = turn("open", start: 0, end: nil, steps: [step("known", at: 100)], total: 10)
        native.promptCount = nil; native.humanPromptCount = nil; native.toolCount = nil
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: nil, to: date(3_600))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: BridgeJSON.compactEncoder.encode(report)) as? [String: Any])
        let records = try XCTUnwrap(object["nativeObservations"] as? [[String: Any]])
        XCTAssertTrue(records[0]["completedAt"] is NSNull)
        XCTAssertTrue(records[0]["submittedPrompts"] is NSNull)
        XCTAssertTrue(records[0]["confirmedHumanPrompts"] is NSNull)
        XCTAssertTrue(records[0]["toolCalls"] is NSNull)
        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        XCTAssertTrue(totals["activeSeconds"] is NSNull)
        XCTAssertEqual(object["metricDefinitionsVersion"] as? String, ActivityMetricDefinitions.version)
    }

    func testEstimatedMeasurementsRemainMetadataAndCannotBecomeKnownTotalsOrCoverage() throws {
        let real = step("real", at: 100, total: 20)
        var estimated = step("estimated", at: 200, total: 10)
        estimated.usage.provenance = .estimated
        let native = turn("n", start: 0, end: 300, steps: [real, estimated])
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(3_600))
        XCTAssertEqual(report.totals.observedModelSteps, 2)
        XCTAssertEqual(report.totals.tokensKnown, 20)
        XCTAssertEqual(report.totals.tokenReceipts, 1)
        XCTAssertEqual(report.totals.usageRecords, 2)
        XCTAssertEqual(report.totals.tokenCoverage, 0.5)
        XCTAssertTrue(report.totals.tokensArePartial)
        XCTAssertEqual(report.totals.weightedEquivalent, 20, "only the fully reconciled known subtotal is weighted")
        XCTAssertTrue(report.receipts.contains { $0.usage.total == 10 && $0.usage.provenance == .estimated })
        XCTAssertEqual(ActivityMetrics.knownTotal(report.modelRows.map(\.tokens)), 20)
        let series = report.series(granularity: .hour, timeZone: utc)
        XCTAssertEqual(series.points.first?.tokensKnown, 20)
        XCTAssertEqual(series.points.first?.usage.tokenCoverage, 0.5)
        XCTAssertEqual(series.total.tokensKnown, 20)
        XCTAssertEqual(report.projected(sessionIDs: ["s"]).totals.tokensKnown, 20)
        let decoded = try BridgeJSON.decoder.decode(ActivityAccounting.Report.self, from: BridgeJSON.compactEncoder.encode(report))
        XCTAssertEqual(decoded.projected(sessionIDs: ["s"]).totals.tokensKnown, 20)
        let estimatedOnly = ActivityAccounting.build(overview: overview([session("estimated", turns: [turn("estimate", start: 0, end: 300, steps: [estimated])])]), from: date(0), to: date(3_600))
        XCTAssertEqual(estimatedOnly.totals.observedModelSteps, 1)
        XCTAssertNil(estimatedOnly.totals.tokensKnown)
        XCTAssertNil(estimatedOnly.totals.outputKnown)
        XCTAssertEqual(estimatedOnly.totals.tokenCoverage, 0)
        XCTAssertTrue(estimatedOnly.totals.tokensArePartial)
        XCTAssertNil(estimatedOnly.totals.weightedEquivalent)
    }

    func testEstimatedNativePoolCannotLaunderAnUnobservedRemainderIntoKnownUsage() {
        var native = turn("n", start: 0, end: 300, steps: [step("known", at: 100, total: 20)], total: 100)
        native.usage.provenance = .estimated
        let report = ActivityAccounting.build(overview: overview([session("s", turns: [native])]), from: date(0), to: date(3_600))
        XCTAssertEqual(report.totals.tokensKnown, 20)
        XCTAssertEqual(ActivityMetrics.knownTotal(report.modelRows.map(\.tokens)), 20)
        XCTAssertFalse(report.receipts.contains { $0.kind == .nativeUsageRemainder && $0.usage.total == 80 && ($0.usage.provenance == .providerReported || $0.usage.provenance == .derived) })
        XCTAssertEqual(report.series(granularity: .hour, timeZone: utc).total.tokensKnown, 20)
    }
}
