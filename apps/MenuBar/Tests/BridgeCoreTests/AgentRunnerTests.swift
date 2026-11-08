@testable import BridgeCore
import Foundation
import XCTest

final class AgentRunnerTests: XCTestCase {
    func testClaudeRunnerUsesBoundedJSONModeAndSurfacesAuthenticationFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-claude-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/sh
        case "$*" in
          *"--output-format json"*) ;;
          *) echo "expected --output-format json" >&2; exit 64 ;;
        esac
        case "$*" in
          *"--model sonnet"*) ;;
          *) echo "expected --model sonnet" >&2; exit 65 ;;
        esac
        case "$*" in
          *"--safe-mode"*"--no-chrome"*) ;;
          *) echo "expected isolated mode" >&2; exit 66 ;;
        esac
        printf '%s\\n' \
          '{"type":"result","is_error":true,"result":"OAuth access token has expired. Re-authenticate to continue.","session_id":"test-session"}'
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        var configuration = AgentConfiguration()
        configuration.claudeCommand = executable.path
        configuration.subprocessTimeoutSeconds = 2
        let result = try await ClaudeRunner(configuration: configuration).run(
            project: directory,
            prompt: "probe",
            nativeSessionID: nil,
            bridgeSessionID: "test-bridge"
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.sessionID, "test-session")
        XCTAssertEqual(
            result.error,
            "OAuth access token has expired. Re-authenticate to continue."
        )
        XCTAssertEqual(result.diagnostics["timed_out"], .bool(false))
    }

    func testCoordinationPreflightRequiresBothLiveAgents() async throws {
        let directory = try makeExecutableDirectory()
        let claude = directory.appendingPathComponent("claude")
        let codex = directory.appendingPathComponent("codex")
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' \
              '{"type":"result","is_error":false,"result":"CLAUDE_READY","session_id":"claude-session"}'
            """,
            to: claude
        )
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' '{"type":"thread.started","thread_id":"codex-thread"}'
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"CODEX_READY"}}'
            """,
            to: codex
        )
        var configuration = AgentConfiguration()
        configuration.claudeCommand = claude.path
        configuration.codexCommand = codex.path

        try await CoordinationAgentPreflight.requireReady(
            configuration: configuration
        )
    }

    func testCodexRunnerIgnoresUserConfigurationAndRules() async throws {
        let directory = try makeExecutableDirectory()
        let codex = directory.appendingPathComponent("codex")
        try writeExecutable(
            """
            #!/bin/sh
            case "$*" in
              *"--ignore-user-config"*"--ignore-rules"*) ;;
              *) echo "expected isolated Codex flags" >&2; exit 66 ;;
            esac
            printf '%s\\n' '{"type":"thread.started","thread_id":"codex-session"}'
            printf '%s\\n' \
              '{"type":"item.completed","item":{"type":"agent_message","text":"CODEX_ISOLATED"}}'
            """,
            to: codex
        )
        var configuration = AgentConfiguration()
        configuration.codexCommand = codex.path

        let result = try await CodexRunner(configuration: configuration).run(
            project: directory,
            prompt: "probe",
            nativeSessionID: nil,
            bridgeSessionID: "test-bridge"
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.sessionID, "codex-session")
        XCTAssertEqual(result.output, "CODEX_ISOLATED")
    }

    func testCoordinationPreflightStopsBeforeCodexWhenClaudeAuthFails() async throws {
        let directory = try makeExecutableDirectory()
        let claude = directory.appendingPathComponent("claude")
        let codex = directory.appendingPathComponent("codex")
        let codexMarker = directory.appendingPathComponent("codex-was-run")
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' \
              '{"type":"result","is_error":true,"result":"OAuth access token has expired. Re-authenticate to continue.","session_id":"claude-session"}'
            exit 1
            """,
            to: claude
        )
        try writeExecutable(
            """
            #!/bin/sh
            touch "\(codexMarker.path)"
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"CODEX_READY"}}'
            """,
            to: codex
        )
        var configuration = AgentConfiguration()
        configuration.claudeCommand = claude.path
        configuration.codexCommand = codex.path

        do {
            try await CoordinationAgentPreflight.requireReady(
                configuration: configuration
            )
            XCTFail("Expected the expired Claude credential to fail preflight")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Claude live preflight failed"))
            XCTAssertTrue(error.localizedDescription.contains("OAuth access token has expired"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexMarker.path))
    }

    private func makeExecutableDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-agent-preflight-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
