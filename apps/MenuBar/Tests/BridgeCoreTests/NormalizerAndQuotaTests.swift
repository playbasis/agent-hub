@testable import BridgeCore
import Foundation
import XCTest

final class NormalizerAndQuotaTests: XCTestCase {
    func testClaudeStopNormalizesToTerminalEvent() throws {
        let event = try EventNormalizer.normalizeClaudeHook(
            name: "Stop",
            payload: [
                "session_id": .string("claude-session"),
                "cwd": .string("/tmp/project"),
                "last_assistant_message": .string("Implemented tests <bridge:continue>"),
            ],
            bridgeSessionID: "bridge-session"
        )
        XCTAssertEqual(event.source, .claude)
        XCTAssertEqual(event.type, .turnComplete)
        XCTAssertEqual(event.sessionID, "bridge-session")
        XCTAssertEqual(event.metadata["bridge_managed"], .bool(false))
    }

    func testClaudeFailureDetectsRateLimit() throws {
        let event = try EventNormalizer.normalizeClaudeHook(
            name: "StopFailure",
            payload: [
                "session_id": .string("s"),
                "cwd": .string("/tmp/project"),
                "error": .string("Usage limit reached; try again in 20 minutes"),
            ]
        )
        XCTAssertEqual(event.type, .rateLimit)
    }

    func testQuotaSwitchesAndRecovers() {
        var tracker = QuotaTracker(cooldownMinutes: 60)
        let now = Date()
        let event = BridgeEvent(
            timestamp: now,
            source: .claude,
            type: .rateLimit,
            content: .string("limited"),
            sessionID: "s",
            projectPath: "/tmp/project"
        )
        tracker.update(event: event, now: now)
        XCTAssertEqual(tracker.bestAvailable(preferred: .claude), .codex)
        tracker.refresh(now: now.addingTimeInterval(3_601))
        XCTAssertTrue(tracker.snapshot()["claude"]?.available == true)
    }

    func testTurnCompletionDoesNotInventQuotaConsumption() {
        var tracker = QuotaTracker(cooldownMinutes: 60)
        let event = BridgeEvent(
            source: .codex,
            type: .turnComplete,
            content: .string("done"),
            sessionID: "s",
            projectPath: "/tmp/project"
        )
        tracker.update(event: event)
        let estimate = tracker.snapshot()["codex"]
        XCTAssertEqual(estimate?.remainingRatio, 1)
        XCTAssertEqual(estimate?.source, .unavailable)
        XCTAssertEqual(estimate?.observedTurns, 1)
    }

    func testCodexAppServerUsageParsesRealWindow() throws {
        let reset = 1_785_493_680
        let line = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":\(reset)},"secondary":null,"planType":"plus","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":\(reset)},"secondary":null,"planType":"plus","rateLimitReachedType":null}}}}
        """
        let estimate = try CodexUsageParser.parse(line: line, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(estimate.source, .live)
        XCTAssertEqual(estimate.planName, "Plus")
        XCTAssertEqual(estimate.windows.count, 1)
        XCTAssertEqual(estimate.windows.first?.label, "Weekly limit")
        XCTAssertEqual(estimate.windows.first?.usedRatio ?? 0, 0.64, accuracy: 0.001)
        XCTAssertEqual(
            estimate.windows.first?.resetAt,
            Date(timeIntervalSince1970: TimeInterval(reset))
        )
    }

    func testCodexUsageParserAcceptsDirectAppServerResult() throws {
        let reset = 1_785_493_680
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 25,
                    "windowDurationMins": 300,
                    "resetsAt": reset,
                ],
                "planType": "pro",
                "rateLimitReachedType": NSNull(),
            ],
        ]
        let estimate = try CodexUsageParser.parse(
            result: result,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(estimate.planName, "Pro")
        XCTAssertEqual(estimate.windows.first?.label, "5-hour limit")
        XCTAssertEqual(estimate.windows.first?.usedRatio ?? 0, 0.25, accuracy: 0.001)
    }

    func testClaudeUsageScreenParsesAllProviderWindows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let terminal = """
        Context window
        425.9k / 1.0M (43%)

        Plan usage limits · Max (5x)

        Current session
        Resets in 1 hr 34 min
        100% used

        Current week (all models)
        Resets in 1 hr 14 min
        59% used

        Weekly · Fable
        Resets in 1 hr 14 min
        100% used
        """
        let estimate = ClaudeUsageParser.parse(terminalTranscript: terminal, now: now)
        XCTAssertEqual(estimate.source, .live)
        XCTAssertEqual(estimate.planName, "Claude Max (5x)")
        XCTAssertEqual(estimate.windows.count, 3)
        XCTAssertEqual(estimate.windows.map(\.label), [
            "5-hour limit",
            "Weekly · all models",
            "Weekly · Fable",
        ])
        XCTAssertEqual(estimate.windows.map { Int(($0.usedRatio * 100).rounded()) }, [100, 59, 100])
        XCTAssertEqual(
            estimate.windows.first?.resetAt,
            now.addingTimeInterval(TimeInterval((60 + 34) * 60))
        )
        XCTAssertFalse(estimate.available)
    }

    func testCodexUsageRejectsOutOfRangeAndMalformedPercentagesBeforeClamping() {
        for raw in ["-1", "101", "-0.5", "100.5", #""NaN""#, #""Infinity""#, "null"] {
            let line = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":\#(raw),"windowDurationMins":300},"secondary":null}}}"#
            XCTAssertThrowsError(try CodexUsageParser.parse(line: line, now: Date()), raw)
        }
    }

    func testCodexUsagePreservesExplicitZeroAndFullWithoutAResetTime() throws {
        for percent in [0, 100] {
            let line = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":\#(percent),"windowDurationMins":300},"secondary":null}}}"#
            let estimate = try CodexUsageParser.parse(line: line, now: Date())
            XCTAssertEqual(estimate.windows.first?.usedRatio, Double(percent) / 100)
            XCTAssertEqual(estimate.available, percent < 100, "an exhausted window is unavailable even if reset timing is missing")
            XCTAssertNil(estimate.limitedUntil)
        }
    }

    func testCodexInvalidWindowCannotContaminateAValidSibling() throws {
        let line = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":101,"windowDurationMins":300},"secondary":{"usedPercent":42,"windowDurationMins":10080}}}}"#
        let estimate = try CodexUsageParser.parse(line: line, now: Date())
        XCTAssertEqual(estimate.windows.map(\.id), ["codex-secondary"])
        XCTAssertEqual(estimate.windows.first?.usedRatio, 0.42)
        XCTAssertEqual(estimate.remainingRatio, 0.58, accuracy: 0.0001)
    }

    func testClaudeUsageRejectsWholeMalformedPercentageTokens() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for raw in ["-1", "101", "100.01", "NaN", "Infinity", "inf", "1e3", "1.2.3", String(repeating: "9", count: 309)] {
            let estimate = ClaudeUsageParser.parse(terminalTranscript: "Current session\n\(raw)% used", now: now)
            XCTAssertTrue(estimate.windows.isEmpty, raw)
            XCTAssertEqual(estimate.source, .unavailable, raw)
            XCTAssertNil(estimate.fetchedAt, raw)
        }
    }

    func testClaudeUsagePreservesZeroDecimalAndFullWithoutAResetTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (text, ratio) in [("0", 0.0), ("12.5", 0.125), ("100", 1.0)] {
            let estimate = ClaudeUsageParser.parse(terminalTranscript: "Current session\n\(text)% used", now: now)
            XCTAssertEqual(estimate.windows.first?.usedRatio, ratio)
            XCTAssertEqual(estimate.available, ratio < 1)
        }
    }

    func testClaudeUsageDoesNotBorrowPercentagesOrResetsFromAnotherWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let missing = "Current session\nNo usage reading\nCurrent week (all models)\n50% used\nResets in 20 min"
        let estimate = ClaudeUsageParser.parse(terminalTranscript: missing, now: now)
        XCTAssertEqual(estimate.windows.map(\.id), ["claude-seven-day"])
        let noReset = "Current session\n25% used\nCurrent week (all models)\nResets in 20 min\n50% used"
        let other = ClaudeUsageParser.parse(terminalTranscript: noReset, now: now)
        XCTAssertEqual(other.windows.count, 2)
        XCTAssertNil(other.windows.first?.resetAt)
        XCTAssertEqual(other.windows.last?.resetAt, now.addingTimeInterval(1_200))
    }

    func testClaudeNewestMalformedRedrawCannotMakeAnOldReadingLookFresh() {
        let transcript = "Current session\n25% used\nCurrent session\nNaN% used"
        let estimate = ClaudeUsageParser.parse(terminalTranscript: transcript, now: Date())
        XCTAssertTrue(estimate.windows.isEmpty)
        XCTAssertNil(estimate.fetchedAt)
    }

    func testClaudeResetDurationCannotOverflowOrExceedItsPlanWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for reset in ["\(Int.max) hr 1 min", "\(Int.max) min", "6 hr 1 min"] {
            let estimate = ClaudeUsageParser.parse(terminalTranscript: "Current session\n25% used\nResets in \(reset)", now: now)
            XCTAssertEqual(estimate.windows.first?.usedRatio, 0.25)
            XCTAssertNil(estimate.windows.first?.resetAt, reset)
        }
        let ordinary = ClaudeUsageParser.parse(terminalTranscript: "Current session\n25% used\nResets in 2 hr", now: now)
        XCTAssertEqual(ordinary.windows.first?.resetAt, now.addingTimeInterval(7_200))
    }

    func testFailedRefreshKeepsLastProviderReadingAndFreshness() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fetchedAt = now.addingTimeInterval(-60)
        var tracker = QuotaTracker(cooldownMinutes: 60)
        tracker.applyProviderUsage(
            QuotaEstimate(
                agent: .claude,
                remainingRatio: 0.4,
                windows: [
                    QuotaWindow(id: "weekly", label: "Weekly", usedRatio: 0.6),
                ],
                source: .live,
                fetchedAt: fetchedAt
            )
        )
        tracker.applyProviderUsage(
            QuotaEstimate(
                agent: .claude,
                source: .unavailable,
                statusMessage: "Refresh failed"
            ),
            now: now
        )
        let estimate = tracker.snapshot()["claude"]
        XCTAssertEqual(estimate?.windows.first?.usedRatio, 0.6)
        XCTAssertEqual(estimate?.fetchedAt, fetchedAt)
        XCTAssertEqual(estimate?.statusMessage, "Refresh failed")
    }

    func testExpiredProviderReadingIsClearedAfterUnavailableRefresh() {
        let now = Date(timeIntervalSince1970: 10_000)
        var tracker = QuotaTracker(cooldownMinutes: 60)
        tracker.applyProviderUsage(
            QuotaEstimate(
                agent: .claude,
                remainingRatio: 0.4,
                windows: [QuotaWindow(id: "weekly", label: "Weekly", usedRatio: 0.6)],
                source: .live,
                fetchedAt: now.addingTimeInterval(-QuotaTracker.unavailableReadingGrace - 1)
            ),
            now: now
        )
        tracker.applyProviderUsage(
            QuotaEstimate(
                agent: .claude,
                source: .unavailable,
                statusMessage: "Claude Code is signed out. Sign in to load plan usage."
            ),
            now: now
        )

        let estimate = tracker.snapshot()["claude"]
        XCTAssertEqual(estimate?.source, .unavailable)
        XCTAssertTrue(estimate?.windows.isEmpty == true)
        XCTAssertNil(estimate?.fetchedAt)
        XCTAssertEqual(
            estimate?.statusMessage,
            "Claude Code is signed out. Sign in to load plan usage."
        )
    }
}
