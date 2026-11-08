@testable import BridgeCore
import Foundation
import XCTest

final class CodexActivityCollectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDesktopReaderPreferencePreservesExplicitExecutableConfiguration() throws {
        let desktop = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertEqual(try CodexActivityCollector.reportingExecutable("codex", desktopCandidates: [
            URL(fileURLWithPath: "/missing/desktop/codex"), desktop,
        ]), desktop)
        XCTAssertEqual(try CodexActivityCollector.reportingExecutable("/bin/echo", desktopCandidates: [desktop]).path, "/bin/echo")
        XCTAssertThrowsError(try CodexActivityCollector.reportingExecutable("/missing/configured/codex", desktopCandidates: [desktop]))
    }

    func testNativeGoalPreservesReportedTimeAndUnknownBudget() throws {
        let goal = try XCTUnwrap(CodexActivityParser.goal(["goal": [
            "objective": "Ship report; api_key=private-secret", "status": "active",
            "createdAt": 1_799_910_000, "updatedAt": 1_799_999_000,
            "timeUsedSeconds": 3_600, "tokensUsed": 12_345, "tokenBudget": NSNull(),
        ]], nativeID: "root"))
        XCTAssertEqual(goal.providerTimeSeconds, 3_600)
        XCTAssertEqual(goal.age(at: now), 90_000)
        XCTAssertNil(goal.tokenBudget)
        XCTAssertEqual(goal.sessionID, "codex:root")
        XCTAssertFalse(goal.objective.contains("private-secret"))
    }

    func testNotLoadedIsUnknownToHelperAndForkIsNotSubagent() throws {
        var object = thread("fork")
        object["forkedFromId"] = "root"
        object["preview"] = "DO NOT SAVE raw prompt"
        let result = try XCTUnwrap(CodexActivityParser.session(object, turns: [turn("inherited")], goal: nil,
            telemetry: CodexActivityTranscript(), historyComplete: true, now: now))
        XCTAssertEqual(result.runtimeState, "notLoaded")
        XCTAssertNil(result.parentSessionID)
        XCTAssertEqual(result.turns.first?.id, "codex:turn:inherited")
        XCTAssertTrue(result.warnings.contains { $0.contains("Forked") })
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("DO NOT SAVE"))
        object["parentThreadId"] = "parent"
        XCTAssertEqual(CodexActivityParser.session(object, turns: [], goal: nil, telemetry: CodexActivityTranscript(),
            historyComplete: true, now: now)?.parentSessionID, "codex:parent")
    }

    func testTimingPromptsAndToolsRemainMetadataOnly() throws {
        let raw: [String: Any] = ["id": "turn", "status": "completed", "startedAt": 100, "completedAt": 160,
            "durationMs": 59_500, "itemsView": "full", "items": [
                ["id": "prompt", "type": "userMessage", "content": [["type": "text", "text": "PRIVATE_PROMPT"]]],
                ["id": "reasoning", "type": "reasoning", "content": ["PRIVATE_REASONING"]],
                ["id": "test", "type": "commandExecution", "command": "swift test --filter Example", "aggregatedOutput": "PRIVATE_OUTPUT"],
                ["id": "test", "type": "commandExecution", "command": "swift test"],
                ["id": "patch", "type": "fileChange", "status": "completed", "changes": [["path": "/repo/main.swift", "kind": ["type": "add"], "diff": "PRIVATE_DIFF"]]],
                ["id": "search", "type": "webSearch", "query": "PRIVATE_QUERY"],
            ]]
        let result = try XCTUnwrap(CodexActivityParser.turn(raw))
        XCTAssertEqual(result.durationSeconds, 59.5)
        XCTAssertEqual(result.promptCount, 1)
        XCTAssertNil(result.humanPromptCount)
        XCTAssertEqual(result.toolCount, 3)
        XCTAssertEqual(result.categories, ["tests": 1, "implementation": 1, "research": 1])
        XCTAssertEqual(result.artifacts.first?.path, "/repo/main.swift")
        XCTAssertNil(result.usage.total)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_"))
        var summary = raw
        summary["itemsView"] = "summary"
        XCTAssertEqual(CodexActivityParser.turn(summary)?.promptCount, 1, "Summary exposes observed submissions, without establishing human origin or full coverage")
        XCTAssertNil(CodexActivityParser.turn(summary)?.toolCount)
    }

    func testTranscriptUsageDeduplicatesResumeAndKeepsModelChanges() throws {
        var transcript = CodexActivityTranscript()
        let records: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "a", "started_at": 100]],
            ["type": "turn_context", "payload": ["turn_id": "a", "model": "model-a", "effort": "high"]],
            usage(lastInput: 100, lastOutput: 20, cumulative: 120),
            usage(lastInput: 50, lastOutput: 10, cumulative: 180),
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "a", "started_at": 100, "completed_at": 120]],
        ]
        for record in records + records { transcript.consume(record) }
        transcript.consume(["type": "turn_context", "payload": ["turn_id": "b", "model": "model-b", "collaboration_mode": ["settings": ["reasoning_effort": "ultra"]]]])
        transcript.consume(usage(lastInput: 20, lastOutput: 5, cumulative: 205))
        let a = try XCTUnwrap(CodexActivityParser.turn(turn("a"), telemetry: transcript))
        let b = try XCTUnwrap(CodexActivityParser.turn(turn("b"), telemetry: transcript))
        XCTAssertEqual(a.usage.input, 150)
        XCTAssertEqual(a.usage.output, 30)
        XCTAssertEqual(a.usage.total, 180, "Cached and reasoning subsets must not be added to totals")
        XCTAssertEqual(a.usage.cachedInput, 40)
        XCTAssertEqual(a.model, "model-a")
        XCTAssertEqual(a.effort, "high")
        XCTAssertEqual(a.durationSeconds, 20)
        XCTAssertEqual(a.usageIsPartial, false)
        XCTAssertEqual(b.model, "model-b")
        XCTAssertEqual(b.effort, "ultra")
        XCTAssertEqual(b.usage.total, 25)
        XCTAssertEqual(b.usageIsPartial, true)
        let session = try XCTUnwrap(CodexActivityParser.session(thread("root"), turns: [turn("a"), turn("b")], goal: nil,
            telemetry: transcript, historyComplete: true, now: now))
        XCTAssertEqual(session.models, ["model-a", "model-b"])
    }

    func testMissingComponentsStayUnknownAndAccountTotalsStaySeparate() throws {
        var transcript = CodexActivityTranscript()
        transcript.consume(["type": "turn_context", "payload": ["turn_id": "a", "model": "model"]])
        transcript.consume(usage(lastInput: 10, lastOutput: 2, cumulative: 12))
        transcript.consume(["type": "event_msg", "payload": ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": 5, "output_tokens": 1, "total_tokens": 6],
            "total_token_usage": ["total_tokens": 18],
        ]]])
        XCTAssertNil(transcript.turns["a"]?.usage.cachedInput)
        XCTAssertEqual(transcript.turns["a"]?.usage.total, 18)
        let account = try XCTUnwrap(CodexActivityParser.account([
            "summary": ["lifetimeTokens": 9_000, "longestRunningTurnSec": 300],
            "dailyUsageBuckets": [["startDate": "2026-11-02", "tokens": 500]],
        ], now: now))
        XCTAssertEqual(account.lifetimeTokens, 9_000)
        XCTAssertNil(account.peakDailyTokens)
        XCTAssertEqual(account.daily.first?.tokens, 500)
    }

    func testReadOnlyCollectionRefreshesPinnedGoalDiscoversChildrenAndBoundsTurns() async throws {
        var methods: [String] = []
        var turnPages = 0
        var childDiscovery = false
        let pinned = ActivitySession(id: "codex:older", provider: .codex, nativeID: "older", title: "Pinned older goal",
            createdAt: now, updatedAt: now, source: "test")
        let result = await CodexActivityCollector(configuration: AgentConfiguration()).collect(now: now, knownSessions: [pinned]) { method, params in
            methods.append(method)
            let id = params?["threadId"] as? String ?? ""
            switch method {
            case "account/usage/read": return ["summary": ["lifetimeTokens": 10_000]]
            case "thread/list":
                XCTAssertEqual(params?["useStateDbOnly"] as? Bool, true)
                if params?["ancestorThreadId"] as? String == "older" {
                    childDiscovery = true
                    var child = self.thread("child")
                    child["parentThreadId"] = "older"
                    return ["data": [child]]
                }
                return ["data": [self.thread("recent")]]
            case "thread/goal/get":
                if id == "older" { return ["goal": ["objective": "Current goal", "status": "active", "createdAt": 100, "updatedAt": 200, "timeUsedSeconds": 10, "tokensUsed": 200]] }
                return ["goal": NSNull()]
            case "thread/read":
                XCTAssertEqual(params?["includeTurns"] as? Bool, false)
                var value = self.thread(id)
                if id == "child" { value["parentThreadId"] = "older" }
                return ["thread": value]
            case "thread/turns/list":
                XCTAssertEqual(params?["itemsView"] as? String, "summary")
                if id != "older" { return ["data": []] }
                turnPages += 1
                return ["data": (0..<20).map { self.turn("\(turnPages)-\($0)") }, "nextCursor": "page-\(turnPages)"]
            default: XCTFail("Unexpected potentially mutating method \(method)"); return [:]
            }
        }
        XCTAssertTrue(childDiscovery)
        XCTAssertEqual(turnPages, 3)
        let session = try XCTUnwrap(result.sessions.first { $0.nativeID == "older" })
        XCTAssertEqual(session.turns.count, 60)
        XCTAssertFalse(session.historyComplete)
        XCTAssertEqual(session.goal?.status, "active")
        XCTAssertEqual(result.sessions.first { $0.nativeID == "child" }?.parentSessionID, "codex:older")
        XCTAssertEqual(result.accountUsage?.lifetimeTokens, 10_000)
        XCTAssertEqual(Set(methods), ["account/usage/read", "thread/list", "thread/goal/get", "thread/read", "thread/turns/list"])
    }

    func testLiveCollectionWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BRIDGE_LIVE_CODEX_ACTIVITY"] == "1" else {
            throw XCTSkip("Set BRIDGE_LIVE_CODEX_ACTIVITY=1 for passive local provider acceptance.")
        }
        let result = await CodexActivityCollector(configuration: AgentConfiguration()).collect()
        XCTAssertFalse(result.sessions.isEmpty, result.health.message)
        XCTAssertNotEqual(result.health.status, "unavailable")
        let goalSessions = result.sessions.filter { $0.goal?.status == "active" }
        print("Codex activity acceptance: \(result.sessions.count) native tasks, \(goalSessions.count) active goals, \(result.sessions.filter(\.isChild).count) subagents, \(result.sessions.flatMap(\.turns).filter { $0.usage.total != nil }.count) turns with usage, account total available: \(result.accountUsage?.lifetimeTokens != nil)")
        print("Codex source health: \(result.health.message)")
        for session in goalSessions {
            print("Goal receipt: models=\(session.models), turns=\(session.turns.count), warnings=\(session.warnings)")
        }
    }

    func testUnavailableCapabilitiesAreNotRetriedForEverySession() async {
        var goals = 0, histories = 0
        let result = await CodexActivityCollector(configuration: AgentConfiguration()).collect(now: now, knownSessions: []) { method, params in
            switch method {
            case "account/usage/read": throw CodexAppServerSession.RPCError(message: "Method not found")
            case "thread/list": return ["data": [self.thread("one"), self.thread("two"), self.thread("three")]]
            case "thread/goal/get": goals += 1; throw CodexAppServerSession.RPCError(message: "Unknown method thread/goal/get")
            case "thread/turns/list": histories += 1; throw CodexAppServerSession.RPCError(message: "Codex app-server did not answer thread/turns/list in time.")
            case "thread/read": return ["thread": self.thread(params?["threadId"] as? String ?? "")]
            default: XCTFail("Unexpected \(method)"); return [:]
            }
        }
        XCTAssertEqual(goals, 1)
        XCTAssertEqual(histories, 1)
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertNil(result.accountUsage)
        XCTAssertTrue(result.sessions.allSatisfy { !$0.historyComplete && $0.turns.isEmpty })
        XCTAssertTrue(result.health.message.contains("goal states"))
    }

    func testMalformedGoalPreservesLastKnownStateWhileExplicitNullClears() async throws {
        let goal = ActivityGoal(id: "goal", sessionID: "codex:one", objective: "Keep working", status: "active", createdAt: now, updatedAt: now)
        let known = ActivitySession(id: "codex:one", provider: .codex, nativeID: "one", title: "Goal", createdAt: now, updatedAt: now, goal: goal, source: "test")
        for malformed in [true, false] {
            let result = await CodexActivityCollector(configuration: AgentConfiguration()).collect(now: now, knownSessions: [known]) { method, params in
                switch method {
                case "account/usage/read": return ["summary": [:]]
                case "thread/list": return ["data": []]
                case "thread/goal/get": return ["goal": malformed ? ["status": "active"] as Any : NSNull()]
                case "thread/read": return ["thread": self.thread("one")]
                case "thread/turns/list": return ["data": []]
                default: XCTFail("Unexpected method \(method)"); return [:]
                }
            }
            XCTAssertEqual(result.sessions.first?.goal, malformed ? goal : nil)
            XCTAssertEqual(result.sessions.first?.warnings.contains("Goal state could not be refreshed."), malformed)
        }
    }

    func testSummaryUsesDeduplicatedNativeItemMetadataWithoutPayloads() throws {
        var transcript = CodexActivityTranscript()
        transcript.consume(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t", "started_at": 100]])
        let emptySummary = CodexActivityParser.turn(["id": "t", "items": [], "itemsView": "summary"], telemetry: transcript)
        XCTAssertNil(emptySummary?.promptCount)
        XCTAssertNil(emptySummary?.toolCount)
        transcript.consume(["type": "response_item", "payload": ["type": "message", "role": "user", "id": "user-1", "content": ["PRIVATE_PROMPT"]]])
        let item: [String: Any] = ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "t",
            "item": ["type": "CommandExecution", "id": "tool-1", "command": ["swift", "test"], "aggregated_output": "PRIVATE_RESULT"]]]
        transcript.consume(item)
        transcript.consume(item)
        let value = try XCTUnwrap(CodexActivityParser.turn(["id": "t", "items": [], "itemsView": "summary"], telemetry: transcript))
        XCTAssertEqual(value.promptCount, 1)
        XCTAssertNil(value.humanPromptCount)
        XCTAssertEqual(value.toolCount, 1)
        XCTAssertEqual(value.categories, ["tests": 1])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("PRIVATE_"))
    }

    func testShiftingTailUsageCannotMasqueradeAsCompleteTurnCorrection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("native.jsonl")
        let start: [String: Any] = ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t", "started_at": 100]]
        let context: [String: Any] = ["type": "turn_context", "payload": ["turn_id": "t", "model": "model"]]
        let completion: [String: Any] = ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t", "started_at": 100, "completed_at": 200]]
        let records: [[String: Any]] = [start, context, usage(lastInput: 100, lastOutput: 20, cumulative: 120),
            ["type": "irrelevant", "payload": String(repeating: "x", count: 4_000)],
            context, usage(lastInput: 50, lastOutput: 10, cumulative: 180), completion]
        let data = try records.reduce(into: Data()) { result, value in
            result.append(try JSONSerialization.data(withJSONObject: value)); result.append(10)
        }
        try data.write(to: path)
        let full = CodexActivityTranscript.read(path: path.path)
        let tail = CodexActivityTranscript.read(path: path.path, maximumBytes: 1_000)
        let fullTurn = try XCTUnwrap(CodexActivityParser.turn(turn("t"), telemetry: full))
        let tailTurn = try XCTUnwrap(CodexActivityParser.turn(turn("t"), telemetry: tail))
        XCTAssertEqual(fullTurn.usage.total, 180)
        XCTAssertEqual(fullTurn.usageIsPartial, false)
        XCTAssertEqual(tailTurn.usage.total, 60)
        XCTAssertEqual(tailTurn.usageIsPartial, true, "A provider completion timestamp does not establish that the full turn was imported")
        XCTAssertEqual(tailTurn.completedAt, fullTurn.completedAt)
    }

    func testUnchangedTranscriptIsReusedAndAnAppendIsReadAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("native.jsonl")
        func lines(_ records: [[String: Any]]) throws -> Data {
            try records.reduce(into: Data()) { result, value in
                result.append(try JSONSerialization.data(withJSONObject: value)); result.append(10)
            }
        }
        func closedTurn(_ id: String, at: Int) -> [[String: Any]] {
            [["type": "event_msg", "payload": ["type": "task_started", "turn_id": id, "started_at": at]],
             ["type": "turn_context", "payload": ["turn_id": id, "model": "model"]],
             ["type": "irrelevant", "payload": String(repeating: "x", count: 70_000)],
             ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": id, "started_at": at, "completed_at": at + 10]]]
        }
        try lines(closedTurn("a", at: 100)).write(to: path)
        let first = CodexActivityTranscript.read(path: path.path)
        let repeated = CodexActivityTranscript.read(path: path.path)
        XCTAssertEqual(Set(first.turns.keys), ["a"], "lines spanning read chunks are still parsed")
        XCTAssertEqual(Set(repeated.turns.keys), ["a"])
        XCTAssertEqual(repeated.turns["a"]?.completedAt, first.turns["a"]?.completedAt)

        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: try lines(closedTurn("b", at: 200)))
        try handle.close()
        let appended = CodexActivityTranscript.read(path: path.path)
        XCTAssertEqual(Set(appended.turns.keys), ["a", "b"], "a changed file is never served from the cache")
    }

    func testOpenTurnAndInterruptedScanUsageAreExplicitLowerBounds() throws {
        var transcript = CodexActivityTranscript()
        transcript.consume(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t", "started_at": 100]])
        transcript.consume(usage(lastInput: 100, lastOutput: 20, cumulative: 120))
        var raw = turn("t")
        raw["status"] = "inProgress"
        XCTAssertEqual(CodexActivityParser.turn(raw, telemetry: transcript)?.usageIsPartial, true)
        transcript.consume(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t", "started_at": 100, "completed_at": 200]])
        XCTAssertEqual(CodexActivityParser.turn(raw, telemetry: transcript)?.usageIsPartial, true, "Stale API state keeps the receipt conservatively partial")
        XCTAssertEqual(CodexActivityParser.turn(turn("t"), telemetry: transcript)?.usageIsPartial, false)
        transcript.scanTruncated = true
        XCTAssertEqual(CodexActivityParser.turn(turn("t"), telemetry: transcript)?.usageIsPartial, true)
        XCTAssertNil(CodexActivityParser.turn(turn("unknown"), telemetry: transcript)?.usageIsPartial)
    }

    func testMalformedHistoryCannotBecomeAnAuthoritativeEmptySnapshot() async throws {
        let malformedPages: [[String: Any]] = [
            [:], ["data": NSNull()], ["data": ["not-a-turn"]],
            ["data": [["status": "completed"]]], ["data": [], "nextCursor": 42],
        ]
        for page in malformedPages {
            let result = await CodexActivityCollector(configuration: AgentConfiguration()).collect(now: now, knownSessions: []) { method, params in
                switch method {
                case "account/usage/read": return ["summary": [:]]
                case "thread/list": return ["data": params?["ancestorThreadId"] == nil ? [self.thread("one")] : []]
                case "thread/goal/get": return ["goal": NSNull()]
                case "thread/read": return ["thread": self.thread("one")]
                case "thread/turns/list": return page
                default: XCTFail("Unexpected method \(method)"); return [:]
                }
            }
            let session = try XCTUnwrap(result.sessions.first)
            XCTAssertFalse(session.historyComplete, "Invalid native data must never authorize removing previously saved turns: \(page)")
            XCTAssertTrue(session.warnings.contains("Turn history could not be fully loaded."))
        }
    }

    func testRequestedSummaryWithoutDiscriminatorDoesNotInventZeroCounts() async throws {
        let result = await CodexActivityCollector(configuration: AgentConfiguration()).collect(now: now, knownSessions: []) { method, params in
            switch method {
            case "account/usage/read": return ["summary": [:]]
            case "thread/list": return ["data": params?["ancestorThreadId"] == nil ? [self.thread("one")] : []]
            case "thread/goal/get": return ["goal": NSNull()]
            case "thread/read": return ["thread": self.thread("one")]
            case "thread/turns/list": return ["data": [["id": "one-turn", "status": "completed", "items": []]]]
            default: XCTFail("Unexpected method \(method)"); return [:]
            }
        }
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertTrue(session.historyComplete)
        XCTAssertNil(session.turns.first?.promptCount)
        XCTAssertNil(session.turns.first?.toolCount)
    }

    func testSameCumulativeTotalWithAdditionalMetadataIsNotCountedTwice() throws {
        var transcript = CodexActivityTranscript()
        transcript.consume(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t", "started_at": 100]])
        transcript.consume(usage(lastInput: 100, lastOutput: 20, cumulative: 120))
        transcript.consume(["type": "event_msg", "payload": ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": 100, "output_tokens": 20, "total_tokens": 120],
            "total_token_usage": ["input_tokens": 100, "output_tokens": 20, "total_tokens": 120],
        ]]])
        transcript.consume(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t", "started_at": 100, "completed_at": 200]])
        XCTAssertEqual(transcript.turns["t"]?.usage.total, 120)
        XCTAssertEqual(transcript.usageIsPartial(for: "t", status: "completed"), false)
    }

    func testMissingAndImpossibleTokenIncrementsStayPartialWithoutInflatingTotals() throws {
        for missing in [true, false] {
            var transcript = CodexActivityTranscript()
            transcript.consume(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t", "started_at": 100]])
            transcript.consume(usage(lastInput: 100, lastOutput: 20, cumulative: 120))
            // A 60-token last response cannot explain a 180-token advance;
            // nor can a 120-token response fit a 60-token advance.
            transcript.consume(usage(lastInput: missing ? 50 : 100, lastOutput: missing ? 10 : 20,
                cumulative: missing ? 300 : 180))
            transcript.consume(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t", "started_at": 100, "completed_at": 200]])
            XCTAssertEqual(transcript.turns["t"]?.usage.total, missing ? 180 : 120)
            XCTAssertEqual(transcript.usageIsPartial(for: "t", status: "completed"), true)
        }
    }

    func testMalformedDatesCannotOverflowNativeGoalIdentity() {
        XCTAssertNil(CodexActivityParser.date(1e100))
        XCTAssertNil(CodexActivityParser.goal(["goal": ["objective": "Goal", "status": "active",
            "createdAt": 1e100, "updatedAt": 100]], nativeID: "root"))
        XCTAssertNil(CodexActivityParser.date(true))
        XCTAssertNil(CodexActivityParser.turn(["id": "bad-duration", "durationMs": 1e100])?.durationSeconds)
        XCTAssertNil(CodexActivityParser.goal(["goal": ["objective": "Goal", "status": "active",
            "createdAt": 100, "updatedAt": 200, "timeUsedSeconds": 1e100]], nativeID: "root")?.providerTimeSeconds)
    }

    private func thread(_ id: String) -> [String: Any] {
        ["id": id, "name": id, "createdAt": 100, "updatedAt": 200, "cwd": "/repo", "status": ["type": "notLoaded"]]
    }
    private func turn(_ id: String) -> [String: Any] {
        ["id": id, "status": "completed", "itemsView": "full", "items": []]
    }
    private func usage(lastInput: Int, lastOutput: Int, cumulative: Int) -> [String: Any] {
        ["type": "event_msg", "timestamp": UUID().uuidString, "payload": ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": lastInput, "output_tokens": lastOutput, "cached_input_tokens": 20,
                "cache_write_input_tokens": 0, "reasoning_output_tokens": 2, "total_tokens": lastInput + lastOutput],
            "total_token_usage": ["total_tokens": cumulative],
        ]]]
    }
}
