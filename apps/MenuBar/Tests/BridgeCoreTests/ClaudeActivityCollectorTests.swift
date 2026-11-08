@testable import BridgeCore
import Foundation
import XCTest

final class ClaudeActivityCollectorTests: XCTestCase {
    private var root: URL!
    private var now: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        now = Date()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func stamp(_ offset: Double = 0) -> String {
        ISO8601.withFractional.string(from: now.addingTimeInterval(offset))
    }

    @discardableResult
    private func write(_ rows: [[String: Any]], name: String = "session.jsonl", trailing: String = "") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(10)
        }
        data.append(contentsOf: trailing.utf8)
        try data.write(to: url)
        return url
    }

    private func assistant(_ request: String, output: Int = 8, model: String = "claude-sonnet-5", time: Double = 0,
                           content: [[String: Any]] = []) -> [String: Any] {
        ["type": "assistant", "sessionId": "native-session", "cwd": "/projects/app", "timestamp": stamp(time),
         "requestId": request, "effort": "high", "message": ["id": "message-\(request)", "role": "assistant",
            "model": model, "stop_reason": "end_turn", "content": content,
            "usage": ["input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": 100,
                "cache_creation_input_tokens": 20, "reasoning_tokens": 4,
                "cache_creation": ["ephemeral_5m_input_tokens": 20, "ephemeral_1h_input_tokens": 0]]]]
    }

    private func user(_ id: String, source: String? = nil, content: Any = "private prompt content") -> [String: Any] {
        var row: [String: Any] = ["type": "user", "sessionId": "native-session", "cwd": "/projects/app",
            "timestamp": stamp(-2), "uuid": id, "message": ["role": "user", "content": content]]
        if let source { row["source"] = source }
        return row
    }

    func testRepeatedSnapshotsCorrectUsageWithoutDoubleCountingAndKeepModelChanges() async throws {
        let tool: [String: Any] = ["type": "tool_use", "id": "edit-1", "name": "Edit", "input": ["file_path": "/projects/app/main.swift", "new_string": "secret code"]]
        try write([user("p1"), assistant("r1", output: 1, time: -10, content: [tool]),
                   assistant("r1", output: 8, time: -8, content: [tool]),
                   assistant("r2", output: 12, model: "claude-opus-5", time: -2)])
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        let session = try XCTUnwrap(collection.sessions.first)
        XCTAssertEqual(session.turns.count, 2)
        XCTAssertEqual(session.models, ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(session.efforts, ["high"])
        let first = try XCTUnwrap(session.turns.first { $0.id.hasSuffix("r1") })
        XCTAssertEqual(first.usage.total, 138) // Reasoning and TTL cache components are subsets.
        XCTAssertEqual(first.usage.provenance, .derived)
        XCTAssertEqual(first.toolCount, 1)
        XCTAssertEqual(first.categories["implementation"], 1)
        XCTAssertEqual(first.artifacts.first?.path, "main.swift")
        XCTAssertEqual(first.promptCount, 1)
        XCTAssertNil(first.humanPromptCount)
        XCTAssertNil(first.durationSeconds)
        XCTAssertNil(first.completedAt)
        XCTAssertNil(ActivityMetrics.elapsedSeconds(session.turns))
        XCTAssertEqual(session.runtimeState, "unknown")
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private prompt content"))
        XCTAssertFalse(encoded.contains("secret code"))
    }

    func testToolResultsAndMetaMessagesAreNotPromptsAndHumanOriginMustBeExplicit() async throws {
        let human = user("human", source: "human")
        var meta = user("meta"); meta["isMeta"] = true
        let toolResult = user("tool", content: [["type": "tool_result", "tool_use_id": "tool1", "content": "result"]])
        let wrappedTool = user("wrapped-tool", content: [["type": "text", "text": "tool wrapper"],
            ["type": "tool_result", "tool_use_id": "tool2", "content": "result"]])
        try write([human, human, meta, toolResult, wrappedTool, assistant("r1")])
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        let turn = try XCTUnwrap(collection.sessions.first?.turns.first)
        XCTAssertEqual(turn.promptCount, 1)
        XCTAssertEqual(turn.humanPromptCount, 1)
    }

    func testSubagentsRetainDistinctIdentityAndParentRelationship() async throws {
        try write([assistant("same-request")], name: "project/native-session.jsonl")
        try write([assistant("same-request")], name: "project/native-session/subagents/agent-worker.jsonl")
        try write([assistant("same-request")], name: "project/native-session/subagents/workflows/wf-1/agent-nested.jsonl")
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        XCTAssertEqual(collection.sessions.count, 3)
        let children = collection.sessions.filter(\.isChild)
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children.allSatisfy { $0.parentSessionID == "claude:native-session" })
        XCTAssertEqual(Set(collection.sessions.flatMap(\.turns).map(\.id)).count, 3)
    }

    func testMissingUsageStaysUnknownAndPartialTrailingLineIsRetried() async throws {
        var row = assistant("r1")
        var message = try XCTUnwrap(row["message"] as? [String: Any]); message.removeValue(forKey: "usage")
        message.removeValue(forKey: "content"); row["message"] = message
        try write([row], trailing: "{\"type\":\"assistant\"")
        let collector = ClaudeActivityCollector(root: root)
        let initial = await collector.collect(now: now)
        let session = try XCTUnwrap(initial.sessions.first)
        XCTAssertFalse(session.historyComplete)
        XCTAssertNil(session.turns.first?.usage.input)
        XCTAssertNil(session.turns.first?.usage.total)
        XCTAssertNil(session.turns.first?.toolCount)
        try write([assistant("r1", output: 30)])
        let updated = await collector.collect(now: now.addingTimeInterval(61))
        XCTAssertEqual(updated.sessions.first?.turns.count, 1)
        XCTAssertEqual(updated.sessions.first?.turns.first?.usage.total, 160)
        XCTAssertEqual(updated.sessions.first?.historyComplete, true)
    }

    func testIncompleteTokenComponentsDoNotInventZeroOrTotalAndDirectDurationIsUsed() async throws {
        var row = assistant("r1")
        var message = try XCTUnwrap(row["message"] as? [String: Any])
        message["usage"] = ["input_tokens": 5, "output_tokens": 4]
        row["message"] = message; row["duration_ms"] = 12_500
        try write([row])
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        let turn = try XCTUnwrap(collection.sessions.first?.turns.first)
        XCTAssertNil(turn.usage.cachedInput)
        XCTAssertNil(turn.usage.cacheWriteInput)
        XCTAssertNil(turn.usage.total)
        XCTAssertEqual(turn.durationSeconds, 12.5)
        XCTAssertEqual(try XCTUnwrap(ActivityMetrics.elapsedSeconds([turn])), 12.5, accuracy: 0.01)
    }

    func testCacheCreationVariantsRemainNullableAndReasoningIsNotAddedTwice() async throws {
        var complete = assistant("complete")
        var message = try XCTUnwrap(complete["message"] as? [String: Any])
        message["usage"] = ["input_tokens": 5, "output_tokens": 10, "cache_read_input_tokens": 100,
            "reasoning_tokens": 8, "cache_creation": ["ephemeral_5m_input_tokens": 20, "ephemeral_1h_input_tokens": 30]]
        complete["message"] = message
        var partial = assistant("partial")
        message["usage"] = ["input_tokens": 5, "output_tokens": 10, "cache_read_input_tokens": 100,
            "cache_creation": ["ephemeral_5m_input_tokens": 20]]
        partial["message"] = message
        try write([complete, partial])
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        let turns = try XCTUnwrap(collection.sessions.first).turns
        XCTAssertEqual(turns.first { $0.id.hasSuffix(":complete") }?.usage.total, 165)
        XCTAssertNil(turns.first { $0.id.hasSuffix(":partial") }?.usage.cacheWriteInput)
        XCTAssertNil(turns.first { $0.id.hasSuffix(":partial") }?.usage.total)
    }

    func testMalformedNumbersCannotCreateImpossibleDurationsOrTokenCounts() async throws {
        var row = assistant("invalid")
        var message = try XCTUnwrap(row["message"] as? [String: Any])
        message["usage"] = ["input_tokens": true, "output_tokens": -1, "cache_read_input_tokens": 1.5,
            "cache_creation_input_tokens": "not-a-number", "total_tokens": 1e100]
        row["message"] = message
        row["duration_ms"] = 1e100
        try write([row])
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        let turn = try XCTUnwrap(collection.sessions.first?.turns.first)
        XCTAssertNil(turn.durationSeconds)
        XCTAssertNil(turn.completedAt)
        XCTAssertNil(turn.usage.input)
        XCTAssertNil(turn.usage.output)
        XCTAssertNil(turn.usage.cachedInput)
        XCTAssertNil(turn.usage.cacheWriteInput)
        XCTAssertNil(turn.usage.total)
        XCTAssertEqual(turn.usage.provenance, .unavailable)
    }

    func testSensitiveAndOutOfProjectArtifactPathsAreExcluded() async throws {
        let paths = ["/projects/app/.env", "/projects/app/.env.production", "/projects/app/.ssh/key", "/outside/secret", "/projects/app/src/main.swift"]
        let tools = paths.enumerated().map { i, path in
            ["type": "tool_use", "id": "tool-\(i)", "name": "Write", "input": ["file_path": path, "content": "secret"]] as [String: Any]
        }
        try write([assistant("r1", content: tools)])
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        let turn = try XCTUnwrap(collection.sessions.first?.turns.first)
        XCTAssertEqual(turn.toolCount, 5)
        XCTAssertEqual(turn.artifacts.map(\.path), ["src/main.swift"])
        XCTAssertEqual(turn.artifacts.first?.status, "edit_requested")
    }

    func testRecentFileLimitAndLargeTranscriptAreExplicitLowerBounds() async throws {
        for i in 0..<43 {
            var row = assistant("request-\(i)"); row["sessionId"] = "session-\(i)"
            let url = try write([row], name: "session-\(i).jsonl")
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(-i))], ofItemAtPath: url.path)
        }
        let old = try write([assistant("old")], name: "old.jsonl")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-15 * 86_400)], ofItemAtPath: old.path)
        let collection = await ClaudeActivityCollector(root: root).collect(now: now)
        XCTAssertEqual(collection.sessions.count, 40)
        XCTAssertTrue(collection.health.message.contains("newest 40"))
        XCTAssertFalse(collection.sessions.contains { $0.nativeID == "native-session" })

        let largeRoot = root.appendingPathComponent("large")
        let largeRow: [String: Any] = ["type": "progress", "timestamp": stamp(-20), "data": String(repeating: "x", count: 2_100_000)]
        try write([user("p1"), largeRow, assistant("recent", time: -1)], name: "large/session.jsonl")
        let largeCollection = await ClaudeActivityCollector(root: largeRoot).collect(now: now)
        let session = try XCTUnwrap(largeCollection.sessions.first)
        XCTAssertFalse(session.historyComplete)
        XCTAssertEqual(session.turns.count, 1)
        XCTAssertTrue(session.warnings.contains { $0.contains("latest 2 MiB") })
        XCTAssertTrue(largeCollection.health.message.contains("lower bounds"))
    }
}
