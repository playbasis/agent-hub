@testable import BridgeCore
import Foundation
import XCTest

final class TraceTests: XCTestCase {
    func testTraceIsAppendOnlyHashChainedAndDetectsTampering() throws {
        let project = try makeProject()
        let store = try ProjectStore(projectPath: project.path)
        _ = try store.appendTrace(record(provider: .claude, session: "session"))
        _ = try store.appendTrace(record(provider: .codex, session: "session"))

        XCTAssertTrue(store.verifyTrace())
        XCTAssertEqual(store.traceRecords().map(\.sequence), [1, 2])
        XCTAssertEqual(
            store.traceRecords()[1].previousHash,
            store.traceRecords()[0].recordHash
        )

        var text = try String(contentsOf: store.traceFile, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"outcome\":\"success\"", with: "\"outcome\":\"failure\"")
        try text.write(to: store.traceFile, atomically: true, encoding: .utf8)
        XCTAssertFalse(store.verifyTrace())
    }

    func testTraceSummaryRequiresClaudeCodexAndGemini() throws {
        let project = try makeProject()
        let store = try ProjectStore(projectPath: project.path)
        _ = try store.appendTrace(record(provider: .claude, session: "session"))
        _ = try store.appendTrace(record(provider: .codex, session: "session"))
        XCTAssertFalse(store.currentTraceSummary().dualProviderVerified)
        var gemini = record(provider: .gemini, session: "session")
        gemini.evidenceProviders = [.claude, .codex]
        _ = try store.appendTrace(gemini)
        XCTAssertTrue(store.currentTraceSummary().dualProviderVerified)
        XCTAssertEqual(store.currentTraceSummary().totalTokens, 30)
    }

    func testRedactorRemovesCredentialsAndHomeUser() {
        let redacted = TraceRedactor.redact(
            "Authorization: Bearer abcdefghijklmnop path=/Users/someone/secret api_key=topsecret"
        )
        XCTAssertFalse(redacted.contains("abcdefghijklmnop"))
        XCTAssertFalse(redacted.contains("topsecret"))
        XCTAssertFalse(redacted.contains("/Users/someone"))
    }

    func testLegacyConfigurationGetsSafeTraceDefaults() throws {
        let data = Data("""
        {
          "schema_version":"1.0",
          "server":{"host":"127.0.0.1","port":8742,"bearer_token":"test","max_event_bytes":1024}
        }
        """.utf8)
        let configuration = try BridgeJSON.decoder.decode(BridgeConfiguration.self, from: data)
        XCTAssertTrue(configuration.trace.enabled)
        XCTAssertTrue(configuration.trace.requireDualProvider)
        XCTAssertEqual(configuration.agents.claudeEffort, "high")
        XCTAssertEqual(configuration.agents.codexReasoningEffort, "high")
    }

    private func record(provider: TraceProvider, session: String) -> TraceRecord {
        TraceRecord(
            id: UUID().uuidString,
            sequence: 0,
            timestamp: Date(),
            bridgeSessionID: session,
            turnID: UUID().uuidString,
            eventID: nil,
            provider: provider,
            nativeSessionID: nil,
            nativeTurnID: nil,
            identity: ProviderIdentity(requestedModel: "requested", resolvedModel: "requested"),
            usage: TokenUsage(input: 4, output: 6, total: 10, provenance: .providerReported),
            tools: [],
            durationMilliseconds: 100,
            timeToFirstTokenMilliseconds: nil,
            outcome: "success",
            exitCode: 0,
            completeness: .complete,
            warnings: [],
            budgetReserved: nil,
            budgetRemaining: nil,
            estimatedCostUSD: nil,
            costProvenance: .unavailable,
            adapterVersion: "test/1",
            previousHash: nil,
            recordHash: ""
        )
    }

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        return project
    }
}
