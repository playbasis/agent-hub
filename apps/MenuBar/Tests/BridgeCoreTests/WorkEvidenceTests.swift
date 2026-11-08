import Foundation
import Darwin
import XCTest
@testable import BridgeCore

final class WorkEvidenceTests: XCTestCase {
    func testCompletedCommandAndMCPErrorDoNotBecomeSuccessfulToolRuns() {
        let batch = WorkEvidenceParser.codex(["data": [
            ["id": "shell", "type": "commandExecution", "status": "completed", "exitCode": 2],
            ["id": "mcp", "type": "mcpToolCall", "status": "completed", "result": ["isError": true]],
            ["id": "dynamic", "type": "dynamicToolCall", "status": "completed", "error": ["message": "provider failed"]],
            ["id": "good", "type": "mcpToolCall", "status": "completed", "error": NSNull(), "result": ["isError": false]],
        ]], includeText: false)
        XCTAssertEqual(batch.items.map(\.status), ["failed", "failed", "failed", "completed"])
        let summary = WorkOutcomeSignals.summarize(batch.items)
        XCTAssertEqual(summary.failureCount, 3)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.successFraction, 0.25)
    }

    func testHandoffRelationshipsRemainVisibleWithoutCapturingPromptText() {
        let batch = WorkEvidenceParser.codex(["data": [["id": "delegate", "type": "collabAgentToolCall", "receiverThreadIds": ["helper-b", "helper-a", "helper-a"], "prompt": "private task"]]], includeText: false)
        XCTAssertEqual(batch.items.first?.relatedSessionIDs, ["helper-a", "helper-b"])
        XCTAssertNil(batch.items.first?.preview)
        XCTAssertFalse(batch.items.description.contains("private task"))
    }

    func testCodexWrapperTimingAndVisibleSequenceWithoutPayloadByDefault() throws {
        let result: [String: Any] = ["data": [
            ["turnId": "turn", "startedAtMs": 1_700_000_000_000 as Int64, "item": ["id": "request", "type": "userMessage", "content": [["type": "text", "text": "private request"]]]],
            ["turnId": "turn", "startedAtMs": 1_700_000_001_000 as Int64, "item": ["id": "command", "type": "commandExecution", "command": "test", "aggregatedOutput": "private output", "exitCode": 1, "durationMs": 1200]],
            ["turnId": "turn", "item": ["id": "response", "type": "agentMessage", "text": "private response"]],
        ], "nextCursor": NSNull()]
        let batch = WorkEvidenceParser.codex(result, includeText: false)
        XCTAssertEqual(batch.items.map(\.kind), [.request, .toolCall, .response])
        XCTAssertEqual(batch.items[0].timestamp, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(batch.items[1].status, "failed")
        XCTAssertEqual(batch.items[1].exitCode, 1)
        XCTAssertEqual(batch.items[1].durationSeconds, 1.2)
        XCTAssertTrue(batch.items.allSatisfy { $0.preview == nil })
        XCTAssertFalse(batch.isPartial)
    }

    func testOnlyProviderSummaryCanAppearNeverHiddenReasoning() {
        let result: [String: Any] = ["data": [
            ["type": "reasoning", "id": "hidden", "content": ["secret chain"], "encryptedContent": "encrypted secret"],
            ["type": "reasoning", "id": "summary", "summary": ["Public provider summary"], "content": ["secret chain"]],
            ["type": "agentMessage", "id": "analysis", "phase": "analysis", "text": "secret analysis"],
        ]]
        let batch = WorkEvidenceParser.codex(result, includeText: true)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertEqual(batch.items.first?.preview, "Public provider summary")
        XCTAssertFalse(batch.items.description.contains("secret chain"))
        XCTAssertFalse(batch.items.description.contains("secret analysis"))
    }

    func testUnknownSchemaMissingIdentityAndCursorStayPartial() {
        let batch = WorkEvidenceParser.codex(["data": [["type": "futureEvent", "id": "future"], ["type": "plan", "text": "plan without id"]], "nextCursor": "next"], includeText: false)
        XCTAssertTrue(batch.isPartial)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertNil(batch.items.first?.nativeID)
    }

    func testRedactionCoversNestedSecretsFlagsPathsAndPayloadBounds() {
        let value: [String: Any] = ["Authorization": "Bearer SECRET-ONE", "nested": ["token": "SECRET-TWO"], "command": "tool --api-key SECRET-THREE /Users/realperson/private", "key": "SECRET-FOUR"]
        let preview = WorkEvidencePrivacy.preview(value)
        for secret in ["SECRET-ONE", "SECRET-TWO", "SECRET-THREE", "SECRET-FOUR", "realperson"] { XCTAssertFalse(preview.contains(secret), secret) }
        XCTAssertTrue(preview.contains("REDACTED"))
        XCTAssertLessThanOrEqual(WorkEvidencePrivacy.preview(String(repeating: "x", count: 40_000), maximumCharacters: 100).count, 101)
    }

    func testClaudeToolResultUsesExactToolIDAndRequestUsesParentUUID() throws {
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "prompt", "message": ["content": [["type": "text", "text": "Please run checks"]]]],
            ["type": "assistant", "uuid": "assistant", "requestId": "request", "parentUuid": "prompt", "message": ["id": "message", "content": [
                ["type": "thinking", "thinking": "PRIVATE CHAIN"], ["type": "text", "text": "Running checks"],
                ["type": "tool_use", "id": "tool-one", "name": "Bash", "input": ["command": "test"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tool-one", "is_error": true, "content": "check failed"], ["type": "tool_result", "tool_use_id": "unrelated", "content": "unrelated output"]]]],
        ]
        let lines = try records.map { try JSONSerialization.data(withJSONObject: $0) }
        let batch = WorkEvidenceParser.claude(lines, nativeTurnID: "claude-request:request", includeText: true, truncated: true)
        XCTAssertTrue(batch.isPartial)
        XCTAssertEqual(batch.items.filter { $0.kind == .request }.first?.nativeID, "prompt")
        XCTAssertEqual(batch.items.filter { $0.kind == .toolCall }.first?.status, "failed")
        XCTAssertEqual(batch.items.filter { $0.kind == .toolResult }.first?.relatedID, "tool-one")
        XCTAssertFalse(batch.items.description.contains("PRIVATE CHAIN"))
        XCTAssertFalse(batch.items.description.contains("unrelated output"))
    }

    func testClaudeScopedRequestIdentityResolvesOnlyItsOwnSession() throws {
        let session = "claude:session-123"
        let native = WorkEvidenceReader.claudeRequestID(sessionID: session, turnID: session + ":claude-request:req_123")
        XCTAssertEqual(native, "req_123")
        XCTAssertEqual(WorkEvidenceReader.claudeRequestID(sessionID: session, turnID: "claude-request:req_123"), "req_123")
        XCTAssertNil(WorkEvidenceReader.claudeRequestID(sessionID: session, turnID: "claude:other:claude-request:req_123"))
        XCTAssertNil(WorkEvidenceReader.claudeRequestID(sessionID: session, turnID: session + ":claude-request:../other"))
        XCTAssertNil(WorkEvidenceReader.claudeRequestID(sessionID: session, turnID: session + ":claude-request:"))
        let line = try JSONSerialization.data(withJSONObject: ["type": "assistant", "requestId": "req_123", "message": ["content": [["type": "tool_use", "id": "tool-1", "name": "Bash"]]]])
        let batch = WorkEvidenceParser.claude([line], nativeTurnID: try XCTUnwrap(native), includeText: false, truncated: false)
        XCTAssertEqual(batch.items.filter { $0.kind == .toolCall }.count, 1)
        XCTAssertNil(batch.items.first?.preview)
    }

    func testNoRequestIsGuessedFromTemporalProximityAndNoTextWithoutOptIn() throws {
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "unlinked", "message": ["content": "unlinked prompt"]],
            ["type": "assistant", "requestId": "request", "message": ["id": "m", "content": [["type": "text", "text": "response"]]]],
        ]
        let batch = WorkEvidenceParser.claude(try records.map { try JSONSerialization.data(withJSONObject: $0) }, nativeTurnID: "claude-request:request", includeText: false, truncated: false)
        XCTAssertTrue(batch.items.allSatisfy { $0.preview == nil })
        XCTAssertFalse(batch.items.contains { $0.kind == .request })
    }

    func testBooleanExitStatusIsNotInventedAsANumber() {
        let batch = WorkEvidenceParser.codex(["data": [["id": "tool", "type": "commandExecution", "exitCode": true]]], includeText: false)
        XCTAssertNil(batch.items.first?.exitCode)
        XCTAssertEqual(batch.items.first?.status, "not recorded")
    }

    func testPayloadHashTracksEligibleContentNotOnlyNativeIdentity() throws {
        func batch(_ value: String) throws -> WorkEvidenceBatch {
            let raw: [String: Any] = ["type": "assistant", "requestId": "request", "message": ["content": [["type": "tool_use", "id": "same-tool", "name": "Read", "input": ["path": value]]]]]
            return WorkEvidenceParser.claude([try JSONSerialization.data(withJSONObject: raw)], nativeTurnID: "claude-request:request", includeText: false, truncated: false)
        }
        XCTAssertNotNil(try batch("first").items.first?.digest)
        XCTAssertNotEqual(try batch("first").items.first?.digest, try batch("second").items.first?.digest)
        let metadataOnly = WorkEvidenceParser.codex(["data": [["type": "sleep", "id": "metadata-only"]]], includeText: false)
        XCTAssertNil(metadataOnly.items.first?.digest, "A metadata ID hash is not a payload digest")
    }

    func testMalformedClaudeRecordsArePartialNotACompletePage() {
        let batch = WorkEvidenceParser.claude([Data("not json".utf8)], nativeTurnID: "claude-request:request", includeText: false, truncated: false)
        XCTAssertTrue(batch.isPartial)
        XCTAssertTrue(batch.items.isEmpty)
    }

    func testNativeEvidenceReadRejectsFIFOAndSymlinkBeforeAnyBlockingRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkEvidenceFileTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("native.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try WorkEvidenceReader.readBoundedRegularFile(fifo))
        let file = directory.appendingPathComponent("regular.jsonl")
        try Data("first\nsecond\n".utf8).write(to: file)
        let link = directory.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
        XCTAssertThrowsError(try WorkEvidenceReader.readBoundedRegularFile(link))
        let (data, partial) = try WorkEvidenceReader.readBoundedRegularFile(file, maximumBytes: 7)
        XCTAssertTrue(partial)
        XCTAssertEqual(data.count, 7)
    }
}
