import Foundation
import XCTest
@testable import BridgeCore

final class ActivityJournalReliabilityTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
    private let zone = TimeZone(secondsFromGMT: 0)!

    func testBriefUsesSharedHalfOpenWindowForUsageOutputsCommitsAndTime() throws {
        let now = start.addingTimeInterval(3_600)
        let turns = [
            turn("before", start: -120, end: -1, tokens: 10_000),
            turn("at-start", start: 0, end: 0, tokens: 5),
            turn("cross-midnight", start: -600, end: 600, tokens: 20),
            turn("inside", start: 1_200, end: 1_800, tokens: 30),
            turn("at-cutoff", start: 3_540, end: 3_600, tokens: 999),
            turn("future", start: 3_660, end: 3_720, tokens: 100_000),
            ActivityTurn(id: "undated", usage: TokenUsage(total: 500_000, provenance: .providerReported)),
        ]
        var work = session("work", turns: turns)
        work.updatedAt = start.addingTimeInterval(-86_400)
        work.models = ["obsolete-lifetime-model"]
        var metadataOnly = session("metadata-only", turns: [])
        metadataOnly.projectPath = "/tmp/renamed-project"
        var carry = session("carry", turns: [])
        carry.projectPath = "/tmp/old-goal-project"
        carry.goal = goal("carry-goal", sessionID: carry.id)
        let repository = ActivityRepository(id: "repo", name: "Repo", root: "/tmp/repo", commits: [
            ActivityCommit(id: "old-commit", subject: "Old", timestamp: start.addingTimeInterval(-1)),
            ActivityCommit(id: "start-commit", subject: "Today", timestamp: start),
            ActivityCommit(id: "cutoff-commit", subject: "Not included", timestamp: now),
        ], commitHistoryAvailable: true)
        let snapshot = ActivityOverview(generatedAt: now, sessions: [work, metadataOnly, carry], repositories: [repository])
        let brief = try ActivityJournalBuilder.build(snapshot: snapshot, now: now, timezone: zone)
        let period = ActivityAnalytics.period(turns, sessions: 1, from: start, to: now)
        XCTAssertEqual(period.tokens, 55)
        XCTAssertEqual(period.activeSeconds, 1_260)
        XCTAssertEqual(brief.outcomes[0], "2 sessions in scope across 2 project folders.")
        XCTAssertEqual(brief.outcomes[1], "3 observed model steps; 3 native records finished; 1 goal remains open.")
        XCTAssertTrue(brief.markdown.contains("Recorded tokens: 55; 3 of 3 normalized usage records reported totals."))
        XCTAssertTrue(brief.markdown.contains("Recorded time (overlaps counted once): 21 min."))
        XCTAssertTrue(brief.markdown.contains("models reported today: today\\-model"))
        XCTAssertFalse(brief.markdown.contains("obsolete-lifetime-model"))
        XCTAssertTrue(brief.evidenceIDs.contains("codex:model-step:at-start:step"))
        XCTAssertTrue(brief.evidenceIDs.contains("codex:at-cutoff"), "A time-only contribution still needs a linked native receipt")
        XCTAssertTrue(brief.evidenceIDs.contains("repo:start-commit"))
        XCTAssertFalse(brief.evidenceIDs.contains("repo:cutoff-commit"))
        XCTAssertFalse(brief.evidenceIDs.contains("future"))
        XCTAssertFalse(brief.evidenceIDs.contains("undated"))
        XCTAssertEqual(brief.continuingGoalIDs, ["carry-goal"])
    }

    func testMissingOrPartialUsageIsLabeledAsSubtotalRatherThanFullTotal() throws {
        var partial = turn("partial", start: 10, end: 20, tokens: 100)
        partial.usageIsPartial = true
        partial.modelSteps?[0].usageIsPartial = true
        let missing = ActivityTurn(id: "missing", startedAt: start.addingTimeInterval(30), status: "inProgress")
        let snapshot = ActivityOverview(generatedAt: start, sessions: [session("work", turns: [partial, missing])])
        let brief = try ActivityJournalBuilder.build(snapshot: snapshot, now: start.addingTimeInterval(60), timezone: zone)
        XCTAssertTrue(brief.markdown.contains("Recorded tokens (known subtotal): 100; 1 of 1 normalized usage records reported totals."))
        XCTAssertTrue(brief.markdown.contains("Observed model steps: 1 (known lower bound); native records supporting this window: 2."))
        XCTAssertTrue(brief.markdown.contains("Missing values remain unknown."))
    }

    func testProviderTimeRejectsNegativeNonfiniteAndUnrepresentableValuesWithoutCrashing() throws {
        var task = session("goal", turns: [])
        task.goal = goal("goal", sessionID: task.id)
        let now = start.addingTimeInterval(600)
        let absent = try ActivityJournalBuilder.build(snapshot: ActivityOverview(generatedAt: start, sessions: [task]), now: now, timezone: zone)
        for value in [-1, Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            task.goal?.providerTimeSeconds = value
            let brief = try ActivityJournalBuilder.build(snapshot: ActivityOverview(generatedAt: start, sessions: [task]), now: now, timezone: zone)
            XCTAssertTrue(brief.markdown.contains("provider-reported time so far: not reported"))
            XCTAssertEqual(brief.snapshotDigest, absent.snapshotDigest, "Invalid measurements share the same explicit unknown state")
        }
        task.goal?.providerTimeSeconds = 0
        let zero = try ActivityJournalBuilder.build(snapshot: ActivityOverview(sessions: [task]), now: now, timezone: zone)
        XCTAssertTrue(zero.markdown.contains("provider-reported time so far: 0 min"))
        task.goal?.providerTimeSeconds = 12
        let short = try ActivityJournalBuilder.build(snapshot: ActivityOverview(sessions: [task]), now: now, timezone: zone)
        XCTAssertTrue(short.markdown.contains("provider-reported time so far: less than 1 min"))
    }

    func testProviderTextCannotInjectMarkdownLinksSectionsOrHTML() throws {
        let malicious = "\n## Injected\n[click](javascript:alert(1)) *bold* <script> &x; `command`"
        var task = session("unsafe", turns: [turn("change", start: 10, end: 20, tokens: 1)])
        task.projectPath = "/tmp/[client](unsafe)*"
        task.goal = goal("unsafe`id\n## Goal injection", sessionID: task.id)
        task.goal?.objective = malicious
        task.turns[0].artifacts = [ActivityArtifact(id: "artifact`id", path: malicious)]
        let snapshot = ActivityOverview(generatedAt: start, sessions: [task], sources: [ActivitySourceHealth(id: "source", status: "ready", message: malicious)])
        let brief = try ActivityJournalBuilder.build(snapshot: snapshot, now: start.addingTimeInterval(60), timezone: zone)
        XCTAssertTrue(brief.markdown.hasPrefix("# Playbasis AI Agent Hub — Daily brief"))
        XCTAssertFalse(brief.markdown.contains("\n## Injected"))
        XCTAssertFalse(brief.markdown.contains("[click](javascript:"))
        XCTAssertFalse(brief.markdown.contains("<script>"))
        XCTAssertTrue(brief.markdown.contains("\\[click\\]\\("))
        XCTAssertTrue(brief.markdown.contains("\\<script\\>"))
        XCTAssertTrue(brief.markdown.contains("&amp;x;"))
        XCTAssertTrue(brief.markdown.contains("\\`command\\`"))
    }

    func testFormatVersionCreatesNewImmutableRevisionWithoutChangingEvidence() throws {
        let (database, _) = try fixtureDatabase()
        let snapshot = ActivityOverview(generatedAt: start, sessions: [session("work", turns: [turn("one", start: 10, end: 20, tokens: 10)])])
        let now = start.addingTimeInterval(60)
        let old = try ActivityJournalBuilder.build(snapshot: snapshot, now: now, timezone: zone, formatVersion: "fixture-format/1")
        let current = try ActivityJournalBuilder.build(snapshot: snapshot, now: now, timezone: zone)
        XCTAssertNotEqual(old.snapshotDigest, current.snapshotDigest)
        let first = try database.publish(old, snapshot: snapshot)
        let second = try database.publish(current, snapshot: snapshot)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.supersedesID, first.id)
        XCTAssertEqual(try database.publish(current, snapshot: snapshot).id, second.id)
        XCTAssertEqual(try database.journal().first(where: { $0.id == first.id })?.snapshotDigest, old.snapshotDigest)
        XCTAssertEqual(try database.reportEvidence(id: first.id), snapshot)
    }

    func testServicePublicationIsIdempotentKeepsEvidenceAndCarriesMissingGoalsForward() async throws {
        let (database, url) = try fixtureDatabase()
        var task = session("work", turns: [turn("one", start: 10, end: 20, tokens: 10)])
        let goalID = "carry`id\n## injected"
        task.goal = goal(goalID, sessionID: task.id)
        try merge(task, into: database, at: start.addingTimeInterval(100))
        let service = ActivityReportingService(databaseURL: url)
        let first = try await service.publishJournal(now: start.addingTimeInterval(120), timezone: zone)
        let duplicate = try await service.publishJournal(now: start.addingTimeInterval(150), timezone: zone)
        XCTAssertEqual(duplicate.id, first.id)
        task.turns[0].usage.total = 200
        try merge(task, into: database, at: start.addingTimeInterval(160))
        let corrected = try await service.publishJournal(now: start.addingTimeInterval(180), timezone: zone)
        XCTAssertEqual(corrected.revision, 2)
        XCTAssertEqual(corrected.supersedesID, first.id)
        let firstEvidence = try await service.reportEvidence(id: first.id)
        let correctedEvidence = try await service.reportEvidence(id: corrected.id)
        XCTAssertEqual(firstEvidence?.sessions.first?.turns.first?.usage.total, 10)
        XCTAssertEqual(correctedEvidence?.sessions.first?.turns.first?.usage.total, 200)
        task.goal = nil
        try merge(task, into: database, at: start.addingTimeInterval(86_500))
        let next = try await service.publishJournal(now: start.addingTimeInterval(86_600), timezone: zone)
        XCTAssertEqual(next.previousID, corrected.id)
        XCTAssertTrue(next.continuingGoalIDs.contains(goalID), "Missing source state is not completion")
        XCTAssertTrue(next.markdown.contains("completion has not been established"))
        XCTAssertFalse(next.markdown.contains("\n## injected"))
        XCTAssertTrue(next.markdown.contains("carry\\`id \\#\\# injected"))
        let journal = try await service.journal()
        XCTAssertEqual(journal.count, 3)
        XCTAssertEqual(journal.first(where: { $0.id == first.id })?.markdown, first.markdown)
    }

    func testExplicitCompletionResolvesCarryForwardWithoutRewritingPastBrief() throws {
        let (database, _) = try fixtureDatabase()
        var task = session("work", turns: [])
        task.goal = goal("carry", sessionID: task.id)
        let before = ActivityOverview(generatedAt: start, sessions: [task])
        let first = try database.publish(ActivityJournalBuilder.build(snapshot: before, now: start.addingTimeInterval(60), timezone: zone), snapshot: before)
        task.goal?.status = "complete"
        let after = ActivityOverview(generatedAt: start.addingTimeInterval(86_400), sessions: [task])
        let second = try database.publish(ActivityJournalBuilder.build(snapshot: after, now: start.addingTimeInterval(86_460), timezone: zone), snapshot: after)
        XCTAssertTrue(second.continuingGoalIDs.isEmpty)
        XCTAssertEqual(second.previousID, first.id)
        XCTAssertEqual(try database.journal().first(where: { $0.id == first.id })?.continuingGoalIDs, ["carry"])
    }

    private func turn(_ id: String, start a: Double, end b: Double, tokens: Int) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: start.addingTimeInterval(a), completedAt: start.addingTimeInterval(b), durationSeconds: b - a,
            status: "completed", promptCount: 1, humanPromptCount: 1, toolCount: 1, model: "today-model",
            usage: TokenUsage(total: tokens, provenance: .providerReported),
            modelSteps: [ActivityModelStep(id: id + ":step", timestamp: start.addingTimeInterval(b), model: "today-model",
                usage: TokenUsage(total: tokens, provenance: .providerReported), evidence: "synthetic-journal-fixture/1")],
            modelStepsComplete: true)
    }
    private func session(_ id: String, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: .codex, nativeID: id, title: "Fixture", projectPath: "/tmp/daily", createdAt: start.addingTimeInterval(-86_400),
            updatedAt: start.addingTimeInterval(60), observedAt: start.addingTimeInterval(60), turns: turns, historyComplete: true, source: "fixture")
    }
    private func goal(_ id: String, sessionID: String) -> ActivityGoal {
        ActivityGoal(id: id, sessionID: sessionID, objective: "Continue the work", status: "active", createdAt: start.addingTimeInterval(-86_400), updatedAt: start)
    }
    private func fixtureDatabase() throws -> (ActivityDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityBriefTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.sqlite")
        return (try ActivityDatabase(url: url), url)
    }
    private func merge(_ task: ActivitySession, into database: ActivityDatabase, at date: Date) throws {
        var task = task; task.observedAt = date
        let health = ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: date, lastSuccessAt: date, message: "Fixture data only")
        try database.merge([ActivityCollection(sessions: [task], health: health)], now: date)
    }
}
