@testable import BridgeCore
import Foundation
import XCTest

final class ModelTests: XCTestCase {
    func testEventRoundTripUsesVersionedSnakeCaseContract() throws {
        let event = BridgeEvent(
            source: .claude,
            type: .turnComplete,
            content: .string("done"),
            sessionID: "session-1",
            projectPath: "/tmp/project"
        )
        let data = try BridgeJSON.compactEncoder.encode(event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? String, "1.0")
        XCTAssertEqual(object["session_id"] as? String, "session-1")
        XCTAssertEqual(object["project_path"] as? String, "/tmp/project")
        let decoded = try BridgeJSON.decoder.decode(BridgeEvent.self, from: data)
        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.source, event.source)
        XCTAssertEqual(decoded.type, event.type)
        XCTAssertEqual(decoded.content, event.content)
        XCTAssertLessThan(abs(decoded.timestamp.timeIntervalSince(event.timestamp)), 0.001)
    }

    func testDecisionRejectsUnsafeTerminalCombination() {
        XCTAssertThrowsError(
            try Decision(
                label: .complete,
                confidence: 1,
                nextAgent: .codex,
                action: .complete,
                refinedPrompt: "",
                summaryForLog: "done",
                reason: "done"
            )
        )
    }

    func testDecisionDecoderAlsoEnforcesInvariants() {
        let invalid = Data(
            """
            {
              "schema_version":"1.0",
              "label":"complete",
              "confidence":1,
              "next_agent":"codex",
              "action":"complete",
              "refined_prompt":"",
              "summary_for_log":"done",
              "reason":"done"
            }
            """.utf8
        )
        XCTAssertThrowsError(try BridgeJSON.decoder.decode(Decision.self, from: invalid))
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "text": .string("hello"),
            "nested": .array([.number(1), .bool(true), .null]),
        ])
        let data = try BridgeJSON.compactEncoder.encode(value)
        XCTAssertEqual(try BridgeJSON.decoder.decode(JSONValue.self, from: data), value)
    }

    func testLegacyCachedStatusHydratesWithRulesProviderDefault() throws {
        let legacy = Data(
            """
            {
              "state": "idle",
              "active_agent": "none",
              "session": null,
              "latest_decision": null,
              "quota": {},
              "service_version": "0.1.0"
            }
            """.utf8
        )
        let status = try BridgeJSON.decoder.decode(BridgeStatus.self, from: legacy)
        XCTAssertEqual(status.provider.provider, "rules")
        XCTAssertEqual(status.provider.state, .ready)
        XCTAssertFalse(status.provider.fallbackActive)
    }

    func testLegacyAgentConfigurationDefaultsToStandardContextClaude() throws {
        let legacy = Data(
            """
            {
              "claude_command": "claude",
              "codex_command": "codex",
              "subprocess_timeout_seconds": 2700,
              "max_output_characters": 500000,
              "claude_permission_mode": "acceptEdits",
              "codex_sandbox": "workspace-write",
              "codex_skip_git_repository_check": false
            }
            """.utf8
        )

        let configuration = try BridgeJSON.decoder.decode(
            AgentConfiguration.self,
            from: legacy
        )

        XCTAssertEqual(configuration.claudeModel, "sonnet")
        XCTAssertTrue(configuration.claudeIsolatedMode)
        XCTAssertTrue(configuration.codexIsolatedMode)
        XCTAssertEqual(configuration.claudePermissionMode, "auto")
    }
}
