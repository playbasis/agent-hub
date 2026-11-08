@testable import BridgeCore
import Foundation
import XCTest

final class ActivityReportingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_788_000_000)
    private func turn(_ id: String, start: Double, end: Double, tokens: Int? = 10) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: base.addingTimeInterval(start), completedAt: base.addingTimeInterval(end), durationSeconds: end - start, status: "completed", promptCount: 1, humanPromptCount: nil, usage: TokenUsage(total: tokens, provenance: tokens == nil ? .unavailable : .providerReported))
    }
    private func session(_ id: String, turns: [ActivityTurn], complete: Bool = false) -> ActivitySession {
        ActivitySession(id: id, provider: .codex, nativeID: id, title: "Test task", projectPath: "/tmp/example", createdAt: base, updatedAt: base.addingTimeInterval(100), observedAt: base.addingTimeInterval(100), runtimeState: "notLoaded", turns: turns, historyComplete: complete, source: "fixture")
    }
    private func database() throws -> (ActivityDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-reporting-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (try ActivityDatabase(url: directory.appendingPathComponent("activity.sqlite")), directory)
    }
    func testParallelTimeCountsOverlapOnceAndPreservesAgentSum() {
        let turns = [turn("a", start: 0, end: 1200), turn("b", start: 0, end: 1200), turn("c", start: 600, end: 1800)]
        XCTAssertEqual(ActivityMetrics.elapsedSeconds(turns), 1800)
        XCTAssertEqual(ActivityMetrics.summedSeconds(turns), 3600)
        XCTAssertEqual(ActivityMetrics.elapsedSeconds(turns, from: base.addingTimeInterval(900), to: base.addingTimeInterval(1500)), 600)
    }
    func testUnknownOpenTimeAndUsageAreNotInvented() {
        let open = ActivityTurn(id: "open", startedAt: base, status: "inProgress")
        XCTAssertNil(ActivityMetrics.elapsedSeconds([open]))
        XCTAssertNil(ActivityMetrics.summedSeconds([open]))
        XCTAssertNil(ActivityMetrics.knownTotal([nil, nil]))
        XCTAssertEqual(ActivityMetrics.knownTotal([0, nil]), 0)
    }
    func testForksDeduplicateNativeTurnIDsForPortfolioTotals() {
        let shared = turn("shared-turn", start: 0, end: 60)
        let sessions = [session("parent", turns: [shared]), session("fork", turns: [shared, turn("new", start: 60, end: 80)])]
        XCTAssertEqual(ActivityMetrics.uniqueTurns(sessions).count, 2)
        XCTAssertEqual(ActivityMetrics.knownTotal(ActivityMetrics.uniqueTurns(sessions).map { $0.usage.total }), 20)
    }
    func testDurableIncrementalMergeCorrectsRequestWithoutDoubleCounting() throws {
        let (database, directory) = try database()
        let health = ActivitySourceHealth(id: "codex", status: "ready", checkedAt: base, lastSuccessAt: base, message: "Fixture")
        let original = session("a", turns: [turn("1", start: 0, end: 60)])
        try database.merge([ActivityCollection(sessions: [original], health: health)], now: base)
        var updated = original
        updated.turns = [turn("1", start: 0, end: 60, tokens: 20), turn("2", start: 70, end: 90)]
        try database.merge([ActivityCollection(sessions: [updated], health: health)], now: base)
        try database.pin("a")
        let reopened = try ActivityDatabase(url: directory.appendingPathComponent("activity.sqlite"))
        let snapshot = try reopened.overview()
        XCTAssertEqual(snapshot.sessions.first?.turns.count, 2)
        XCTAssertEqual(ActivityMetrics.knownTotal(snapshot.sessions.flatMap(\.turns).map { $0.usage.total }), 30)
        XCTAssertEqual(snapshot.pinnedSessionID, "a")
        XCTAssertEqual(snapshot.sessions.first?.runtimeState, "notLoaded")
    }
    func testCompleteSnapshotRemovesRevertedTurnsButBoundedSnapshotRetainsHistory() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "codex", status: "ready", message: "Fixture")
        let old = session("a", turns: [turn("1", start: 0, end: 60), turn("2", start: 70, end: 90)])
        try database.merge([ActivityCollection(sessions: [old], health: health)], now: base)
        try database.merge([ActivityCollection(sessions: [session("a", turns: [turn("2", start: 70, end: 90)])], health: health)], now: base)
        XCTAssertEqual(try database.overview().sessions.first?.turns.count, 2)
        try database.merge([ActivityCollection(sessions: [session("a", turns: [turn("1", start: 0, end: 60)], complete: true)], health: health)], now: base)
        XCTAssertEqual(try database.overview().sessions.first?.turns.count, 1)
    }
    func testObservedIdentitiesSurvivePartialEnrichmentButNotRemovedEvidence() throws {
        let (database, _) = try database()
        var measured = turn("identity", start: 0, end: 60)
        measured.model = "native-model"; measured.effort = "high"
        let health = ActivitySourceHealth(id: "codex", status: "partial", checkedAt: base, message: "Bounded history")
        try database.merge([ActivityCollection(sessions: [session("identity-session", turns: [measured])], health: health)], now: base)
        try database.merge([ActivityCollection(sessions: [session("identity-session", turns: [])], health: health)], now: base)
        XCTAssertEqual(try database.overview().sessions.first?.models, ["native-model"])
        XCTAssertEqual(try database.overview().sessions.first?.efforts, ["high"])
        try database.merge([ActivityCollection(sessions: [session("identity-session", turns: [], complete: true)], health: health)], now: base)
        XCTAssertEqual(try database.overview().sessions.first?.models, [])
        XCTAssertEqual(try database.overview().sessions.first?.efforts, [])
    }
    func testFailedRefreshPreservesEvidenceWithExplicitSourceFailure() throws {
        let (database, _) = try database()
        try database.merge([ActivityCollection(sessions: [session("a", turns: [])], health: ActivitySourceHealth(id: "codex", status: "ready", checkedAt: base, lastSuccessAt: base, message: "Ready"))], now: base)
        try database.merge([ActivityCollection(sessions: [], health: ActivitySourceHealth(id: "codex", status: "unavailable", checkedAt: base.addingTimeInterval(60), message: "Offline"))], now: base.addingTimeInterval(60))
        let snapshot = try database.overview()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sources.first?.lastSuccessAt, base)
        XCTAssertEqual(snapshot.sources.first?.status, "unavailable")
    }
    func testObservationGuardsUseTheSamePrecisionAsPersistedTimestamps() throws {
        let (database, _) = try database()
        let storedTime = base.addingTimeInterval(0.001)
        var original = session("precision", turns: [])
        original.observedAt = storedTime
        let health = ActivitySourceHealth(id: "codex", status: "ready", checkedAt: storedTime, lastSuccessAt: storedTime, message: "Ready")
        try database.merge([ActivityCollection(sessions: [original], health: health)], now: storedTime)
        // Both dates serialize to the same millisecond. A finer raw fraction
        // must not make the follow-up look older than the persisted receipt.
        let incomingTime = storedTime.addingTimeInterval(-0.0001)
        XCTAssertEqual(try BridgeJSON.compactEncoder.encode(incomingTime), try BridgeJSON.compactEncoder.encode(storedTime))
        var corrected = original
        corrected.observedAt = incomingTime; corrected.title = "Corrected"
        let failure = ActivitySourceHealth(id: "codex", status: "unavailable", checkedAt: incomingTime, message: "Offline")
        try database.merge([ActivityCollection(sessions: [corrected], health: failure)], now: storedTime)
        let snapshot = try database.overview()
        XCTAssertEqual(snapshot.sources.first?.status, "unavailable")
        XCTAssertEqual(snapshot.sessions.first?.title, "Corrected")
        let persistedTime = try BridgeJSON.decoder.decode(Date.self, from: BridgeJSON.compactEncoder.encode(storedTime))
        XCTAssertEqual(snapshot.sources.first?.lastSuccessAt, persistedTime)
    }
    func testJournalKeepsRevisionsEvidenceAndPreviousDayLinks() throws {
        let (database, _) = try database()
        let timezone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let snapshot = ActivityOverview(generatedAt: base, sessions: [session("a", turns: [turn("1", start: 0, end: 60)])])
        let proposal = try ActivityJournalBuilder.build(snapshot: snapshot, now: base.addingTimeInterval(120), timezone: timezone)
        let first = try database.publish(proposal, snapshot: snapshot)
        XCTAssertEqual(try database.publish(proposal).id, first.id)
        XCTAssertEqual(try database.journal().count, 1)
        var changed = snapshot
        changed.sessions[0].turns[0].usage.total = 100
        let second = try database.publish(ActivityJournalBuilder.build(snapshot: changed, now: base.addingTimeInterval(150), timezone: timezone), snapshot: changed)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.supersedesID, first.id)
        XCTAssertEqual(try database.reportEvidence(id: first.id)?.sessions[0].turns[0].usage.total, 10)
        let next = try database.publish(ActivityJournalBuilder.build(snapshot: changed, now: base.addingTimeInterval(86400), timezone: timezone))
        XCTAssertEqual(next.previousID, second.id)
        XCTAssertEqual(try database.journal().count, 3)
    }
    func testGitParsingPreservesSpacesAndDeduplicatesSharedCommits() {
        let worktrees = ActivityGitReader.worktrees("worktree /tmp/project with space\0HEAD abc\0branch refs/heads/main\0\0worktree /tmp/child\0HEAD def\0detached\0\0")
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0].path, "/tmp/project with space")
        XCTAssertEqual(worktrees[1].branch, "Detached HEAD")
        let commit = "abc\u{1f}1788000000\u{1f}Build artifact\u{1e}"
        XCTAssertEqual(ActivityGitReader.commits(commit + commit).count, 1)
        XCTAssertEqual(ActivityGitReader.changedFiles("1 .M record\0? ignored\02 R. rename\0original path\0"), 2)
    }

    func testPartialReplayPreservesKnownMetricsButExplicitZeroCorrectsThem() throws {
        var original = turn("shared", start: 0, end: 60, tokens: 20)
        original.model = "test-model"; original.toolCount = 3
        let partial = ActivityTurn(id: "shared", status: "unknown")
        let merged = original.merging(partial)
        XCTAssertEqual(merged.usage.total, 20)
        XCTAssertEqual(merged.durationSeconds, 60)
        XCTAssertEqual(merged.model, "test-model")
        XCTAssertEqual(merged.status, "completed")
        var correction = partial
        correction.usage = TokenUsage(total: 0, provenance: .providerReported)
        XCTAssertEqual(merged.merging(correction).usage.total, 0)
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "fixture", status: "ready", message: "Ready")
        try database.merge([ActivityCollection(sessions: [session("a", turns: [original], complete: true)], health: health)], now: base)
        try database.merge([ActivityCollection(sessions: [session("a", turns: [partial], complete: true)], health: health)], now: base)
        XCTAssertEqual(try database.overview().sessions[0].turns[0].usage.total, 20)
    }

    func testMovingTranscriptTailsCannotEraseKnownUsageOrInflateTheirUnion() {
        var earlier = turn("same", start: 0, end: 60, tokens: 100)
        earlier.usageIsPartial = true
        var later = earlier; later.usage.total = 70
        let merged = earlier.merging(later)
        XCTAssertEqual(merged.usage.total, 100, "overlapping tails retain a lower bound, not a sum or newest smaller tail")
        later.usage.total = 120
        XCTAssertEqual(earlier.merging(later).usage.total, 120)
        later.usage.total = 90; later.usageIsPartial = false
        let complete = earlier.merging(later)
        XCTAssertEqual(complete.usage.total, 90, "authoritative complete correction is allowed to decrease a subtotal")
        XCTAssertEqual(complete.merging(earlier).usage.total, 90, "a later partial replay cannot replace complete evidence")
    }

    func testPartialClaudeResponseResolvesPendingPlaceholderWithoutLosingOrDuplicatingPrompts() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "claude.activity", status: "partial", message: "Bounded transcript")
        let sessionID = "claude:native-session"
        let pending = ActivityTurn(id: "\(sessionID):\(sessionID):pending-prompts", startedAt: base.addingTimeInterval(10),
            status: "submission_observed", promptCount: 2, humanPromptCount: 1)
        var value = session(sessionID, turns: [turn("retained-history", start: 0, end: 5), pending])
        value.provider = .claude; value.source = "claude-local-transcript/1"
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)

        var response = turn("\(sessionID):claude-request:response", start: 20, end: 30, tokens: 20)
        response.promptCount = 0
        value.turns = [response]
        value.observedAt = base.addingTimeInterval(200)
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base.addingTimeInterval(200))
        let resolved = try XCTUnwrap(database.overview().sessions.first)
        XCTAssertEqual(resolved.turns.count, 2, "Retain old native history, but not the superseded synthetic turn")
        XCTAssertFalse(resolved.turns.contains { $0.id == pending.id })
        XCTAssertEqual(resolved.turns.first { $0.id == response.id }?.promptCount, 2)
        XCTAssertEqual(resolved.turns.first { $0.id == response.id }?.humanPromptCount, 1)
        XCTAssertEqual(ActivityMetrics.knownTotal(resolved.turns.map { $0.usage.total }), 30)

        // Another moving tail still cannot see the old submission. Neither
        // its known count nor the single response's usage may be erased/added.
        value.observedAt = base.addingTimeInterval(300)
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base.addingTimeInterval(300))
        let replay = try XCTUnwrap(database.overview().sessions.first)
        XCTAssertEqual(replay.turns.first { $0.id == response.id }?.promptCount, 2)
        XCTAssertEqual(replay.turns.first { $0.id == response.id }?.humanPromptCount, 1)
        XCTAssertEqual(ActivityMetrics.knownTotal(replay.turns.map { $0.usage.total }), 30)
    }

    func testClaudePendingCountAlreadyReportedByResponseIsNotAddedTwiceAndCompleteCorrectionWins() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "claude.activity", status: "partial", message: "Bounded transcript")
        let sessionID = "claude:reported-submission"
        let pending = ActivityTurn(id: "\(sessionID):pending-prompts", startedAt: base.addingTimeInterval(10),
            status: "submission_observed", promptCount: 1)
        var value = session(sessionID, turns: [pending])
        value.provider = .claude; value.source = "claude-local-transcript/1"
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
        var response = turn("\(sessionID):claude-request:response", start: 20, end: 30)
        value.turns = [response]
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
        XCTAssertEqual(try database.overview().sessions.first?.turns.count, 1)
        XCTAssertEqual(try database.overview().sessions.first?.turns.first?.promptCount, 1)

        response.promptCount = 0; value.turns = [response]; value.historyComplete = true
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
        XCTAssertEqual(try database.overview().sessions.first?.turns.first?.promptCount, 0,
            "An explicitly complete transcript may correct a previously observed count")
    }

    func testPartialClaudePendingSubmissionsStayWhenResponseEvidenceIsUnresolvedOrUndated() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "claude.activity", status: "partial", message: "Bounded transcript")
        let cases: [(String, ActivityTurn?, Date?)] = [
            ("missing", nil, base.addingTimeInterval(10)),
            ("older-response", turn("response", start: 0, end: 5), base.addingTimeInterval(10)),
            ("undated-submission", turn("response", start: 20, end: 30), nil),
            ("undated-response", ActivityTurn(id: "response", status: "completed"), base.addingTimeInterval(10)),
            ("start-only", ActivityTurn(id: "response", startedAt: base.addingTimeInterval(20), status: "inProgress"), base.addingTimeInterval(10)),
        ]
        for (name, response, submittedAt) in cases {
            let sessionID = "claude:\(name)"
            let pending = ActivityTurn(id: "\(sessionID):\(sessionID):pending-prompts", startedAt: submittedAt,
                status: "submission_observed", promptCount: 1)
            var value = session(sessionID, turns: [pending])
            value.provider = .claude; value.source = "claude-local-transcript/1"
            try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
            value.turns = response.map { response in
                var response = response; response.id = "\(sessionID):claude-request:response"; return [response]
            } ?? []
            try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
            let retained = try XCTUnwrap(database.overview().sessions.first { $0.id == sessionID })
            XCTAssertTrue(retained.turns.contains { $0.id == pending.id }, name)
        }
    }

    func testOlderRefreshAndOtherAdaptersCannotResolveClaudePendingPlaceholder() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "claude.activity", status: "partial", message: "Bounded transcript")
        for source in ["claude-local-transcript/1", "other-adapter"] {
            let sessionID = "claude:\(source)"
            let pending = ActivityTurn(id: "\(sessionID):pending-prompts", startedAt: base.addingTimeInterval(10),
                status: "submission_observed", promptCount: 1)
            var value = session(sessionID, turns: [pending])
            value.provider = .claude; value.source = source
            value.observedAt = base.addingTimeInterval(200)
            try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
            value.turns = [turn("\(sessionID):claude-request:response", start: 20, end: 30)]
            if source == "claude-local-transcript/1" { value.observedAt = base.addingTimeInterval(100) }
            try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
            let retained = try XCTUnwrap(database.overview().sessions.first { $0.id == sessionID })
            XCTAssertTrue(retained.turns.contains { $0.id == pending.id }, source)
        }
    }

    func testContinuingOlderClaudeRequestAndStillPendingSnapshotDoNotResolveSubmission() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "claude.activity", status: "partial", message: "Bounded transcript")
        let sessionID = "claude:continuing-request"
        let pending = ActivityTurn(id: "\(sessionID):pending-prompts", startedAt: base.addingTimeInterval(10),
            status: "submission_observed", promptCount: 1)
        let responseID = "\(sessionID):claude-request:older-response"
        var value = session(sessionID, turns: [turn(responseID, start: 0, end: 5), pending])
        value.provider = .claude; value.source = "claude-local-transcript/1"
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
        value.turns = [turn(responseID, start: 20, end: 30)]
        for _ in 0..<2 { try database.merge([ActivityCollection(sessions: [value], health: health)], now: base) }
        let retained = try XCTUnwrap(database.overview().sessions.first)
        XCTAssertTrue(retained.turns.contains { $0.id == pending.id })
        XCTAssertEqual(retained.turns.first { $0.id == responseID }?.startedAt, base)

        // Even genuine newer responses cannot override a snapshot that still
        // explicitly reports an outstanding submission.
        value.turns = [turn("\(sessionID):claude-request:newer", start: 40, end: 50), pending]
        try database.merge([ActivityCollection(sessions: [value], health: health)], now: base)
        XCTAssertTrue(try database.overview().sessions[0].turns.contains { $0.id == pending.id })
    }

    func testCumulativeCodexUsageAndCacheSubsetsRemainExactAcrossDatabaseReplays() throws {
        let (database, _) = try database()
        var transcript = CodexActivityTranscript()
        transcript.consume(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn"]])
        let first: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": 10_000, "cached_input_tokens": 9_500, "output_tokens": 100,
                "reasoning_output_tokens": 40, "total_tokens": 10_100],
            "total_token_usage": ["total_tokens": 10_100],
        ]]]
        transcript.consume(first)
        transcript.consume(first) // Repeated provider snapshot, not another charge.
        transcript.consume(["type": "event_msg", "payload": ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": 5_000, "cached_input_tokens": 4_500, "output_tokens": 50,
                "reasoning_output_tokens": 20, "total_tokens": 5_050],
            "total_token_usage": ["total_tokens": 15_150],
        ]]])
        var measured = turn("native-turn", start: 0, end: 60)
        measured.usage = try XCTUnwrap(transcript.turns["turn"]).usage
        let health = ActivitySourceHealth(id: "codex-activity", status: "partial", message: "Fixture")
        let value = session("native-session", turns: [measured])
        for _ in 0..<3 { try database.merge([ActivityCollection(sessions: [value], health: health)], now: base) }
        let usage = try XCTUnwrap(database.overview().sessions.first?.turns.first?.usage)
        XCTAssertEqual(usage.input, 15_000)
        XCTAssertEqual(usage.cachedInput, 14_000)
        XCTAssertEqual(usage.output, 150)
        XCTAssertEqual(usage.reasoning, 60)
        XCTAssertEqual(usage.total, 15_150, "Cached/reasoning are subsets, and cumulative snapshots must not be summed")
    }

    func testPinnedAndOpenGoalSessionsSurviveTheRecentSessionLimit() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "fixture", status: "ready", message: "Ready")
        var pinned = session("pinned", turns: [])
        pinned.updatedAt = base.addingTimeInterval(-86400)
        var goal = session("goal", turns: [])
        goal.updatedAt = base.addingTimeInterval(-86400)
        goal.goal = ActivityGoal(id: "goal-v1", sessionID: goal.id, objective: "Continue working", status: "active", createdAt: base, updatedAt: base)
        let recent = (0..<251).map { session("recent-\($0)", turns: []) }
        try database.merge([ActivityCollection(sessions: recent + [pinned, goal], health: health)], now: base)
        try database.pin(pinned.id)
        let snapshot = try database.overview()
        XCTAssertTrue(snapshot.sessions.contains { $0.id == pinned.id })
        XCTAssertTrue(snapshot.sessions.contains { $0.id == goal.id })
        XCTAssertEqual(snapshot.pinnedSession?.id, pinned.id)
    }

    func testJournalDigestTracksCorrectionsBelowDisplayPrecision() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        var snapshot = ActivityOverview(generatedAt: base, sessions: [session("a", turns: [turn("a", start: 0, end: 60)])])
        let first = try ActivityJournalBuilder.build(snapshot: snapshot, now: base.addingTimeInterval(120), timezone: zone)
        snapshot.generatedAt = base.addingTimeInterval(100)
        snapshot.sessions[0].observedAt = base.addingTimeInterval(1000)
        let refreshed = try ActivityJournalBuilder.build(snapshot: snapshot, now: base.addingTimeInterval(150), timezone: zone)
        XCTAssertEqual(first.snapshotDigest, refreshed.snapshotDigest)
        snapshot.sessions[0].turns[0].durationSeconds = 60.1
        let corrected = try ActivityJournalBuilder.build(snapshot: snapshot, now: base.addingTimeInterval(150), timezone: zone)
        XCTAssertNotEqual(first.snapshotDigest, corrected.snapshotDigest)
    }

    func testJournalCarriesUnobservedGoalsWithoutClaimingTheyCompleted() throws {
        let (database, _) = try database()
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        var active = session("a", turns: [])
        active.goal = ActivityGoal(id: "open-goal", sessionID: "a", objective: "Finish task", status: "active", createdAt: base, updatedAt: base)
        let before = ActivityOverview(generatedAt: base, sessions: [active])
        _ = try database.publish(ActivityJournalBuilder.build(snapshot: before, now: base, timezone: zone), snapshot: before)
        let missing = ActivityOverview(generatedAt: base.addingTimeInterval(86400), sessions: [session("b", turns: [])])
        let next = try database.publish(ActivityJournalBuilder.build(snapshot: missing, now: base.addingTimeInterval(86400), timezone: zone), snapshot: missing)
        XCTAssertTrue(next.continuingGoalIDs.contains("open-goal"))
        XCTAssertTrue(next.markdown.contains("completion has not been established"))
    }

    func testOlderConcurrentRefreshCannotReplaceNewerEvidenceOrHealth() throws {
        let (database, directory) = try database()
        let olderConnection = try ActivityDatabase(url: directory.appendingPathComponent("activity.sqlite"))
        let oldTime = base.addingTimeInterval(100), newTime = base.addingTimeInterval(200)
        var older = session("a", turns: [turn("removed", start: 0, end: 60)], complete: true)
        older.observedAt = oldTime
        older.goal = ActivityGoal(id: "goal", sessionID: "a", objective: "Task", status: "active", createdAt: base, updatedAt: oldTime)
        var newer = older
        newer.title = "New title"; newer.observedAt = newTime; newer.updatedAt = newTime
        newer.goal?.status = "complete"; newer.goal?.updatedAt = newTime
        newer.turns = [turn("correct", start: 70, end: 90, tokens: 30)]
        try database.merge([ActivityCollection(sessions: [newer], health: ActivitySourceHealth(id: "codex", status: "ready", checkedAt: newTime, lastSuccessAt: newTime, message: "New"), accountUsage: ActivityAccountUsage(observedAt: newTime, lifetimeTokens: 300))], now: newTime)
        try olderConnection.merge([ActivityCollection(sessions: [older], health: ActivitySourceHealth(id: "codex", status: "unavailable", checkedAt: oldTime, message: "Old failure"), accountUsage: ActivityAccountUsage(observedAt: oldTime, lifetimeTokens: 100))], now: oldTime)
        let snapshot = try database.overview()
        XCTAssertEqual(snapshot.generatedAt, newTime)
        XCTAssertEqual(snapshot.sessions.first?.title, "New title")
        XCTAssertEqual(snapshot.sessions.first?.goal?.status, "complete")
        XCTAssertEqual(snapshot.sessions.first?.turns.map(\.id), ["correct"])
        XCTAssertEqual(snapshot.sources.first?.status, "ready")
        XCTAssertEqual(snapshot.accountUsage?.lifetimeTokens, 300)
    }

    func testFailedMergeRollsBackAllRowsAndLeavesConnectionUsable() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: base, message: "Before")
        try database.merge([ActivityCollection(sessions: [session("a", turns: [])], health: health)], now: base)
        var invalid = session("bad", turns: [turn("bad", start: 0, end: 1)])
        invalid.turns[0].durationSeconds = .nan
        XCTAssertThrowsError(try database.merge([ActivityCollection(sessions: [session("also-rolled-back", turns: []), invalid], health: ActivitySourceHealth(id: "fixture", status: "unavailable", checkedAt: base.addingTimeInterval(60), message: "After"))], now: base.addingTimeInterval(60)))
        let snapshot = try database.overview()
        XCTAssertEqual(snapshot.sessions.map(\.id), ["a"])
        XCTAssertEqual(snapshot.sources.first?.message, "Before")
        XCTAssertEqual(snapshot.generatedAt, base)
        try database.pin("a")
        XCTAssertEqual(try database.overview().pinnedSessionID, "a")
    }

    func testSQLiteStringBindingsDoNotAliasEmbeddedNulIDs() throws {
        let (database, _) = try database()
        let health = ActivitySourceHealth(id: "fixture", status: "ready", message: "Fixture")
        try database.merge([ActivityCollection(sessions: [session("same", turns: []), session("same\0distinct", turns: [])], health: health)], now: base)
        XCTAssertEqual(Set(try database.overview().sessions.map(\.id)), ["same", "same\0distinct"])
    }

    func testJournalDigestIsOrderIndependentAndTimezoneAware() throws {
        var task = session("a", turns: [turn("t", start: 0, end: 60)])
        task.models = ["z", "a"]; task.efforts = ["high", "low"]; task.warnings = ["b", "a"]
        task.turns[0].artifacts = [ActivityArtifact(id: "2", path: "b"), ActivityArtifact(id: "1", path: "a")]
        var snapshot = ActivityOverview(generatedAt: base, sessions: [task], accountUsage: ActivityAccountUsage(daily: [ActivityAccountDay(date: "2026-01-02", tokens: 2), ActivityAccountDay(date: "2026-01-01", tokens: 1)]), repositories: [ActivityRepository(id: "repo", name: "Repo", root: "/tmp/repo", worktrees: [ActivityWorktree(path: "b"), ActivityWorktree(path: "a")], commits: [ActivityCommit(id: "2", subject: "Two", timestamp: base, paths: ["b", "a"]), ActivityCommit(id: "1", subject: "One", timestamp: base)], commitHistoryAvailable: true)])
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let first = try ActivityJournalBuilder.build(snapshot: snapshot, now: base.addingTimeInterval(120), timezone: zone)
        snapshot.sessions[0].models.reverse(); snapshot.sessions[0].efforts.reverse(); snapshot.sessions[0].warnings.reverse()
        snapshot.sessions[0].turns[0].artifacts.reverse(); snapshot.accountUsage?.daily.reverse()
        snapshot.repositories[0].worktrees.reverse(); snapshot.repositories[0].commits[0].paths.reverse(); snapshot.repositories[0].commits.reverse()
        let reordered = try ActivityJournalBuilder.build(snapshot: snapshot, now: base.addingTimeInterval(120), timezone: zone)
        XCTAssertEqual(first.snapshotDigest, reordered.snapshotDigest)
        let utc = try ActivityJournalBuilder.build(snapshot: snapshot, now: base.addingTimeInterval(120), timezone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertNotEqual(first.snapshotDigest, utc.snapshotDigest)
    }

    func testGitRenameSourcesAreNotCountedAsPorcelainRecords() {
        XCTAssertEqual(ActivityGitReader.changedFiles("2 R. renamed-file\01 looks-like-record.txt\01 .M actual-file\0"), 2)
        XCTAssertTrue(ActivityGitReader.commits("abc\u{1f}nan\u{1f}Bad timestamp\u{1e}").isEmpty)
    }

    func testGitFailedHistoryIsNotAConfirmedZeroAndEmptySuccessIs() async throws {
        let failure = ActivityGitReader(execute: { _, args in
            if args.contains("--git-common-dir") { return "/tmp/repo/.git\n" }
            if args.contains("--show-toplevel") { return "/tmp/repo\n" }
            if args.first == "worktree" { return "worktree /tmp/repo\0HEAD abc\0branch refs/heads/main\0\0" }
            if args.first == "status" { return "" }
            throw BridgeError.processFailed("fixture history failed")
        })
        let unavailable = await failure.read(paths: ["/tmp/repo"], now: base)
        XCTAssertEqual(unavailable.first?.commitHistoryAvailable, false)
        XCTAssertEqual(unavailable.first?.worktrees.first?.changedFiles, 0)
        XCTAssertTrue(unavailable.first?.warning?.contains("does not mean zero") == true)
        let success = ActivityGitReader(execute: { _, args in
            if args.contains("--git-common-dir") { return "/tmp/repo/.git\n" }
            if args.contains("--show-toplevel") { return "/tmp/repo\n" }
            if args.first == "worktree" { return "worktree /tmp/repo\0\0" }
            return ""
        })
        let empty = await success.read(paths: ["/tmp/repo"], now: base)
        XCTAssertEqual(empty.first?.commitHistoryAvailable, true)
        XCTAssertEqual(empty.first?.commits.count, 0)
    }

    func testUnavailableRepositoryRefreshRetainsDatedEvidence() throws {
        let (database, _) = try database()
        let before = ActivityRepository(id: "/repo/.git", name: "Repo", root: "/repo", commits: [ActivityCommit(id: "abc", subject: "Known commit", timestamp: base)], observedAt: base, commitHistoryAvailable: true)
        try database.repositories([before])
        try database.repositories([ActivityRepository(id: "/repo", name: "Repo", root: "/repo", observedAt: base.addingTimeInterval(60), warning: "Unavailable", commitHistoryAvailable: false)])
        let retained = try XCTUnwrap(database.overview().repositories.first)
        XCTAssertEqual(retained.id, before.id)
        XCTAssertEqual(retained.commits, before.commits)
        XCTAssertEqual(retained.observedAt, base)
        XCTAssertEqual(retained.commitHistoryAvailable, false)
        XCTAssertTrue(retained.warning?.contains("retained evidence") == true)
        let (initiallyMissing, _) = try self.database()
        try initiallyMissing.repositories([ActivityRepository(id: "/repo", name: "Repo", root: "/repo", observedAt: base.addingTimeInterval(-60), commitHistoryAvailable: false)])
        try initiallyMissing.repositories([before])
        XCTAssertEqual(try initiallyMissing.overview().repositories.map(\.id), [before.id], "A recovered repository replaces its inaccessible-path placeholder")
    }

    func testCancelledRefreshDoesNotStartProviderCollection() async throws {
        let (_, directory) = try database()
        let destination = directory.appendingPathComponent("not-created.sqlite")
        let service = ActivityReportingService(databaseURL: destination)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.refresh(configuration: AgentConfiguration(), force: true)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
