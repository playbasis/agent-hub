@testable import BridgeCore
import Foundation
import XCTest

final class ModelNamingTests: XCTestCase {
    func testProviderIdentifiersReadAsProductNames() {
        XCTAssertEqual(ModelNaming.display("gpt-6.1-terra"), "GPT-6.1 Terra")
        XCTAssertEqual(ModelNaming.display("gpt-6-astra"), "GPT-6 Astra")
        XCTAssertEqual(ModelNaming.display("gpt-5-codex"), "GPT-5 Codex")
        XCTAssertEqual(ModelNaming.display("claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(ModelNaming.display("claude-sonnet-4-5-20250929"), "Claude Sonnet 4.5", "release dates are dropped")
        XCTAssertEqual(ModelNaming.display("claude-3-5-sonnet-20241022"), "Claude 3.5 Sonnet")
        XCTAssertEqual(ModelNaming.display("gemini-3.5-flash"), "Gemini 3.5 Flash")
        XCTAssertEqual(ModelNaming.display("glm-5.3-flash"), "GLM-5.3 Flash")
        XCTAssertEqual(ModelNaming.display("o4-mini"), "o4 Mini")
        XCTAssertEqual(ModelNaming.display("sonnet"), "Sonnet")
        XCTAssertEqual(ModelNaming.display(nil), "Unknown model")
        XCTAssertEqual(ModelNaming.display("  "), "Unknown model")
    }

    func testEffortLevelsUseEverydayWords() {
        XCTAssertEqual(ModelNaming.effort("xhigh"), "Extra high")
        XCTAssertEqual(ModelNaming.effort("ultra"), "Ultra")
        XCTAssertEqual(ModelNaming.effort("medium"), "Medium")
        XCTAssertEqual(ModelNaming.effort(nil), "Default effort")
        XCTAssertEqual(ModelNaming.planOwner(.codex), "ChatGPT")
    }

    func testBrandKeepsCodenameOutOfUserFacingName() {
        XCTAssertEqual(BridgeBrand.productName, "Playbasis AI Agent Hub")
        XCTAssertFalse(BridgeBrand.productName.contains("Bridge"))
    }
}

final class ActivityHighlightsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func session(_ id: String, provider: AgentName = .codex, project: String = "/p/app", turns: [ActivityTurn]) -> ActivitySession {
        // Pattern fixtures represent one observed model response per record;
        // native turns alone must no longer imply that count in production.
        let measured = turns.map { original -> ActivityTurn in
            var value = original
            if value.usage.total != nil, value.usage.provenance == .unavailable { value.usage.provenance = .providerReported }
            if provider == .codex, value.modelSteps == nil {
                value.modelSteps = [ActivityModelStep(id: value.id, timestamp: ActivityAnalytics.timestamp(value), model: value.model,
                    usage: value.usage, usageIsPartial: value.usageIsPartial)]
                value.modelStepsComplete = true
            }
            return value
        }
        return ActivitySession(id: id, provider: provider, nativeID: id, title: "Session \(id)", projectPath: project,
                        createdAt: date("2026-11-01T00:00:00Z"), updatedAt: date("2026-11-02T12:00:00Z"),
                        observedAt: date("2026-11-02T12:00:00Z"), turns: measured, source: "test")
    }

    private func turn(_ id: String, _ start: String, minutes: Double = 10, status: String = "completed", usage: TokenUsage = TokenUsage()) -> ActivityTurn {
        let begin = date(start)
        return ActivityTurn(id: id, startedAt: begin, completedAt: begin.addingTimeInterval(minutes * 60), durationSeconds: minutes * 60,
                            status: status, usage: usage)
    }

    private func input(_ sessions: [ActivitySession], quotas: [AgentName: QuotaEstimate] = [:], account: ActivityAccountUsage? = nil) -> ActivityHighlights.Input {
        ActivityHighlights.Input(sessions: sessions, from: date("2026-10-27T00:00:00Z"), to: date("2026-11-02T18:00:00Z"),
                                 quotas: quotas, account: account, timeZone: utc, locale: locale)
    }

    func testFastPlanPaceIsTheFirstAlertAndExplainsTheResetGap() throws {
        let now = date("2026-11-02T18:00:00Z")
        // A weekly window that opened six hours ago and is already 30% used.
        let window = QuotaWindow(id: "codex-primary", label: "Weekly limit", usedRatio: 0.3,
                                 resetAt: date("2026-11-09T12:00:00Z"), durationMinutes: 10_080)
        let estimate = QuotaEstimate(agent: .codex, windows: [window], source: .live, fetchedAt: now)
        let highlights = ActivityHighlights.make(input([], quotas: [.codex: estimate]))
        let first = try XCTUnwrap(highlights.first)
        XCTAssertEqual(first.kind, .planPace)
        XCTAssertEqual(first.tone, .alert, "running out within a day is an alert")
        XCTAssertEqual(first.provider, .codex)
        XCTAssertEqual(first.value, "14h")
        XCTAssertTrue(first.title.hasPrefix("ChatGPT weekly limit could run out tomorrow at"), first.title)
        XCTAssertTrue(first.detail.hasSuffix("before it resets · 70% left"), first.detail)
        XCTAssertTrue(first.note?.contains("average pace since the limit last reset") == true, "the method stays available on demand")
    }

    func testStaleOrHealthyPlansNeverRaiseAlerts() {
        let now = date("2026-11-02T18:00:00Z")
        let window = QuotaWindow(id: "w", label: "Weekly limit", usedRatio: 0.3, resetAt: date("2026-11-09T12:00:00Z"), durationMinutes: 10_080)
        let stale = QuotaEstimate(agent: .codex, windows: [window], source: .live, fetchedAt: now.addingTimeInterval(-7_200))
        XCTAssertTrue(ActivityHighlights.make(input([], quotas: [.codex: stale])).isEmpty, "an old reading cannot forecast")

        let calm = QuotaWindow(id: "c", label: "5-hour limit", usedRatio: 0.05, durationMinutes: 300)
        let claude = QuotaEstimate(agent: .claude, windows: [calm], source: .live, fetchedAt: now)
        let healthy = ActivityHighlights.make(input([], quotas: [.claude: claude]))
        XCTAssertEqual(healthy.map(\.kind), [.planHealthy])
        XCTAssertEqual(healthy.first?.detail, "Claude 95% left")
    }

    func testPassedForecastRequestsARefreshInsteadOfClaimingHealthyOrExhaustedCapacity() throws {
        let now = date("2026-11-02T18:00:00Z")
        let fetched = now.addingTimeInterval(-930)
        // Measured 50% after 15 minutes. The same pace forecast expiry after
        // another 15 minutes, but the still-fresh reading is now 15m30s old.
        let window = QuotaWindow(id: "hour", label: "Hourly", usedRatio: 0.5, resetAt: fetched.addingTimeInterval(2_700), durationMinutes: 60)
        let estimate = QuotaEstimate(agent: .codex, windows: [window], source: .live, fetchedAt: fetched)
        let highlights = ActivityHighlights.make(input([], quotas: [.codex: estimate]))
        let first = try XCTUnwrap(highlights.first)
        XCTAssertEqual(first.kind, .planPace)
        XCTAssertEqual(first.tone, .warning)
        XCTAssertEqual(first.value, "Refresh")
        XCTAssertTrue(first.detail.contains("50% left when read"))
        XCTAssertTrue(first.note?.contains("does not mean the limit is used up") == true)
        XCTAssertFalse(highlights.contains { $0.kind == .planHealthy || $0.kind == .planLow })
    }

    func testProviderFreshnessUsesCurrentClockWithoutAdvancingTheSavedLocalScope() {
        let saved = date("2026-11-02T18:00:00Z"), current = date("2026-11-02T19:00:00Z")
        let window = QuotaWindow(id: "weekly", label: "Weekly", usedRatio: 0.05,
                                 resetAt: current.addingTimeInterval(86_400), durationMinutes: 10_080)
        let quota = QuotaEstimate(agent: .codex, windows: [window], source: .live, fetchedAt: saved)
        let report = ActivityAccounting.build(overview: ActivityOverview(generatedAt: saved, sessions: []), from: saved.addingTimeInterval(-3_600), to: saved)
        let frozen = ActivityHighlights.Input(sessions: [], from: report.scope.from, to: saved, quotas: [.codex: quota],
                                              timeZone: utc, locale: locale, accounting: report, providerNow: current)
        XCTAssertTrue(ActivityHighlights.make(frozen).isEmpty, "a one-hour-old provider reading must not remain healthy against the saved clock")
        XCTAssertEqual(report.scope.to, saved)
        XCTAssertEqual(report.scope.asOf, saved)
    }

    func testPassedProviderForecastRequestsRefreshEvenWhenLocalSnapshotIsAnHourOld() throws {
        let saved = date("2026-11-02T18:00:00Z"), current = date("2026-11-02T19:00:00Z")
        let fetched = current.addingTimeInterval(-930)
        let window = QuotaWindow(id: "hourly", label: "Hourly", usedRatio: 0.5,
                                 resetAt: fetched.addingTimeInterval(2_700), durationMinutes: 60)
        let quota = QuotaEstimate(agent: .codex, windows: [window], source: .live, fetchedAt: fetched)
        let report = ActivityAccounting.build(overview: ActivityOverview(generatedAt: saved, sessions: []), from: saved.addingTimeInterval(-3_600), to: saved)
        let highlights = ActivityHighlights.make(.init(sessions: [], from: report.scope.from, to: saved, quotas: [.codex: quota],
                                                     timeZone: utc, locale: locale, accounting: report, providerNow: current))
        let first = try XCTUnwrap(highlights.first)
        XCTAssertEqual(first.value, "Refresh")
        XCTAssertEqual(first.tone, .warning)
        XCTAssertFalse(highlights.contains { $0.kind == .planHealthy })
        XCTAssertFalse(first.title.contains("could run out"), "a passed forecast is not reported as a future allowance")
        XCTAssertEqual(report.scope.to, saved)
    }

    func testBusiestDayOvernightAndFailuresComeFromMeasuredTurns() {
        var turns: [ActivityTurn] = []
        for index in 0 ..< 30 { turns.append(turn("night-\(index)", "2026-11-02T0\(index % 6):\(10 + index):00Z")) }
        for index in 0 ..< 5 { turns.append(turn("monday-\(index)", "2026-10-27T14:0\(index):00Z")) }
        turns.append(turn("broken", "2026-11-02T10:00:00Z", status: "failed"))
        turns.append(turn("stopped", "2026-11-02T11:00:00Z", status: "interrupted"))
        let highlights = ActivityHighlights.make(input([session("a", turns: turns)]), limit: 20)
        let kinds = highlights.map(\.kind)
        XCTAssertTrue(kinds.contains(.busiestDay))
        XCTAssertTrue(kinds.contains(.overnight))
        let overnight = highlights.first { $0.kind == .overnight }
        XCTAssertEqual(overnight?.value, "81%")
        XCTAssertEqual(overnight?.title, "Overnight activity")
        XCTAssertEqual(overnight?.detail, "30 model steps between midnight and 7 AM")
        XCTAssertTrue(overnight?.note?.contains("isn't time you worked") == true, "the caveat moves to the note, not away")
        let busiest = highlights.first { $0.kind == .busiestDay }
        XCTAssertEqual(busiest?.title, "Today was the busiest day")
        XCTAssertEqual(busiest?.detail, "More model steps than the other 1 day combined")
        XCTAssertTrue(busiest?.note?.contains("aren't counted as idle") == true, "unobserved dates are not idle days")
        XCTAssertEqual(busiest?.value, "32")
        let failures = highlights.first { $0.kind == .failures }
        XCTAssertEqual(failures?.value, "2")
        XCTAssertEqual(failures?.title, "Requests didn't finish")
        XCTAssertEqual(failures?.detail, "1 failed · 1 interrupted · of 37")
        XCTAssertEqual(failures?.sessionID, "a")
        XCTAssertEqual(failures?.tone, .warning, "over 5% unfinished deserves attention")
    }

    func testContextReuseNeverRoundsUpToOneHundredPercent() {
        let usage = TokenUsage(input: 1_000, output: 2, cachedInput: 999, total: 1_002)
        let turns = (0 ..< 12).map { turn("t\($0)", "2026-11-01T1\($0 % 10):00:00Z", usage: usage) }
        let reuse = ActivityHighlights.make(input([session("a", turns: turns)]), limit: 20).first { $0.kind == .contextReuse }
        XCTAssertEqual(reuse?.value, "99%")
        XCTAssertEqual(reuse?.detail, "About 500 re-read for every token written")
        XCTAssertEqual(ActivityHighlights.roughly(783.4), "780")
        XCTAssertEqual(ActivityHighlights.roughly(1_234), "1,200")
        XCTAssertEqual(ActivityHighlights.roughly(42.4), "42")
    }

    func testParallelPeakProviderShareAndStreak() {
        let codex = (0 ..< 24).map { turn("c\($0)", "2026-11-01T10:00:00Z", minutes: 60) }
        let claude = [turn("k1", "2026-11-01T12:00:00Z")]
        let account = ActivityAccountUsage(observedAt: date("2026-11-02T18:00:00Z"), currentStreakDays: 12, longestStreakDays: 39)
        let highlights = ActivityHighlights.make(input([session("c", turns: codex), session("k", provider: .claude, turns: claude)], account: account), limit: 20)
        XCTAssertNil(highlights.first { $0.kind == .parallel }, "24 overlapping turns in one native session are still one agent")
        let share = highlights.first { $0.kind == .providerShare }
        XCTAssertEqual(share?.value, "96%")
        XCTAssertEqual(share?.title, "Observed model steps by Codex")
        XCTAssertEqual(share?.detail, "24 Codex · 1 Claude")
        XCTAssertTrue(share?.note?.contains("work delivered") == true)
        XCTAssertEqual(highlights.first { $0.kind == .streak }?.detail, "Best run: 39 days")
    }

    func testParallelCountsDistinctSessionsAndDropsInheritedForkTurns() {
        let shared = turn("inherited", "2026-11-01T10:00:00Z", minutes: 60)
        let parent = session("p", turns: [shared, turn("p2", "2026-11-01T10:30:00Z", minutes: 60)])
        var child = session("child", turns: [shared, turn("child-work", "2026-11-01T10:00:00Z", minutes: 60)])
        child.parentSessionID = parent.nativeID
        let third = session("third", provider: .claude, turns: [turn("third-work", "2026-11-01T10:30:00Z", minutes: 60)])
        let result = ActivityHighlights.make(input([parent, child, third]), limit: 20).first { $0.kind == .parallel }
        XCTAssertEqual(result?.value, "3")
        XCTAssertEqual(result?.title, "Most agents at once")
        XCTAssertEqual(result?.detail, "2.3 on average while working")
        XCTAssertNil(ActivityHighlights.make(input([parent, child]), limit: 20).first { $0.kind == .parallel })
    }

    func testExpiredWindowsCannotRaiseLowPlanAlertOrDiluteHealthyCapacity() {
        let now = date("2026-11-02T18:00:00Z")
        let expired = QuotaWindow(id: "old", label: "5-hour", usedRatio: 0.99, resetAt: now, durationMinutes: 300)
        let current = QuotaWindow(id: "new", label: "Weekly", usedRatio: 0.1, resetAt: now.addingTimeInterval(86_400), durationMinutes: 10_080)
        let estimate = QuotaEstimate(agent: .claude, windows: [expired, current], source: .live, fetchedAt: now)
        let highlights = ActivityHighlights.make(input([], quotas: [.claude: estimate]))
        XCTAssertFalse(highlights.contains { $0.kind == .planLow })
        XCTAssertEqual(highlights.first?.value, "90%")
    }

    func testMissingOutputAndPartialUsageNeverInflateContextReuseRatio() {
        var turns = (0..<10).map { turn("missing-\($0)", "2026-11-01T10:00:00Z", usage: TokenUsage(input: 1_000, cachedInput: 999, total: 1_000)) }
        turns.append(turn("complete", "2026-11-01T11:00:00Z", usage: TokenUsage(input: 1_000, output: 10, cachedInput: 999, total: 1_010)))
        XCTAssertNil(ActivityHighlights.make(input([session("s", turns: turns)]), limit: 20).first { $0.kind == .contextReuse })
        let partial = (0..<12).map { index -> ActivityTurn in
            var value = turn("partial-\(index)", "2026-11-01T10:00:00Z", usage: TokenUsage(input: 1_000, output: 2, cachedInput: 999, total: 1_002))
            value.usageIsPartial = true
            return value
        }
        XCTAssertNil(ActivityHighlights.make(input([session("s", turns: partial)]), limit: 20).first { $0.kind == .contextReuse })
    }

    func testStaleAccountAndUnknownBestDoNotClaimARecordStreak() {
        let stale = ActivityAccountUsage(observedAt: date("2026-10-01T00:00:00Z"), currentStreakDays: 12, longestStreakDays: 12)
        XCTAssertNil(ActivityHighlights.make(input([], account: stale)).first { $0.kind == .streak })
        let current = ActivityAccountUsage(observedAt: date("2026-11-02T18:00:00Z"), currentStreakDays: 12)
        let streak = ActivityHighlights.make(input([], account: current)).first { $0.kind == .streak }
        XCTAssertEqual(streak?.detail, "Best run not reported")
        XCTAssertTrue(streak?.note?.contains("all your devices") == true)
        let inconsistent = ActivityAccountUsage(observedAt: date("2026-11-02T18:00:00Z"), currentStreakDays: 12, longestStreakDays: 10)
        XCTAssertNil(ActivityHighlights.make(input([], account: inconsistent)).first { $0.kind == .streak })
    }

    func testEmptyEvidenceProducesNoHighlights() {
        XCTAssertTrue(ActivityHighlights.make(input([])).isEmpty)
        let sparse = [turn("only", "2026-11-01T10:00:00Z")]
        XCTAssertTrue(ActivityHighlights.make(input([session("a", turns: sparse)])).isEmpty, "one request is not a pattern")
    }
}

final class BridgeLogDisplayTests: XCTestCase {
    func testFieldsRenderAsReadablePairsWithoutEscapedSlashes() {
        let entry = BridgeLogEntry(id: "1", timestamp: "2026-11-02T16:32:25.784Z", level: "INFO", message: "Started bridge session",
                                   fieldsSummary: #"{"project":"\/var\/folders\/t4\/bridge","session_id":"ABC","port":8742,"ok":true}"#,
                                   rawLine: "{}", isStructured: true)
        let sanitized = BridgeLogPresentation.sanitized(entry)
        XCTAssertFalse(sanitized.fieldsSummary?.contains(#"\/"#) ?? true)
        let pairs = BridgeLogPresentation.fieldPairs(sanitized.fieldsSummary)
        XCTAssertEqual(pairs.map(\.key), ["ok", "port", "project", "session id"])
        XCTAssertEqual(pairs.map(\.value), ["true", "8742", "/var/folders/t4/bridge", "ABC"])
        XCTAssertEqual(BridgeLogPresentation.displayMessage("Bridge runtime stopped gracefully"), "Agent Hub stopped gracefully")
        XCTAssertEqual(BridgeLogPresentation.displayMessage(entry.message), "Started relay session")
        XCTAssertEqual(BridgeLogPresentation.displayMessage("Recorded hook event during managed turn"), "Claude reported progress during a step")
        XCTAssertNotNil(BridgeLogPresentation.date(entry.timestamp))
        XCTAssertNotNil(BridgeLogPresentation.date("2026-11-02T16:32:25Z"))
    }
}

final class PresentationAggregateTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testWeekHourGridIsMondayFirstAndHonoursThePeriod() {
        let utc = TimeZone(identifier: "UTC")!
        let turns = [
            ActivityTurn(id: "mon", completedAt: date("2026-11-02T19:30:00Z")),   // Monday
            ActivityTurn(id: "sun", completedAt: date("2026-11-01T03:10:00Z")),   // Sunday
            ActivityTurn(id: "old", completedAt: date("2026-10-01T03:10:00Z")),
        ]
        let grid = ActivityAnalytics.weekHour(turns, from: date("2026-10-27T00:00:00Z"), to: date("2026-11-03T00:00:00Z"), timeZone: utc)
        XCTAssertEqual(grid.count, 7)
        XCTAssertEqual(grid[0][19], 1, "Monday is the first row")
        XCTAssertEqual(grid[6][3], 1, "Sunday is the last row")
        XCTAssertEqual(grid.flatMap { $0 }.reduce(0, +), 2, "turns outside the period are excluded")
    }

    func testCompositionNormalisesCodexAndClaudeConventions() throws {
        let codex = ActivityTurn(id: "codex", completedAt: Date(), usage: TokenUsage(input: 1_000, output: 10, cachedInput: 900, total: 1_010))
        let claude = ActivityTurn(id: "claude", completedAt: Date(), usage: TokenUsage(input: 5, output: 20, cachedInput: 500, cacheWriteInput: 75, total: 600))
        let unknown = ActivityTurn(id: "unknown", completedAt: Date(), usage: TokenUsage(output: 3, total: 50))
        let value = try XCTUnwrap(ActivityAnalytics.composition([codex, claude, unknown]))
        XCTAssertEqual(value.freshInput, 105)
        XCTAssertEqual(value.rereadContext, 1_400)
        XCTAssertEqual(value.cacheWrites, 75)
        XCTAssertEqual(value.output, 30)
        XCTAssertEqual(value.receipts, 2, "a receipt without cache reads is not split")
        XCTAssertEqual(value.total, 1_610)
        XCTAssertNil(ActivityAnalytics.composition([unknown]))
    }

    func testCompositionRejectsUnknownWritesAndImpossibleOrOverflowingTotals() {
        let unknownWrites = ActivityTurn(id: "ambiguous", usage: TokenUsage(input: 5, output: 20, cachedInput: 500, total: 600))
        let invalidWrites = ActivityTurn(id: "negative", usage: TokenUsage(input: 5, output: 20, cachedInput: 500, cacheWriteInput: -1, total: 525))
        let impossible = ActivityTurn(id: "overflow-components", usage: TokenUsage(input: 0, output: Int.max, cachedInput: Int.max, cacheWriteInput: 0, total: Int.max))
        XCTAssertNil(ActivityAnalytics.composition([unknownWrites, invalidWrites, impossible]))
        let fresh = ActivityTurn(id: "fresh", usage: TokenUsage(input: Int.max, output: 0, cachedInput: 0, cacheWriteInput: 0, total: Int.max))
        let output = ActivityTurn(id: "output", usage: TokenUsage(input: 0, output: 1, cachedInput: 0, cacheWriteInput: 0, total: 1))
        XCTAssertNil(ActivityAnalytics.composition([fresh, output]), "bucket sums can fit individually while their combined total overflows")
    }
}
